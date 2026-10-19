#!/bin/bash
# Sets up Otto's "Stay awake with lid closed" (lid-closed mode). Otto's Settings → Keep Awake does this
# for you: the Hermes relay runs this script with OTTO_AWAKE_ELEVATE=osascript, so the one privileged step
# goes through the standard macOS administrator prompt (Touch ID or password). Run by hand only on a
# headless Mac (then it uses sudo in the terminal):
#
#   bash ~/code/hermes-ios/scripts/install_awake.sh
#
# Installs:
#   /etc/sudoers.d/otto-awake   lets YOUR user run exactly these four commands without a password:
#                                 /usr/bin/pmset -a disablesleep 1|0
#                                 /usr/bin/pmset -b lowpowermode 1|0
#   ~/Library/LaunchAgents/ai.elier.otto-awake-backstop.plist
#                               runs `relay/awake.py --backstop` every minute: if a lid-closed session's
#                               end time has passed and the relay is gone, it turns sleep back on.
# Nothing else. The Otto app itself never changes system settings; the relay (relay/awake.py) does,
# through the rule above. Undo everything with scripts/uninstall_awake.sh.
#
# Adapted from Insomnia's install.sh (https://github.com/krishhgg/Insomnia, MIT, Krish Garg).
#
# Exit codes: 0 done, 3 the administrator prompt was cancelled, 1 anything else.
#
# OTTO_AWAKE_DRY_RUN=1 writes into $OTTO_AWAKE_DRY_ROOT and prints the privileged commands instead of
# running them (used by relay/test_awake.py). OTTO_AWAKE_DRY_CANCEL=1 acts as if the prompt was cancelled.
set -euo pipefail

DRY="${OTTO_AWAKE_DRY_RUN:-}"
ROOT="${OTTO_AWAKE_DRY_ROOT:-}"
ELEVATE="${OTTO_AWAKE_ELEVATE:-sudo}"   # sudo (terminal) | osascript (the relay, from Otto)
PROMPT="Otto wants to keep this Mac awake with the lid closed."
RELAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../relay" && pwd)"
LABEL="ai.elier.otto-awake-backstop"
USER_NAME="$(id -un)"
PY="${OTTO_AWAKE_PYTHON:-}"
if [[ -z "$PY" ]]; then
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "$c" ]]; then PY="$c"; break; fi
  done
fi
SUDOERS_DEST="${ROOT}/etc/sudoers.d/otto-awake"
PLIST="${ROOT}${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${ROOT}${HOME}/.hermes/logs"

run() {  # launchd step
  if [[ -n "$DRY" ]]; then echo "DRY: $*"; else "$@"; fi
}

if [[ "$(id -u)" == "0" ]]; then
  echo "Run this as yourself, not with sudo; it asks for the password when it needs it." >&2
  exit 1
fi
if [[ ! "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Unexpected user name: $USER_NAME" >&2
  exit 1
fi
if [[ -z "$PY" ]]; then
  echo "No python3 found (looked in /opt/homebrew/bin, /usr/local/bin, /usr/bin)." >&2
  exit 1
fi
if [[ ! -f "$RELAY_DIR/awake.py" ]]; then
  echo "Can't find $RELAY_DIR/awake.py" >&2
  exit 1
fi
if [[ "$ELEVATE" != "sudo" && "$ELEVATE" != "osascript" ]]; then
  echo "OTTO_AWAKE_ELEVATE must be sudo or osascript" >&2
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/otto-awake.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# 1. sudoers rule: exactly four commands, this user only.
cat > "$tmp/otto-awake" <<EOF
# Otto lid-closed mode (installed by hermes-ios/scripts/install_awake.sh; remove with uninstall_awake.sh).
# Lets ${USER_NAME} keep the Mac awake with the lid closed and restore normal sleep, nothing else.
${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -b lowpowermode 1, /usr/bin/pmset -b lowpowermode 0
EOF
/usr/sbin/visudo -cf "$tmp/otto-awake" >/dev/null
if [[ ! "$tmp" =~ ^[A-Za-z0-9/._-]+$ ]]; then
  echo "Unexpected temporary path: $tmp" >&2
  exit 1
fi
INSTALL_CMD="/usr/bin/install -m 0440 -o root -g wheel '$tmp/otto-awake' /etc/sudoers.d/otto-awake && /usr/sbin/visudo -cf /etc/sudoers.d/otto-awake"

if [[ "$ELEVATE" == "osascript" ]]; then
  if [[ -n "$DRY" ]]; then
    echo "DRY: osascript do shell script \"$INSTALL_CMD\" with prompt \"$PROMPT\" with administrator privileges"
    if [[ -n "${OTTO_AWAKE_DRY_CANCEL:-}" ]]; then echo "Cancelled." >&2; exit 3; fi
    mkdir -p "$(dirname "$SUDOERS_DEST")"
    cp "$tmp/otto-awake" "$SUDOERS_DEST"
  else
    if ! err="$(/usr/bin/osascript -e "do shell script \"$INSTALL_CMD\" with prompt \"$PROMPT\" with administrator privileges" 2>&1 >/dev/null)"; then
      if [[ "$err" == *"-128"* ]]; then echo "Cancelled." >&2; exit 3; fi
      echo "Couldn't install the rule: $err" >&2
      exit 1
    fi
  fi
elif [[ -z "$DRY" ]]; then
  echo "Installing /etc/sudoers.d/otto-awake (your Mac password, once):"
  sudo /usr/bin/install -m 0440 -o root -g wheel "$tmp/otto-awake" /etc/sudoers.d/otto-awake
else
  mkdir -p "$(dirname "$SUDOERS_DEST")"
  cp "$tmp/otto-awake" "$SUDOERS_DEST"
  echo "DRY: sudo install -m 0440 -o root -g wheel otto-awake /etc/sudoers.d/otto-awake"
fi

# 2. Backstop LaunchAgent (runs as you, every 60 s and at login). No prompt.
mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>${PY}</string>
    <string>${RELAY_DIR}/awake.py</string>
    <string>--backstop</string>
  </array>
  <key>WorkingDirectory</key><string>${RELAY_DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${HOME}/.hermes/logs/otto-awake-backstop.log</string>
  <key>StandardErrorPath</key><string>${HOME}/.hermes/logs/otto-awake-backstop.log</string>
</dict></plist>
EOF
/usr/bin/plutil -lint "$PLIST" >/dev/null
run /bin/launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
run /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"

# 3. Check.
if [[ -z "$DRY" ]]; then
  if sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
    echo "Done. Otto → Settings → Keep Awake → \"Stay awake with lid closed\" now works."
  else
    echo "The sudoers rule didn't take effect; check /etc/sudoers.d/otto-awake." >&2
    exit 1
  fi
fi
