#!/bin/bash
# Build Otto for Mac (Release) from the rebrand/otto tip and install it to /Applications/Otto.app.
# Release step only (docs/release.md): feature cards never run this; scripts/otto_release.sh calls it.
# One install/release at a time (flock), trunk tip only, Weft-checked (scripts/trunk_guard.sh).
# Usage: scripts/install_mac.sh            (env: DD = derived data dir; OTTO_INSTALL_DRY_RUN=1 = checks only)
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."
source scripts/trunk_guard.sh
otto_release_lock "$SELF" "$@"
[ "${1:-Release}" = Release ] || { echo "error: only Release builds are installed as Otto.app (Debug runs use the Otto Dev bundle)" >&2; exit 2; }
otto_trunk_guard
SHA=$(git rev-parse --short HEAD)
if [ "${OTTO_INSTALL_DRY_RUN:-0}" = "1" ]; then
  echo "dry run: would build and install Otto for Mac from $SHA"
  sleep "${OTTO_DRY_RUN_SLEEP:-0}"
  exit 0
fi
DD="${DD:-${TMPDIR:-/tmp}/otto-mac-dd-$(basename "$PWD")}"
xcodegen generate -q
xcodebuild -project Hermes.xcodeproj -scheme OttoMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" -allowProvisioningUpdates build -quiet
APP="$DD/Build/Products/Release/Otto.app"
codesign --verify --deep --strict "$APP"
# Re-check right before replacing the installed app: rebrand/otto may have moved during the build.
otto_trunk_guard
osascript -e 'tell application id "ai.elier.hermes.mac" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Otto || break; sleep 0.5; done
rm -rf /Applications/Otto.app
ditto "$APP" /Applications/Otto.app
open /Applications/Otto.app
BUILD=$(defaults read /Applications/Otto.app/Contents/Info.plist CFBundleVersion)
otto_note_install mac "$BUILD" "$(scutil --get ComputerName 2>/dev/null || hostname -s)"
echo "installed Otto $BUILD from $SHA"
