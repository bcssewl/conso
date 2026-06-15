#!/usr/bin/env bash
# scripts/setup-local-signing.sh
#
# One-time setup of a STABLE, self-signed code-signing identity used to sign
# distributable builds of conso (see scripts/release.sh). Because the identity
# is stable across rebuilds, macOS keeps the app's TCC permissions (Full Disk
# Access, notifications) instead of re-prompting after every update.
#
# Needs NO Apple Developer account. The certificate is self-signed, so other
# Macs do not "trust" it for Gatekeeper — users approve the app once via
# System Settings -> Privacy & Security -> Open Anyway. That is the same model
# Trace uses. (A notarized build with a paid "Developer ID Application" identity
# would remove that one-time prompt; this script is the free path.)
#
# Safe to re-run: it recreates the keychain from scratch.
#
# Creates:
#   - dedicated keychain  ~/Library/Keychains/conso-signing.keychain-db
#   - self-signed cert    CN="conso Local Signing"  (valid 10 years)
# and adds the keychain to your user search list so codesign can find it.

set -euo pipefail

CERT_CN="conso Local Signing"
KEYCHAIN="conso-signing.keychain"
# Throwaway password: this keychain holds only a meaningless self-signed cert
# that is worthless on any other machine, so the password is not a secret.
KCPASS="conso-local-signing"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> generating self-signed code-signing certificate"
cat > "$TMP/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = conso Local Signing
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null

# NOTE: the PKCS#12 export password MUST be non-empty — `security import`
# silently imports zero keys from an empty-password .p12 (no error, but
# `find-identity` then shows nothing and signing fails with "no identity found").
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:"$KCPASS" -name "$CERT_CN" 2>/dev/null

echo "==> (re)creating keychain $KEYCHAIN"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KEYCHAIN"

echo "==> importing identity + authorizing codesign (so signing never prompts)"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KCPASS" -A -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "==> adding keychain to the user search list (preserving existing, absolute paths)"
# IMPORTANT: pass full -db paths via a quoted array. Round-tripping the existing
# list through sed + unquoted word-splitting can mangle an entry and silently
# drop the login keychain from the search list.
KCPATH="$HOME/Library/Keychains/conso-signing.keychain-db"
declare -a SEARCH=("$KCPATH")
while IFS= read -r kc; do
    [ -n "$kc" ] && [ "$kc" != "$KCPATH" ] && SEARCH+=("$kc")
done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')
security list-keychains -d user -s "${SEARCH[@]}"

echo "==> smoke test (self-signed cert is reported NOT_TRUSTED; that is expected"
echo "    and only matters for Gatekeeper verification, never for signing)"
cp /bin/echo "$TMP/cs-test"
codesign --force --options runtime --sign "$CERT_CN" "$TMP/cs-test"
codesign --verify --strict "$TMP/cs-test"

echo "==> OK — '$CERT_CN' ready. Next: scripts/sparkle-sign.sh --generate-key"
