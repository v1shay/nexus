#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${NEXUS_DERIVED_DATA:-$ROOT/.build}"

/usr/bin/xcodebuild \
  -project "$ROOT/nexus/nexus.xcodeproj" \
  -scheme nexus \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP="$DERIVED_DATA/Build/Products/Debug/nexus.app"
echo "Built Nexus at $APP"

if [[ "${1:-}" == "--run" ]]; then
  /usr/bin/open "$APP"
fi
