# Otto for Mac

A native SwiftUI macOS app (target `OttoMac`, product `Otto.app`, bundle id `ai.elier.hermes.mac`,
macOS 26+). It is not Catalyst: it compiles the shared `ios/Hermes` sources for macOS, with the
Mac shell and shims in `ios/OttoMac/`.

## Build, install, run

Only the release step installs (docs/release.md). Parallel worktrees share one /Applications/Otto.app
(and one build number line); installing from a branch that lacks landed work silently removes it
from John's Mac. `scripts/install_mac.sh` (and `scripts/install_ios_device.sh` for phones/iPads)
take the release lock and refuse unless HEAD is exactly the rebrand/otto tip, clean, and has every
Weft landing; checked before the build and again right before copying. Feature cards never run them.

```sh
scripts/otto_release.sh --mac     # from ~/code/hermes-ios on rebrand/otto: numbers the build, installs Release
```

Debug builds are a separate app, "Otto Dev" (`ai.elier.hermes.mac.dev`, own data dir), so a scratch or
screenshot build never replaces or impersonates the installed Otto. Quit it when you're done.

What install_mac.sh runs:

```sh
xcodegen generate -q
osascript -e 'set volume output muted true'
xcodebuild -project Hermes.xcodeproj -scheme OttoMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$TMPDIR/otto-mac-dd" -allowProvisioningUpdates build
APP="$TMPDIR/otto-mac-dd/Build/Products/Release/Otto.app"
codesign --verify --deep --strict "$APP"
osascript -e 'tell application id "ai.elier.hermes.mac" to quit'; rm -rf /Applications/Otto.app
ditto "$APP" /Applications/Otto.app && open /Applications/Otto.app
```

Signed with John's Apple Development identity (team UFF39H3A3T, hardened runtime, microphone
entitlement) and App Sandboxed for the Mac App Store; see `docs/app-store/mac-sandbox.md`.

Signing is manual: the `keychain-access-groups` entitlement needs a provisioning profile and Xcode on
this Mac has no Apple account, so automatic signing can't make one. Profiles "ai.elier.hermes.mac
Development" (Release) and "ai.elier.hermes.mac.dev Development" (Debug, Otto Dev) are API-made and
cover every registered Mac; refresh them (new Mac, expiry) with
`uv run --with pyjwt --with cryptography --with requests scripts/dev_profiles.py`.

## Keychain (no password prompts)

Every credential (gateway key, Weft token, the shared relay/limits vault) goes through
`ios/LimitsShared/SecureStore.swift`. On macOS that's the data protection keychain
(`kSecUseDataProtectionKeychain`, group `UFF39H3A3T.ai.elier.hermes.shared`): access is by team +
group, not by the exact binary, so rebuilt, re-signed or worktree builds never show "wants to use your
confidential information … enter the login keychain password".

- Migration: the first time a Release build misses the gateway or Weft item, it looks once in the
  legacy login keychain, copies the value over and deletes the old item. That one read is the only
  place macOS can still ask (once per item, only if the old item's ACL doesn't trust the new build);
  the look is recorded in defaults and never repeated. SharedVault items aren't moved (rewritten at
  launch / cache).
- Otto Dev (Debug) never reads the legacy keychain: it starts clean and pairs once.
- Debug builds without keychain entitlements (unsigned, errSecMissingEntitlement -34018) keep the items
  in `Application Support/SecureStore/` instead. Release builds always use the keychain.
- Never query with `kSecUseDataProtectionKeychain` absent on macOS: for an entitled app that matches
  both keychains (a delete removes the new copy too). Use `true` (new) or explicit `false` (legacy only).

## Connection

- Default: this Mac's API server. The sandboxed app can't read `~/.hermes/.env`, so it pairs once
  through the relay: the connect screen calls `POST http://127.0.0.1:8650/macpair/start` by itself on first
  launch, the relay shows an Allow dialog with a 6-digit code (Otto shows the same code), and after the
  click `/macpair/poll` returns the gateway URL (from `API_SERVER_HOST`/`API_SERVER_PORT`, default
  `http://127.0.0.1:8642`) and `API_SERVER_KEY` once. Otto keeps them in the Keychain like any server.
  If the key is rotated: Settings → Connection → Use This Mac (pairs again). `LocalPairing.swift`,
  `relay/macpair.py`.
