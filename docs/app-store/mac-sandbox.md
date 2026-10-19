# Otto for Mac: App Sandbox (Mac App Store)

Target `OttoMac`. Dev builds use bundle `ai.elier.hermes.mac` (automatic signing, `docs/macos.md`); the Mac
App Store build is `ai.elier.hermes` (see "Store record and release" below). The Mac App Store requires App
Sandbox; Otto has it on in every configuration (`ios/OttoMac/OttoMac.entitlements`, set via
`CODE_SIGN_ENTITLEMENTS` in `project.yml`).

## Store record and release

**Record: the existing Otto record (ASC app 6818258172, "Otto Agent"), as a MAC_OS version: universal
purchase.** The bundle id `ai.elier.hermes` is registered as platform UNIVERSAL, so the ASC API accepted
`POST /v1/appStoreVersions {platform: MAC_OS}` on the iOS record; no second record or name was needed. Name,
subtitle, category, privacy label, age rating, price (free) and availability are app-level and shared with
iOS; only the version's description, keywords, promo text, URLs, screenshots and review details are per
platform. Consequence: the store app has a different bundle id than dev builds, so it gets its own container
and Keychain items and pairs once ("Use This Mac") on first launch. The dev identity stays `.mac` so local
installs over `/Applications/Otto.app` keep working.

Release path (all scripted):

```sh
scripts/release_mac.sh                  # archive (overrides bundle id + manual "ai.elier.hermes MacAppStore"
                                        # profile, Apple Distribution), export .pkg (3rd Party Mac Developer
                                        # Installer), verify entitlements == OttoMac.entitlements + team/app id,
                                        # hardened runtime, signatures; upload. UPLOAD=0 stops before upload.
BUILD_VERSION=79 uv run scripts/asc_listing_mac.py metadata screenshots status
uv run scripts/asc_listing_mac.py submit    # MAC_OS reviewSubmission only; refuses if one is in review
```

Store screenshots (`mac-final-*.png`, 2880x1800) come from a Debug ad-hoc copy with a throwaway bundle id
(`ai.elier.hermes.mac.shots`) launched with `-hermes.url/-hermes.key`, `-hermes.open <session>`,
`-hermes.hideSidebar YES` (the sidebar lists real workspaces/chats) or `-hermes.keepAwakeSettings YES`;
chats are created via `POST /api/sessions` + `/v1/runs` with neutral prompts and deleted afterwards. Keep
"Hermes", "Claude" and spend figures out of the shots (Usage and the Keep Awake footnotes show them).

First submission: build 79, 2026-10-17, submission 850abed3 (MAC_OS). Sandbox check during the screenshot run
showed only the known OS noise below.

## Entitlements and why

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | Required for the Mac App Store. |
| `com.apple.security.network.client` | Otto is a client: the Hermes API server (`127.0.0.1:8642` or a tailnet / LAN / HTTPS address), the companion relay (`:8650` here, `:8651` on the tailnet), voice WebSockets. Loopback needs it too. |
| `com.apple.security.device.audio-input` | Voice mode and dictation (the microphone prompt uses `NSMicrophoneUsageDescription`). |
| `com.apple.security.files.user-selected.read-only` | "Attach image" uses the system open panel (`fileImporter` in `MacChatChrome.swift`); the picked files are read once with their security scope. Paste and drag-and-drop need nothing. |

Not used, on purpose: no `network.server` (Otto never listens), no temporary exceptions, no
`files.downloads`/home access, no Apple Events, no app groups. Keychain works without an entitlement.
Speech recognition needs only `NSSpeechRecognitionUsageDescription`. Keep-awake uses an
`IOPMAssertionCreateWithName` power assertion, which the sandbox allows (no `caffeinate`/`pmset`).

**Lid-closed mode never makes the app request root.** "Stay awake with lid closed" (in Otto's window,
View → Keep Mac Awake and Settings → Keep Awake; there is no menu bar item) only calls the relay over HTTP:
`POST /hermes/awake` for the plan and, the first time, `POST /hermes/awake/setup` (`/undo` to remove it).
The relay is installed separately, runs outside the sandbox as the user, and runs `scripts/install_awake.sh`
itself; macOS shows the system administrator prompt from the relay's process when the user enables
lid-closed mode, to install the narrow `/etc/sudoers.d/otto-awake` rule. The app contains no `Process`,
`osascript`, `AuthorizationCreate` or SMJobBless. 2.4.5 risk: the prompt reads "Otto wants to…" right
after a click in Otto, so Review may see it as the app escalating (see `review-note-keep-awake.md`).

## What changed for the sandbox

- **Token.** The pre-sandbox app read `API_SERVER_KEY` from `~/.hermes/.env` at each launch. A sandboxed app
  can't. It now pairs once with the relay on the same Mac (below) and keeps the gateway URL + key in the
  Keychain (`KeychainStore`, same as any other server). `LocalServer.env()`/`AppModel.connectWithoutSaving`
  are gone.
