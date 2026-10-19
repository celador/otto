"""Gemini Live voice for Otto's voice mode.

Gemini Live (a speech-to-speech model) owns the conversation: it listens, talks, handles barge-in
and turn-taking, answers general and public questions itself (web_search/weather via the relay's voice_search), and hands anything that needs
the user's data or an action to Hermes through the `ask_otto` function (the same
"voice frontend delegates to the agent" shape as Hermes's own GPT-Live mode). The phone connects
straight to Google's WebSocket; the Gemini API key never leaves the Mac. The relay mints a
single-use ephemeral token locked to the setup below and hands the phone that setup to send.

Key: GEMINI_API_KEY (or GOOGLE_API_KEY) in ~/.hermes/.env. Optional GEMINI_LIVE_MODEL /
GEMINI_LIVE_VOICE override the defaults.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import voice_user

ENV_FILE = Path(os.environ.get("HERMES_ENV_FILE", Path.home() / ".hermes" / ".env"))
API = "https://generativelanguage.googleapis.com/v1beta"
WS_URL = ("wss://generativelanguage.googleapis.com/ws/"
          "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained")
DEFAULT_MODEL = "gemini-3.8-live"
DEFAULT_VOICE = "Charon"
# Prebuilt voices (speech-generation guide); the label is what Settings shows.
VOICES = {
    "Charon": "Informative", "Puck": "Upbeat", "Kore": "Firm", "Fenrir": "Excitable",
    "Aoede": "Breezy", "Leda": "Youthful", "Orus": "Firm", "Zephyr": "Bright",
    "Achird": "Friendly", "Algieba": "Smooth", "Despina": "Smooth", "Enceladus": "Breathy",
    "Iapetus": "Clear", "Sadaltager": "Knowledgeable", "Schedar": "Even", "Sulafat": "Warm",
    "Umbriel": "Easy-going", "Vindemiatrix": "Gentle",
}
VOICE_RX = re.compile(r"[A-Z][a-z]{2,15}")
LOCKED = ("model", "generationConfig", "systemInstruction", "tools")

PERSONA = (
    "You are Otto, {user}'s voice assistant, the spoken front end of their Hermes agent. Speak naturally, "
    "warm and direct, at an unhurried pace. Keep turns short: one to three sentences unless they ask for "
    "more. Never read out markdown, lists, file paths, code or URLs; summarize them. Answer in the "
    "language {user} speaks (they may switch languages mid-conversation).\n\n"
    "{User} sometimes pauses mid-sentence to think. If what they said sounds unfinished, wait for them "
    "instead of answering.\n\n"
    "Interruption policy: stop speaking when {user} interrupts and listen.\n\n"
    "Speed matters most: {user} hates waiting. Answer yourself, right away, whenever you can:\n"
    "- General knowledge, explanations, definitions, math, translations, advice, opinions, "
    "brainstorming, small talk.\n"
    "- Anything public and current (news, sports, prices, people, companies, places, hours, facts "
    "about the world): call web_search and answer from the results. Weather: call weather.\n"
    "- Repeating, shortening or explaining something already said in this conversation.\n\n"
    "Backend: Otto agent (call ask_otto). A full AI agent on {user}'s Mac: it runs commands, reads and "
    "edits files and code, reads their email, calendar, chats, notes and memory, schedules tasks, "
    "deploys their apps. It takes a few seconds or more, so only use it when you need it.\n\n"
    "Call ask_otto when:\n"
    "- The answer depends on {user}'s own data: their email, calendar, messages, files, projects, apps, "
    "servers, accounts, contacts, memory, or what they did or decided before.\n"
    "- {User} asks to do, change, make, fix, build, send, run, schedule or remember anything.\n"
    "- A correction or follow-up changes work already requested (call it again with the change).\n"
    "- {User} explicitly asks for Otto or the agent, or asks for deep research.\n\n"
    "Put the full request in ask_otto, self-contained, in {user}'s words plus any context from this "
    "conversation it needs (they may only have said \"yes\" or \"Tuesday instead\"). After calling it, "
    "say in a few words that you're on it, then keep talking with {user} normally if they want; never "
    "guess or invent the result. While Otto works you may get progress updates marked partial: mention "
    "one only if it is genuinely useful news (what Otto found or is doing), in a few words, never the "
    "same thing twice, and stay silent while {user} is talking. When the final result arrives, tell "
    "them the answer in your own short spoken words right away. If the result says something failed or "
    "is still running, say so plainly.\n\n"
    "Call stop_otto when {user} says to stop, cancel or never mind the work in progress. Call otto_command "
    "for app actions: \"/new\" starts a new chat, \"/model <name>\" switches the agent's model."
)

def persona(now: dt.datetime | None = None, env: dict[str, str] | None = None) -> str:
    """The persona plus today's date in the user's time zone (so "tomorrow" and searches are right).
    Name, place and time zone come from ~/.hermes/.env (OTTO_USER_NAME / _PLACE / _TZ, voice_user.py)."""
    env = _env() if env is None else env
    return voice_user.fill(PERSONA, env) + "\n\n" + voice_user.now_line(env, now)


TOOLS = [{"functionDeclarations": [
    {
        "name": "ask_otto",
        "description": ("Hand a request to the Otto agent (Hermes), which has tools, files, the web, "
                        "the user's accounts and memory. Returns the agent's answer when it finishes, which can "
                        "take from seconds to minutes."),
        "behavior": "NON_BLOCKING",
        "parameters": {
            "type": "OBJECT",
            "properties": {
                "request": {"type": "STRING",
                            "description": "The complete, self-contained request in the user's words."},
            },
            "required": ["request"],
        },
    },
    {
        "name": "stop_otto",
        "description": "Stop the agent's work in progress.",
        "behavior": "NON_BLOCKING",
    },
    {
        "name": "otto_command",
        "description": "Run an app command: \"/new\" (new chat) or \"/model <name>\" (switch the agent's model).",
        "behavior": "NON_BLOCKING",
        "parameters": {
            "type": "OBJECT",
            "properties": {"command": {"type": "STRING", "description": "The slash command."}},
            "required": ["command"],
        },
    },
    {
        "name": "web_search",
        "description": "Search the public web. Returns result titles and snippets in about a second.",
        "parameters": {
            "type": "OBJECT",
            "properties": {"query": {"type": "STRING", "description": "Search query."}},
            "required": ["query"],
        },
    },
    {
        "name": "weather",
        "description": "Current weather plus today's and tomorrow's forecast for a place (default: where the user lives).",
        "parameters": {
            "type": "OBJECT",
            "properties": {"place": {"type": "STRING", "description": "City, optionally \", Country\"."}},
        },
    },
]}]
# Gemini's own Google Search (needs a paid Gemini API tier; the free key answers 429). With
# GEMINI_LIVE_GOOGLE_SEARCH=1 it is offered next to web_search.
GOOGLE_SEARCH = {"googleSearch": {}}


class LiveError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _env() -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        lines = ENV_FILE.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    return out


def _key(env: dict[str, str]) -> str:
    return env.get("GEMINI_API_KEY") or env.get("GOOGLE_API_KEY") or ""


def status() -> dict[str, Any]:
    env = _env()
    ok = bool(_key(env))
    return {
        "available": ok,
        "reason": None if ok else "Add GEMINI_API_KEY to ~/.hermes/.env on your Mac.",
        "model": env.get("GEMINI_LIVE_MODEL") or DEFAULT_MODEL,
        "default_voice": env.get("GEMINI_LIVE_VOICE") or DEFAULT_VOICE,
        "voices": [{"name": n, "style": s} for n, s in VOICES.items()],
    }


# Gemini ends John's turn this long after he stops talking. HIGH sensitivity + 900 ms: answers ~1.2 s
# after speech in the live probe (relay/probe_vad.py), a 600 ms mid-sentence pause still doesn't end
# the turn. LOW/1200 (2026-10-14) was slow and, with someone talking in the background, never ended.
# The phone backs this up with its own quiet detector and tap-to-send (audioStreamEnd).
# Start sensitivity LOW: background babble shouldn't open a turn by itself. In a really noisy room
# (airport: babble + PA) even that never ends the turn, and audioStreamEnd doesn't either (probe,
# 2026-10-18), so the phone switches to client-driven turns there: it sends the setup with
# automaticActivityDetection {disabled: true} and activityStart/activityEnd from its own detector
# (relay/turn_detect.py mirrors it). See NOISY_* below and GeminiLive.swift.
SILENCE_MS = 900
# The phone's noisy-room switch, for reference (the phone decides): floor above this dBFS.
NOISY_FLOOR_DBFS = -45


def build_setup(model: str, voice: str, silence_ms: int = SILENCE_MS, now: dt.datetime | None = None,
                google_search: bool = False) -> dict[str, Any]:
    """The BidiGenerateContentSetup the phone sends first (camelCase, as on the wire)."""
    return {
        "model": f"models/{model}",
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
        },
        "systemInstruction": {"parts": [{"text": persona(now)}]},
        "tools": TOOLS + ([GOOGLE_SEARCH] if google_search else []),
        "realtimeInputConfig": {
            "automaticActivityDetection": {
                "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
                "silenceDurationMs": silence_ms,
                "prefixPaddingMs": 40,
            },
        },
        "inputAudioTranscription": {},
        "outputAudioTranscription": {},
        "sessionResumption": {},
        "contextWindowCompression": {"slidingWindow": {}},
    }


def check_voice(voice: Any, default: str) -> str:
    if voice in (None, ""):
        return default
    if not isinstance(voice, str) or not VOICE_RX.fullmatch(voice):
        raise LiveError(400, "bad voice")
    return voice


def mint(body: dict[str, Any] | None = None, opener=urllib.request.urlopen,
         now: dt.datetime | None = None) -> dict[str, Any]:
    """A single-use ephemeral token (30 min, new session within 2 min) + the setup to send."""
    body = body or {}
    env = _env()
    key = _key(env)
    if not key:
        raise LiveError(409, "Gemini Live needs GEMINI_API_KEY in ~/.hermes/.env on your Mac")
    model = env.get("GEMINI_LIVE_MODEL") or DEFAULT_MODEL
    voice = check_voice(body.get("voice"), env.get("GEMINI_LIVE_VOICE") or DEFAULT_VOICE)
    silence = body.get("silence_ms", SILENCE_MS)
    if not isinstance(silence, int) or not 300 <= silence <= 4000:
        raise LiveError(400, "silence_ms must be 300-4000")
    now = now or dt.datetime.now(dt.timezone.utc)
    setup = build_setup(model, voice, silence, now, google_search=env.get("GEMINI_LIVE_GOOGLE_SEARCH") == "1")
    iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")  # noqa: E731
    expire = now + dt.timedelta(minutes=30)
    payload = {
        "uses": 1,
        "expireTime": iso(expire),
        "newSessionExpireTime": iso(now + dt.timedelta(minutes=2)),
        # The token only opens this model with Otto's persona, tools and voice; the phone still sends
        # the rest (VAD, transcription, the resumption handle when it reconnects).
        "bidiGenerateContentSetup": {k: setup[k] for k in LOCKED},
        "fieldMask": ",".join(LOCKED),
    }
    req = urllib.request.Request(f"{API}/auth_tokens", data=json.dumps(payload).encode(), method="POST",
                                 headers={"x-goog-api-key": key, "Content-Type": "application/json"})
    try:
        with opener(req, timeout=15) as r:
            data = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = (json.loads(e.read() or b"{}").get("error") or {}).get("message", "")
        except Exception:  # noqa: BLE001
            pass
        raise LiveError(502, f"Gemini token request failed ({e.code}) {detail}".strip()) from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise LiveError(504, f"Gemini unreachable: {e}") from None
    token = data.get("name")
    if not token:
        raise LiveError(502, "Gemini returned no token")
    return {"token": token, "ws_url": WS_URL, "model": model, "voice": voice,
            "expires_at": iso(expire), "setup": setup}
