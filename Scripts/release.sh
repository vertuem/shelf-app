#!/bin/bash
# Produces the release artifacts in dist/: Shelf-<version>.dmg, Shelf-<version>.zip,
# SHA256SUMS.txt and release-notes.md. Run by .github/workflows/release.yml on a v* tag,
# and locally for a dry run:
#
#   Scripts/release.sh 1.2.0 57
#
# With DEVELOPER_ID and the notary secrets set, everything is signed with the
# Developer ID, notarized and stapled. Without them (forks, local dry runs) the
# app is signed ad-hoc and notarization is skipped; README explains the
# Gatekeeper "Open Anyway" step for such builds.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [build-number]}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${2:-0}"
DIST=dist
rm -rf "$DIST" build
mkdir -p "$DIST"

Scripts/build.sh --release --version "$VERSION" --build "$BUILD_NUMBER"
APP=build/Shelf.app

CAN_NOTARIZE=false
if [[ -n "${DEVELOPER_ID:-}" && -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  CAN_NOTARIZE=true
fi

# 1. Notarize the app itself, then staple it, so the copy inside the DMG is stapled too.
if $CAN_NOTARIZE; then
  ditto -c -k --keepParent "$APP" build/Shelf-notarize.zip
  Scripts/notarize.sh build/Shelf-notarize.zip "$APP"
  rm build/Shelf-notarize.zip
else
  echo "warning: no Developer ID or notary credentials; producing an ad-hoc signed, un-notarized build" >&2
fi

# 2. The DMG: background picture and an Applications shortcut.
DMG="$DIST/Shelf-$VERSION.dmg"
if command -v create-dmg >/dev/null; then
  create-dmg \
    --volname "Shelf $VERSION" \
    --background Resources/dmg-background.png \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "Shelf.app" 165 190 \
    --app-drop-link 495 190 \
    --hide-extension "Shelf.app" \
    --no-internet-enable \
    "$DMG" "$APP"
else
  echo "create-dmg not found; building a plain DMG with hdiutil" >&2
  STAGING=$(mktemp -d)
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "Shelf $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
  rm -rf "$STAGING"
fi

# 3. Sign and notarize the DMG so the updater can verify it with codesign and spctl.
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi
if $CAN_NOTARIZE; then
  Scripts/notarize.sh "$DMG"
fi

# 4. Zip, checksums and the changelog section for the release body.
ditto -c -k --keepParent "$APP" "$DIST/Shelf-$VERSION.zip"
(cd "$DIST" && shasum -a 256 "Shelf-$VERSION.dmg" "Shelf-$VERSION.zip" > SHA256SUMS.txt)
awk -v version="$VERSION" '
  $0 ~ "^## \\[" version "\\]" { printing = 1; next }
  printing && /^## \[/ { exit }
  printing { print }
' CHANGELOG.md > "$DIST/release-notes.md"
[[ -s "$DIST/release-notes.md" ]] || echo "See CHANGELOG.md." > "$DIST/release-notes.md"

echo "==> dist/"
ls -la "$DIST"
cat "$DIST/SHA256SUMS.txt"
