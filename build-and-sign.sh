#!/bin/bash

# Build and sign script for SmoothyREC with Developer ID
# This script builds, signs, notarizes, and creates a distributable DMG

set -e

# Configuration - EDIT THESE VALUES
APP_NAME="SmoothyREC"
BUNDLE_ID="com.smoothyrec.SmoothyREC"
VERSION="1.0.0"
DEVELOPER_ID="YOUR_DEVELOPER_ID"  # e.g., "Developer ID Application: Your Name (TEAM_ID)"
NOTARY_PROFILE="AC_PASSWORD"      # Keychain profile name for notarization
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_NAME="$APP_NAME-$VERSION.dmg"
VOLUME_NAME="$APP_NAME $VERSION"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check for required tools
if ! command -v xcodebuild &> /dev/null; then
    echo -e "${RED}Error: xcodebuild not found. Please install Xcode.${NC}"
    exit 1
fi

if [ "$DEVELOPER_ID" == "YOUR_DEVELOPER_ID" ]; then
    echo -e "${RED}Error: Please edit this script and set your DEVELOPER_ID${NC}"
    exit 1
fi

echo -e "${GREEN}Building $APP_NAME v$VERSION${NC}"
echo "=========================================="

# Clean previous builds
if [ -d "$BUILD_DIR" ]; then
    echo -e "${YELLOW}Cleaning previous builds...${NC}"
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

# Build and archive with signing
echo -e "${YELLOW}Building and archiving with signing...${NC}"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    ONLY_ACTIVE_ARCH=NO

# Export and sign app
echo -e "${YELLOW}Exporting and signing app...${NC}"
mkdir -p "$EXPORT_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/"

# Sign the app
echo -e "${YELLOW}Signing app...${NC}"
codesign --force --deep --sign "$DEVELOPER_ID" \
    --entitlements "SmoothyREC/SmoothyREC.entitlements" \
    "$EXPORT_PATH/$APP_NAME.app"

# Verify signature
echo -e "${YELLOW}Verifying signature...${NC}"
codesign --verify --verbose "$EXPORT_PATH/$APP_NAME.app"

# Create DMG
echo -e "${YELLOW}Creating DMG...${NC}"

DMG_TEMP="$BUILD_DIR/dmg_temp"
mkdir -p "$DMG_TEMP"
cp -R "$EXPORT_PATH/$APP_NAME.app" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$BUILD_DIR/$DMG_NAME"

# Notarize
echo -e "${YELLOW}Submitting for notarization...${NC}"
xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# Staple notarization
echo -e "${YELLOW}Stapling notarization...${NC}"
xcrun stapler staple "$BUILD_DIR/$DMG_NAME"

echo -e "${GREEN}Build complete!${NC}"
echo "=========================================="
echo -e "DMG location: ${YELLOW}$BUILD_DIR/$DMG_NAME${NC}"
echo ""
echo -e "${GREEN}The app is ready for distribution!${NC}"
