#!/bin/bash
# Updates Resources/Localizable.xcstrings from the strings in the source code.
# New strings are added in English; strings no longer used are marked stale.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
swift build --scratch-path "$SCRATCH" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$SCRATCH/strings" >/dev/null
ARGS=()
while IFS= read -r file; do
  ARGS+=(--stringsdata "$file")
done < <(find "$SCRATCH" -name '*.stringsdata' | grep -E '/(Shelf|ShelfCore|ShelfCapture|ShelfPaste|ShelfUI)(-t)?\.build/')
xcrun xcstringstool sync Resources/Localizable.xcstrings "${ARGS[@]}"
echo "Synced ${#ARGS[@]} files into Resources/Localizable.xcstrings"
