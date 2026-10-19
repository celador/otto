# Changes — Weft's combined change log (card I1, board `weft`)

Drawer → **Changes**. It's the phone as the human's supervision surface for agents that change code unwatched
(Weft design principle 9, "the editor disappears"). It shows every intent, edit, squiggle, negotiation, landing
and revert across repos, newest first and live. From there you can approve, undo, pause/resume or message an agent.

Protocol: WCP v0.1 observer + human API (`~/github/weft/docs/protocol/wcp-v0.md` §9).

## Code (`ios/Hermes/Weft/`)
- `WeftModels.swift` has the wire types (EventRecord, pages, stream frames, HumanAction). It uses explicit
  CodingKeys and no `convertFromSnakeCase`, because payload keys like `reply_to` must stay as sent. Unknown kinds,
  fields and diagnostic codes decode leniently (spec §10).
- `WeftLog.swift` is a pure value type and holds the resume logic. It keeps records per repo keyed by seq, de-dupes
  by seq, and tracks a per-repo high-water mark (the `after=` resume point). It caps each repo at 500 records and
  merges them into one feed ordered by `(ts, repo, seq)`. It also computes the filters, negotiation threads
  (`reply_to` chains), candidates per task (approved / landed / reverted) and the paused state of each agent.
- `WeftClient.swift` covers HTTPS and the WebSocket. Every request sends `WCP-Version: 0.1`. The token goes in
  `Authorization` (also on the WS upgrade) and never in a URL. Actions send an `Idempotency-Key`. The address and
  token live in their own Keychain item (`ai.elier.hermes.weft`).
- `WeftStore.swift` follows the same detach/reattach discipline as `ChatModel`:
  - **Detach.** When the screen disappears or the app goes to the background, it closes the sockets.
  - **Catch up.** On foreground or reconnect it first pages `events?after=<high-water>`. A new repo, or one more
    than 500 behind, gets a `tail=1` page instead (the old rows are dropped so the window stays contiguous).
  - **Stream.** It then reopens `stream?after=<high-water>` (replay → `replay.done` → live).
  - **Reconnect.** Silence for more than 75 s counts as a dead socket and triggers a reconnect, with backoff up to
    30 s. Close code 4413 (replay cap, 5000 on the gateway) means refresh `/v1/repos`, page (a fresh tail when the
    gap is past the 500-record window), then reconnect. 4401 and 4403 stop with an error. `WeftStreamPolicy`.
  - **Cache.** The last 500 records per repo are saved in `Caches/hermes/weft/`.
- `ChangesView.swift` holds the feed, rows, squiggle callouts and formatting. `WeftEventDetailView.swift` holds the
  event detail, the action sheets and dialogs, the filters and the connection settings. `WeftDiffView.swift` is a
  unified diff view: line numbers, +/- tint, light syntax colouring, horizontal scroll.

## Vendor extensions the app reads (not in WCP v0.1)
The gateway may stamp these on records (spec §10 allows `x_` fields). Without them the app falls back to ids.
The deployed weft-gateway drops unknown top-level fields on submitted events but keeps `payload` verbatim,
so producers (adapters, B10) put them in `payload` instead; the app reads top-level first, then `payload`.
- `x_task_title`: the task's title, shown in rows and on detail.
- `x_evidence` on a change's records (checkpoint and land are enough):
  `{preview_url, tests: {passed, failed, total}, screenshots: [url], review: {verdict, summary}, cost_usd}`.
  It shows in detail → Evidence, and as test counts on the candidate rows.

## Human actions (need a human-scope token; observer tokens get a "read-only" message)
`POST /v1/repos/{repo}/actions`. The encodings are pinned against the spec fixtures in tests.
- **Approve candidate** opens a sheet with an optional note.
- **Undo landing** asks for confirmation and a reason. Only land rows that haven't been reverted offer it.
- **Pause** asks for confirmation. **Resume** runs straight away.
- **Message** opens a sheet with steer / negotiate / info.

These are on the detail action bar (above the fold), the detail ⋯ menu and the row long-press menu. Swiping a row
offers Message.

## Setup (none: auto-config)
Nothing to enter. When Otto connects to Hermes (and on foreground, and when a Weft view opens while
unconfigured) it calls the relay's `GET /hermes/weft/config` (`relay/weft_config.py`) and saves the answer
into the Weft Keychain item (`ai.elier.hermes.weft`) tagged `source: auto` (`WeftAutoConfig.swift`).
- The host returns `{url, token, scope, principal}`. url = `url` in `~/.config/weft/hermes-adapter.json`.
  token = one **human**-scope token for all repos (principal `john`), minted once with
  `~/.config/weft/preview-admin-token` via `POST /v1/admin/tokens` and kept in
  `~/.config/weft/otto-human-token.json` (mode 600). No admin token → `observer-all-token` (scope `observe`,
  read-only). Neither → 503, and the strip says "Your Hermes host has no Weft token".
- A 401 from the gateway on an auto token makes the app ask again with `?renew=1`; the host checks its token
  against `/v1/repos` and mints a new one if it was revoked.
