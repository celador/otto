#!/bin/bash
# Removes Otto's lid-closed mode: turns normal sleep back on, then removes the backstop LaunchAgent,
# the sudoers rule and the journal. Otto's "Undo lid-closed setup" button does this for you (the relay runs
# it with OTTO_AWAKE_ELEVATE=osascript: one macOS administrator prompt). By hand, on a headless Mac:
#
#   bash ~/code/hermes-ios/scripts/uninstall_awake.sh
#
# Exit codes: 0 done, 3 the administrator prompt was cancelled (nothing removed), 1 anything else.
# OTTO_AWAKE_DRY_RUN=1 / OTTO_AWAKE_DRY_ROOT: print privileged steps instead (tests);
# OTTO_AWAKE_DRY_CANCEL=1 acts as if the prompt was cancelled.
set -uo pipefail

DRY="${OTTO_AWAKE_DRY_RUN:-}"
ROOT="${OTTO_AWAKE_DRY_ROOT:-}"
ELEVATE="${OTTO_AWAKE_ELEVATE:-sudo}"
PROMPT="Otto wants to undo the lid-closed setup on this Mac."
LABEL="ai.elier.otto-awake-backstop"
PLIST="${ROOT}${HOME}/Library/LaunchAgents/${LABEL}.plist"
STATE="${ROOT}${OTTO_AWAKE_HOME:-$HOME/.hermes/otto-awake}"
SUDOERS="${ROOT}/etc/sudoers.d/otto-awake"

run() { if [[ -n "$DRY" ]]; then echo "DRY: $*"; else "$@"; fi; }

if [[ "$(id -u)" == "0" ]]; then
  echo "Run this as yourself, not with sudo." >&2
  exit 1
fi

LOW=""
if [[ -f "$STATE/journal.json" ]] && grep -q '"low_power_set_by_us": true' "$STATE/journal.json"; then
  LOW=1
fi

if [[ "$ELEVATE" == "osascript" ]]; then
  # Sleep back on and the rule removed, as root, behind one administrator prompt.
  CMD="/usr/bin/pmset -a disablesleep 0"
  [[ -n "$LOW" ]] && CMD="$CMD; /usr/bin/pmset -b lowpowermode 0"
  CMD="$CMD; /bin/rm -f /etc/sudoers.d/otto-awake"
  if [[ -n "$DRY" ]]; then
    echo "DRY: osascript do shell script \"$CMD\" with prompt \"$PROMPT\" with administrator privileges"
    if [[ -n "${OTTO_AWAKE_DRY_CANCEL:-}" ]]; then echo "Cancelled." >&2; exit 3; fi
    rm -f "$SUDOERS"
  else
    if ! err="$(/usr/bin/osascript -e "do shell script \"$CMD\" with prompt \"$PROMPT\" with administrator privileges" 2>&1 >/dev/null)"; then
      if [[ "$err" == *"-128"* ]]; then echo "Cancelled." >&2; exit 3; fi
      echo "Couldn't remove the rule: $err" >&2
      exit 1
    fi
  fi
else
  # 1. Sleep back on first, while the rule still allows it without a password.
  run sudo /usr/bin/pmset -a disablesleep 0
  [[ -n "$LOW" ]] && run sudo /usr/bin/pmset -b lowpowermode 0
fi

# 2. Backstop agent.
run /bin/launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "$PLIST"

# 3. Sudoers rule (terminal path) and journal.
if [[ "$ELEVATE" != "osascript" ]]; then
  if [[ -n "$DRY" ]]; then
    rm -f "$SUDOERS"
    echo "DRY: sudo rm -f /etc/sudoers.d/otto-awake"
  else
    sudo /bin/rm -f /etc/sudoers.d/otto-awake
  fi
fi
rm -rf "$STATE"

if [[ -z "$DRY" ]]; then
  echo "Removed. pmset now reports: $(/usr/bin/pmset -g | grep -i sleepdisabled | tr -s ' \t' ' ')"
fi
exit 0
