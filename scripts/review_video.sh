#!/bin/bash
# Record the App Review screen recording on John's physical iPhone (no taps needed).
# Phone must be unlocked on the Home Screen and running a DEBUG build (launch args).
# Neutral content only: a fresh chat with a weather/travel prompt, Skills, Usage.
set -uo pipefail
DEV=${DEV:-00008140-0009145E220B001C}
OUT=${OUT:-$HOME/.hermes/cache/scratch/revvid}
mkdir -p "$OUT"; rm -f "$OUT/raw.mp4"
osascript -e 'set volume output muted true' 2>/dev/null
L() { xcrun devicectl device process launch --device "$DEV" --terminate-existing ai.elier.hermes -- "$@" >/dev/null 2>&1; }

xcrun devicectl device capture screen-record --device "$DEV" --destination "$OUT/raw.mp4" --duration ${DUR:-85} >"$OUT/rec.log" 2>&1 &
REC=$!
sleep 4                                   # Home Screen first: the recording starts before launch
L -hermes.tab chats -hermes.autosend "Search the web for today's weather in Lisbon and suggest three things to do there this afternoon." -hermes.expandTools YES
sleep 50                                  # tool call + streamed reply
L -hermes.tab skills
sleep 10
L -hermes.tab usage
sleep 10
wait $REC
xcrun devicectl device process launch --device "$DEV" --terminate-existing ai.elier.hermes -hermes.tab chats >/dev/null 2>&1
ls -la "$OUT/raw.mp4" && cat "$OUT/rec.log" | tail -2
