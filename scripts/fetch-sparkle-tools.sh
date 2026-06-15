#!/usr/bin/env bash
# scripts/fetch-sparkle-tools.sh
#
# Downloads the Sparkle release tarball and extracts the CLI tools
# (sign_update, generate_appcast, generate_keys) into scripts/.sparkle-tools/bin
# so the release pipeline can EdDSA-sign updates and build the appcast without a
# system-wide Sparkle install. The .sparkle-tools dir is gitignored.
#
# Usage:
#   scripts/fetch-sparkle-tools.sh            # fetch default pinned version
#   SPARKLE_VERSION=2.9.3 scripts/fetch-sparkle-tools.sh
#
# Idempotent: if the tools already exist it does nothing.

set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/scripts/.sparkle-tools"
BIN_DIR="$TOOLS_DIR/bin"

if [[ -x "$BIN_DIR/sign_update" && -x "$BIN_DIR/generate_appcast" ]]; then
    echo "==> Sparkle tools already present at $BIN_DIR"
    exit 0
fi

URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading Sparkle ${SPARKLE_VERSION} tools"
echo "    $URL"
if ! /usr/bin/curl -fsSL "$URL" -o "$TMP/sparkle.tar.xz"; then
    echo "ERROR: download failed. Check SPARKLE_VERSION or your network." >&2
    exit 1
fi

echo "==> extracting bin/"
/usr/bin/tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP"

mkdir -p "$BIN_DIR"
# The tarball ships the CLI tools under bin/. Copy the ones we need.
for tool in sign_update generate_appcast generate_keys; do
    if [[ -f "$TMP/bin/$tool" ]]; then
        cp "$TMP/bin/$tool" "$BIN_DIR/$tool"
        chmod +x "$BIN_DIR/$tool"
    else
        echo "WARN: $tool not found in tarball bin/" >&2
    fi
done

echo "==> Sparkle tools ready at $BIN_DIR"
ls -1 "$BIN_DIR"
