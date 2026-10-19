#!/bin/bash
# Point Hérmes on a device at the live weft-gateway without showing the token anywhere:
# reads ~/.config/weft/ios-live.json (written by weft_live_seed.mjs seed) and launches the app
# with hermes://weft?url=..&token=.. as the payload URL. The phone must be unlocked.
#   scripts/weft_configure_device.sh [device udid] [observer|human|john]   (default GoldBrick, john = observe+human on all repos)
set -euo pipefail
DEV=${1:-00008140-0009145E220B001C}
ROLE=${2:-john}
PAY=$(python3 -c "
import json, os, urllib.parse as u
st = json.load(open(os.path.expanduser('~/.config/weft/ios-live.json')))
print('hermes://weft?url=' + u.quote(st['url'], safe='') + '&token=' + u.quote(st['$ROLE'], safe=''))")
xcrun devicectl device process launch --device "$DEV" --terminate-existing --payload-url "$PAY" ai.elier.hermes 2>&1 \
  | grep -v -i -e token -e 'hermes://' | tail -3
