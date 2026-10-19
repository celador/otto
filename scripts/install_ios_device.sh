#!/bin/bash
# Build Otto (iOS, Debug) from the rebrand/otto tip, re-sign with the dev profiles and install it on devices
# (docs/HANDOFF.md, scripts/resign_dev.sh). Release step only (docs/release.md): feature cards never run this.
# One install/release at a time (flock), trunk tip only, Weft-checked (scripts/trunk_guard.sh).
# Usage: scripts/install_ios_device.sh <device-id> [<device-id> ...]
#   KEEP_WATCH=1 for an iPhone paired with the Watch (signs the watch app too); default drops it (iPads).
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."
[ $# -ge 1 ] || { echo "usage: $0 <device-id> [...]" >&2; exit 2; }
source scripts/trunk_guard.sh
otto_release_lock "$SELF" "$@"
otto_trunk_guard
if [ "${OTTO_INSTALL_DRY_RUN:-0}" = "1" ]; then
  echo "dry run: would build and install Otto for iOS from $(git rev-parse --short HEAD) on $*"
  sleep "${OTTO_DRY_RUN_SLEEP:-0}"
  exit 0
fi
DD="${DD:-${TMPDIR:-/tmp}/otto-ios-dd-$(basename "$PWD")}"
OUT="${OUT:-${TMPDIR:-/tmp}/otto-ios-signed-$(basename "$PWD")}"
xcodegen generate -q
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build -quiet
scripts/resign_dev.sh "$DD/Build/Products/Debug-iphoneos/Hermes.app" "$OUT"
otto_trunk_guard
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$OUT/Hermes.app/Info.plist")
fail=0; done_devs=""
for D in "$@"; do
  if xcrun devicectl device install app --device "$D" "$OUT/Hermes.app"; then
    xcrun devicectl device process launch --terminate-existing --device "$D" ai.elier.hermes || true
    done_devs="$done_devs,$D"
  else
    echo "install failed on $D (locked or unreachable?)" >&2; fail=1
  fi
done
[ -n "$done_devs" ] && otto_note_install ios "$BUILD" "${done_devs#,}"
exit $fail
