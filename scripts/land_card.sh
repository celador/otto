#!/bin/bash
# Finish an Otto feature card: rebase its branch onto rebrand/otto, merge it (--no-ff), push, post the
# Weft `land` (releases the card's claims; later cards are told to rebase), remove its worktree.
# This is the LAST step of every Otto card. Cards never install: the release step does (docs/release.md).
#
# Usage: scripts/land_card.sh <task_id> [--keep-worktree]
#   Run it from anywhere inside the repo (the card's own worktree is fine). One landing at a time
#   (flock ~/.hermes/locks/otto-trunk.lock). Weft unreachable -> the git merge still happens and the
#   landing is recorded on the next land_card.sh run (idempotent --recent catch-up).
set -euo pipefail
TASK="${1:-${HERMES_KANBAN_TASK:-}}"
[[ $TASK =~ ^t_[0-9a-f]{8}$ ]] || { echo "usage: $0 <task_id> [--keep-worktree]" >&2; exit 2; }
KEEP=0; [ "${2:-}" = "--keep-worktree" ] && KEEP=1
TRUNK="${OTTO_BASE_BRANCH:-rebrand/otto}"
MAIN="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
WT="$MAIN/.worktrees/$TASK"
[ -d "$WT" ] || { echo "error: no worktree at $WT" >&2; exit 1; }
BRANCH="$(git -C "$WT" branch --show-current)"
[ -n "$BRANCH" ] && [ "$BRANCH" != "$TRUNK" ] || { echo "error: $WT is not on a card branch ($BRANCH)" >&2; exit 1; }
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
# Copy otto_weft.py before the worktree goes away (it may be this card's own copy).
WEFT_PY="$(mktemp -d)/otto_weft.py"; cp "$SCRIPTS/otto_weft.py" "$WEFT_PY"

if [ -n "$(git -C "$WT" status --porcelain --untracked-files=all -- ios project.yml Packages scripts docs)" ]; then
  echo "error: $TASK has uncommitted work; commit it first:" >&2
  git -C "$WT" status --short -- ios project.yml Packages scripts docs | head -10 >&2; exit 1
fi

LOCK_DIR="${OTTO_LOCK_DIR:-$HOME/.hermes/locks}"; mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/otto-trunk.lock"
FLOCK="$(command -v flock || echo /opt/homebrew/bin/flock)"
"$FLOCK" -n 9 || { echo "another card is landing; waiting..." >&2; "$FLOCK" -w 1800 9; }

[ "$(git -C "$MAIN" branch --show-current)" = "$TRUNK" ] || {
  echo "error: the main checkout $MAIN is not on $TRUNK; refusing to merge there" >&2; exit 1; }
if git -C "$MAIN" remote get-url origin >/dev/null 2>&1 && perl -e 'alarm 30; exec @ARGV' git -C "$MAIN" fetch -q origin "$TRUNK"; then
  git -C "$MAIN" merge --ff-only -q FETCH_HEAD 2>/dev/null || true
fi

if ! git -C "$WT" rebase -q "$TRUNK"; then
  git -C "$WT" rebase --abort || true
  echo "error: $BRANCH does not rebase cleanly onto $TRUNK. Resolve in $WT (git rebase $TRUNK), then rerun." >&2
  exit 1
fi
AHEAD=$(git -C "$MAIN" rev-list --count "$TRUNK..$BRANCH")
if [ "$AHEAD" = 0 ]; then
  echo "$BRANCH has no commits beyond $TRUNK: nothing to merge; releasing its Weft claims" >&2
  SHA=$(git -C "$MAIN" rev-parse "$TRUNK")
  WL="$HOME/github/weft/packages/adapters/hermes/scripts/weft_land.py"
  [ -f "$WL" ] && python3 "$WL" --repo hermes-ios --git-dir "$MAIN" --ref "$TRUNK" --trunk-ref "$TRUNK" \
    --kanban-db "$HOME/.hermes/kanban/boards/otto/kanban.db" --branch "$BRANCH" --sha "$SHA" || true
else
  git -C "$MAIN" merge --no-ff -q -m "Merge branch '$BRANCH' [$TASK]" "$BRANCH"
  echo "merged $BRANCH ($AHEAD commit(s)) into $TRUNK at $(git -C "$MAIN" rev-parse --short HEAD)"
  if git -C "$MAIN" remote get-url origin >/dev/null 2>&1; then
    perl -e 'alarm 90; exec @ARGV' git -C "$MAIN" push -q origin "$TRUNK" || echo "warning: push to origin failed; push $TRUNK later" >&2
  fi
  python3 "$WEFT_PY" --repo "$MAIN" land --recent 5 || true
fi

if [ "$KEEP" = 0 ]; then
  cd "$MAIN"
  git worktree remove "$WT" && echo "removed worktree $WT (branch $BRANCH kept)" \
    || echo "warning: could not remove $WT (open files?); remove it later with git worktree remove" >&2
fi
rm -rf "$(dirname "$WEFT_PY")"
echo "landed $TASK. Do not install from the card: the release step (scripts/otto_release.sh) installs trunk."
