#!/bin/zsh
set -euo pipefail

# Hermetic Nexus smoke test. It deliberately uses an in-memory credential
# store, so it never reads the login Keychain, starts dictation, or sends a
# prompt to a cloud provider. Add --ui to also run the typed-overlay
# controller lifecycle smoke test.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Build/Products/Debug/nexus.app"
RESULTS_DIR="${NEXUS_AUTOMATION_RESULTS:-$ROOT/.build/automation-results}"
mkdir -p "$RESULTS_DIR"

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local child_pid=$!
  ( sleep "$seconds"; kill -TERM "$child_pid" 2>/dev/null || true ) &
  local watchdog_pid=$!
  local exit_status=0
  wait "$child_pid" || exit_status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$exit_status"
}

"$ROOT/scripts/build-nexus.sh"

export NEXUS_AUTOMATION=1
export NEXUS_APP="$APP"

"$ROOT/scripts/nex-computer" doctor > "$RESULTS_DIR/native-tool-doctor.json"
"$ROOT/scripts/nex-computer" search "open a folder and show its contents" > "$RESULTS_DIR/native-tool-search.json"

/usr/bin/xcodebuild \
  -project "$ROOT/nexus/nexus.xcodeproj" \
  -scheme nexus \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build" \
  -only-testing:nexusTests/NexusGeometryTests/testAutomationSecretStoreNeverTouchesLoginKeychain \
  test > "$RESULTS_DIR/keychain-store-test.log"

if [[ "${1:-}" == "--ui" ]]; then
  run_with_timeout 15 "$APP/Contents/MacOS/nexus" --nexus-ui-smoke \
    > "$RESULTS_DIR/typed-overlay-lifecycle.log"
  /usr/bin/grep -q "Nexus typed lifecycle smoke: passed" \
    "$RESULTS_DIR/typed-overlay-lifecycle.log"
fi

echo "Nexus automation smoke test passed. Results: $RESULTS_DIR"
