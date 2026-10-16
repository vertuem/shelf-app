#!/bin/bash
# Builds Shelf.app into build/.
#
#   Scripts/build.sh                         debug, dev bundle id, ad-hoc signed
#   Scripts/build.sh --release               release config, release bundle id
#   Scripts/build.sh --release --version 1.2.0 --build 57
#
# Signing: with DEVELOPER_ID set (for example "Developer ID Application: Your
# Name (TEAMID)") the app is signed with it, hardened runtime and a
# secure timestamp. Without it the app is signed ad-hoc, so any fork builds
# without an Apple account. Local builds always use the .dev bundle id unless
# --release is passed, so Accessibility grants for dev and release never collide.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=debug
BUNDLE_ID=com.vertuem.shelf.dev
VERSION=0.0.0
BUILD_NUMBER=0
REPOSITORY=${SHELF_REPOSITORY:-vertuem/shelf-app}
OUTPUT=build

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIGURATION=release; BUNDLE_ID=com.vertuem.shelf ;;
    --dev-bundle-id) BUNDLE_ID=com.vertuem.shelf.dev ;;
    --version) VERSION="$2"; shift ;;
    --build) BUILD_NUMBER="$2"; shift ;;
    --output) OUTPUT="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

# Swift Build, not the native build system: the native one generates resource
# accessors that look for a package's bundle only at the root of the .app (which
# code signing forbids) and in this machine's .build folder, so KeyboardShortcuts
# crashed on any Mac but the build machine. Swift Build's accessors also look in
# Contents/Resources, where the bundles are copied below.
BUILD=(swift build -c "$CONFIGURATION" --arch arm64 --build-system swiftbuild)
echo "==> swift build ($CONFIGURATION, arm64)"
"${BUILD[@]}" --product Shelf
BIN_DIR=$("${BUILD[@]}" --show-bin-path)

APP="$OUTPUT/Shelf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Shelf" "$APP/Contents/MacOS/Shelf"
# SwiftPM records the deployment target (14.0) as the SDK version. AppKit reads
# that number to decide whether an app gets the current design, so without
# this fix-up macOS 26 draws the sidebar, toolbar and controls in compatibility
# mode instead of Liquid Glass.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
xcrun vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/Shelf" "$APP/Contents/MacOS/Shelf"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" -e "s#__REPOSITORY__#$REPOSITORY#g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon: the layered Icon Composer document, which macOS 26 renders as
# Liquid Glass with its dark, tinted and clear styles, compiled by actool into
# Assets.car; and the flat AppIcon.icns for macOS 14 and 15.
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
PARTIAL_PLIST=$(mktemp -d)/AppIcon-partial.plist
if xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
     --target-device mac --minimum-deployment-target 14.0 --app-icon AppIcon --include-all-app-icons \
     --output-partial-info-plist "$PARTIAL_PLIST" >/dev/null 2>&1 && [[ -f "$APP/Contents/Resources/Assets.car" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
  echo "==> Liquid Glass icon compiled"
elif [[ "$BUNDLE_ID" != *.dev ]]; then
  echo "error: actool could not compile Resources/AppIcon.icon; a release needs the Liquid Glass icon." >&2
  echo "       Run 'sudo xcodebuild -runFirstLaunch' if actool reports a missing plugin." >&2
  exit 1
else
  echo "warning: actool could not compile Resources/AppIcon.icon; using the flat icon only." >&2
  echo "         Run 'sudo xcodebuild -runFirstLaunch' if actool reports a missing plugin." >&2
fi
cp Resources/Sounds/*.wav "$APP/Contents/Resources/"

# SwiftPM resource bundles (KeyboardShortcuts' localizations, GRDB's privacy manifest).
for bundle in "$BIN_DIR"/*.bundle; do
  case "$(basename "$bundle")" in
    *Tests*) ;;
    *) cp -R "$bundle" "$APP/Contents/Resources/" ;;
  esac
done

# String Catalog to .strings and .stringsdict in the main bundle.
# InfoPlist.xcstrings translates the reasons macOS shows in permission prompts.
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done

echo "==> codesign"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  for bundle in "$APP/Contents/Resources"/*.bundle; do
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$bundle"
  done
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Shelf.entitlements --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep --options runtime --entitlements Resources/Shelf.entitlements --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($BUNDLE_ID $VERSION ($BUILD_NUMBER), $([[ -n "${DEVELOPER_ID:-}" ]] && echo "Developer ID" || echo "ad-hoc"))"
