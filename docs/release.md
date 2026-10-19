# Otto release path: Weft-guarded, one lane

Why: on 2026-10-18 five parallel Otto cards merged cleanly but **installed** over each other: a card
installed a build from a stale worktree over the freshly installed workspace dashboard, and another
launched its own stale Debug Otto for a screenshot. John saw features "disappear" twice. Since then:

1. **Weft enforces hermes-ios** (`~/.config/weft/hermes-adapter.json` → `modes.hermes-ios = enforce`).
   An edit that would overwrite something already landed is blocked (`stale_overwrite`), same-file
   work by two cards gets a `claim_wait` warning in the tool result, and `git commit` /
   `kanban_complete` are refused while a card has open Weft errors. **Fail open**: when the gateway
   is unreachable, every tool call goes through (one log line in `~/.cache/weft-hermes/<profile>.log`,
   circuit breaker, at most one timeout per 5 minutes). Proof: `scripts/weft_conflict_probe.py`
   (output in `docs/weft-evidence/conflict-probe.txt`).
2. **Cards land, they don't install.** A card's last step is `scripts/land_card.sh <task_id>`:
   rebase onto `rebrand/otto`, `merge --no-ff`, push, post the Weft `land` (trunk_ref
   `refs/heads/rebrand/otto`) so the card's claims are released and later cards are told to rebase,
   remove the worktree. One landing at a time (`flock ~/.hermes/locks/otto-trunk.lock`).
3. **Only the release step installs or uploads**: `scripts/otto_release.sh`, run from the main
   checkout (`~/code/hermes-ios`, on `rebrand/otto`) by the operator or a "Release" card:

   ```sh
   scripts/otto_release.sh --mac --testflight                                 # Mac + TestFlight (iOS)
   scripts/otto_release.sh --mac --iphone <udid> --ipad <udid> --ipad <udid>  # devices
   scripts/otto_release.sh --mac-store                                        # Mac App Store upload
   ```

   - one install/release at a time: `flock ~/.hermes/locks/otto-release.lock` (a second run waits and
     prints who holds it; nested scripts share the lock);
   - trunk tip only: `HEAD == rebrand/otto`, nothing uncommitted under `ios/`, `project.yml`,
     `Packages/`, `origin/rebrand/otto` not ahead, and every landing Weft has on `rebrand/otto` is in
     `HEAD` (`scripts/otto_weft.py check`). Weft unreachable → the git checks + lock still apply;
   - build number = max(`project.yml`, newest App Store Connect build) + 1, committed on
     `rebrand/otto` as `Build N [release]` and pushed. Nothing else bumps `CURRENT_PROJECT_VERSION`;
   - every install/upload is recorded in Weft (system `checkpoint` with `x_install {build, target,
     devices}`), which the Weft strip shows in blue.

   `install_mac.sh`, `install_ios_device.sh`, `release.sh`, `release_mac.sh` carry the same lock and
   guard (`scripts/trunk_guard.sh`), so calling one directly is just as safe. `OTTO_INSTALL_DRY_RUN=1`
   runs only the checks. `OTTO_ALLOW_STALE_INSTALL=1` skips the trunk checks (deliberate bisecting
   only; never the lock).
4. **Debug Mac builds are "Otto Dev"** (`ai.elier.hermes.mac.dev`): a scratch/screenshot build can't
   replace or be mistaken for John's `/Applications/Otto.app` (`ai.elier.hermes.mac`). Quit it when
   the screenshot is taken. `install_mac.sh` installs Release only.
5. **Otto shows it**: the workspace dashboard's Weft strip (Mac/iPad under board + usage, ⇧⌘E on
   the Mac; iPhone: the Weft button in the workspace header) lists who is editing which files,
   conflicts (amber), landings (green) and installs/releases (blue). Rows open the Weft event detail.

Tests: `bash scripts/tests/test_release_guard.sh` (stale branch refused, tip allowed, dirty tree
refused, missing Weft landing refused, Weft down fails open, concurrent installs wait on the lock,
release numbering, land_card merge + refusal); adapter tests in `~/github/weft`
(`packages/adapters/hermes/tests`, `EnforceFailsOpenTests`); Swift `WeftStripTests`.

Weft quirk worth knowing: a brand-new card session's first edit to a file that was ever landed can
be blocked once with `stale_overwrite ... after your base #0` (the new session hasn't been told about
trunk yet). Retrying the same edit passes; it is not a real conflict.
