#!/bin/bash
# Installs Otto's hotspot failover helper (otto-netwatch) for this user. No administrator rights needed.
# Otto's Settings → Hotspot runs this through the Hermes relay (POST /hermes/hotspot/setup); by hand:
#
#   bash ~/code/hermes-ios/scripts/install_netwatch.sh
#
# Installs:
#   ~/Library/Application Support/Otto/Otto Network Helper.app
#       the helper, built from netwatch/ (Swift) and signed with your Apple Development identity when
#       there is one (a stable signature keeps the Keychain item and the Location Services grant across
#       reinstalls; ad-hoc builds need the hotspot password saved again after each reinstall)
#   ~/Library/LaunchAgents/ai.elier.otto-netwatch.plist
#       runs it at login and keeps it running (lid open or closed, keep-awake session or not)
# The helper's state lives in ~/.hermes/otto-netwatch/ (config.json, status.json, netwatch.log; no
# passwords). Undo with scripts/uninstall_netwatch.sh.
#
# Why a helper: the App Store Otto app is sandboxed and can't change Wi-Fi networks. Adapted from
# Insomnia's hotspot handoff (https://github.com/krishhgg/Insomnia, MIT, Krish Garg).
#
# Env: OTTO_NETWATCH_SIGN=<identity|-> overrides the signing identity. OTTO_NETWATCH_DRY_RUN=1 builds
# and assembles into $OTTO_NETWATCH_DRY_ROOT without touching launchd (tests).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY="${OTTO_NETWATCH_DRY_RUN:-}"
ROOT="${OTTO_NETWATCH_DRY_ROOT:-}"
LABEL="ai.elier.otto-netwatch"
APP_DIR="${ROOT}${HOME}/Library/Application Support/Otto"
APP="${APP_DIR}/Otto Network Helper.app"
PLIST="${ROOT}${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${ROOT}${HOME}/.hermes/logs"
STATE_DIR="${ROOT}${HERMES_HOME:-$HOME/.hermes}/otto-netwatch"
VERSION="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 1)"

if [[ "$(id -u)" == "0" ]]; then
  echo "Run this as yourself, not with sudo." >&2
  exit 1
fi
if ! command -v swift >/dev/null; then
  echo "Needs the Swift toolchain (xcode-select --install)." >&2
  exit 1
fi

echo "Building otto-netwatch…"
swift build -c release --package-path "$REPO/netwatch" >/dev/null
BIN="$(swift build -c release --package-path "$REPO/netwatch" --show-bin-path)/otto-netwatch"
[[ -x "$BIN" ]] || { echo "Build produced no binary at $BIN" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/otto-netwatch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
STAGE="$tmp/Otto Network Helper.app"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BIN" "$STAGE/Contents/MacOS/otto-netwatch"
cat > "$STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${LABEL/otto-netwatch/otto.netwatch}</string>
  <key>CFBundleName</key><string>Otto Network Helper</string>
  <key>CFBundleDisplayName</key><string>Otto Network Helper</string>
  <key>CFBundleExecutable</key><string>otto-netwatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSBackgroundOnly</key><true/>
  <key>NSLocationUsageDescription</key>
  <string>Otto reads Wi-Fi network names so it can switch this Mac to your iPhone hotspot when Wi-Fi stops working, and switch back when it returns. It never uses your location.</string>
  <key>NSLocationAlwaysUsageDescription</key>
  <string>Otto reads Wi-Fi network names so it can switch this Mac to your iPhone hotspot when Wi-Fi stops working, and switch back when it returns. It never uses your location.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>
      <key>captive.apple.com</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    </dict>
  </dict>
</dict>
</plist>
EOF

SIGN="${OTTO_NETWATCH_SIGN:-}"
if [[ -z "$SIGN" ]]; then
  SIGN="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$SIGN" ]]; then
  SIGN="-"
  echo "No Apple Development identity: signing ad hoc (save the hotspot password again after each reinstall)."
fi
codesign --force --sign "$SIGN" --identifier "${LABEL/otto-netwatch/otto.netwatch}" "$STAGE" >/dev/null 2>&1 \
  || codesign --force --sign - --identifier "${LABEL/otto-netwatch/otto.netwatch}" "$STAGE"
codesign --verify --strict "$STAGE"

mkdir -p "$APP_DIR" "$LOG_DIR" "$(dirname "$PLIST")"
mkdir -p -m 700 "$STATE_DIR"
EXE="$APP/Contents/MacOS/otto-netwatch"
cat > "$tmp/$LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${EXE#"$ROOT"}</string><string>run</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>HERMES_HOME</key><string>${HERMES_HOME:-$HOME/.hermes}</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>${LOG_DIR#"$ROOT"}/otto-netwatch.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR#"$ROOT"}/otto-netwatch.out.log</string>
</dict>
</plist>
EOF
plutil -lint "$tmp/$LABEL.plist" >/dev/null

if [[ -n "$DRY" ]]; then
  rm -rf "$APP"
  ditto "$STAGE" "$APP"
  cp "$tmp/$LABEL.plist" "$PLIST"
  echo "DRY: launchctl bootstrap gui/$(id -u) $PLIST"
  echo "Installed (dry run) into $ROOT"
  exit 0
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
rm -rf "$APP"
ditto "$STAGE" "$APP"
cp "$tmp/$LABEL.plist" "$PLIST"
# So Location Services knows the helper as an app (its own row in Privacy & Security → Location Services).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
echo "Installed: $APP (signed: $SIGN)"
echo "Running at login as $LABEL. Status: ~/.hermes/otto-netwatch/status.json"