- Precedence: a connection typed in Settings → Weft → Advanced (or `hermes://weft?url&token`) is `source:
  manual` and always wins; "Use Automatic Connection" drops it. Items saved before auto-config (no
  `source`) are replaced by the host's.
- Repos: the strip follows `repo(forFolder:)` (the adapter's `sanitize_repo` of the workspace folder). If the
  gateway doesn't list that repo it shows one line, "Weft isn't tracking <repo> yet"; add it with
  `python3 ~/github/weft/packages/adapters/hermes/scripts/install.py --sync --enforce weft,hermes-ios`.
- "Connect…" only appears when auto-config failed, next to the reason (host unreachable, relay outdated, no
  token on host, gateway unreachable).

## Live gateway (B2 preview)
`https://weft-gateway-preview.elier.ai`. `scripts/weft_live_seed.mjs` (admin token from
`~/.config/weft/preview-admin-token`) creates repos `ios-demo` / `ios-site`, issues observer/human/system/agent tokens
into `~/.config/weft/ios-live.json` (mode 600, never printed) and plays the scenario through the real API:
```bash
node scripts/weft_live_seed.mjs seed              # repos, tokens, scenario, task titles + evidence
node scripts/weft_live_seed.mjs live --count 4    # gemini-c appends live events
node scripts/weft_live_seed.mjs land              # throwaway land of I-b, to undo from the app
node scripts/weft_live_seed.mjs revert-pending    # stands in for B8: system revert per undo request
node scripts/weft_live_seed.mjs bulk              # ios-bulk with 5100 records (past the replay cap)
scripts/weft_configure_device.sh                  # phone unlocked: hermes://weft?url&token via payload URL
```
Simulator: launch with `-weft.url <url> -weft.token <token>` read from that file (never on screen or in logs).
`-weft.forceStreamAfter ios-bulk:0` makes the first stream for that repo open from 0 to provoke 4413.
Request log: `npx wrangler tail weft-gateway-preview --format json` in weft `apps/gateway` (print path+query only).

## Fixture gateway (offline)
```bash
python3 scripts/weft_fixture_server.py                 # :8796, token "dev" (human), "observer" (read-only)
python3 scripts/weft_fixture_server.py --preload 21 --live-interval 5   # last 7 events arrive live
```
The scenario has two repos (`weft-demo`, `weft-site`) and four agents (Claude Code, Codex, Gemini, Hermes). In order:
1. claude-a firmly claims and then changes `refreshToken`'s signature.
2. codex-b's next edit is blocked with `stale_assumption`, a red squiggle that links to the cause.
3. gemini-c gets a `stale_read` warning, an amber squiggle.
4. codex-b and claude-a negotiate: propose → counter → accept, then claude-a adds the overload.
5. The two candidates for T-1 carry evidence. John approves; two changes land; the codex-b landing is auto-reverted.
6. John steers codex-b, which re-plans.

Actions you send append records and stream back (undo → control, then a revert 2 s later).

Debug launch args (simulator):
- `-weft.url http://127.0.0.1:8796 -weft.token dev`: config for this launch only, not saved.
- `-hermes.tab changes` (plus `-hermes.url http://127.0.0.1:1 -hermes.key x` to get past the connect screen with no
  gateway).
- `-weft.openEvent weft-demo:9`
- `-weft.onlyConflicts YES`, `-weft.showFilters YES`, `-weft.resetFilters YES`
- `-weft.debugAction "pause|resume|message|approve|undo:<repo>:<target>[:text]"` runs a human action through the
  real client.

Screenshots: take them with the launch arguments above (none are committed).

## Verified
Build 32 (fixture gateway): 78 unit tests; live rows animate in; background → foreground resume pages
`events?after=` then `stream?after=`; pause and undo POST and stream back.

Build 33 against the live weft-gateway preview (card I1b, 2026-10-04), 87/87 unit tests (live-captured fixtures in
`ios/HermesTests/WeftFixtures/live/`):
- `/v1/repos` lists only the token's repos; first open pages `events?tail=1&limit=200` per repo, then
  `stream?after=<head>` (Authorization header on the upgrade). Status goes Live after `replay.done`; pings keep it.
- Live: gemini-c events stream in and highlight. The raw stream (`stream?after=37`) is
  `auth.ok, 38, 39, 40, replay.done, ping`.
- Resume: backgrounded at high-water 42, two events appended, foreground → gateway log shows
  `events?after=42` then `stream?after=45`.
- 4413: `ios-bulk` (5108 records), stream forced from 0 → gateway closes 4413 → app refreshes repos, pages,
  reconnects `stream?after=5108` (NSLog `WEFT 4413 paged`).
- Human actions via `-weft.debugAction` with a human token: pause (#25), message (#26), resume (#27), approve I-b
  (#28), undo of throwaway land #29 (#30); the system revert (#31) streamed into the open land detail, which then shows
  "Reverted in #31" and drops Undo. With an observer token the app shows the read-only alert (403).
- Task titles and evidence from `payload.x_*` render in rows, Task section, candidate test counts and Evidence.