- Settings (⌘,) → Connection switches to Tailscale (`https://<OTTO_DEFAULT_HOST>:8642`, relay :8651,
  same key, saved in the Keychain) or back to this Mac. The Tailscale buttons only appear when the build has
  a host (`OTTO_DEFAULT_HOST` in `Config/Local.xcconfig`); otherwise use "Or enter another server". Disconnect shows the connect screen.

## What's shared and what's Mac-only

- Shared: chat (streaming, tool rows, approvals, slash commands, model picker, fast mode, read aloud,
  dictation, voice mode), Board, Changes, Automations, Artifacts, Agents, Skills, Memory, Messaging,
  Usage, Archived, Settings incl. voice picker.
- Mac-only (`ios/OttoMac`): `MacShell.swift` (split view sidebar in the Hermes desktop's density,
  connect/settings windows, menu commands), `MacComposerTextView.swift` (NSTextView composer: Return
  sends, Shift/Option-Return newline, paste/drop images), `MacChatChrome.swift` (Esc stops,
  ⌘K/⌘L focus, focused-scene actions for the Chat menu), `MacDesign.swift` (palette, friendly model
  names, grouped tool rows, sidebar rows), `MacCompat.swift` (UIKit-name shims), `MacStubs.swift`
  (no-op Live Activities / watch / HealthKit / background refresh).
- Left out on Mac: camera capture, Live Activities, widgets, watch link, HealthKit, background run
  notifications, Siri/App Intents donation, the Apple TV pairing screen.

## Workspaces

The sidebar is workspace-first: **Workspaces** (Hermes projects: icon, name, chat count; the chevron shows
the five latest chats), **Pinned**, then **Other chats** (not in any workspace). Board, Automations, Changes,
Artifacts, Agents, Skills, Memory, Usage and Archived sit in the Menu section; Messaging is gone
(configure it in the Hermes desktop). Chats move between workspaces by **dragging a chat row onto a
workspace row** (it highlights; a failed move shows a note above the footer and the row goes back), from
the context menu, the chat ⋯ menu or the workspace chip above the composer. See relay/README.md → Workspaces.

**Workspace mode (dashboard).** Clicking a workspace *enters* it (`WorkspaceMode`, persisted per device in
`mac.activeWorkspace`, so a relaunch lands back inside). The sidebar becomes ← + the workspace's name and only
its chats (newest first, same row actions); ← / Esc / ⌘[ exits back to the screen you were on. Dropping a chat
on the ← header takes it out of the workspace. The detail is a dashboard (`Views/WorkspaceDashboard.swift`):
chat | right column with the workspace's **board** (polled every 5 s, new cards glow "NEW" for 6 s; click
opens the card detail) over a compact **Usage** panel (today's spend and tokens, this chat's cost, 14-day
sparkline, Claude/Codex limit bars; polled every 12 s and at once when a run finishes or a card moves; numbers
roll). ⇧⌘B / ⇧⌘U (View menu, toolbar buttons) toggle the panes; the column width and board/usage split are
remembered (`dashboard.*` defaults). ⌘N starts a chat in the workspace you're in; ⌥⌘N and "New chat in X" still
pick a workspace explicitly. With no chat open the dashboard shows an empty composer: typing starts a chat
there. The old workspace page (header, Chats | Board) is still reachable from the row's context menu →
Workspace details. iPad (regular width) uses the same dashboard; iPhone filters the drawer list and puts
Board / Usage buttons in the workspace header (sheets). Logic + tests: `Models/WorkspaceMode.swift`,
`HermesTests/WorkspaceModeTests.swift`.

## Keep Mac awake

