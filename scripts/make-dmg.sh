#!/usr/bin/env bash
# scripts/make-dmg.sh
#
# Builds a distributable .dmg containing conso.app and an /Applications symlink,
# laid out as a proper install window (the app icon beside the Applications folder,
# so the user just drags across). Pure hdiutil + a best-effort Finder/AppleScript
# layout pass. Optionally codesigns the DMG with the app's self-signed identity.
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

# Positions the app icon and the Applications shortcut side-by-side in an icon-view
# window so dragging across is obvious. Drives Finder via AppleScript, which can need a
# one-time "allow control of Finder" approval — callers run this best-effort.
style_dmg() {
    local vol="$1" appname="$2"
    /usr/bin/osascript 2>/dev/null <<OSA
tell application "Finder"
  tell disk "$vol"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {220, 140, 760, 500}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 104
    try
      set text size of vo to 12
    end try
    set position of item "$appname.app" of container window to {150, 185}
    set position of item "Applications" of container window to {400, 185}
    update without registering applications
    delay 1
  end tell
end tell
OSA
}
# NOTE: deliberately do NOT `close` the Finder window — closing it before the write
# commits drops the .DS_Store (the layout is lost). Leaving it open lets Finder flush
# (~500ms); the shell then waits for .DS_Store and detaches (which closes everything).

echo "    cleaning previous DMG + staging"
rm -rf "$STAGE_DIR" "$DMG_OUT"
mkdir -p "$STAGE_DIR"

echo "    staging bundle and Applications symlink"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "    sizing volume"
SIZE_KB="$(/usr/bin/du -sk "$STAGE_DIR" | /usr/bin/awk '{print $1}')"
SIZE_KB="$(( SIZE_KB + 51200 ))"   # +50 MiB headroom

TMP_DMG="$DIST_DIR/.tmp-$APP_NAME-$VERSION.dmg"
rm -f "$TMP_DMG"

echo "    hdiutil create (read-write)"
/usr/bin/hdiutil create \
    -srcfolder "$STAGE_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -o "$TMP_DMG" >/dev/null

echo "    laying out the install window (best-effort)"
# Clear any stale mount of the same volume so Finder targets the right disk.
/usr/bin/hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
ATTACH_OUT="$(/usr/bin/hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen 2>/dev/null || true)"
DEV="$(printf '%s\n' "$ATTACH_OUT" | /usr/bin/grep -E '^/dev/' | /usr/bin/head -1 | /usr/bin/awk '{print $1}')"
MOUNT="$(printf '%s\n' "$ATTACH_OUT" | /usr/bin/grep -E '/Volumes/' | /usr/bin/sed -E 's|^.*(/Volumes/.*)$|\1|' | /usr/bin/head -1)"
[ -z "$MOUNT" ] && MOUNT="/Volumes/$VOLUME_NAME"
if [[ -n "$DEV" ]]; then
    # Foreground: Apple Events to Finder don't deliver reliably from a detached
    # subshell. osascript returns in ~1s here (Finder automation is permitted); the
    # `|| true` keeps a denied/failed attempt from aborting the build.
    style_dmg "$VOLUME_NAME" "$APP_NAME" || true
    # Wait for Finder to actually flush .DS_Store (appears ~500ms) before we freeze it.
    for _ in $(/usr/bin/seq 1 20); do [[ -f "$MOUNT/.DS_Store" ]] && break || /bin/sleep 0.5; done
    if [[ -f "$MOUNT/.DS_Store" ]]; then echo "    install window styled"; else
        echo "WARN: layout not saved (Finder automation unavailable?) — shipping a plain, functional DMG." >&2
    fi
    /bin/sync; /bin/sleep 1
    for _ in 1 2 3 4 5; do /usr/bin/hdiutil detach "$DEV" >/dev/null 2>&1 && break || /bin/sleep 1; done
fi

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
