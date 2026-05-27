#!/bin/bash

# Build, sign, notarize, and DMG-package SmoothyREC for distribution.
#
# REQUIRES a paid Apple Developer account. Without one, use ./build-dev.sh +
# ./create-dmg.sh to ship an unsigned build (your users will need to
# right-click → Open the first launch).
#
# Required environment variables (or edit the defaults below):
#   DEVELOPER_ID   - e.g. "Developer ID Application: Your Name (TEAM_ID)"
#   NOTARY_PROFILE - the keychain profile name created with:
#                      xcrun notarytool store-credentials NOTARY_PROFILE \
#                        --apple-id you@example.com \
#                        --team-id  TEAM_ID \
#                        --password app-specific-password
#
# Optional:
#   VERSION        - overrides the version stamped on the DMG filename (defaults to 1.0.0)

set -euo pipefail

# Configuration
APP_NAME="SmoothyREC"
BUNDLE_ID="com.smoothyrec.SmoothyREC"
VERSION="${VERSION:-1.0.0}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_NAME="$APP_NAME-$VERSION.dmg"
VOLUME_NAME="$APP_NAME $VERSION"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() {
    echo -e "${RED}error: $1${NC}" >&2
    exit 1
}

# Preflight
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode from the App Store."
command -v xcrun       >/dev/null 2>&1 || die "xcrun not found. Install the Xcode command line tools."

if [[ -z "$DEVELOPER_ID" ]]; then
    die "DEVELOPER_ID is empty.
       Set it before running, e.g.:
         export DEVELOPER_ID='Developer ID Application: Your Name (TEAM_ID)'
       List signing identities you already have with:
         security find-identity -v -p codesigning"
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
    die "NOTARY_PROFILE is empty.
       Create one once with:
         xcrun notarytool store-credentials NOTARY_PROFILE \\
           --apple-id you@example.com \\
           --team-id  TEAM_ID \\
           --password app-specific-password
       Then re-run with:
         export NOTARY_PROFILE=NOTARY_PROFILE"
fi

# Confirm the identity actually exists in the keychain before we go any further
if ! security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID"; then
    die "Developer ID '$DEVELOPER_ID' not found in the keychain.
       Run 'security find-identity -v -p codesigning' to see what's available."
fi

echo -e "${GREEN}Building $APP_NAME v$VERSION${NC}"
echo "=========================================="

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build & archive
echo -e "${YELLOW}Archiving with signing...${NC}"
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

# Export
echo -e "${YELLOW}Exporting...${NC}"
mkdir -p "$EXPORT_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/"

# Re-sign deep with hardened runtime entitlements (xcodebuild's signing alone
# can miss embedded frameworks; --deep + --timestamp + --options runtime is
# what notarization requires).
echo -e "${YELLOW}Signing app...${NC}"
codesign --force --deep --sign "$DEVELOPER_ID" \
    --options runtime \
    --timestamp \
    --entitlements "SmoothyREC/SmoothyREC.entitlements" \
    "$EXPORT_PATH/$APP_NAME.app"

echo -e "${YELLOW}Verifying signature...${NC}"
codesign --verify --deep --strict --verbose=2 "$EXPORT_PATH/$APP_NAME.app" || \
    die "codesign verification failed — check the output above."

# Build the DMG using create-dmg.sh (it knows about background, layout, etc.)
echo -e "${YELLOW}Creating DMG...${NC}"
./create-dmg.sh "$EXPORT_PATH" "$BUILD_DIR" "$DMG_NAME" "$VOLUME_NAME" || \
    die "DMG creation failed."

# Sign the DMG itself (Gatekeeper checks both)
echo -e "${YELLOW}Signing DMG...${NC}"
codesign --force --sign "$DEVELOPER_ID" --timestamp "$BUILD_DIR/$DMG_NAME" || \
    die "DMG signing failed."

# Notarize
echo -e "${YELLOW}Submitting for notarization (this can take 5-15 minutes)...${NC}"
NOTARY_OUTPUT=$(xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1) || {
        echo "$NOTARY_OUTPUT" >&2
        die "Notarization submission failed. The output above will include a submission ID; fetch the log with:
       xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
    }

echo "$NOTARY_OUTPUT"

if ! echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
    die "Notarization did NOT return 'Accepted'. See output above for the submission ID, then run:
       xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
fi

# Staple
echo -e "${YELLOW}Stapling notarization ticket...${NC}"
xcrun stapler staple "$BUILD_DIR/$DMG_NAME" || die "Stapling failed."

# Verify the staple — this is what catches the "shipped a broken DMG" bug
echo -e "${YELLOW}Verifying stapled DMG with Gatekeeper...${NC}"
xcrun stapler validate "$BUILD_DIR/$DMG_NAME" || die "Stapler validate failed."
spctl --assess --type open --context context:primary-signature -vv "$BUILD_DIR/$DMG_NAME" || \
    die "Gatekeeper (spctl) refused the DMG. Check the output above."

echo ""
echo -e "${GREEN}Build complete!${NC}"
echo "=========================================="
echo -e "DMG: ${YELLOW}$BUILD_DIR/$DMG_NAME${NC}"
echo -e "Notarized and stapled. Safe to upload to your website."
