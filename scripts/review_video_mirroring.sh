#!/bin/bash
# Record the App Review video through iPhone Mirroring (physical iPhone screen), driving the app via devicectl.
S=$HOME/.hermes/cache/scratch/revvid; rm -f $S/mir.mov; DEV=00008140-0009145E220B001C
R=${R:-1112,72,326,718}
L() { xcrun devicectl device process launch --device $DEV --terminate-existing ai.elier.hermes -- "$@" 2>&1 | tail -1; }
osascript -e 'tell application "iPhone Mirroring" to activate' -e 'delay 0.5' -e 'tell application "System Events" to keystroke "1" using command down'
sleep 3
screencapture -x -R$R $S/home.png
screencapture -v -V 72 -R$R $S/mir.mov > $S/sc.log 2>&1 &
REC=$!
sleep 4
echo "launch1 $(L -hermes.tab chats -hermes.autosend "Search the web for this weekend's weather in Kyoto and suggest a one-day walking route." -hermes.expandTools YES)"
sleep 34
echo "launch2 $(L -hermes.tab agents)"
sleep 12
echo "launch3 $(L -hermes.tab usage)"
sleep 14
wait $REC
ls -la $S/mir.mov; tail -2 $S/sc.log
