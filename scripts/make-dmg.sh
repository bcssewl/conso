#!/usr/bin/env bash
# scripts/make-dmg.sh
#
# Builds a distributable .dmg containing conso.app and an /Applications symlink,
# using pure hdiutil (no create-dmg dependency). Optionally codesigns the DMG with
# the same self-signed identity as the app inside.
#
# Required environment:
#   APP_BUNDLE   absolute path to the .app to package
#   DIST_DIR     directory to write the DMG into
#   APP_NAME     "conso"
#   VERSION      marketing version (no leading "v")
#
# Optional environment:
#   SIGN_IDENTITY   codesign identity for the DMG (e.g. "conso Local Signing").

set -euo pipefail

: "${APP_BUNDLE:?APP_BUNDLE must be set}"
: "${DIST_DIR:?DIST_DIR must be set}"
: "${APP_NAME:?APP_NAME must be set}"
: "${VERSION:?VERSION must be set}"

[[ -d "$APP_BUNDLE" ]] || { echo "ERROR: bundle not found at $APP_BUNDLE" >&2; exit 1; }

DMG_OUT="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGE_DIR="$DIST_DIR/.dmg-stage"
VOLUME_NAME="$APP_NAME $VERSION"

echo "    cleaning previous DMG + staging"
rm -rf "$STAGE_DIR" "$DMG_OUT"
mkdir -p "$STAGE_DIR"

echo "    staging bundle and Applications symlink"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "    sizing volume"
SIZE_KB="$(/usr/bin/du -sk "$STAGE_DIR" | /usr/bin/awk '{print $1}')"
SIZE_KB="$(( SIZE_KB + 51200 ))"   # +50 MiB headroom for filesystem overhead

TMP_DMG="$DIST_DIR/.tmp-$APP_NAME-$VERSION.dmg"
rm -f "$TMP_DMG"

echo "    hdiutil create"
/usr/bin/hdiutil create \
    -srcfolder "$STAGE_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -o "$TMP_DMG" >/dev/null

echo "    converting to compressed read-only"
/usr/bin/hdiutil convert "$TMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_OUT" >/dev/null

rm -f "$TMP_DMG"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "    signing DMG with '$SIGN_IDENTITY'"
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$DMG_OUT"
else
    echo "    (DMG not signed — no SIGN_IDENTITY)"
fi

echo "    verifying DMG"
/usr/bin/hdiutil verify "$DMG_OUT" >/dev/null

rm -rf "$STAGE_DIR"
echo "    dmg: $DMG_OUT"
