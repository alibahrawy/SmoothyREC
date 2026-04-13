#!/bin/bash

# One-time setup: Creates a self-signed certificate for stable code signing.
# After running this, grant Screen Recording permission ONCE in System Settings.
# It will persist across rebuilds when using ./build-dev.sh

set -e

CERT_NAME="SmoothyREC Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Check if certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists!"
    echo "No action needed. Just run ./build-dev.sh to build."
    exit 0
fi

echo "Creating self-signed code signing certificate..."
echo "This certificate will be used to sign SmoothyREC so that"
echo "Screen Recording / Camera / Microphone permissions persist."
echo ""

# Create certificate config
CERT_CONFIG=$(mktemp /tmp/smoothyrec-cert.XXXXXX)
cat > "$CERT_CONFIG" <<EOF
[ req ]
default_bits       = 2048
default_keyfile    = privkey.pem
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = v3_ca

[ req_distinguished_name ]
commonName         = $CERT_NAME

[ v3_ca ]
basicConstraints   = critical, CA:FALSE
keyUsage           = critical, digitalSignature
extendedKeyUsage   = codeSigning
EOF

# Generate certificate
openssl req -x509 -new -newkey rsa:2048 \
    -keyout /tmp/smoothyrec-dev.key \
    -out /tmp/smoothyrec-dev.crt \
    -days 3650 -nodes \
    -config "$CERT_CONFIG" 2>/dev/null

# Import into login keychain
security import /tmp/smoothyrec-dev.crt -k "$KEYCHAIN" -T /usr/bin/codesign 2>/dev/null
security import /tmp/smoothyrec-dev.key -k "$KEYCHAIN" -T /usr/bin/codesign 2>/dev/null

# Allow codesign to use the key
security set-key-partition-list -S apple-tool:,apple-default:,codesign: -k "" "$KEYCHAIN" 2>/dev/null || true

# Clean up temp files
rm -f "$CERT_CONFIG" /tmp/smoothyrec-dev.key /tmp/smoothyrec-dev.crt

echo ""
echo "Certificate created successfully!"
echo ""
echo "Next steps:"
echo "1. Run: ./build-dev.sh"
echo "2. Open the app: open build/SmoothyREC.app"
echo "3. Grant Screen Recording / Camera / Microphone permissions"
echo "   in System Settings > Privacy & Security"
echo "4. Permissions will NOW persist across rebuilds!"
echo ""
echo "If you get a keychain password prompt, enter your login password."