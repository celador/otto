# Card footer for Otto (hermes-ios) cards

Paste this at the end of every Otto feature card body (and read `docs/HANDOFF.md`, `docs/release.md`).

- Work in your card's worktree on your card branch. Integration branch: `rebrand/otto` (not `main`).
- Weft enforces this repo. If an edit is blocked with a Weft diagnostic, re-read the cited file
  against the current code and redo the edit; if it says to rebase, `git rebase rebrand/otto`.
- Run the tests for what you touched (`xcodebuild test`; scripts: `bash scripts/tests/test_release_guard.sh`).
- **Finish = `scripts/land_card.sh <task_id>`** (rebase, merge into rebrand/otto, push, Weft land,
  remove the worktree), then complete the card.
- **Never install from your worktree.** No `install_mac.sh` / `install_ios_device.sh` / TestFlight
  from a feature card, and never launch a Debug Otto as John's running app: Debug Mac builds are
  "Otto Dev" (`ai.elier.hermes.mac.dev`); quit it after screenshots. Installs and uploads happen only
  in the release step, `scripts/otto_release.sh`, from the main checkout (operator or a "Release" card).
- Never bump `CURRENT_PROJECT_VERSION` in a card; the release step numbers builds.
- Leave other sessions' uncommitted files alone (e.g. untracked `docs/app-store/review-reply-otto.md`).

Release card body: `cd ~/code/hermes-ios && scripts/otto_release.sh --mac --testflight [--iphone <udid>] [--ipad <udid>]`,
then check the installed build (`defaults read /Applications/Otto.app/Contents/Info.plist CFBundleVersion`).
