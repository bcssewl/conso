#!/usr/bin/env bash
# scripts/release.sh
#
# Cut a conso release in one command, built LOCALLY on this Mac (conso targets macOS 26
# + FoundationModels + a privileged helper, which GitHub's hosted runners can't build).
# Mirrors Trace's self-signed DMG + Sparkle model, adapted to the Xcode project:
#
#   xcodebuild (Release, self-signed) -> deep-sign Sparkle inside-out -> .dmg
#   -> EdDSA-signed appcast -> GitHub Release (+ rolling beta-feed)
#
# Usage:
#   scripts/release.sh v1.0.0                 # stable release (Stable channel)
#   scripts/release.sh v1.1.0-beta.1          # pre-release (Beta channel only)
#   scripts/release.sh v1.0.0 --no-publish    # build + sign + dmg + appcast, no git/gh
#   scripts/release.sh v1.0.0 "Notes line"    # custom release-notes lead line
#
# One-time setup (see README): scripts/setup-local-signing.sh && scripts/sparkle-sign.sh --generate-key
#
# HARD RULE (Sparkle self-signed continuity): never rotate BOTH the "conso Local Signing"
# certificate AND the EdDSA key in the same release, or existing users can't update.

set -euo pipefail

APP_NAME="conso"
REPO="bcssewl/conso"
SIGN_IDENTITY="conso Local Signing"
STABLE_FEED_PREFIX="https://github.com/$REPO/releases/download"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$DIST_DIR/.build-release"
BIN_DIR="$REPO_ROOT/scripts/.sparkle-tools/bin"
INFO_PLIST="$REPO_ROOT/conso/conso/Info.plist"
PROJECT="$REPO_ROOT/conso/conso.xcodeproj"

# ---- args ---------------------------------------------------------------------------
VERSION="${1:-}"
NO_PUBLISH=0
NOTES_LEAD=""
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-publish) NO_PUBLISH=1; shift ;;
        *) NOTES_LEAD="$1"; shift ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "usage: scripts/release.sh vX.Y.Z[-suffix] [--no-publish] [\"notes lead\"]" >&2
    exit 1
fi
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "ERROR: version must look like v1.2.3 or v1.2.3-beta.1 (got '$VERSION')" >&2
    exit 1
fi
TAG="$VERSION"
MARKETING="${VERSION#v}"
PRERELEASE=0
[[ "$VERSION" == *-* ]] && PRERELEASE=1

# ---- preflight ----------------------------------------------------------------------
echo "==> preflight"

# NOTE: omit -v — a self-signed cert is reported NOT_TRUSTED and filtered out by -v,
# but codesign can still sign with it by name (that's the whole self-signed model).
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "ERROR: signing identity '$SIGN_IDENTITY' not found." >&2
    echo "       run: scripts/setup-local-signing.sh" >&2
    exit 1
fi

if grep -q "REPLACE_WITH_REAL_ED_PUBLIC_KEY" "$INFO_PLIST"; then
    echo "ERROR: SUPublicEDKey is still the placeholder in $INFO_PLIST" >&2
    echo "       run: scripts/sparkle-sign.sh --generate-key  (then paste the key)" >&2
    exit 1
fi

[[ -x "$BIN_DIR/generate_appcast" ]] || "$REPO_ROOT/scripts/fetch-sparkle-tools.sh"

