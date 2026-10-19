#!/usr/bin/env bash
# Watch Otto's App Sandbox denials while you click through the app (Mac App Store build).
# Usage: scripts/mac_sandbox_check.sh [seconds=180]   then use Otto; prints a summary at the end.
# Known OS noise on macOS 27 (logged by nearly every sandboxed process) is listed separately.
set -euo pipefail
SECS="${1:-180}"
OUT="${TMPDIR:-/tmp}/otto-sandbox-$(date +%s).log"
echo "Watching Otto sandbox denials for ${SECS}s → $OUT. Use Otto now."
log stream --style compact --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "Otto("' >"$OUT" 2>&1 &
PID=$!
sleep "$SECS"
kill "$PID" 2>/dev/null || true
NOISE='vfs.disk-space'
echo
echo "OS noise ($NOISE): $(grep -c "$NOISE" "$OUT" || true) line(s)"
echo "Other denials:"
grep 'deny(' "$OUT" | grep -v "$NOISE" | sed -E 's/.*Sandbox: //; s/^[0-9]+ duplicate reports? for Sandbox: //' | sort | uniq -c | sort -rn || echo "  none"
