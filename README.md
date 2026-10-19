# Otto

Otto is a set of open-source native apps for [Hermes Agent](https://github.com/NousResearch/hermes-agent):
iPhone and iPad, Mac, Apple Watch and Apple TV. It talks to your own Hermes gateway; nothing goes
through a third-party server.

- Organized by workspaces: each workspace has its chats and its kanban board side by side.
- Tool calls are visible: every command, file read or edit, and search the agent runs shows up in the
  chat as it happens, with its input and output.
- Also: voice mode, automations (cron jobs), skills, memory, artifacts, usage limits, widgets and a
  terminal pane.

Otto is an independent project, not affiliated with Nous Research.

## Layout

| Path | What |
|---|---|
| `ios/Hermes` | iPhone / iPad app (shared with the Mac app) |
| `ios/OttoMac` | Mac app shell (native SwiftUI) |
| `ios/HermesWatch`, `ios/HermesTV`, `ios/HermesWidgets`, `ios/HermesShare` | Watch, TV, widgets, share extension |
| `relay/` | Small Python service that runs next to Hermes on your Mac: board, voice, pairing, terminal ([relay/README.md](relay/README.md)) |
| `docs/` | Design and implementation notes |

## Build

Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # optional, see below
xcodegen generate
open Hermes.xcodeproj
```

The project file is generated from `project.yml` and is not committed. Signing settings in
`project.yml` use the original developer's team and bundle IDs; change `DEVELOPMENT_TEAM`,
`bundleIdPrefix` and the `PRODUCT_BUNDLE_IDENTIFIER`s to your own to run on a device.

`Config/Local.xcconfig` (gitignored) holds per-machine settings:

- `OTTO_DEFAULT_HOST`: your Hermes Mac's Tailscale host, e.g. `my-mac.my-tailnet.ts.net`. The Mac app
  then offers "Use Tailscale" for `https://<host>:8642`, and the Apple TV pairing screen starts with it.
  Leave it empty and the apps show their normal connect screen.

Tests: `xcodebuild test -project Hermes.xcodeproj -scheme Hermes -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
and `cd relay && pytest`.

## Connect to your Hermes gateway

1. Turn on the Hermes API server and give it a key: `API_SERVER_KEY=<a long random string>` in
   `~/.hermes/.env` (default port 8642).
2. Start the relay on the same Mac (`relay/kanban_relay.py`, port 8650; see [relay/README.md](relay/README.md)).
   It reads the same `~/.hermes/.env`.
3. Reach it from your phone: with Tailscale,
   `tailscale serve --bg --https=8642 http://127.0.0.1:8642` and
   `tailscale serve --bg --https=8651 http://127.0.0.1:8650`.
4. In Otto, enter `https://<your-mac>.<tailnet>.ts.net:8642` and the key. The relay is found on the
   same host at port 8651 (override under Settings → Board).

On the Mac, "Use This Mac" pairs with the local gateway: the relay shows an Allow dialog with a
code, and the key goes into your Keychain.

Optional, for the voice persona (`~/.hermes/.env`): `OTTO_USER_NAME`, `OTTO_USER_PLACE`,
`OTTO_USER_TZ` (IANA time zone).

## License

MIT, see [LICENSE](LICENSE). Third-party code and approaches: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
