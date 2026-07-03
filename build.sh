#!/bin/bash

# Build script for SmoothyREC
# This script builds the app and creates a DMG for distribution

set -e

# Configuration
APP_NAME="SmoothyREC"
BUNDLE_ID="com.smoothyrec.SmoothyREC"
VERSION="1.1.0"
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

echo -e "${GREEN}Building $APP_NAME v$VERSION${NC}"
echo "=========================================="

# Clean previous builds
if [ -d "$BUILD_DIR" ]; then
    echo -e "${YELLOW}Cleaning previous builds...${NC}"
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

# Build and archive
echo -e "${YELLOW}Building and archiving...${NC}"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO

# Export app
echo -e "${YELLOW}Exporting app...${NC}"
mkdir -p "$EXPORT_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/"

# Create DMG
echo -e "${YELLOW}Creating DMG...${NC}"

# Create temporary directory for DMG contents
DMG_TEMP="$BUILD_DIR/dmg_temp"
mkdir -p "$DMG_TEMP"

# Copy app to temp directory
cp -R "$EXPORT_PATH/$APP_NAME.app" "$DMG_TEMP/"

# Create symbolic link to Applications folder
ln -s /Applications "$DMG_TEMP/Applications"

# Create the DMG
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$BUILD_DIR/$DMG_NAME"

echo -e "${GREEN}Build complete!${NC}"
echo "=========================================="
echo -e "App location: ${YELLOW}$EXPORT_PATH/$APP_NAME.app${NC}"
echo -e "DMG location: ${YELLOW}$BUILD_DIR/$DMG_NAME${NC}"
echo ""
echo "To distribute:"
echo "  1. Sign the app with your Developer ID:"
echo "     codesign --force --deep --sign 'Developer ID Application: Your Name' $EXPORT_PATH/$APP_NAME.app"
echo ""
echo "  2. Notarize the app:"
echo "     xcrun notarytool submit $BUILD_DIR/$DMG_NAME --keychain-profile 'AC_PASSWORD' --wait"
echo ""
echo "  3. Staple the notarization:"
echo "     xcrun stapler staple $BUILD_DIR/$DMG_NAME"
