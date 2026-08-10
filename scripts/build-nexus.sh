#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${NEXUS_DERIVED_DATA:-$ROOT/.build}"
EXPECTED_REQUIREMENT='designated => identifier "na.nexus"'
XCODE_DEVELOPER_DIR="${NEXUS_DEVELOPER_DIR:-}"

if [[ -z "$XCODE_DEVELOPER_DIR" ]]; then
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    XCODE_DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    XCODE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
  fi
fi

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcodebuild \
  -project "$ROOT/nexus/nexus.xcodeproj" \
  -scheme nexus \
  -configuration Debug \
  -destination 'platform=macOS,name=My Mac' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$DERIVED_DATA/Build/Products/Debug/nexus.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
ACTUAL_REQUIREMENT="$(/usr/bin/codesign --display --requirements - "$APP" 2>&1 |
  /usr/bin/sed -n 's/^[[:space:]]*\(designated =>.*\)$/\1/p')"
if [[ "$ACTUAL_REQUIREMENT" != "$EXPECTED_REQUIREMENT" ]]; then
  echo "Nexus has an unexpected designated requirement: $ACTUAL_REQUIREMENT" >&2
  exit 1
fi
echo "Built Nexus at $APP"
echo "Durable requirement: $ACTUAL_REQUIREMENT"

if [[ "${1:-}" == "--run" ]]; then
  EXECUTABLE="$APP/Contents/MacOS/nexus"
  running_pids() {
    /bin/ps -axo pid=,command= | /usr/bin/awk -v executable="$EXECUTABLE" '$2 == executable { print $1 }'
  }

  for pid in ${(f)"$(running_pids)"}; do
    [[ -n "$pid" ]] && /bin/kill "$pid" 2>/dev/null || true
  done
  for _ in {1..20}; do
    [[ -z "$(running_pids)" ]] && break
    /bin/sleep 0.05
  done
  for pid in ${(f)"$(running_pids)"}; do
    [[ -n "$pid" ]] && /bin/kill -9 "$pid" 2>/dev/null || true
  done
  /usr/bin/open -n "$APP"
fi
