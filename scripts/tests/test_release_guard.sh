#!/bin/bash
# Tests for Otto's release path (scripts/trunk_guard.sh, install_mac.sh, otto_release.sh, land_card.sh,
# otto_weft.py) in a throwaway repo. No builds, no network: OTTO_INSTALL_DRY_RUN=1 stops each script
# right after its checks, Weft is faked with OTTO_WEFT_EVENTS or made unreachable with OTTO_WEFT_HOME.
#   bash scripts/tests/test_release_guard.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export OTTO_ASC_LATEST=0 OTTO_LOCK_DIR="$T/locks" OTTO_WEFT_LOG="$T/weft.log" OTTO_INSTALL_DRY_RUN=1 OTTO_SKIP_FETCH=1
export OTTO_WEFT_HOME="$T/no-weft"   # default: gateway unreachable -> fail open
unset OTTO_RELEASE_LOCKED HERMES_KANBAN_TASK
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; echo "$2" | sed 's/^/     /' | head -12; fail=$((fail+1)); }
g() { git -c user.email=t@t -c user.name=t "$@"; }

R="$T/repo"; mkdir -p "$R/scripts" "$R/ios"
cp "$SRC"/{trunk_guard.sh,install_mac.sh,install_ios_device.sh,otto_release.sh,land_card.sh,otto_weft.py} "$R/scripts/"
printf 'settings:\n  base:\n    CURRENT_PROJECT_VERSION: "86"\n' > "$R/project.yml"
echo 'let a = 1' > "$R/ios/A.swift"
printf ".worktrees/\n" > "$R/.gitignore"
cd "$R"; g init -q -b rebrand/otto; g add -A; g commit -qm init
g branch stale
echo 'let b = 2' > ios/B.swift; g add -A; g commit -qm "landed feature"
TIP=$(git rev-parse HEAD)

# 1. stale branch -> refused
g checkout -q stale
out=$(scripts/install_mac.sh 2>&1); rc=$?
[ $rc -ne 0 ] && [[ $out == *"build only from the rebrand/otto tip"* ]] && ok "stale branch refused" || bad "stale branch refused" "$out"

# 2. a card branch that CONTAINS trunk is still refused (only the tip itself builds)
g checkout -q -b otto/t_bbbbbbbb rebrand/otto; echo x > ios/C.swift; g add -A; g commit -qm wip
out=$(scripts/install_mac.sh 2>&1); rc=$?
[ $rc -ne 0 ] && [[ $out == *"Feature cards never install"* ]] && ok "card branch ahead of trunk refused" || bad "card branch refused" "$out"

# 3. trunk tip, Weft unreachable -> allowed (fail open), logged
g checkout -q rebrand/otto
out=$(scripts/install_mac.sh 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *"dry run: would build"* ]] && [[ $out == *"fail open"* ]] && grep -q "Weft unreachable" "$OTTO_WEFT_LOG" \
  && ok "tip allowed; Weft unreachable fails open with a log line" || bad "tip allowed (fail open)" "$out"

# 4. uncommitted change under ios/ -> refused
echo dirty >> ios/A.swift
out=$(scripts/install_mac.sh 2>&1); rc=$?
[ $rc -ne 0 ] && [[ $out == *"uncommitted changes"* ]] && ok "dirty tree refused" || bad "dirty tree refused" "$out"
g checkout -q -- ios/A.swift

# 5. Weft reachable (faked): a landing not in HEAD -> refused; all landings in HEAD -> allowed
FAKE_WEFT="$T/weft"; mkdir -p "$FAKE_WEFT/packages/adapters/hermes/scripts"   # exists, but events are faked
OTHER=$(cd "$T" && git init -q other && cd other && g commit -q --allow-empty -m x && git rev-parse HEAD)
printf '[{"seq":5,"kind":"land","status":"accepted","change":"hermes-default/t_cccccccc","payload":{"sha":"%s","trunk_ref":"refs/heads/rebrand/otto"}}]' "$OTHER" > "$T/missing.json"
out=$(OTTO_WEFT_HOME="$FAKE_WEFT" OTTO_WEFT_EVENTS="$T/missing.json" scripts/install_mac.sh 2>&1); rc=$?
[ $rc -ne 0 ] && [[ $out == *"Weft has landings on rebrand/otto that this build does not contain"* ]] \
  && ok "landing missing from the build refused" || bad "landing missing refused" "$out"
