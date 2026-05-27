#!/bin/bash
#
# Quick development build with stable code signing.
#
# Usage:
#   ./setup-dev-certificate.sh   # one-time, creates a stable signing identity
#   ./build-dev.sh               # builds + signs
#   open build/SmoothyREC.app    # runs
#
# First time: grant Screen Recording / Camera / Mic in System Settings.
# With the stable identity, permissions PERSIST across rebuilds and across
# macOS's "quit and reopen" prompt. Without it, ad-hoc signing means macOS
# loses track of the permission every time you rebuild OR relaunch.

set -euo pipefail

APP_NAME="SmoothyREC"
BUILD_DIR="build"
CERT_NAME="SmoothyREC Dev Signing"

YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "Building $APP_NAME..."

# Detect signing identity up front so we can warn before wasting a build.
# `-p codesigning` without `-v` because self-signed certs are flagged
# "not trusted" by the trust evaluator but codesign uses them fine by SHA-1.
SIGN_IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | grep "$CERT_NAME" | head -1 | awk '{print $2}' || true)

if [[ -z "$SIGN_IDENTITY" ]]; then
    cat <<EOF
${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${RED}WARNING: no stable signing identity found.${NC}

This build will be ad-hoc signed, which means macOS will:
  - DROP Screen Recording permission every time you rebuild
  - DROP it again after the 'quit and reopen' prompt
  - Refuse to associate any granted permission with this app reliably

Fix it in one step:
  ${YELLOW}./setup-dev-certificate.sh${NC}

Then re-run this build. Permissions will persist after that.
${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

EOF
fi

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
[ -d "$APP_PATH" ] || { echo -e "${RED}Build failed${NC}"; exit 1; }

cp -R "$APP_PATH" "$BUILD_DIR/"
FINAL_APP="$BUILD_DIR/$APP_NAME.app"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing with stable identity: $CERT_NAME"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --entitlements "SmoothyREC/SmoothyREC.entitlements" \
        "$FINAL_APP"

    # Confirm we got what we wanted (not silently fell back to ad-hoc).
    SIG=$(codesign -dvv "$FINAL_APP" 2>&1 | awk -F= '/^Signature=/{print $2}')
    if [[ "$SIG" == "adhoc" ]]; then
        echo -e "${RED}Signing fell back to ad-hoc despite finding an identity. Run ./setup-dev-certificate.sh again.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Signed (stable identity → Screen Recording permission will persist).${NC}"
else
    echo -e "${YELLOW}Ad-hoc signing (you were warned). Run ./setup-dev-certificate.sh to fix.${NC}"
    codesign --force --deep --sign '-' \
        --entitlements "SmoothyREC/SmoothyREC.entitlements" \
        "$FINAL_APP"
fi

echo ""
echo "✓ Built: $FINAL_APP"
echo "Run: open $FINAL_APP"