All inside Otto, no menu bar item: the cup in the sidebar footer (shows "Awake" while the Mac is kept awake;
click for a popover), View → Keep Mac Awake, and Settings → Keep Awake. Modes: **Off / While agents are
working / For a duration** (presets or days/hours/minutes, Add time, End now). `KeepAwake.swift` holds an
IOKit `PreventUserIdleSystemSleep` assertion only while needed: "while working" = the relay's
`GET /hermes/awake` says a chat turn or kanban run is active (older relays: `GET /hermes/running`), polled
every 10 s. Released when agents go idle, when the relay can't be reached (a timer keeps holding), at the
timer's end and when Otto quits. Works under App Sandbox (the assertion shows in `pmset -g assertions`).

A closed lid still sleeps the Mac. **Stay awake with lid closed** asks the relay (`POST /hermes/awake`,
relay/README.md → Lid-closed mode) to do it; the app makes no system changes and never asks for root. The
first time it's turned on, Otto calls `POST /hermes/awake/setup`: the relay shows the macOS administrator
prompt ("Otto wants to keep this Mac awake with the lid closed."), John approves once with Touch ID or his
password, and Otto shows "Done", "Cancelled. Nothing was changed." or the error. **Undo Lid-Closed Setup**
(Settings → Keep Awake) calls `/undo` the same way. App Review wording: docs/app-store/review-note-keep-awake.md.
Tests: `OttoMacTests` (scheme OttoMac → test).

## iPhone hotspot failover

Settings → Hotspot. When Wi-Fi stops reaching the internet (~25 s, so blips are ignored), the Mac joins the
iPhone's Personal Hotspot; it switches back once the original Wi-Fi has worked for 2 min. The sandboxed app can't
change networks, so a helper does it: **otto-netwatch** (`netwatch/`), a LaunchAgent the relay installs with
"Set Up" (`POST /hermes/hotspot/setup` → `scripts/install_netwatch.sh`, no admin prompt). Otto shows the helper's
status and edits its settings (on/off, hotspot name, password → login Keychain via the helper, Test Now) through
`/hermes/hotspot` (relay/README.md). Works with the lid closed and with or without Keep Awake. Ported from
Insomnia's hotspot handoff (THIRD_PARTY_NOTICES.md); its tmux "continue" nudge is left out.

One-time on the Mac: Location Services on (System Settings → Privacy & Security → Location Services) and allowed
for "Otto Network Helper", so it can read Wi-Fi names; System Settings → Wi-Fi → "Ask to join hotspots" →
Automatic. On the iPhone: Personal Hotspot → "Allow Others to Join" on.

## Keyboard

⌘N new chat (in the workspace you're in) · ⇧⌘N new window · ⇧⌘B / ⇧⌘U board / usage pane · ⌘[ / Esc exit workspace · Return send · Shift-Return newline · ⌘K / ⌘L focus composer ·
⇧⌘M model · ⌘/ slash commands · ⌘F find in chat · ⇧⌘V voice mode · Esc stop · ⌘R refresh · ⌘, settings.

## Pitfalls found while building it

- Before the sandbox `~/Library/Caches` was shared with every app, so files go under a folder named
  after the bundle id (`AppDirs`); `ios/OttoMac/container-migration.plist` moves those folders and the
  prefs into the container on the first sandboxed launch.
- Sandboxed, `homeDirectoryForCurrentUser` is the container: use `getpwuid(getuid())` for the real home
  (`Workspace.tildePath`). Never read `~/.hermes`, spawn processes or run AppleScript from the app; ask the
  relay over HTTP instead.
- `focusedSceneValue` with closures must be `Equatable` (by identity), or every render re-runs the menu
  commands and the app spins at 100% CPU.
- Don't build `ChatModel` inside the shell's `body`: `MacChatHost` owns it in `@State` and reads the
  transcript cache off the main thread.
- Never change NSView frames inside `sizeThatFits` (AppKit layout loop → crash); the composer measures
  text with `boundingRect` and its scroll view sizes the text view in `layout()`.
