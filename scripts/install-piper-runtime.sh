#!/bin/zsh
set -euo pipefail

runtime_version="1.6.0"
runtime_directory="$HOME/Library/Application Support/Nexus/Voice/PiperPython"
runtime_executable="$runtime_directory/bin/piper"

if [[ -x "$runtime_executable" ]]; then
  if "$runtime_executable" --help >/dev/null 2>&1; then
    echo "Nexus Piper runtime is already installed: $runtime_executable"
    exit 0
  fi
fi

if ! /usr/bin/python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; then
  echo "Piper requires Python 3.9 or newer. Install current Xcode command-line tools and retry." >&2
  exit 1
fi

/usr/bin/python3 -m venv "$runtime_directory"
"$runtime_directory/bin/python" -m pip install \
  --disable-pip-version-check \
  --only-binary=:all: \
  "piper-tts==$runtime_version"

if [[ ! -x "$runtime_executable" ]] || ! "$runtime_executable" --help >/dev/null 2>&1; then
  echo "Piper installed but its executable failed verification." >&2
  exit 1
fi

echo "Installed and verified Nexus Piper $runtime_version: $runtime_executable"
