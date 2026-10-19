# ChatGPT voice engine (continuous voice on the ChatGPT subscription)

Status: built and verified on the Mac (relay bridge + iOS client). Branch `otto/t_9420eeaa-…`.

## Access path (feasibility)

- There is no public API for ChatGPT's Advanced Voice Mode. The OpenAI Realtime API is the public
  equivalent but needs an OpenAI API key (per-minute billing), which John's policy rules out.
- The Codex CLI (0.154, signed in with ChatGPT) has an experimental app-server API
  `thread/realtime/start|appendAudio|appendText|appendSpeech|stop|listVoices`. Probed live:
  - transport `websocket` → "realtime conversation requires API key auth" (blocked).
  - transport `webrtc` + protocol `v3` → Codex POSTs our SDP offer to
    `chatgpt.com/backend-api/…/realtime/calls` with the ChatGPT login and returns the answer SDP.
    This is "AVAS" (the Advanced Voice service): ChatGPT's own voices
    (cove, juniper, maple, spruce, ember, vale, breeze, arbor, sol), server-side turn detection,
    barge-in, transcripts, and "delegation" for requests it can't answer.
  - `v1` needs an `OpenAI-Alpha: quicksilver=v2` header Codex doesn't send; `v2` is rejected for AVAS.
- So: feasible with no API key and no purchase, through an experimental, undocumented Codex
  surface. It can change or disappear with any Codex update (see Failure modes).

## Shape

```
iPhone/iPad/Mac (GeminiLive.swift, engine = .chatgpt)
   │  Gemini-Live-style JSON over WSS (tailnet https :8657)
   ▼
relay/chatgpt_live_bridge.py  (Mac, venv ~/.hermes/chatgpt-live, 127.0.0.1:8656)
   │  aiortc WebRTC (Opus 48 kHz) + "oai-events" data channel
   │  codex app-server (one warm process, ChatGPT login) for call setup + delegations
   ▼
ChatGPT realtime (AVAS v3)
```

The bridge speaks the subset of Gemini Live's wire format the phone already uses, so the phone's
client, audio engine, echo cancellation, phases, `ask_otto` handling and agent progress code are
reused unchanged. Only the token route differs.

- Auth: phone → relay `POST /hermes/voice-live/chatgpt/token` (bearer API_SERVER_KEY) → single-use
  HMAC token (2 min to connect) → `wss://<tailnet host>:8657/live?access_token=…`. The ChatGPT
  login stays in `~/.codex/auth.json` on the Mac; nothing leaves it.
- Audio: phone mic 16 kHz PCM16 (100 ms chunks) → bridge upsamples to 48 kHz 20 ms frames → WebRTC.
  ChatGPT's 48 kHz stereo → 24 kHz mono PCM16, 40 ms messages; silence between turns isn't sent.
- Context: the chat's last turns ride in the setup message; the bridge passes them as v3
  `initialItems` (≤16 items, ≤12k chars).
- Delegation: ChatGPT's `handoff_request` → `toolCall ask_otto {request}` to the phone → the phone
  runs it on Hermes like Gemini (voice turn, Haiku fast, no Honcho) → `toolResponse` → bridge
  `appendText` (developer: "Otto agent, final result …") → ChatGPT says it. Partial WHEN_IDLE
  progress goes too; SILENT progress doesn't. Codex's own turn for the delegation is interrupted
  at once and its thread has every tool disabled, so Codex never acts.
- Barge-in: server-side (ChatGPT stops talking when John talks). The bridge sends `interrupted`
  when a new user turn starts while the answer is playing (within 0.6 s), and drops the cut-off
  tail for 0.5 s. Late input transcripts of the same question are not treated as barge-in.
- Ending: the phone closes the socket (Stop, "bye", silence on the screenless/watch paths as
  today) → `thread/realtime/stop`, WebRTC closed. A call the server ends (2 h cap, limits) →
  `goAway` → the phone reconnects with a fresh session (context re-sent).
- Engine choice: Settings → Voice mode → Engine: Gemini Live / ChatGPT voice / Otto voice (local),
  plus a ChatGPT voice picker. If the Mac isn't set up or the bridge fails to start, `connect()`
  returns false and voice mode falls back to Otto voice (local), same as Gemini.

## Measured (Mac, tailnet wss, synthetic speech)

- Session start (token → setupComplete): 1.6–2.2 s warm (was 7 s until aiortc's STUN gather was
  turned off; ChatGPT's side is ICE-lite on a public IP).
- End of speech → first reply audio: 0.74–1.18 s for direct answers (target ≤1.5 s). If John
  starts talking within a second of the session opening, that first answer is ~0.6 s slower:
  ChatGPT drops speech in its first second, so the bridge holds the mic for 1 s after
  `session.started` and then catches up by skipping queued silence (no words lost; before the
  hold, 3 of 7 immediate starts lost words).
- Delegation: tool call at end of speech, filler "Let me check that" ~1 s, answer spoken as soon as
  Hermes returns.
- Barge-in: ChatGPT stopped ~1.5 s after the interrupting speech began ("Stop. What is two plus
  two?"); the bridge flushed the phone and the next answer ("Four.") played.
- Reply audio round-tripped through Parakeet STT matches the transcript.

## Failure modes

- Codex update renames/removes `thread/realtime` or v3/AVAS → token works, bridge start fails →
  phone falls back to Otto voice; the log says why (`~/.hermes/logs/otto-chatgpt-live.log`).
- ChatGPT plan voice limits: `session.usage.updated.usage_limit.status` is logged; the server ends
  the call → goAway → reconnect fails → "Lost the voice connection".
- Codex signed out / API-key login: status says so; the engine is unavailable (no fallback to an
  API key, ever: `OPENAI_API_KEY` is stripped from the bridge's environment).
- Mac asleep/off-tailnet: same as Gemini (token request fails → Otto voice).
- Not in this engine: `stop_otto`, `otto_command` (/new, /model), the relay's fast web_search /
  weather functions. ChatGPT delegates those requests to Hermes instead.

## Setup (once, on the Mac)

`scripts/setup_chatgpt_live.sh` (venv + `tailscale serve --https=8657`). The relay starts and
restarts the bridge itself. Probe: `~/.hermes/chatgpt-live/venv/bin/python relay/probe_chatgpt_live.py q.wav --host my-mac.example.ts.net`.
