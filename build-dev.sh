#!/bin/bash

# Quick development build with stable code signing
# Run: ./build-dev.sh
# Then: ./build-dev.sh && open build/SmoothyREC.app
#
# First time: Grant Screen Recording / Camera / Mic permission to the app in
# System Settings > Privacy & Security. With the stable signing identity,
# permissions persist across subsequent rebuilds.

set -e

APP_NAME="SmoothyREC"
BUILD_DIR="build"

echo "Building $APP_NAME..."

# Clean and build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild build \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -destination "platform=macOS" \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -3

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Debug/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: Build failed"
    exit 1
fi

cp -R "$APP_PATH" "$BUILD_DIR/"
FINAL_APP="$BUILD_DIR/$APP_NAME.app"

# Try stable signing with dev certificate if it exists
CERT_NAME="SmoothyREC Dev Signing"
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME" | head -1 | awk '{print $2}')

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with stable identity: $CERT_NAME"
    codesign --force --sign "$SIGN_IDENTITY" --deep "$FINAL_APP" 2>/dev/null || \
    codesign --force --sign '-' --deep "$FINAL_APP"
else
    echo "Ad-hoc signing (permissions may reset between builds)"
    codesign --force --sign '-' --deep "$FINAL_APP"
fi

echo ""
echo "✓ Built: $FINAL_APP"
echo ""
echo "Run: open $FINAL_APP"
echo ""
echo "TIP: If Screen Recording permission keeps resetting, create a stable"
echo "signing identity by running: ./setup-dev-certificate.sh"