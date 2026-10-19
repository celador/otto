# Hérmes iOS — handoff (2026-09-30)

Read `docs/architecture.md` first (Runs API, reattach, event names, rules).
This doc covers the current state, **open bugs (fix these first)**, and next work.

## Project facts
- Repo: `~/code/hermes-ios`, branch `main`, pushed. Last commits:
  - `8c4d650` v0.3 features (dictation, read aloud, reply actions, starter prompts, Siri/Shortcuts, widgets, Control Center, haptics)
  - `eee8e10` attempted composer fixes (DraftStore + dictation generation guard) — **John reports the bugs still happen; treat as unverified.**
- XcodeGen: edit `project.yml`, run `xcodegen generate`. `*.xcodeproj` is gitignored.
- Targets: `Hermes` (app, `ai.elier.hermes`), `HermesWidgets` (WidgetKit extension, `ai.elier.hermes.widgets`), `HermesTests` (Swift Testing).
- Shared code for app + widget: `ios/Shared/LaunchIntents.swift` (LaunchAction URLs + App Intents).
- iOS 18 target, Swift 6, team `UFF39H3A3T`.
- Gateway: `https://my-mac.example.ts.net:8642` (tailnet only), bearer = `API_SERVER_KEY` in `~/.hermes/.env`. **Never print or commit the key.**

## Build / test / install
**Installs and uploads go only through the release step: `scripts/otto_release.sh` from the main checkout (docs/release.md).** Feature cards finish with `scripts/land_card.sh <task_id>` and never install (docs/agent-rules.md is the card footer). Every install script takes the release lock (`flock ~/.hermes/locks/otto-release.lock`) and refuses unless HEAD is exactly the rebrand/otto tip, clean, and contains every landing Weft has on rebrand/otto (fail open to the git check when Weft is down). The raw device commands below are reference only.
```bash
cd ~/code/hermes-ios && xcodegen generate
# tests (simulator)
xcodebuild -project Hermes.xcodeproj -scheme Hermes -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath $TMPDIR/hermes-dd test
# John's iPhone ("GoldBrick")
D=<your-iphone-udid>   # xcrun devicectl list devices
xcodebuild -project Hermes.xcodeproj -scheme Hermes -configuration Debug -destination "id=$D" -derivedDataPath $TMPDIR/hermes-dev -allowProvisioningUpdates build
xcrun devicectl device install app --device $D $TMPDIR/hermes-dev/Build/Products/Debug-iphoneos/Hermes.app
xcrun devicectl device process launch --terminate-existing --device $D ai.elier.hermes   # fails with "Locked" if phone locked; install still succeeded
```
Debug launch args (simulator): `-hermes.url`, `-hermes.key`, `-hermes.autosend "prompt"`, `-hermes.open <sessionID>`, `-hermes.launchURL "hermes://new?dictate=1"`, `-hermes.autoimage <path>`, `-hermes.autosteer "text"`, `-hermes.expandTools YES`.

**Simulator warning:** on 2026-09-30 CoreSimulator wedged (`simctl boot/io/openurl` hung, even after killing CoreSimulatorService). `simctl openurl hermes://…` also triggers an "Open in Hermes?" system alert that blocks automation — use `-hermes.launchURL` instead. A Mac reboot is probably needed before simulator screenshots work again. None of the v0.3 UI has been visually verified on a simulator; John has only used it on-device.

## Composer / delivery bugs — fixed in build 2 (2026-09-30)
Build number now bumps per phone install and shows in Settings → Gateway → "This app".

1. **Typed text lost after switching apps** — root cause: iOS ended the app in the background; relaunch landed on the chat list (draft was saved, but hidden in that chat). Fix: `@AppStorage("openChat")` (`OpenChat` in SessionListView) reopens the chat on launch. Verified in simulator (type → Home → terminate → relaunch → same chat, same text).
2. **Dictated text stays after Send** — not reproducible in the simulator (no speech input). Guards: `Dictation` generation counter (eee8e10) + `ComposerEcho` (DraftStore.swift) clears text written back within 2 s of Send that equals the message or its ending (late recognizer result, keyboard dictation re-commit, pending autocorrect). Unit-tested; **needs John on device**. Still ask which mic he uses if it recurs.
3. **Dropped messages** — root cause (from gateway logs): the phone made no requests after 15:41, so both sends failed on the network (Tailscale down), and the failure only lived in memory — the next reload replaced the transcript with server history. Fix: `Chat/Outbox.swift` persists each message before sending, removes it only when the gateway accepts it; failures show "Not delivered · Retry · Delete". Retry reuses the id as Idempotency-Key. Steer to a finished run (gateway 409 `run_not_accepting_steer`) now starts a new turn. Verified in simulator: send to unreachable URL → relaunch on real gateway → still shown → Retry → delivered once.

