#!/bin/bash
#
# Package SmoothyREC into a professional DMG installer
# This script uses create-dmg (brew install create-dmg)
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME="SmoothyREC"
VOLUME_NAME="SmoothyREC Installer"

# Check dependencies
if ! command -v create-dmg &> /dev/null; then
    echo -e "${RED}✗ create-dmg not found${NC}"
    echo "Install with: brew install create-dmg"
    exit 1
fi

echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo -e "${BLUE}  SmoothyREC DMG Creator${NC}"
echo -e "${BLUE}═══════════════════════════════════════${NC}"
echo ""

# Find the built app
BUILD_DIR="${1:-build}"
OUTPUT_DIR="${2:-.}"

# Search for app in common locations
APP_PATH=""
for path in \
    "${BUILD_DIR}/${APP_NAME}.app" \
    "${BUILD_DIR}/export/${APP_NAME}.app" \
    "${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"; do
    if [ -d "$path" ]; then
        APP_PATH="$path"
        break
    fi
done

if [ -z "$APP_PATH" ]; then
    echo -e "${RED}Error: Could not find ${APP_NAME}.app${NC}"
    echo "Searched in:"
    echo "  - ${BUILD_DIR}/${APP_NAME}.app"
    echo "  - ${BUILD_DIR}/export/${APP_NAME}.app"
    echo "  - ${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"
    echo ""
    echo "Usage: ./create-dmg.sh [build_dir] [output_dir]"
    exit 1
fi

echo -e "${GREEN}✓ Found:${NC} $(basename "$APP_PATH")"
echo -e "${YELLOW}  Location:${NC} $APP_PATH"
echo ""

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

cp -R "$APP_PATH" "$TEMP_DIR/"

# Create background
mkdir -p "$TEMP_DIR/.background"

echo -e "${YELLOW}Creating background image...${NC}"

# Create background using Python (always available on macOS)
python3 << 'EOF'
import sys
import os

bg_path = os.path.join(os.environ['TEMP_DIR'], '.background', 'background.png')

# Use PIL if available, otherwise create PPM and convert

try:
    from PIL import Image, ImageDraw, ImageFont
    
    width, height = 540, 380
    img = Image.new('RGB', (width, height), '#f5f5f5')
    draw = ImageDraw.Draw(img)
    
    # Draw gradient
    for y in range(height):
        gray = int(245 - (y / height) * 30)
        draw.line([(0, y), (width, y)], fill=(gray, gray, gray))
    
    # Draw text
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 30)
    except:
        font = ImageFont.load_default()
    
    text = "SmoothyREC"
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    x = (width - text_width) // 2
    y = 40
    
    draw.text((x, y), text, fill='#333333', font=font)
    img.save(bg_path)
    print(f"Created background at {bg_path}")
    
except ImportError:
    # Fallback: create simple PPM and convert with sips
    import subprocess
    
    width, height = 540, 380
    pixels = []
    
    for y in range(height):
        gray = int(245 - (y / height) * 30)
        for x in range(width):
            pixels.extend([gray, gray, gray])
    
    ppm_path = bg_path.replace('.png', '.ppm')
    with open(ppm_path, 'wb') as f:
        f.write(b'P6\n')
        f.write(f'{width} {height}\n255\n'.encode())
        f.write(bytes(pixels))
    
    subprocess.run(['sips', '-s', 'format', 'png', ppm_path, '--out', bg_path], 
                   capture_output=True)
    os.remove(ppm_path)
    print(f"Created background using sips at {bg_path}")
EOF

echo -e "${GREEN}✓ Background created${NC}"
echo ""

# Remove old DMG
if [ -f "${OUTPUT_DIR}/${APP_NAME}.dmg" ]; then
    echo -e "${YELLOW}Removing old DMG...${NC}"
    rm "${OUTPUT_DIR}/${APP_NAME}.dmg"
fi

# Create DMG
echo -e "${YELLOW}Creating DMG with create-dmg...${NC}"
echo ""

create-dmg \
    --volname "$VOLUME_NAME" \
    --background "$TEMP_DIR/.background/background.png" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 135 190 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 405 190 \
    --format UDZO \
    --no-internet-enable \
    "${OUTPUT_DIR}/${APP_NAME}.dmg" \
    "$TEMP_DIR"

# Verify
if [ -f "${OUTPUT_DIR}/${APP_NAME}.dmg" ]; then
    SIZE=$(du -h "${OUTPUT_DIR}/${APP_NAME}.dmg" | cut -f1)
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ DMG Created Successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}File:${NC}     ${OUTPUT_DIR}/${APP_NAME}.dmg"
    echo -e "${BLUE}Size:${NC}     $SIZE"
    echo ""
    echo "Layout:"
    echo "  [SmoothyREC.app]  →  [Applications]"
    echo "       (135,190)          (405,190)"
    echo ""
else
    echo -e "${RED}✗ DMG creation failed${NC}"
    exit 1
fi
