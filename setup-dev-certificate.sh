#!/bin/bash
#
# One-time setup: creates a self-signed code-signing identity so SmoothyREC's
# Screen Recording / Camera / Microphone permissions PERSIST across rebuilds
# and across the macOS "quit and reopen" relaunch dance.
#
# Why this is needed: macOS keys those privacy permissions to the app's code
# signature. With an ad-hoc (no-identity) signature, every rebuild produces a
# different signature hash, so the permission entry gets orphaned and silently
# dropped when macOS asks you to relaunch.
#
# Run once per machine. After this, ./build-dev.sh will use the stable identity
# automatically and permissions will stick.

set -euo pipefail

CERT_NAME="SmoothyREC Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() {
    echo -e "${RED}error: $1${NC}" >&2
    exit 1
}

command -v openssl  >/dev/null 2>&1 || die "openssl not found (this should never happen on macOS)."
command -v security >/dev/null 2>&1 || die "security CLI not found (should ship with macOS)."

# Already installed? Skip.
# Note: we use `-p codesigning` WITHOUT `-v`. Self-signed certs are marked
# "not trusted" by macOS's trust evaluator (CSSMERR_TP_NOT_TRUSTED), so `-v`
# would hide them — but codesign can use them just fine by SHA-1 hash. TCC
# (the privacy system) keys permissions to the signature hash, not the trust
# chain, so untrusted-but-stable signatures persist permissions correctly.
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo -e "${GREEN}Certificate '$CERT_NAME' already installed.${NC}"
    echo "Run ./build-dev.sh to build."
    exit 0
fi

echo "Creating self-signed code-signing identity '$CERT_NAME'..."
echo "(This is local to your machine. End users won't see this cert.)"
echo ""

TMPDIR=$(mktemp -d -t smoothyrec-cert)
trap 'rm -rf "$TMPDIR"' EXIT

KEY="$TMPDIR/key.pem"
CRT="$TMPDIR/cert.pem"
P12="$TMPDIR/identity.p12"

# Generate a 10-year cert with codeSigning EKU. The -addext flag puts the
# extension into the cert itself (older approaches that used a config file
# often produced certs that codesign couldn't use).
openssl req -x509 -newkey rsa:2048 \
    -keyout "$KEY" \
    -out    "$CRT" \
    -days   3650 \
    -nodes \
    -subj   "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    >/dev/null 2>&1 || die "openssl failed to generate the cert."

# Bundle key + cert into a PKCS#12. macOS's `security import` only registers
# them as a *paired* signing identity when they arrive together this way.
#
# `-macalg sha1` + `-keypbe PBE-SHA1-3DES` + `-certpbe PBE-SHA1-3DES` keep
# the bundle compatible with Apple's `security` CLI, which only understands
# the legacy SHA-1 PBE algorithms. Modern OpenSSL 3.x defaults to SHA-256-based
# algorithms that produce a "MAC verification failed" error on import.
# A throwaway password — Apple's `security import` refuses empty PKCS#12
# passwords with a misleading "MAC verification failed" error.
P12_PASS="smoothyrec-local"

openssl pkcs12 -export \
    -inkey "$KEY" \
    -in    "$CRT" \
    -out   "$P12" \
    -name  "$CERT_NAME" \
    -macalg sha1 \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -passout pass:"$P12_PASS" \
    2>/dev/null || die "openssl pkcs12 export failed."

# Import into the login keychain, granting codesign access.
echo -e "${YELLOW}macOS will likely prompt for your login password to authorize the import.${NC}"
security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    || die "security import failed."

# Without this, codesign would get a UI prompt on every signing attempt.
# The -k "" empty-password is the keychain unlock password; macOS will prompt
# the user for it interactively if needed.
security set-key-partition-list \
    -S apple-tool:,apple-default:,codesign: \
    -s \
    -k "" \
    "$KEYCHAIN" \
    >/dev/null 2>&1 \
    || echo -e "${YELLOW}note: couldn't pre-authorize codesign (you may get a one-time keychain prompt on first build).${NC}"

# Verify (without -v — self-signed certs are flagged not-trusted, which is fine)
if ! security find-identity -p codesigning | grep -q "$CERT_NAME"; then
    die "Cert imported but 'security find-identity' doesn't see it. Open Keychain Access and check the login keychain for '$CERT_NAME'."
fi

echo ""
echo -e "${GREEN}✓ '$CERT_NAME' is installed.${NC}"
echo ""
echo "Next steps:"
echo "  1. ./build-dev.sh                              (will now use stable identity)"
echo "  2. open build/SmoothyREC.app                   (or copy to /Applications)"
echo "  3. Grant Screen Recording / Camera / Microphone in System Settings"
echo "  4. Quit + reopen when macOS asks — this time it will stick"
echo ""
echo "Note: macOS will still show 'unidentified developer' on first launch."
echo "      Right-click → Open the first time, then it's fine forever."
