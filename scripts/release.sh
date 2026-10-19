#!/bin/bash
# Archive, export (manual App Store signing) and upload Hermes - unofficial.
# Release step only (docs/release.md): one at a time (flock), rebrand/otto tip only, Weft-checked.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."
source scripts/trunk_guard.sh
otto_release_lock "$SELF" "$@"
otto_trunk_guard
S=${TMPDIR:-/tmp}/hermes-release
rm -rf "$S/Hermes.xcarchive" "$S/export"
mkdir -p "$S"
# ITMS-90626: App Intent metadata must not name a device (build 72 was rejected for "iPhone").
if grep -rniE '(IntentDescription\(|shortTitle:|\.description\(")[^/]*"[^"]*(iphone|ipad|apple watch)' ios --include=*.swift | grep -v HermesTests; then
  echo "error: App Intent / widget text names a device (ITMS-90626); fix the lines above" >&2; exit 1
fi
/opt/homebrew/bin/xcodegen generate -q
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$S/Hermes.xcarchive" -derivedDataPath "$S/dd" archive 2>&1 | grep -E "error:|ARCHIVE" | sort -u
xcodebuild -exportArchive -archivePath "$S/Hermes.xcarchive" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$S/export" 2>&1 | grep -iE "error|EXPORT" | sort -u
ISS=$(grep '^ISSUER_ID' ~/.appstoreconnect/asc.py | cut -d'"' -f2)
test -f "$S/export/Hermes.ipa" || { echo "error: export produced no Hermes.ipa" >&2; exit 1; }
UP=$(xcrun altool --upload-app --type ios --file "$S/export/Hermes.ipa" --apiKey 6Y764P847N --apiIssuer "$ISS" 2>&1 || true)
echo "$UP" | grep -E "UPLOAD|ERROR|error" | head -5
[[ $UP == *"UPLOAD SUCCEEDED"* ]] || { echo "error: upload failed" >&2; exit 1; }
BUILD=$(/usr/libexec/PlistBuddy -c "Print ApplicationProperties:CFBundleVersion" "$S/Hermes.xcarchive/Info.plist")
otto_note_install testflight-ios "$BUILD" "App Store Connect"
