# Otto's release guard. Sourced by every script that installs or uploads a build
# (install_mac.sh, install_ios_device.sh, release.sh, release_mac.sh, otto_release.sh).
#
# Why: parallel kanban cards once installed stale worktree builds over a newer one, twice, and John
# saw landed features "disappear". Rules (docs/release.md):
#   1. One install/release at a time: otto_release_lock re-execs the script under
#      flock ~/.hermes/locks/otto-release.lock (others wait and are told who holds it).
#   2. Build only from the rebrand/otto tip: HEAD == rebrand/otto, nothing uncommitted under ios/,
#      project.yml or Packages/, origin/rebrand/otto not ahead.
#   3. Weft agrees: every landing Weft has on rebrand/otto is in HEAD (scripts/otto_weft.py check).
#      Weft unreachable -> fail open: rules 1-2 still hold, one log line.
# Feature cards never call these: they finish with scripts/land_card.sh.
# Override for deliberate bisecting only: OTTO_ALLOW_STALE_INSTALL=1 (skips 2-3, never 1).

OTTO_BASE_BRANCH="${OTTO_BASE_BRANCH:-rebrand/otto}"
OTTO_LOCK_DIR="${OTTO_LOCK_DIR:-$HOME/.hermes/locks}"
OTTO_LOCK="$OTTO_LOCK_DIR/otto-release.lock"

# Usage (first line of a script, before any work): otto_release_lock "$0" "$@"
otto_release_lock() {
  [ "${OTTO_RELEASE_LOCKED:-}" = "$OTTO_LOCK" ] && return 0
  local self="$1"; shift
  mkdir -p "$OTTO_LOCK_DIR"
  local flock_bin; flock_bin="$(command -v flock || true)"
  [ -n "$flock_bin" ] || flock_bin=/opt/homebrew/bin/flock
  if [ ! -x "$flock_bin" ]; then
    echo "error: flock not found (brew install flock)" >&2; exit 1
  fi
  if ! "$flock_bin" -n "$OTTO_LOCK" true 2>/dev/null; then
    echo "otto release lock is held: $(cat "$OTTO_LOCK.holder" 2>/dev/null || echo unknown); waiting..." >&2
  fi
  export OTTO_RELEASE_LOCKED="$OTTO_LOCK"
  exec "$flock_bin" -w "${OTTO_LOCK_WAIT:-5400}" "$OTTO_LOCK" /bin/bash -c '
    echo "$$ $(date +%H:%M:%S) $2 (${HERMES_KANBAN_TASK:-operator}) in $PWD" > "$1.holder"
    shift 2; exec "$@"' _ "$OTTO_LOCK" "$(basename "$self")" "$self" "$@"
}

# Usage: otto_trunk_guard   (cwd = the checkout being built)
otto_trunk_guard() {
  if [ "${OTTO_ALLOW_STALE_INSTALL:-0}" = "1" ]; then
    echo "warning: OTTO_ALLOW_STALE_INSTALL=1, trunk checks skipped" >&2; return 0
  fi
  local head trunk dirty
  if ! trunk=$(git rev-parse --verify -q "$OTTO_BASE_BRANCH^{commit}"); then
    echo "Refusing to install: branch $OTTO_BASE_BRANCH not found" >&2; exit 1
  fi
  head=$(git rev-parse HEAD)
  if [ "$head" != "$trunk" ]; then
    echo "Refusing to install: build only from the $OTTO_BASE_BRANCH tip." >&2
    echo "  HEAD $(git rev-parse --short HEAD) != $OTTO_BASE_BRANCH $(git rev-parse --short "$trunk")." >&2
    echo "  Feature cards never install: finish with scripts/land_card.sh <task>; the release step" >&2
    echo "  (scripts/otto_release.sh, run from the main checkout) installs." >&2
    exit 1
  fi
  dirty=$(git status --porcelain --untracked-files=all -- ios project.yml Packages 2>/dev/null)
  if [ -n "$dirty" ]; then
    echo "Refusing to install: uncommitted changes would go into the build:" >&2
    echo "$dirty" | head -10 >&2; exit 1
  fi
  if [ "${OTTO_SKIP_FETCH:-0}" != "1" ] && git remote get-url origin >/dev/null 2>&1; then
    if perl -e 'alarm 20; exec @ARGV' git fetch -q origin "$OTTO_BASE_BRANCH" 2>/dev/null; then
      if ! git merge-base --is-ancestor FETCH_HEAD HEAD; then
        echo "Refusing to install: origin/$OTTO_BASE_BRANCH has commits this checkout lacks; pull first." >&2
        exit 1
      fi
    else
      echo "warning: could not fetch origin/$OTTO_BASE_BRANCH; checking locally only" >&2
    fi
  fi
  local rc=0
  python3 "$(git rev-parse --show-toplevel)/scripts/otto_weft.py" --repo "$PWD" check --head "$head" || rc=$?
  case $rc in
    0) ;;
    75) echo "weft unreachable: git trunk check + lock only (fail open)" >&2 ;;
    *) exit 1 ;;
  esac
}

# Usage: otto_note_install <target> <build> [devices]
otto_note_install() {
  [ "${OTTO_INSTALL_DRY_RUN:-0}" = "1" ] && [ -z "${OTTO_NOTE_IN_DRY_RUN:-}" ] && return 0
  python3 "$(git rev-parse --show-toplevel)/scripts/otto_weft.py" --repo "$PWD" note \
    --head "$(git rev-parse HEAD)" --target "$1" --build "$2" --devices "${3:-}" || true
}
