# Hérmes — architecture notes

iOS client (`ai.elier.hermes`, team UFF39H3A3T, App Store name "Hérmes") for the user's own Hermes gateway API server (port 8642, bearer `API_SERVER_KEY`). John's instance: `https://my-mac.example.ts.net:8642`, tailnet-only via `tailscale serve --bg --https=8642 http://127.0.0.1:8642`.

## Key decision: Runs API, not session chat/stream
`POST /api/sessions/{id}/chat/stream` interrupts the run when the SSE client disconnects, which is fatal on iOS (sockets die on background). Turns use `POST /v1/runs` (`session_id` + `Idempotency-Key`); events come from `GET /v1/runs/{id}/events`, replayed via `Last-Event-ID`. ChatModel detaches on background and reattaches on foreground; RunBookmark reattaches across relaunch. After a run ends the transcript is replaced by `GET /api/sessions/{id}/messages`.

Event names are in the JSON payload (`"event"`), not the SSE `event:` field. Captured payloads are pinned in `ios/HermesTests/HermesTests.swift`.

Approvals: `approval.request` → `POST /v1/runs/{id}/approval {choice, request_id}`. John's gateway runs `approvals.mode: off`, so only tests exercise this.

## Rules
- XcodeGen (`project.yml`); `*.xcodeproj` gitignored.
- No TestFlight; John presses Submit.
- Never commit/print `API_SERVER_KEY`.
- Debug-only launch args: `-hermes.url`, `-hermes.key`, `-hermes.autosend "prompt"`.

## App Store blockers
1. Reviewer needs a demo gateway reachable from the internet (sandboxed toolset, throwaway key).
2. Privacy + support URLs.
3. John creates the App Store Connect record ("Hérmes").
4. Name proximity to Hermès (fashion house) — expect scrutiny.

## v0.2 (personal-use focus)
- **Photos**: camera + library, downscaled to 1600px JPEG, sent as `input_image` data URLs in `/v1/runs` input. The server stores only `[screenshot]` in history; `Transcript.adoptLocalImages` keeps the phone's copy visible for the session.
- **Steer**: typing while a run is going calls `POST /v1/runs/{id}/steer`; the history shows it as an `[OUT-OF-BAND USER MESSAGE]` user row, which `HistoryCleaner` renders as an "Added mid-turn" bubble.
- **History cleanup**: messaging-gateway origin preambles stripped; `display_kind: hidden` rows skipped.
- **Tool rows** expand to show input + output (full from history, ≤500-char redacted preview when live).
- **Model picker** per chat + default for new chats, from `GET /api/model/options`; sent as `model` + `provider` per run.
- **Session list**: search, pin/archive/rename (`PATCH /api/sessions/{id}`), chats vs automations filter, source icons.
- **Offline cache**: session list + last 300 messages per chat in Caches; opens instantly, readable with Tailscale off.
- **Finished-run notifications** without APNs: background task keeps polling ~25s after backgrounding, `BGAppRefreshTask` (`ai.elier.hermes.refresh`) later, and a check on foreground. Tap opens the chat. Real push needs an APNs relay (v0.3).
- Debug launch args: `-hermes.open <sessionID>`, `-hermes.autoimage <path>`, `-hermes.autosteer "text"`, `-hermes.expandTools YES`.

## Changes (Weft change log, build 32)
Drawer → Changes: WCP v0.1 observer/human client for Weft (`ios/Hermes/Weft/`). This is a separate server from the
Hermes gateway, with its own URL and token in the Keychain. Per-repo `events?after=` paging + WebSocket
`stream?after=` with resume from the high-water seq, 500-record offline cache, and human actions. See `docs/weft.md`.

## Voice turn-taking in noisy rooms (build 82)

Live voice (Gemini Live, ChatGPT voice) normally lets the server's VAD end John's turn; the phone's
`TurnEndpointer` only backs it up. In an airport that never ends: babble/PA keeps Gemini's VAD "in
speech", Gemini sends no input transcription (so the phone's backup never fired), and even
`audioStreamEnd` doesn't close the turn. Measured with `relay/probe_vad.py --bg <babble> --noise -27`
(8-talker synthetic babble, ~8 dB SNR): server VAD (HIGH or LOW start sensitivity) never answered;
client-driven turns answered 2.2-2.8 s after speech ended, with the full transcript.

- Relay setup: `startOfSpeechSensitivity: START_SENSITIVITY_LOW` (quiet-room latency unchanged, ~1 s).
- `LiveTurns`: the room is learned from the mic before the socket opens; floor above -45 dBFS =
  `client` turns: the setup goes out with `automaticActivityDetection {disabled: true}` and the
  phone sends `activityStart` (+0.6 s pre-roll) / `activityEnd` (ChatGPT: mic gated + `audioStreamEnd`).
  Mid-session it switches server → client when the floor stays above -45 dBFS for 3 s, or when an
  end of turn (quiet/tap/max) gets no answer within 4 s (2.5 s after a tap); that case replays the
  unanswered turn as one activity. Switching opens a FRESH Gemini session (chat as context): a
  resumed session with a changed VAD config silently ignores activities.
- `TurnEndpointer` client bands (mirrored in `relay/turn_detect.py`, unit-tested on both sides):
  onset 0.3 s over floor+8 / room median+6; a 0.2 s word over floor+6 / median+4 and within 8 dB of
  his level keeps the turn; quiet under floor+4 / median+2 or 8 dB under his level; 1.5 s quiet ends
  it; 25 s max. `NoiseFloor` now adapts to sustained "voice" (2.5 s without a 0.3 s gap → floor moves
  toward the 4 s 20th percentile), and its rates are time-based.
- Local engine: a transcript change only resets the end-of-turn clock if the mic heard near-field
  voice within 1 s (noisy rooms only); max turn 25 s (sends at the next 0.3 s breath, hard 35 s).
- Voice log (Settings → voice diag / relay upload): `gemini: room floor=… turns=client (noisy …)`,
  `gemini: switching to client turns (reason)`, `gemini: turn start (client)`, `gemini: end of turn
  (client, quiet|tap|max 25s|short)`, `gemini: room floor=… median=… turns=…` every 10 s; local:
  `end of turn (reason) floor=… farField=N`, `far-field words ignored xN`.