- **Audit of everything that touched the disk / processes / scripts** (OttoMac + shared code compiled into it):
  - Files: only `AppDirs` (Caches / Application Support / Documents, now inside the container),
    `FileManager.temporaryDirectory` (artifact previews, container tmp), and open-panel picks (scoped).
    No reads outside the container.
  - `Workspace.tildePath` used `homeDirectoryForCurrentUser`, which is the container under the sandbox; it now
    uses `getpwuid(getuid())` so `~/code/x` still shows as `~/code/x`.
  - Processes / AppleScript / Apple Events: none in the app (`Process`, `NSTask`, `NSAppleScript`, `osascript`
    don't appear in OttoMac or the shared sources it compiles). The relay, which runs outside the app, shows
    the pairing dialog.
  - Clipboard, drag and drop, `ShareLink`, Quick Look previews, `openURL`: allowed in the sandbox.
- **Data from older builds.** `ios/OttoMac/container-migration.plist` moves `~/Library/Application Support/ai.elier.hermes.mac`,
  `~/Library/Caches/ai.elier.hermes.mac` and the prefs plist into the container the first time a sandboxed
  build runs, so cached chats and settings carry over.

## Pairing with Hermes on this Mac

1. Otto's connect screen calls `POST http://127.0.0.1:8650/macpair/start` (it does this by itself on the first
   launch; afterwards **Use This Mac** in the window or in Settings → Connection).
2. The relay shows a macOS dialog: "Otto wants to connect to Hermes on this Mac. Code: 123 456". Otto shows the
   same code under "Click Allow in the dialog on this Mac".
3. Click **Allow** (Return picks Don't Allow). Otto's poll (`GET /macpair/poll?id=`) gets the gateway URL and key exactly once, connects and
   saves them in the Keychain. Nothing to type.

Security: the start/poll/cancel routes need no bearer because the app has no key yet, but they only answer a
native process on this Mac talking to `127.0.0.1` directly. Each of the three routes returns 403 when:
- the peer address isn't loopback, or the request came through Tailscale Serve (forwarding headers);
- `Host` isn't `127.0.0.1`, `localhost` or `[::1]` (optionally with a port). This blocks DNS rebinding: a
  web page whose hostname resolves to 127.0.0.1 still sends its own domain as `Host`;
- an `Origin` or any `Sec-Fetch-*` header is present. Browsers always send these on fetch/XHR; URLSession
  never does, so no web page can start, poll or cancel a pairing.

The dialog's default button is **Don't Allow**, so Return or a stray keypress can't approve a request;
Allow needs an explicit click. The key is only released after a click on this Mac's own screen (or after an
already-connected iPhone approves the code via the Apple TV approval route; the pools are shared). Codes
expire after 10 minutes, one dialog at a time, starts are rate-limited, and the poll id is a 24-byte secret.
Relay auth for everything else is unchanged (bearer = `API_SERVER_KEY`).

Fallbacks: **Use Tailscale** reuses the key Otto already holds (or pairs first); "Or enter another server"
takes any URL + key (another Mac, a LAN or HTTPS host). If `API_SERVER_KEY` is rotated, Settings →
Connection → Use This Mac pairs again. Relay side: `relay/macpair.py`, `relay/test_macpair.py`; app side:
`ios/Hermes/Networking/LocalPairing.swift`, `MacPairingFlow` in `ios/OttoMac/MacShell.swift`,
`ios/HermesTests/LocalPairingTests.swift`.

## Verifying

```sh
xcodebuild -project Hermes.xcodeproj -scheme OttoMac -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$TMPDIR/Otto.xcarchive" -allowProvisioningUpdates archive
codesign -d --entitlements - "$TMPDIR/Otto.xcarchive/Products/Applications/Otto.app"   # app-sandbox true
scripts/mac_sandbox_check.sh 180    # then click through Otto; prints Otto's denials minus OS noise
```

Kernel sandbox reports aren't kept by `log show`, so watch live while using the app.

Known OS noise, not Otto's: on macOS 27 the kernel logs `deny(1) system-info vfs.disk-space` for nearly
every sandboxed process (tccd, securityd, runningboardd, QuickLook, Shortcuts…) when a system framework
asks for free disk space. Otto's code doesn't ask; there's no entitlement for it and it has no effect.
Biome's "Refusing connection from Otto, process not properly entitled" isn't a sandbox denial either.
Once per launch AppKit/LaunchServices also logs a soft burst (`iokit-open-user-client AppleNVMeEANUC`,
`file-read-data …/SomeOther.app/Contents/PkgInfo` for other apps registered in LaunchServices, e.g. Xcode
DerivedData builds) the first time the app's text/Services machinery warms up. Otto doesn't make those calls,
nothing fails, and no entitlement covers them.

Pass on 2026-10-16 (Release archive, macOS 27.0.1): launch, first-run auto-pair (relay dialog shown with the
code; approved through the code route), reconnect from the Keychain on relaunch, workspaces + chats from the
migrated cache, open a chat, send a message and stream the reply with tools, board data, limits, model
visibility. Only the OS noise above showed up.

## App Review notes (Mac)

> Otto is a client for Hermes Agent, a free, open-source AI agent from Nous Research that people run on their
> own computers. Otto connects to the user's own Hermes server; there is no account, no service of mine behind
> it, and no login I can give you. It works like an SSH or database client: you install Hermes Agent, turn on
> its API server, and Otto talks only to that server.
>
> To try it on a Mac that runs Hermes: open Otto, click Use This Mac, and click Allow in the dialog that shows
> the same 6-digit code (Hermes hands Otto its access token; it's kept in the Keychain). To use a server
> elsewhere, enter its address and access key under "Or enter another server".
>
> Entitlements: App Sandbox; outgoing network connections (to the user's server); microphone (voice mode and
> dictation, only after the user starts them); read access to files the user picks in the open panel (attach an
> image). No analytics, ads, payments or third-party sign-in.
>
> Hermes Agent is MIT licensed. Otto credits Nous Research in Settings > About; I'm not affiliated with them.

A demo video like the iOS one (`docs/app-store/review-reply-2.1.md`) is the expected answer if Review asks for
more under 2.1.
