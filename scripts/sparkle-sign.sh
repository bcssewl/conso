#!/usr/bin/env bash
# scripts/sparkle-sign.sh
#
# Thin wrapper over Sparkle's sign_update / generate_keys. The EdDSA private key
# lives in the login Keychain (created once by --generate-key); the tools read it
# from there, so no private key is ever written into the repo.
#
# Usage:
#   scripts/sparkle-sign.sh <artifact>          # print sparkle:edSignature + length
#   scripts/sparkle-sign.sh --generate-key      # create + store a keypair (one-time)
#   scripts/sparkle-sign.sh --print-public-key  # print SUPublicEDKey (paste into Info.plist)
#
# The release pipeline (scripts/release.sh) signs via generate_appcast, which reads
# the same Keychain key — this script is for manual / one-off use.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/scripts/.sparkle-tools/bin"

ensure_tools() {
    if [[ ! -x "$BIN_DIR/sign_update" || ! -x "$BIN_DIR/generate_keys" ]]; then
        "$REPO_ROOT/scripts/fetch-sparkle-tools.sh" >&2
    fi
}

ensure_tools

case "${1:-}" in
    "")
        echo "usage: scripts/sparkle-sign.sh <artifact> | --generate-key | --print-public-key" >&2
        exit 1
        ;;
    --generate-key)
        # Creates the keypair (if absent) in the login Keychain and prints the public key.
        "$BIN_DIR/generate_keys"
        ;;
    --print-public-key)
        "$BIN_DIR/generate_keys" -p
        ;;
    *)
        [[ -f "$1" ]] || { echo "ERROR: artifact not found: $1" >&2; exit 1; }
        # Reads the private key from the login Keychain automatically.
        "$BIN_DIR/sign_update" "$1"
        ;;
esac
