#!/bin/bash
# Creates a stable self-signed code-signing identity in a dedicated keychain so
# the macOS Accessibility grant survives rebuilds (ad-hoc signing does not).
# Safe to re-run: it recreates the keychain and certificate from scratch.
set -euo pipefail

CERT_NAME="SidestMac Dev"
KC_NAME="sidest-signing.keychain"
KCPASS="sidest-signing"
P12PASS="sidest"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code-signing certificate..."
cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=SidestMac Dev
O=SidestMac
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/openssl.cnf" >/dev/null 2>&1

# macOS `security import` needs legacy PBE + SHA1 MAC (LibreSSL defaults fail).
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -passout "pass:$P12PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "==> Creating dedicated signing keychain..."
security delete-keychain "$KC_NAME" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC_NAME"
security set-keychain-settings -lut 21600 "$KC_NAME"   # don't auto-lock quickly
security unlock-keychain -p "$KCPASS" "$KC_NAME"

echo "==> Importing identity..."
security import "$WORK/identity.p12" -k "$KC_NAME" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security
# Let codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC_NAME" >/dev/null

echo "==> Adding keychain to search list..."
security list-keychains -d user -s "$KC_NAME" $(security list-keychains -d user | sed 's/"//g')

echo "==> Done. Identity:"
security find-identity -p codesigning "$KC_NAME" | grep "$CERT_NAME" || true
echo
echo "Now run ./build.sh — it signs with '$CERT_NAME'."
echo "Grant Accessibility to dist/SidestMac.app ONCE; it persists across rebuilds."
