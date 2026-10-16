#!/bin/bash
# Updates the version and sha256 in Casks/shelf.rb, for the personal tap
# (vertuem/homebrew-tap). Once the repository clears homebrew-cask's notability
# threshold, use `brew bump-cask-pr --version <version> shelf` instead.
#
#   Scripts/bump-cask.sh 1.2.0 dist/Shelf-1.2.0.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1#v}"
DMG="$2"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/shelf.rb
echo "Casks/shelf.rb -> $VERSION ($SHA)"