printf '[{"seq":5,"kind":"land","status":"accepted","change":"hermes-default/t_cccccccc","payload":{"sha":"%s","trunk_ref":"refs/heads/rebrand/otto"}},{"seq":6,"kind":"land","status":"accepted","payload":{"sha":"%s","trunk_ref":"refs/heads/main"}}]' "$TIP" "$OTHER" > "$T/ok.json"
out=$(OTTO_WEFT_HOME="$FAKE_WEFT" OTTO_WEFT_EVENTS="$T/ok.json" scripts/install_mac.sh 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *"weft: ok (1 landings"* ]] && ok "all rebrand/otto landings in HEAD -> allowed (other trunks ignored)" || bad "weft ok" "$out"

# 6. two concurrent installs -> the second waits on the lock
start=$(date +%s)
OTTO_DRY_RUN_SLEEP=3 scripts/install_mac.sh > "$T/first.out" 2>&1 &
p1=$!; sleep 0.7
OTTO_DRY_RUN_SLEEP=0 scripts/install_mac.sh > "$T/second.out" 2>&1; rc2=$?
end=$(date +%s); wait $p1; rc1=$?
second=$(cat "$T/second.out")
[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ $((end - start)) -ge 3 ] && [[ $second == *"lock is held"*"install_mac.sh"* ]] \
  && ok "second concurrent install waited $((end - start))s for the lock and was told who held it" \
  || bad "concurrent lock" "rc1=$rc1 rc2=$rc2 waited=$((end - start))s\n$second"

# 7. the release step: build number from the branch, nested installs don't deadlock on the lock
out=$(perl -e 'alarm 30; exec @ARGV' scripts/otto_release.sh --mac --ipad 0000 2>&1); rc=$?
[ $rc -eq 0 ] && [[ $out == *"would commit Build 87"* ]] && [[ $out == *"would build and install Otto for Mac"* ]] \
  && [[ $out == *"Otto for iOS"* ]] && ok "otto_release.sh: next build 87, nested installs share the lock" || bad "otto_release" "$out"

# 8. land_card.sh: rebases the card, merges --no-ff, removes the worktree, Weft unreachable -> still lands in git
g worktree add -q -b otto/t_aaaaaaaa .worktrees/t_aaaaaaaa rebrand/otto
echo 'let d = 4' > .worktrees/t_aaaaaaaa/ios/D.swift
g -C .worktrees/t_aaaaaaaa add -A; g -C .worktrees/t_aaaaaaaa commit -qm "feature d [t_aaaaaaaa]"
echo 'let e = 5' > ios/E.swift; g add -A; g commit -qm "trunk moved meanwhile"
out=$(cd .worktrees/t_aaaaaaaa && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  bash scripts/land_card.sh t_aaaaaaaa 2>&1); rc=$?
subj=$(git log -1 --format=%s rebrand/otto)
[ $rc -eq 0 ] && [ -f ios/D.swift ] && [ -f ios/E.swift ] && [ ! -d .worktrees/t_aaaaaaaa ] \
  && [[ $subj == "Merge branch 'otto/t_aaaaaaaa' [t_aaaaaaaa]" ]] && git merge-base --is-ancestor HEAD~1 HEAD \
  && ok "land_card.sh merged the rebased card into rebrand/otto and removed its worktree" || bad "land_card" "rc=$rc $subj\n$out"

# 9. land_card.sh refuses a card with uncommitted work
g worktree add -q -b otto/t_dddddddd .worktrees/t_dddddddd rebrand/otto
echo 'let f = 6' > .worktrees/t_dddddddd/ios/F.swift
out=$(bash scripts/land_card.sh t_dddddddd 2>&1); rc=$?
[ $rc -ne 0 ] && [[ $out == *"uncommitted work"* ]] && [ -d .worktrees/t_dddddddd ] && ok "land_card.sh refuses uncommitted work" || bad "land_card dirty" "$out"

echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
