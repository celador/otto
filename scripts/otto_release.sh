#!/bin/bash
# THE release step for Otto (docs/release.md). The only thing that installs or uploads Otto builds.
# Run by the operator or a "Release" card, from the main checkout on rebrand/otto, never by a feature card.
#
#   scripts/otto_release.sh [--mac] [--iphone <udid>]... [--ipad <udid>]... [--testflight] [--mac-store] [--no-bump]
#
# 1. takes the release lock (one install/release at a time; others wait and are told who holds it)
# 2. trunk guard: HEAD == rebrand/otto tip, clean, origin not ahead, every Weft landing included
# 3. build number = max(project.yml, newest App Store Connect build) + 1, committed on rebrand/otto
#    ("Build N [release]") and pushed. Only this step changes CURRENT_PROJECT_VERSION.
# 4. installs/uploads what was asked; each one is recorded in Weft (seen in Otto's Weft strip)
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."
source scripts/trunk_guard.sh
otto_release_lock "$SELF" "$@"

MAC=0; TF=0; MACSTORE=0; BUMP=1; IPHONES=(); IPADS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mac) MAC=1 ;;
    --testflight) TF=1 ;;
    --mac-store) MACSTORE=1 ;;
    --no-bump) BUMP=0 ;;
    --iphone) IPHONES+=("$2"); shift ;;
    --ipad) IPADS+=("$2"); shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$(git branch --show-current)" = "$OTTO_BASE_BRANCH" ] || {
  echo "error: run the release step from the checkout that has $OTTO_BASE_BRANCH checked out (the main checkout)" >&2; exit 1; }
otto_trunk_guard

if [ "$BUMP" = 1 ]; then
  CUR=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml | head -1)
  ASC=${OTTO_ASC_LATEST:-$(perl -e 'alarm 60; exec @ARGV' uv run -q ~/.appstoreconnect/asc.py GET \
    '/v1/builds?filter[app]=6818258172&sort=-uploadedDate&limit=20&fields[builds]=version' 2>/dev/null \
    | python3 -c 'import json,sys
raw = sys.stdin.read(); raw = raw[raw.find("{"):]   # asc.py prints the HTTP status line first
try: print(max(int(b["attributes"]["version"]) for b in json.loads(raw)["data"] if b["attributes"]["version"].isdigit()))
except Exception: print(0)' || echo 0)}
  [ "$ASC" = 0 ] && echo "warning: could not read App Store Connect builds; numbering from project.yml" >&2
  NEXT=$(( (CUR > ASC ? CUR : ASC) + 1 ))
  if [ "${OTTO_INSTALL_DRY_RUN:-0}" = "1" ]; then
    echo "dry run: would commit Build $NEXT (project.yml $CUR, App Store Connect $ASC)"
  else
    sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: \)\"$CUR\"/\1\"$NEXT\"/" project.yml
    git add project.yml
    git commit -q -m "Build $NEXT [release]" ${HERMES_KANBAN_TASK:+-m "Kanban-Task: $HERMES_KANBAN_TASK"}
    perl -e 'alarm 90; exec @ARGV' git push -q origin "$OTTO_BASE_BRANCH" || echo "warning: push failed; push $OTTO_BASE_BRANCH later" >&2
    echo "Build $NEXT committed on $OTTO_BASE_BRANCH ($(git rev-parse --short HEAD))"
  fi
fi

rc=0
[ "$MAC" = 1 ] && { scripts/install_mac.sh || rc=1; }
[ ${#IPHONES[@]} -gt 0 ] && { KEEP_WATCH=1 scripts/install_ios_device.sh "${IPHONES[@]}" || rc=1; }
[ ${#IPADS[@]} -gt 0 ] && { scripts/install_ios_device.sh "${IPADS[@]}" || rc=1; }
[ "$TF" = 1 ] && { scripts/release.sh || rc=1; }
[ "$MACSTORE" = 1 ] && { scripts/release_mac.sh || rc=1; }
exit $rc
