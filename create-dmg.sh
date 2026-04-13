#!/bin/bash

# create-dmg.sh
# Creates a professional DMG installer for SmoothyREC using create-dmg
# Install create-dmg via: brew install create-dmg

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
APP_NAME="SmoothyREC"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
VOLUME_NAME="${APP_NAME} Installer"

# Check if create-dmg is installed
if ! command -v create-dmg &> /dev/null; then
    echo -e "${RED}Error: create-dmg is not installed${NC}"
    echo "Install it with: brew install create-dmg"
    exit 1
fi

# Parse arguments
BUILD_DIR="${1:-build}"
OUTPUT_DIR="${2:-.}"

# Find the .app bundle
if [ -d "${BUILD_DIR}/${APP_BUNDLE}" ]; then
    APP_PATH="${BUILD_DIR}/${APP_BUNDLE}"
elif [ -d "${BUILD_DIR}/export/${APP_BUNDLE}" ]; then
    APP_PATH="${BUILD_DIR}/export/${APP_BUNDLE}"
elif [ -d "${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_BUNDLE}" ]; then
    APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_BUNDLE}"
else
    echo -e "${RED}Error: Could not find ${APP_BUNDLE}${NC}"
    echo "Searched in:"
    echo "  - ${BUILD_DIR}/${APP_BUNDLE}"
    echo "  - ${BUILD_DIR}/export/${APP_BUNDLE}"
    echo "  - ${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_BUNDLE}"
    echo ""
    echo "Usage: $0 [build_directory] [output_directory]"
    exit 1
fi

echo -e "${GREEN}Found app bundle: ${APP_PATH}${NC}"

# Create temporary directory for DMG contents
TEMP_DIR=$(mktemp -d)
echo -e "${YELLOW}Working in temporary directory: ${TEMP_DIR}${NC}"

# Copy app to temp directory
cp -R "${APP_PATH}" "${TEMP_DIR}/"

# Create a background image for the DMG window
BACKGROUND_DIR="${TEMP_DIR}/.background"
mkdir -p "${BACKGROUND_DIR}"

# Create a simple background image using sips and built-in tools
echo -e "${YELLOW}Creating background image...${NC}"

# Create a simple gradient background (540x380 pixels - standard DMG window size)
osascript <<EOF > /dev/null 2>&1
tell application "Finder"
    set bgPath to "${BACKGROUND_DIR}/background.png"
end tell
EOF

# Alternative: Create background using ImageMagick if available, otherwise use solid color
if command -v convert &> /dev/null; then
    # Create a nice gradient background with ImageMagick
    convert -size 540x380 \
        gradient:'#f5f5f5'-'#e0e0e0' \
        -pointsize 30 \
        -fill '#333333' \
        -gravity center \
        -annotate +0+0 "${APP_NAME}" \
        "${BACKGROUND_DIR}/background.png"
else
    # Create a simple colored background using sips
    # Create a raw RGB file and convert to PNG
    python3 << PYTHON_EOF
import struct

width, height = 540, 380
# Light gray gradient
pixels = []
for y in range(height):
    gray = int(245 - (y / height) * 30)
    for x in range(width):
        pixels.extend([gray, gray, gray])

# Write as PPM then convert
with open('${BACKGROUND_DIR}/background.ppm', 'wb') as f:
    f.write(b'P6\n')
    f.write(f'{width} {height}\n255\n'.encode())
    f.write(bytes(pixels))

import subprocess
subprocess.run(['sips', '-s', 'format', 'png', '${BACKGROUND_DIR}/background.ppm', '--out', '${BACKGROUND_DIR}/background.png'])
import os
os.remove('${BACKGROUND_DIR}/background.ppm')
PYTHON_EOF
fi

# Set icon positions and create DMG
echo -e "${GREEN}Creating DMG with create-dmg...${NC}"

# Remove existing DMG if present
if [ -f "${OUTPUT_DIR}/${DMG_NAME}" ]; then
    echo -e "${YELLOW}Removing existing DMG...${NC}"
    rm "${OUTPUT_DIR}/${DMG_NAME}"
fi

# Create the DMG using create-dmg
create-dmg \
    --volname "${VOLUME_NAME}" \
    --background "${BACKGROUND_DIR}/background.png" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "${APP_BUNDLE}" 135 190 \
    --hide-extension "${APP_BUNDLE}" \
    --app-drop-link 405 190 \
    --no-internet-enable \
    --format UDZO \
    "${OUTPUT_DIR}/${DMG_NAME}" \
    "${TEMP_DIR}"

# Check if DMG was created successfully
if [ -f "${OUTPUT_DIR}/${DMG_NAME}" ]; then
    # Get file size
    DMG_SIZE=$(du -h "${OUTPUT_DIR}/${DMG_NAME}" | cut -f1)
    echo -e "${GREEN}✓ DMG created successfully!${NC}"
    echo "  Location: ${OUTPUT_DIR}/${DMG_NAME}"
    echo "  Size: ${DMG_SIZE}"
    echo ""
    echo -e "${GREEN}DMG Contents:${NC}"
    hdiutil attach "${OUTPUT_DIR}/${DMG_NAME}" -readonly -noverify -noautofsck 2>/dev/null | grep "/Volumes/${VOLUME_NAME}" | while read -r line; do
        MOUNT_POINT=$(echo "$line" | awk '{print $3}')
        ls -1 "${MOUNT_POINT}"
        hdiutil detach "${MOUNT_POINT}" 2>/dev/null
    done
else
    echo -e "${RED}Error: DMG creation failed${NC}"
    exit 1
fi

# Clean up
rm -rf "${TEMP_DIR}"
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Show DMG info
echo ""
echo -e "${GREEN}DMG Info:${NC}"
hdiutil imageinfo "${OUTPUT_DIR}/${DMG_NAME}" | grep -E "(Format|Size|Compressed)"

exit 0
