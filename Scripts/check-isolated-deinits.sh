#!/bin/bash
# Fails if any Shelf class has an isolated deinit.
#
# On Swift runtimes before macOS 26.4, an isolated deinit that releases another
# object with an isolated deinit aborts the process ("pointer being freed was
# not allocated" in swift_task_deinitOnExecutorMainActorBackDeploy). Classes
# in modules with `defaultIsolation(MainActor)` get isolated deinits implicitly,
# so Shelf's targets mark types `@MainActor` one by one instead.
# KeyboardShortcuts is excluded: its few deliberate isolated deinits are
# tracked upstream.
#
#   Scripts/check-isolated-deinits.sh [path/to/binary]
set -euo pipefail
cd "$(dirname "$0")/.."
BINARY="${1:-}"
if [[ -z "$BINARY" ]]; then
  swift build >/dev/null
  BINARY="$(swift build --show-bin-path)/Shelf"
fi
OFFENDERS=$(xcrun objdump -d --no-show-raw-insn "$BINARY" \
  | awk '/^[0-9a-f]+ <.*>:$/ { sym = $2 } /deinitOnExecutor/ { print sym }' \
  | tr -d '<>:' | sort -u | xcrun swift-demangle \
  | grep -E "__deallocating_deinit" | grep -E "(^| )(Shelf|ShelfUI|ShelfCore|ShelfCapture|ShelfPaste)\." || true)
if [[ -n "$OFFENDERS" ]]; then
  echo "Isolated deinits found (add @MainActor to the type, or declare 'nonisolated deinit {}'):" >&2
  echo "$OFFENDERS" >&2
  exit 1
fi
echo "No isolated deinits in Shelf's modules."
