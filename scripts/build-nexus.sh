#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${NEXUS_DERIVED_DATA:-$ROOT/.build}"
XCODE_DEVELOPER_DIR="${NEXUS_DEVELOPER_DIR:-}"
SIGNING_IDENTITY="${NEXUS_CODE_SIGN_IDENTITY:-}"
INSTALL_APP_PATH="${NEXUS_INSTALL_APP_PATH:-$HOME/Applications/Nexus.app}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  DISCOVERED_IDENTITIES="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
      /usr/bin/sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]* "\(Apple Development:.*\)"$/\1/p'
  )"
  if [[ -n "$DISCOVERED_IDENTITIES" ]]; then
    APPLE_DEVELOPMENT_IDENTITIES=("${(@f)DISCOVERED_IDENTITIES}")
  else
    APPLE_DEVELOPMENT_IDENTITIES=()
  fi
  if (( ${#APPLE_DEVELOPMENT_IDENTITIES[@]} == 1 )); then
    SIGNING_IDENTITY="$APPLE_DEVELOPMENT_IDENTITIES[1]"
    echo "Using the only available Apple Development signing identity: $SIGNING_IDENTITY"
  elif (( ${#APPLE_DEVELOPMENT_IDENTITIES[@]} > 1 )); then
    echo "Multiple Apple Development signing identities are available. Set NEXUS_CODE_SIGN_IDENTITY to the identity intended for the durable Nexus permission host." >&2
    exit 2
  fi
fi

if [[ -z "$XCODE_DEVELOPER_DIR" ]]; then
  if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    XCODE_DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  else
    XCODE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
  fi
fi

BUILD_ARGUMENTS=(
  -project "$ROOT/nexus/nexus.xcodeproj" \
  -scheme nexus \
  -configuration Debug \
  -destination 'platform=macOS,name=My Mac' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=YES
)
if [[ -n "$SIGNING_IDENTITY" ]]; then
  BUILD_ARGUMENTS+=(CODE_SIGN_IDENTITY="$SIGNING_IDENTITY")
fi
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcodebuild "${BUILD_ARGUMENTS[@]}" build

APP="$DERIVED_DATA/Build/Products/Debug/nexus.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
ACTUAL_REQUIREMENT="$(/usr/bin/codesign --display --requirements - "$APP" 2>&1 |
  /usr/bin/sed -n 's/^# \(designated =>.*\)$/\1/p')"
echo "Built Nexus at $APP"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  SIGNER_AUTHORITY="$(/usr/bin/codesign -dvv "$APP" 2>&1 | /usr/bin/sed -n 's/^Authority=\(Apple Development:.*\)$/\1/p' | /usr/bin/head -1)"
  if [[ -z "$SIGNER_AUTHORITY" || "$ACTUAL_REQUIREMENT" != *'anchor apple generic'* || "$ACTUAL_REQUIREMENT" != *'identifier "na.nexus"'* ]]; then
    echo "Nexus was not signed with a stable Apple Development identity. Refusing to present it as a durable macOS privacy-permission host." >&2
    echo "Requirement: $ACTUAL_REQUIREMENT" >&2
    echo "Authority: ${SIGNER_AUTHORITY:-unavailable}" >&2
    exit 1
  fi
  echo "Durable signer: $SIGNER_AUTHORITY"
  echo "Durable requirement: $ACTUAL_REQUIREMENT"
else
  echo "Ad-hoc requirement: $ACTUAL_REQUIREMENT"
  echo "Note: this is an ad-hoc development build. macOS privacy grants are only durable across rebuilt copies after an Apple Development certificate is installed." >&2
fi

install_app() {
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "Refusing to install an ad-hoc build as the durable permission host. Install an Apple Development signing identity in Xcode Settings > Accounts, then rerun this command (or set NEXUS_CODE_SIGN_IDENTITY explicitly)." >&2
    exit 2
  fi
  local install_parent="${INSTALL_APP_PATH:h}"
  mkdir -p "$install_parent"
  local stage_root
  stage_root="$(mktemp -d "$install_parent/.nexus-install.XXXXXX")"
  /usr/bin/ditto "$APP" "$stage_root/Nexus.app"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$stage_root/Nexus.app"
  if [[ -e "$INSTALL_APP_PATH" ]]; then
    local backup_path="$install_parent/.Nexus.previous-$(date +%Y%m%d-%H%M%S).app"
    /bin/mv "$INSTALL_APP_PATH" "$backup_path"
    echo "Preserved previous installed build at $backup_path"
  fi
  /bin/mv "$stage_root/Nexus.app" "$INSTALL_APP_PATH"
  /bin/rmdir "$stage_root"
  echo "Installed durable permission host at $INSTALL_APP_PATH"
}

if [[ "${1:-}" == "--install" || "${1:-}" == "--install-run" ]]; then
  install_app
fi

if [[ "${1:-}" == "--run" || "${1:-}" == "--install-run" ]]; then
  RUN_APP="$APP"
  [[ "${1:-}" == "--install-run" ]] && RUN_APP="$INSTALL_APP_PATH"
  EXECUTABLE="$RUN_APP/Contents/MacOS/nexus"
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
  /usr/bin/open -n "$RUN_APP"
fi
