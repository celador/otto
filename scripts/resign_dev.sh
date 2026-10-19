#!/bin/bash
# Re-sign a Debug Hermes.app with the API-made "<bundle> Development" profiles (see dev_profiles.py),
# for devices the wildcard team profile doesn't cover yet. Usage: scripts/resign_dev.sh <Hermes.app> <out dir>
set -euo pipefail
SRC="$1"; OUT="$2"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
IDENTITY="Apple Development: john nelson (3D395VBZTF)"

profile_for() {  # bundle id -> profile path
  for f in "$PROFILES"/*.mobileprovision; do
    n=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || true)
    [ "$n" = "$1 Development" ] && { echo "$f"; return; }
  done
  echo "no profile for $1" >&2; exit 1
}

sign() {  # bundle path, bundle id
  local b="$1" id="$2" prof ents
  prof=$(profile_for "$id")
  cp "$prof" "$b/embedded.mobileprovision"
  # Debug builds keep their code in <name>.debug.dylib (+ __preview.dylib) next to the executable.
  for d in "$b"/*.dylib; do [ -e "$d" ] && codesign -f -s "$IDENTITY" "$d"; done
  ents=$(mktemp)
  security cms -D -i "$prof" | plutil -extract Entitlements xml1 -o "$ents" -
  # Keep the app's own entitlements (app groups etc.) on top of what the profile allows.
  codesign -d --entitlements :- "$b" 2>/dev/null > "$ents.app" || true
  if [ -s "$ents.app" ]; then
    /usr/libexec/PlistBuddy -c "Set :application-identifier UFF39H3A3T.$id" "$ents.app" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :get-task-allow true" "$ents.app" 2>/dev/null || true
    ents_use="$ents.app"
  else
    # Unsigned build (CODE_SIGNING_ALLOWED=NO): start from the profile, but pin the shared keychain group.
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$ents" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" -c "Add :keychain-access-groups:0 string UFF39H3A3T.ai.elier.hermes.shared" "$ents"
    ents_use="$ents"
  fi
  codesign -f -s "$IDENTITY" --entitlements "$ents_use" --generate-entitlement-der "$b"
}

rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$SRC" "$OUT/"
APP="$OUT/$(basename "$SRC")"
if [ "${KEEP_WATCH:-0}" = "1" ] && [ -d "$APP/Watch/HermesWatch.app" ]; then
  W="$APP/Watch/HermesWatch.app"
  [ -d "$W/PlugIns/HermesWatchWidgets.appex" ] && sign "$W/PlugIns/HermesWatchWidgets.appex" ai.elier.hermes.watchkitapp.widgets
  sign "$W" ai.elier.hermes.watchkitapp
else
  rm -rf "$APP/Watch"   # the watch app isn't needed on an iPad
fi
for fw in "$APP"/Frameworks/*; do [ -e "$fw" ] && codesign -f -s "$IDENTITY" "$fw"; done
[ -d "$APP/PlugIns/HermesShare.appex" ] && sign "$APP/PlugIns/HermesShare.appex" ai.elier.hermes.share
[ -d "$APP/PlugIns/HermesWidgets.appex" ] && sign "$APP/PlugIns/HermesWidgets.appex" ai.elier.hermes.widgets
sign "$APP" ai.elier.hermes
codesign --verify --deep --strict "$APP" && echo "signed: $APP"
