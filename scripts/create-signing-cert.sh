#!/bin/bash
# Creates a local certificate for signing DyskLink, once per Mac.
# With a stable identity, the macOS Accessibility grant isn't lost with every new build.
# This certificate is not trusted as a root and is only useful on this Mac.
# To remove it: security delete-identity -c "DyskLink Local Signing"
set -euo pipefail

NAME="DyskLink Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Already exists: $NAME"
    exit 0
fi

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# This password only protects the temporary file, which is deleted after import.
PASS="$(/usr/bin/openssl rand -hex 24)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

# Only codesign may use this key without asking.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created: $NAME"
