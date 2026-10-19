#!/bin/bash
# Archive, export (manual Mac App Store signing) and upload Otto for Mac (target OttoMac, bundle ai.elier.hermes,
# same ASC record as iOS: app 6818258172, platform MAC_OS). Profile: "ai.elier.hermes MacAppStore"
# (MAC_APP_STORE, Apple Distribution cert); installer identity: 3rd Party Mac Developer Installer.
# UPLOAD=0 stops after the export and checks.
# Release step only (docs/release.md): one at a time (flock), rebrand/otto tip only, Weft-checked.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."
source scripts/trunk_guard.sh
otto_release_lock "$SELF" "$@"
otto_trunk_guard
# Same ITMS-90626 guard as release.sh (shared intent sources compile into the Mac app too).
if grep -rniE '(IntentDescription\(|shortTitle:|\.description\(")[^/]*"[^"]*(iphone|ipad|apple watch)' ios --include=*.swift | grep -v HermesTests; then
  echo "error: App Intent / widget text names a device (ITMS-90626); fix the lines above" >&2; exit 1
fi
S=${TMPDIR:-/tmp}/otto-mac-release
rm -rf "$S/Otto.xcarchive" "$S/export"
mkdir -p "$S"
/opt/homebrew/bin/xcodegen generate -q
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# project.yml keeps the dev identity (ai.elier.hermes.mac, automatic signing) for local installs; the store
# build overrides it here. OttoMac has no embedded targets, so command-line overrides only hit the app.
xcodebuild -project Hermes.xcodeproj -scheme OttoMac -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$S/Otto.xcarchive" -derivedDataPath "$S/dd" \
  PRODUCT_BUNDLE_IDENTIFIER=ai.elier.hermes CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=UFF39H3A3T \
  CODE_SIGN_IDENTITY="Apple Distribution" PROVISIONING_PROFILE_SPECIFIER="ai.elier.hermes MacAppStore" \
  archive 2>&1 | grep -E "error:|ARCHIVE" | sort -u
APP="$S/Otto.xcarchive/Products/Applications/Otto.app"
test -d "$APP" || { echo "error: archive failed" >&2; exit 1; }
xcodebuild -exportArchive -archivePath "$S/Otto.xcarchive" -exportOptionsPlist scripts/ExportOptionsMac.plist \
  -exportPath "$S/export" 2>&1 | grep -iE "error|EXPORT" | sort -u
PKG="$S/export/Otto.pkg"
test -f "$PKG" || { echo "error: export produced no Otto.pkg" >&2; exit 1; }

# Checks: the shipped entitlements are exactly ios/OttoMac/OttoMac.entitlements plus the two identifiers
# every App Store signature carries; hardened runtime on; distribution-signed; installer-signed.
X="$S/expanded"; rm -rf "$X"; pkgutil --expand-full "$PKG" "$X"
SIGNED=$(find "$X" -name Otto.app -maxdepth 3 -type d | head -1)
codesign -d --entitlements :- "$SIGNED" 2>/dev/null > "$S/shipped.plist"
python3 - "$S/shipped.plist" ios/OttoMac/OttoMac.entitlements <<'PY'
import plistlib, sys
shipped = plistlib.load(open(sys.argv[1], "rb")); want = plistlib.load(open(sys.argv[2], "rb"))
# $(AppIdentifierPrefix) in keychain-access-groups is expanded at signing time.
want = {k: [x.replace("$(AppIdentifierPrefix)", "UFF39H3A3T.") for x in v] if isinstance(v, list) else v
        for k, v in want.items()}
extra = {"com.apple.application-identifier": "UFF39H3A3T.ai.elier.hermes", "com.apple.developer.team-identifier": "UFF39H3A3T"}
if shipped != {**want, **extra}:
    sys.exit(f"error: shipped entitlements differ from OttoMac.entitlements:\n{shipped}")
print("entitlements ok:", sorted(shipped))
PY
SIG=$(codesign -dvv "$SIGNED" 2>&1)   # no grep -q in a pipe: pipefail + SIGPIPE
[[ $SIG == *"Authority=Apple Distribution"* ]] || { echo "error: not Apple Distribution signed" >&2; exit 1; }
[[ $SIG =~ flags=[^[:space:]]*runtime ]] || { echo "error: hardened runtime off" >&2; exit 1; }
codesign --verify --deep --strict "$SIGNED"
PKGSIG=$(pkgutil --check-signature "$PKG")
[[ $PKGSIG == *"3rd Party Mac Developer Installer"* ]] || { echo "error: pkg not installer-signed" >&2; exit 1; }
echo "build $(defaults read "$SIGNED/Contents/Info.plist" CFBundleVersion) ok: $PKG"
[ "${UPLOAD:-1}" = 1 ] || exit 0
ISS=$(grep '^ISSUER_ID' ~/.appstoreconnect/asc.py | cut -d'"' -f2)
UP=$(xcrun altool --upload-app --type macos --file "$PKG" --apiKey 6Y764P847N --apiIssuer "$ISS" 2>&1 || true)
echo "$UP" | grep -E "UPLOAD|ERROR|error" | head -5
[[ $UP == *"UPLOAD SUCCEEDED"* ]] || { echo "error: upload failed" >&2; exit 1; }
otto_note_install testflight-mac "$(defaults read "$SIGNED/Contents/Info.plist" CFBundleVersion)" "App Store Connect"
