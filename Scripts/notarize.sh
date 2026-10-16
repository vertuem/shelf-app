#!/bin/bash
# Submits a file (zip or dmg) to Apple's notary service, waits, and staples the ticket.
#
#   Scripts/notarize.sh build/Shelf.dmg [build/Shelf.app]
#
# Needs APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (an app-specific password).
# The optional second argument is stapled too (the app inside a notarized zip).
set -euo pipefail
FILE="$1"
EXTRA="${2:-}"
: "${APPLE_ID:?APPLE_ID is not set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is not set}"

echo "==> notarytool submit $FILE"
xcrun notarytool submit "$FILE" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait --timeout 30m

if [[ "$FILE" == *.dmg ]]; then
  xcrun stapler staple "$FILE"
  xcrun stapler validate "$FILE"
fi
if [[ -n "$EXTRA" ]]; then
  xcrun stapler staple "$EXTRA"
  xcrun stapler validate "$EXTRA"
fi
