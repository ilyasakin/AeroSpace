#!/usr/bin/env bash
# One-time setup so debug builds keep their Accessibility permission across rebuilds.
#
# THE PROBLEM: debug builds are ad-hoc signed, so macOS ties the Accessibility grant to the
# exact binary hash, which changes on every build. AeroSpace then resets the grant and you must
# re-approve it every single time.
#
# THE FIX: create ONE stable self-signed code-signing certificate. build-debug.sh signs every
# build with it, so the app's identity stays constant and macOS keeps the grant.
#
# Run this once (it asks for your password to trust the certificate), then grant Accessibility
# one more time. After that, rebuilds won't ask again.
set -euo pipefail

CERT_CN="AeroSpace Debug Self-Signed"

if security find-identity -v -p codesigning | grep -q "$CERT_CN"; then
    echo "✓ Signing identity '$CERT_CN' already exists. Nothing to do."
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -nodes \
    -subj "/CN=$CERT_CN" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"

# Export the PKCS12 with macOS's own LibreSSL (/usr/bin/openssl), not a Homebrew OpenSSL 3 that may
# be first on PATH: the macOS keychain fails MAC verification on OpenSSL 3's PKCS12 even with the
# legacy flags, but accepts LibreSSL's default encoding. A throwaway password protects the temp file.
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/cert.p12" \
    -passout pass:aerospace -name "$CERT_CN"

echo "Importing the certificate into your login keychain…"
# -A lets codesign use the key without a per-build prompt; -T authorizes codesign specifically
security import "$tmp/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "aerospace" -A -T /usr/bin/codesign

echo "Trusting the certificate for code signing (this needs your password)…"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$tmp/cert.pem"

echo
echo "✓ Done. Now run ./build-debug.sh (or ./run-debug.sh) and grant Accessibility one more time."
echo "  Future rebuilds will keep the grant."