if [[ "$NO_PUBLISH" -eq 0 ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "ERROR: uncommitted changes — commit or stash before publishing." >&2
        git status --short >&2
        exit 1
    fi
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "ERROR: tag $TAG already exists." >&2
        exit 1
    fi
    command -v gh >/dev/null || { echo "ERROR: gh CLI not found." >&2; exit 1; }
fi

BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"   # monotonic CFBundleVersion

echo "    version : $MARKETING (build $BUILD)"
echo "    tag     : $TAG  $( [[ $PRERELEASE -eq 1 ]] && echo '(pre-release -> Beta channel)' )"
echo "    publish : $( [[ $NO_PUBLISH -eq 1 ]] && echo no || echo yes )"

mkdir -p "$DIST_DIR"
rm -rf "$BUILD_DIR"

# ---- build --------------------------------------------------------------------------
echo "==> xcodebuild (Release, self-signed)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    MARKETING_VERSION="$MARKETING" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CONSO_DIST_CHANNEL="self-signed" \
    clean build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "ERROR: built app not found at $APP" >&2; exit 1; }

# ---- deep-sign Sparkle inside-out (research-confirmed order) -------------------------
echo "==> deep-signing with '$SIGN_IDENTITY' (inside-out)"
SP="$APP/Contents/Frameworks/Sparkle.framework"
cs() { /usr/bin/codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$@"; }
if [[ -d "$SP" ]]; then
    cs "$SP/Versions/B/XPCServices/Installer.xpc"
    cs --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Downloader.xpc"
    cs "$SP/Versions/B/Autoupdate"
    cs "$SP/Versions/B/Updater.app"
    cs "$SP"
fi
# Privileged helper: inert under self-signing (HelperClient won't connect), but sign it
# so the bundle seal is consistent.
[[ -f "$APP/Contents/MacOS/$APP_NAME-helper" ]] && cs "$APP/Contents/MacOS/$APP_NAME-helper"
# The app last, preserving the entitlements Xcode applied.
cs --preserve-metadata=entitlements "$APP"

echo "==> verifying signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
echo "    distribution channel: $(/usr/libexec/PlistBuddy -c 'Print ConsoDistributionChannel' "$APP/Contents/Info.plist")"

# ---- DMG ----------------------------------------------------------------------------
echo "==> building DMG"
APP_BUNDLE="$APP" DIST_DIR="$DIST_DIR" APP_NAME="$APP_NAME" VERSION="$MARKETING" \
    SIGN_IDENTITY="$SIGN_IDENTITY" "$REPO_ROOT/scripts/make-dmg.sh"
DMG="$DIST_DIR/$APP_NAME-$MARKETING.dmg"
cp -f "$DMG" "$DIST_DIR/$APP_NAME.dmg"   # the releases/latest "latest" alias asset

# ---- appcast (EdDSA-signed via the login-keychain key) ------------------------------
echo "==> generating EdDSA-signed appcast"
FEED_DIR="$DIST_DIR/feed"
rm -rf "$FEED_DIR"; mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/"
"$BIN_DIR/generate_appcast" \
    --download-url-prefix "$STABLE_FEED_PREFIX/$TAG/" \
    -o "$DIST_DIR/appcast.xml" \
    "$FEED_DIR"
echo "    appcast: $DIST_DIR/appcast.xml"

if [[ "$NO_PUBLISH" -eq 1 ]]; then
    echo "==> --no-publish: built + signed locally, nothing pushed."
    echo "    app     : $APP"
    echo "    dmg     : $DMG"
    echo "    appcast : $DIST_DIR/appcast.xml"
    exit 0
fi

# ---- publish ------------------------------------------------------------------------
echo "==> tagging $TAG"
git tag "$TAG"
git push origin "$TAG"

NOTES_FILE="$DIST_DIR/.notes.md"
{
    [[ -n "$NOTES_LEAD" ]] && echo "$NOTES_LEAD" && echo
    cat <<'NOTES'
Self-signed build — not notarized by Apple, so macOS Gatekeeper blocks it on first open.

**First launch (macOS 15 Sequoia and later removed right-click → Open):** double-click
conso once, then open **System Settings → Privacy & Security**, scroll to the bottom,
click **Open Anyway**, and authenticate. You only do this once. If macOS says the app is
"damaged", clear the download quarantine:

    xattr -dr com.apple.quarantine /Applications/conso.app

Updates after that are seamless (Sparkle, in-app). Permissions you grant carry across updates.

Note: four root-maintenance features (rebuild Spotlight, flush DNS, clear system font
caches, delete APFS snapshots) require the signed developer build and are disabled here.
NOTES
} > "$NOTES_FILE"

PRERELEASE_FLAG=""
[[ "$PRERELEASE" -eq 1 ]] && PRERELEASE_FLAG="--prerelease"

echo "==> creating GitHub release $TAG"
gh release create "$TAG" \
    "$DMG" \
    "$DIST_DIR/$APP_NAME.dmg" \
    "$DIST_DIR/appcast.xml" \
    --repo "$REPO" \
    --title "$APP_NAME $MARKETING" \
    --notes-file "$NOTES_FILE" \
    $PRERELEASE_FLAG

# Rolling beta-feed release: the Beta channel always reads this constant URL, so refresh
# its appcast on EVERY release (stable too) — beta testers never fall behind stable.
echo "==> refreshing rolling beta-feed appcast"
if ! gh release view beta-feed --repo "$REPO" >/dev/null 2>&1; then
    gh release create beta-feed \
        --repo "$REPO" \
        --prerelease \
        --title "Beta update feed (rolling)" \
        --notes "conso's Beta update channel. This pre-release only hosts appcast.xml; it is refreshed on every release. Enable Beta updates in conso → Settings."
fi
gh release upload beta-feed "$DIST_DIR/appcast.xml" --repo "$REPO" --clobber

echo
echo "==> shipped $TAG"
echo "    release : https://github.com/$REPO/releases/tag/$TAG"
echo "    download: https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"
