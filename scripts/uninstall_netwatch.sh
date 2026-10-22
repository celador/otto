#!/bin/bash
# Removes Otto's hotspot failover helper (scripts/install_netwatch.sh). Keeps ~/.hermes/otto-netwatch
# unless --purge; --purge also deletes the saved hotspot password from the login Keychain.
set -euo pipefail
LABEL="ai.elier.otto-netwatch"
APP="$HOME/Library/Application Support/Otto/Otto Network Helper.app"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
STATE_DIR="${HERMES_HOME:-$HOME/.hermes}/otto-netwatch"

if [[ "${1:-}" == "--purge" && -x "$APP/Contents/MacOS/otto-netwatch" && -f "$STATE_DIR/config.json" ]]; then
  ssid="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hotspot_ssid",""))' "$STATE_DIR/config.json" 2>/dev/null || true)"
  if [[ -n "$ssid" ]]; then "$APP/Contents/MacOS/otto-netwatch" clear-password --ssid "$ssid" || true; fi
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP"
if [[ "${1:-}" == "--purge" ]]; then rm -rf "$STATE_DIR"; fi
echo "Removed otto-netwatch."
