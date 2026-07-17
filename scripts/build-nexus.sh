#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${NEXUS_DERIVED_DATA:-$ROOT/.build}"
SIGNING_IDENTITY="${NEXUS_CODE_SIGN_IDENTITY:-system local code signing}"
SIGNING_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"

if [[ "$SIGNING_IDENTITIES" != *"\"$SIGNING_IDENTITY\""* ]]; then
  echo "Nexus requires the stable '$SIGNING_IDENTITY' signing identity." >&2
  echo "Configure that identity or set NEXUS_CODE_SIGN_IDENTITY to another persistent certificate." >&2
  echo "Refusing to create an ad-hoc build because it would trigger repeated Keychain prompts." >&2
  exit 1
fi

/usr/bin/xcodebuild \
  -project "$ROOT/nexus/nexus.xcodeproj" \
  -scheme nexus \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM='' \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER='' \
  build

APP="$DERIVED_DATA/Build/Products/Debug/nexus.app"
SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNATURE_DETAILS" == *"Signature=adhoc"* ]] || \
   [[ "$SIGNATURE_DETAILS" != *"Authority=$SIGNING_IDENTITY"* ]]; then
  echo "Nexus was not signed by '$SIGNING_IDENTITY'; refusing to run an unstable build." >&2
  exit 1
fi
echo "Built Nexus at $APP"
echo "Signed Nexus with stable identity: $SIGNING_IDENTITY"

if [[ "${1:-}" == "--run" ]]; then
  /usr/bin/open "$APP"
fi