## What shipped in v0.3 (on John's phone)
- `Voice/Dictation.swift` — SFSpeechRecognizer + AVAudioEngine, live partials into composer, level meter.
- `Voice/Speaker.swift` — AVSpeechSynthesizer read-aloud; `SpeechText.clean` strips markdown (tested).
- `Voice/Haptics.swift` — send tap, success on run finish.
- `ChatView` — mic button in composer, `MessageActions` (Copy / Read aloud / Share) under the last reply of each turn, `StarterPrompts` on empty chat, launch handling (`LaunchAction`).
- `App/HermesShortcuts.swift` — AppShortcutsProvider: Ask / Talk to / Show a photo / New chat.
- `HermesWidgets/` — Home Screen (small/medium) launcher, Lock Screen (circular/rectangular), Control Center controls (New chat, Talk).
- Info.plist: mic + speech recognition usage strings.

## Next feature work (John approved direction, not started)
John wants Hermes-specific features surfaced with a bigger menu (tabs):
1. **Chats** (existing).
2. **Board** — Hermes Kanban: boards → columns (triage, todo, ready, running, blocked, done), task detail with comments/events, comment, unblock, complete, create task, switch board.
3. **Automations** — cron jobs: list, run now, pause/resume. The gateway already serves these: `GET /api/jobs`, `POST /api/jobs/{id}/run|pause|resume` (bearer = API key, verified 200 on `/api/jobs`).
4. Later: Skills, Memory.

**Blocker for Board — needs John's decision:** the Kanban API is not on the gateway (8642). It lives on the dashboard server (`127.0.0.1:9119`, `/api/plugins/kanban/{boards,board,tasks,tasks/{id},tasks/{id}/comments,...}`), which is loopback-only and authenticates with `X-Hermes-Session-Token` (`HERMES_DASHBOARD_SESSION_TOKEN` in `~/.hermes/.env`). That token grants the **whole dashboard** (config, etc.). Options:
   - (a) `tailscale serve` 9119 on a new port (e.g. 9443) + the app stores the dashboard token in Keychain (second field in Connect/Settings). Fastest; broader access.
   - (b) Add narrow kanban routes to the gateway API server (bearer = API key) — cleaner, but it's a Hermes core change (upstream `~/.hermes/hermes-agent`), so prefer a plugin or upstream PR.
   - (c) The kanban MCP at `https://kanban.elier.ai/mcp` (Clerk OAuth) — more work in-app.
   John has not chosen yet. Build Automations first; it has no blocker.

## Rules (from John)
- No TestFlight; John presses Submit himself. Not ready for review anyway (needs demo gateway, privacy/support URLs).
- Test on simulator and look at a screenshot before claiming UI works; say plainly what was only compiled vs. seen.
- Keep core content above the fold, dense iPhone layouts, no "N due"/guilt counters.
- Commit + push to `main` when a change is verified; install on GoldBrick for John to try.


## v0.4 — tabs, Board, Automations (build 3, 2026-09-30)
- `MainTabs` (HermesApp.swift): Chats · Board · Automations. Widget/Siri/notification launches switch to Chats. Debug arg `-hermes.tab board|automations`, `-hermes.openTask <id>`.
- **Board** (`Views/BoardView.swift`, `Networking/KanbanClient.swift`, `Models/BoardModels.swift`): board picker (open-count sorted), columns as sections (done hidden behind "Show N done"), task detail with Move to (triage/todo/ready/blocked+reason/done), assignee picker, comments (post as `hermes-ios`), history; long details collapse (`CollapsibleText`) so actions stay above the fold. New task sheet (title, details, assignee, triage toggle).
- Board traffic goes to the **Kanban relay** (`relay/`, see its README): `https://<gateway host>:8651`, same API key. Override in Settings → Board. The relay currently runs as a Hermes background process; John must load the LaunchAgent once from Terminal for it to survive reboots.
- **Automations** (`Views/AutomationsView.swift`): `/api/jobs` list (active first, by next run), friendly cron text (`ScheduleText`), swipe Run now / Pause / Resume, detail with last error, instructions, script.
- Verified: 34 unit tests pass; simulator screenshots of Board, task detail and Automations with live data; relay smoke test over the tailnet (create → comment → archive; blocked field → 400; DELETE → 405). Not verified on device.
- Next ideas: Live Activity for running tasks, Share extension, hands-free voice, APNs relay, Skills/Memory tabs.
