#!/bin/bash
#
# Creates a SmoothyREC.dmg installer.
#
# Usage:
#   ./create-dmg.sh                                       # uses defaults
#   ./create-dmg.sh <build_dir>                           # search for .app under build_dir
#   ./create-dmg.sh <build_dir> <output_dir>              # also override output dir
#   ./create-dmg.sh <build_dir> <output_dir> <dmg_name>   # override output filename
#   ./create-dmg.sh <build_dir> <output_dir> <dmg_name> <volume_name>
#
# Requires `create-dmg` (brew install create-dmg).

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() {
    echo -e "${RED}error: $1${NC}" >&2
    exit 1
}

# Defaults
APP_NAME="SmoothyREC"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR="${1:-build}"
OUTPUT_DIR="${2:-.}"
DMG_NAME="${3:-${APP_NAME}.dmg}"
VOLUME_NAME="${4:-${APP_NAME} Installer}"

command -v create-dmg >/dev/null 2>&1 || die "create-dmg not installed. Run: brew install create-dmg"

# Find the .app bundle
if   [ -d "${BUILD_DIR}/${APP_BUNDLE}" ];                                    then APP_PATH="${BUILD_DIR}/${APP_BUNDLE}"
elif [ -d "${BUILD_DIR}/export/${APP_BUNDLE}" ];                             then APP_PATH="${BUILD_DIR}/export/${APP_BUNDLE}"
elif [ -d "${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_BUNDLE}" ]; then APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_BUNDLE}"
elif [ -d "${BUILD_DIR}/DerivedData/Build/Products/Debug/${APP_BUNDLE}" ];   then APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/Debug/${APP_BUNDLE}"
else
    die "Could not find ${APP_BUNDLE}. Searched under '${BUILD_DIR}'. Build it first (./build-dev.sh)."
fi

echo -e "${GREEN}Found app bundle: ${APP_PATH}${NC}"

# Stage DMG contents in a temp dir
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT
echo -e "${YELLOW}Staging in ${TEMP_DIR}...${NC}"

cp -R "${APP_PATH}" "${TEMP_DIR}/"

# First-launch instructions (especially important for unsigned builds — macOS
# Gatekeeper will show "cannot be opened because Apple cannot check it for
# malicious software" otherwise and panicked users will trash the app).
cat > "${TEMP_DIR}/READ ME FIRST.txt" <<'README'
SmoothyREC — First Launch
=========================

1. Drag SmoothyREC.app to the Applications folder (shown to the right).
2. Open Applications.
3. RIGHT-CLICK (or Control-click) SmoothyREC and choose "Open".
4. macOS will show a security warning — click "Open" once.

   You only have to do this the first time. After that you can launch
   SmoothyREC normally from Spotlight, Launchpad, or your Applications folder.

Why?
   SmoothyREC isn't distributed through the Mac App Store, so macOS asks for
   one extra confirmation on first launch. After that it's a regular app.

After launching:
   SmoothyREC will ask for Screen Recording, Camera, and Microphone
   permissions in System Settings. Grant the ones you want to use, then
   relaunch when prompted.

Troubleshooting:
   https://github.com/alibahrawy/SmoothyREC
README

# Background image (540x380, gradient with the app name)
BG_DIR="${TEMP_DIR}/.background"
mkdir -p "${BG_DIR}"

if command -v convert >/dev/null 2>&1; then
    convert -size 540x380 \
        gradient:'#f5f5f5'-'#e0e0e0' \
        -pointsize 30 \
        -fill '#333333' \
        -gravity center \
        -annotate +0+0 "${APP_NAME}" \
        "${BG_DIR}/background.png"
else
    # Fallback: solid light-gray background via Python + sips
    python3 - "${BG_DIR}/background.png" <<'PYTHON_EOF'
import os, subprocess, sys, tempfile
out_png = sys.argv[1]
width, height = 540, 380
pixels = bytearray()
for y in range(height):
    gray = int(245 - (y / height) * 30)
    pixels.extend([gray, gray, gray] * width)

ppm_path = out_png + '.ppm'
with open(ppm_path, 'wb') as f:
    f.write(b'P6\n')
    f.write(f'{width} {height}\n255\n'.encode())
    f.write(bytes(pixels))
subprocess.run(['sips', '-s', 'format', 'png', ppm_path, '--out', out_png],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.remove(ppm_path)
PYTHON_EOF
fi

# Wipe any existing DMG at the target location
mkdir -p "${OUTPUT_DIR}"
if [ -f "${OUTPUT_DIR}/${DMG_NAME}" ]; then
    echo -e "${YELLOW}Removing existing ${DMG_NAME}...${NC}"
    rm "${OUTPUT_DIR}/${DMG_NAME}"
fi

echo -e "${GREEN}Building ${DMG_NAME}...${NC}"
create-dmg \
    --volname "${VOLUME_NAME}" \
    --background "${BG_DIR}/background.png" \
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

# Verify
[ -f "${OUTPUT_DIR}/${DMG_NAME}" ] || die "create-dmg reported success but the file isn't there."

DMG_SIZE=$(du -h "${OUTPUT_DIR}/${DMG_NAME}" | cut -f1)
echo ""
echo -e "${GREEN}✓ ${DMG_NAME} created (${DMG_SIZE})${NC}"
echo "  Location: ${OUTPUT_DIR}/${DMG_NAME}"
echo ""
echo "Quick sanity check (mount + ls + unmount):"
hdiutil attach "${OUTPUT_DIR}/${DMG_NAME}" -readonly -noverify -noautofsck >/dev/null
MOUNT=$(hdiutil info | awk -v vol="${VOLUME_NAME}" '$0 ~ vol {print $1}' | tail -1)
if [ -z "$MOUNT" ]; then
    # Fallback: locate via /Volumes
    MOUNT=$(ls -td /Volumes/* | head -1)
fi
ls -1 "/Volumes/${VOLUME_NAME}" 2>/dev/null || true
hdiutil detach "/Volumes/${VOLUME_NAME}" >/dev/null 2>&1 || true
