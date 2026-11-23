#!/bin/bash
# Creates a self-signed code-signing certificate, "KlipKlik Local Signing", in
# the login keychain, and trusts it for code signing on this Mac.
#
# Why: macOS ties Accessibility, Screen Recording and Full Disk Access to the
# app's signature. An ad-hoc signature changes on every build, so every rebuild
# looks like a new app and every grant silently stops counting. Signed with
# this certificate, every build has the same signature and grants survive.
#
# It is not an Apple Developer ID: it only means anything on this Mac, which is
# all a locally built app needs. Run once; build_app.sh picks it up by name.
# macOS asks for your password once, to trust the certificate.
set -euo pipefail

NAME="KlipKlik Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "==> '$NAME' already exists and is trusted. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSWORD="$(uuidgen)"

cat > "$WORK/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "==> Creating the certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.conf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

echo "==> Adding it to the login keychain"
# -T lets codesign use the key without asking each build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "==> Trusting it for code signing (macOS asks for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "==> Done. Scripts/build_app.sh now signs with '$NAME'."
else
    echo "!! The certificate was added but is not trusted for code signing." >&2
    exit 1
fi
