"""ChatGPT voice for Otto's voice mode, on John's ChatGPT subscription (no OpenAI API key).

How it reaches ChatGPT's voice: the Codex CLI (`codex app-server`, signed in with ChatGPT) exposes
`thread/realtime/*`. With transport `webrtc` and protocol `v3` it opens a call on
chatgpt.com/backend-api's realtime service ("AVAS", the Advanced Voice backend) with the ChatGPT
login; the websocket transport needs API-key auth and is not used. v3 speaks with ChatGPT's own
voices (cove, juniper, ...), detects turns, handles barge-in server-side, and "delegates" requests it
can't answer, which we route to Hermes instead of Codex.

Shape (the phone code is the Gemini Live client, reused):
  phone ──Gemini-Live-style JSON over WSS──▶ chatgpt_live_bridge.py (Mac, aiortc) ──WebRTC──▶ ChatGPT
The bridge terminates WebRTC on the Mac and speaks the subset of Gemini Live's wire format that
`GeminiLive.swift` uses: setup/setupComplete, realtimeInput audio (16 kHz PCM16), serverContent
(24 kHz PCM16 audio, transcriptions, interrupted, turnComplete) and toolCall/toolResponse for
`ask_otto`. A ChatGPT delegation becomes an `ask_otto` call, the phone runs it on Hermes exactly as
for Gemini, and the result goes back to ChatGPT as developer text that it then speaks.

This module is stdlib-only (the relay runs on Homebrew python): the persona, tokens, status,
the event translation and PCM conversion. The WebRTC/websocket daemon is chatgpt_live_bridge.py,
in its own venv (~/.hermes/chatgpt-live/venv: aiortc, websockets, numpy), started by the relay.
"""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from array import array
from pathlib import Path
from typing import Any, Callable

import voice_user

ENV_FILE = Path(os.environ.get("HERMES_ENV_FILE", Path.home() / ".hermes" / ".env"))
CODEX_AUTH = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "auth.json"
VENV_PY = Path(os.environ.get("OTTO_CHATGPT_LIVE_PY", Path.home() / ".hermes" / "chatgpt-live" / "venv" / "bin" / "python"))
BRIDGE = Path(__file__).with_name("chatgpt_live_bridge.py")
LOG = Path.home() / ".hermes" / "logs" / "otto-chatgpt-live.log"
BRIDGE_PORT = int(os.environ.get("OTTO_CHATGPT_LIVE_PORT", "8656"))
# Published on the tailnet by `tailscale serve --bg --https=8657 http://127.0.0.1:8656`.
PUBLIC_PORT = int(os.environ.get("OTTO_CHATGPT_LIVE_PUBLIC_PORT", "8657"))

VERSION = "v3"  # AVAS calls take v1 (needs a header Codex doesn't send) or v3
DEFAULT_VOICE = "cove"
# ChatGPT's voices (the v1/v3 set); labels as in the ChatGPT app.
VOICES = {
    "cove": "Composed, direct", "juniper": "Open, upbeat", "maple": "Cheerful, candid",
    "spruce": "Calm, affirming", "ember": "Confident, optimistic", "vale": "Bright, inquisitive",
    "breeze": "Animated, earnest", "arbor": "Easygoing, versatile", "sol": "Savvy, relaxed",
}
TOKEN_TTL = 120  # seconds to open the socket after minting
TOOL_NAME = "ask_otto"
MAX_CONTEXT_ITEMS = 16
MAX_CONTEXT_CHARS = 12_000

PERSONA = (
    "You are Otto, {user}'s voice assistant, the spoken front end of their Hermes agent. Speak naturally, "
    "warm and direct, at an unhurried pace. Keep turns short: one to three sentences unless they ask for "
    "more. Never read out markdown, lists, file paths, code or URLs; summarize them. Answer in the "
    "language {user} speaks (they may switch languages mid-conversation).\n\n"
    "{User} sometimes pauses mid-sentence to think. If what they said sounds unfinished, wait for them.\n\n"
    "Speed matters most: {user} hates waiting. Answer yourself, right away, whenever you can: general "
    "knowledge, explanations, math, translations, advice, opinions, brainstorming, small talk, and "
    "repeating or explaining something already said.\n\n"
    "Your backend is the Otto agent: a full AI agent on {user}'s Mac. It runs commands, reads and edits "
    "files and code, reads their email, calendar, chats, notes and memory, searches the web, schedules "
    "tasks and deploys their apps. Delegate to it when the answer depends on {user}'s own data or anything "
    "current you don't know (news, weather, prices), when they ask to do, change, send, run, build, "
    "schedule or remember anything, when a follow-up changes work already requested, or when they ask "
    "for Otto or the agent. Make the delegated request complete and self-contained. After delegating, "
    "say in a few words that you're on it; never guess or invent the result. Messages that start with "
    "\"Otto agent\" are the agent talking to you, not {user}: when one has the final result, tell {user} "
    "the answer in your own short spoken words right away; one marked partial is progress you mention "
    "only if it is genuinely useful news. If the result says something failed, say so plainly."
)


def persona(now: dt.datetime | None = None, env: dict[str, str] | None = None) -> str:
    """The persona for the user named in ~/.hermes/.env (OTTO_USER_NAME / _PLACE / _TZ, voice_user.py)."""
    env = _env() if env is None else env
    return voice_user.fill(PERSONA, env) + "\n\n" + voice_user.now_line(env, now)


class LiveError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _env(path: Path | None = None) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        lines = (path or ENV_FILE).read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    return out


def _secret(env: dict[str, str]) -> bytes:
    key = env.get("API_SERVER_KEY") or ""
    if not key:
        raise LiveError(409, "API_SERVER_KEY missing from ~/.hermes/.env")
    # A derived key: the bridge never sees or needs the API key itself for anything else.
    return hashlib.sha256(b"otto-chatgpt-live:" + key.encode()).digest()


# MARK: tokens (relay mints, bridge verifies; single use is enforced by the bridge)

def make_token(env: dict[str, str], claims: dict[str, Any], now: float | None = None) -> str:
    now = time.time() if now is None else now
    body = dict(claims, exp=int(now) + TOKEN_TTL, nonce=secrets.token_urlsafe(12))
    raw = base64.urlsafe_b64encode(json.dumps(body, separators=(",", ":")).encode()).rstrip(b"=")
    sig = base64.urlsafe_b64encode(hmac.new(_secret(env), raw, hashlib.sha256).digest()).rstrip(b"=")
    return (raw + b"." + sig).decode()


def verify_token(env: dict[str, str], token: str, now: float | None = None) -> dict[str, Any] | None:
    now = time.time() if now is None else now
    try:
        raw, sig = token.encode().split(b".", 1)
        want = base64.urlsafe_b64encode(hmac.new(_secret(env), raw, hashlib.sha256).digest()).rstrip(b"=")
        if not hmac.compare_digest(want, sig):
            return None
        body = json.loads(base64.urlsafe_b64decode(raw + b"=" * (-len(raw) % 4)))
    except (ValueError, LiveError):
        return None
    if not isinstance(body, dict) or not isinstance(body.get("exp"), int) or body["exp"] < now:
        return None
    return body


# MARK: relay side: status + mint

def codex_login() -> str | None:
    """'chatgpt' when Codex is signed in with a ChatGPT account (never reads token values out)."""
    try:
        data = json.loads(CODEX_AUTH.read_text())
    except (OSError, ValueError):
        return None
    if data.get("tokens") and not data.get("OPENAI_API_KEY"):
        return "chatgpt"
    if (data.get("auth_mode") or "").lower() in ("chatgpt", "chatgptauthtokens"):
        return "chatgpt"
    return "apikey" if data.get("OPENAI_API_KEY") else None


def codex_bin() -> str | None:
    """The Codex CLI (the relay's LaunchAgent PATH doesn't include ~/.local/bin)."""
    found = shutil.which("codex")
    if found:
        return found
    for p in (Path.home() / ".local" / "bin" / "codex", Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex")):
        if p.exists():
            return str(p)
    return None


def _reason() -> str | None:
    if not codex_bin():
        return "Install the Codex CLI on your Mac and sign in with ChatGPT."
    login = codex_login()
    if login != "chatgpt":
        return "Sign the Codex CLI in with your ChatGPT account on your Mac (codex login)."
    if not VENV_PY.exists():
        return "Run scripts/setup_chatgpt_live.sh on your Mac."
    return None


def status() -> dict[str, Any]:
    reason = _reason()
    env = _env()
    return {
        "available": reason is None,
        "reason": reason,
        "model": "ChatGPT voice (" + VERSION + ")",
        "default_voice": env.get("CHATGPT_LIVE_VOICE") or DEFAULT_VOICE,
        "voices": [{"name": n, "style": s} for n, s in VOICES.items()],
    }


def check_voice(voice: Any, default: str) -> str:
    if voice in (None, ""):
        return default
    if not isinstance(voice, str) or voice.lower() not in VOICES:
        raise LiveError(400, "bad voice")
    return voice.lower()


def ws_url(host: str | None) -> str:
    """The bridge's public URL on the same tailnet host the phone used to reach the relay."""
    h = (host or "").split(":")[0].strip() or "127.0.0.1"
    if h in ("127.0.0.1", "localhost"):
        return f"ws://127.0.0.1:{BRIDGE_PORT}/live"
    return f"wss://{h}:{PUBLIC_PORT}/live"


def mint(body: dict[str, Any] | None = None, host: str | None = None, now: dt.datetime | None = None,
         ensure: Callable[[], None] | None = None) -> dict[str, Any]:
    """Same shape as gemini_live.mint, so the phone's Gemini Live client can use it unchanged."""
    body = body or {}
    reason = _reason()
    if reason:
        raise LiveError(409, reason)
    env = _env()
    voice = check_voice(body.get("voice"), env.get("CHATGPT_LIVE_VOICE") or DEFAULT_VOICE)
    (ensure or ensure_running)()
    now = now or dt.datetime.now(dt.timezone.utc)
    token = make_token(env, {"voice": voice}, now.timestamp())
    expire = now + dt.timedelta(hours=2)
    return {"token": token, "ws_url": ws_url(host), "model": "chatgpt-voice-" + VERSION, "voice": voice,
            "expires_at": expire.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "setup": {"engine": "chatgpt", "voice": voice}}


# MARK: relay side: keep the bridge daemon running (same pattern as local_voice_client)

_proc: subprocess.Popen | None = None
_lock = threading.Lock()
_last_spawn = 0.0


def _healthy(timeout: float = 0.6) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{BRIDGE_PORT}/health", timeout=timeout) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def ensure_running(wait: float = 8.0) -> None:
    global _proc, _last_spawn
    if _healthy():
        return
    with _lock:
        if _healthy():
            return
        if _proc is None or _proc.poll() is not None:
            if time.time() - _last_spawn < 2:
                time.sleep(2)
            _last_spawn = time.time()
            LOG.parent.mkdir(parents=True, exist_ok=True)
            env = {k: v for k, v in os.environ.items() if k not in ("OPENAI_API_KEY", "PYTHONPATH", "VIRTUAL_ENV")}
            env["PATH"] = env.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin:" + str(Path.home() / ".local" / "bin")
            log = open(LOG, "ab")  # noqa: SIM115
            _proc = subprocess.Popen([str(VENV_PY), str(BRIDGE), "--port", str(BRIDGE_PORT)], stdout=log,
                                     stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env,
                                     cwd=str(BRIDGE.parent), start_new_session=True)
        end = time.time() + wait
        while time.time() < end:
            if _healthy():
                return
            time.sleep(0.2)
    raise LiveError(503, "ChatGPT voice bridge didn't start (see ~/.hermes/logs/otto-chatgpt-live.log)")


# MARK: phone setup → realtime start params

def context_items(setup: dict[str, Any]) -> list[dict[str, str]]:
    """The chat's last turns (sent in the setup by the phone) as v3 initial items, newest kept."""
    turns = setup.get("context") if isinstance(setup, dict) else None
    items: list[dict[str, str]] = []
    for t in turns if isinstance(turns, list) else []:
        if not isinstance(t, dict):
            continue
        role = t.get("role")
        text = t.get("text")
        if role not in ("user", "assistant") or not isinstance(text, str) or not text.strip():
            continue
        items.append({"role": role, "text": text.strip()[:2000]})
    items = items[-MAX_CONTEXT_ITEMS:]
    while items and sum(len(i["text"]) for i in items) > MAX_CONTEXT_CHARS:
        items.pop(0)
    return items


def start_params(thread_id: str, sdp: str, voice: str, setup: dict[str, Any] | None = None,
                 now: dt.datetime | None = None) -> dict[str, Any]:
    p: dict[str, Any] = {
        "threadId": thread_id,
        "outputModality": "audio",
        "version": VERSION,
        "voice": voice,
        "transport": {"type": "webrtc", "sdp": sdp},
        "includeStartupContext": False,
        # Delegations are ours (→ Hermes); Codex never answers them.
        "clientManagedHandoffs": True,
        "prompt": persona(now),
    }
    items = context_items(setup or {})
    if items:
        p["initialItems"] = items
    return p


# Codex thread that backs the realtime session: no tools at all (we interrupt its turns anyway).
THREAD_START = {
    "ephemeral": True,
    "sandbox": "read-only",
    "approvalPolicy": "never",
    "baseInstructions": "Reply with an empty message. Never call tools.",
    "config": {
        "features": {k: False for k in ("shell_tool", "unified_exec", "apps", "plugins", "multi_agent",
                                        "browser_use", "computer_use", "image_generation", "goals",
                                        "memories", "hooks")},
        "web_search": "disabled",
    },
}


# MARK: wire translation (pure, unit-tested)

# ChatGPT hands over John's raw words ("Ask Otto to check my mail"); the agent *is* Otto, and
# "ask Otto" makes it look for another bot. Keep the request, drop the addressing.
_ADDRESS = re.compile(r"^\s*(?:(?:hey|ok|okay|please)[\s,]+)*(?:(?:can|could|would) you\s+)?(?:ask|tell|have|get)\s+"
                      r"(?:otto|the agent|my agent|hermes)\s*[,:]?\s*(?:to\s+)?", re.I)


def clean_request(text: str) -> str:
    text = " ".join(text.split())
    out = _ADDRESS.sub("", text, count=1)
    if out != text and out:
        out = out[0].upper() + out[1:]
    return out or text

def _server_content(**kw: Any) -> dict[str, Any]:
    return {"serverContent": kw}


def audio_message(pcm24k: bytes) -> dict[str, Any]:
    return _server_content(modelTurn={"parts": [{"inlineData": {
        "mimeType": "audio/pcm;rate=24000", "data": base64.b64encode(pcm24k).decode()}}]})


class Translator:
    """ChatGPT realtime events → Gemini-Live-style messages for the phone, plus the barge-in and
    audio gating state. `out` collects phone messages; actions for the app-server go to `actions`."""

    HANGOVER = 0.35  # keep forwarding this long after the last loud frame (natural pauses)
    LOUD = 120  # peak |sample| that counts as speech in the model's output
    PLAYING = 0.6

    def __init__(self) -> None:
        self.out: list[dict[str, Any]] = []
        self.actions: list[tuple[str, dict[str, Any]]] = []
        self.assistant_turn: str | None = None
        self.interrupted_turn: str | None = None  # an interrupted assistant turn whose tail we drop
        self.last_loud = float("-inf")
        self.calls: dict[str, str] = {}  # ask_otto call id → request
        self.usage_limited: str | None = None
        self.interrupted_at = 0.0

    # data channel events (v3)
    def on_event(self, e: dict[str, Any], now: float) -> None:
        t = e.get("type")
        if t == "input_transcript.added":
            # Input transcripts lag: the last words of a question arrive after the answer started,
            # so they are not a barge-in. A new user turn is (turn.created below).
            text = (e.get("item") or {}).get("text") or ""
            if text:
                self.out.append(_server_content(inputTranscription={"text": text}))
        elif t == "output_transcript.added":
            text = (e.get("item") or {}).get("text") or ""
            if text and not self.muted(now):
                self.out.append(_server_content(outputTranscription={"text": text}))
        elif t == "turn.created":
            turn = e.get("turn") or {}
            if turn.get("role") == "assistant":
                self.assistant_turn = turn.get("id")
                if self.interrupted_turn and self.interrupted_turn != turn.get("id"):
                    self.interrupted_turn = None
            elif turn.get("role") == "user" and self.speaking(now):
                # John started talking over the answer: ChatGPT stops on its side; flush the phone.
                self.interrupt(now)
        elif t == "turn.done":
            turn = e.get("turn") or {}
            if turn.get("role") == "assistant":
                if not self.muted(now):
                    self.out.append(_server_content(turnComplete=True))
                self.assistant_turn = None
        elif t == "session.usage.updated":
            lim = e.get("usage_limit") or {}
            if lim.get("status"):
                self.usage_limited = str(lim.get("status"))
        elif t == "error":
            msg = (e.get("error") or {}).get("message") or e.get("message") or "error"
            self.out.append({"error": {"message": str(msg)}})

    def speaking(self, now: float) -> bool:
        # The phone still plays what we forwarded a moment ago, hence the longer window here.
        return self.assistant_turn is not None or now - self.last_loud < self.PLAYING

    def interrupt(self, now: float) -> None:
        if self.muted(now):
            return
        self.interrupted_turn = self.assistant_turn or "pending"
        self.interrupted_at = now
        self.last_loud = float("-inf")
        self.out.append(_server_content(interrupted=True))

    MUTE = 0.5  # after a barge-in, drop the model's audio this long (the cut-off tail)

    def muted(self, now: float) -> bool:
        """Dropping the interrupted answer: while its turn is still open, and briefly after."""
        if self.interrupted_turn is None:
            return False
        if self.interrupted_turn == self.assistant_turn or now - self.interrupted_at < self.MUTE:
            return True
        self.interrupted_turn = None
        return False

    # model audio (48 kHz frames from WebRTC, already converted to 24 kHz mono PCM16)
    def on_audio(self, pcm24k: bytes, peak: int, now: float) -> bytes | None:
        """Returns the chunk to forward, or None (silence between turns, or an interrupted tail)."""
        if self.muted(now):
            return None
        if peak >= self.LOUD:
            self.last_loud = now
        if peak >= self.LOUD or now - self.last_loud < self.HANGOVER:
            return pcm24k
        return None

    # app-server notifications
    def on_item_added(self, item: dict[str, Any]) -> None:
        if item.get("type") != "handoff_request":
            return
        call_id = str(item.get("handoff_id") or item.get("item_id") or secrets.token_hex(6))
        request = (item.get("input_transcript") or "").strip()
        if not request:
            parts = [p.get("text", "") for p in item.get("active_transcript") or [] if p.get("role") == "user"]
            request = " ".join(s.strip() for s in parts if s).strip()
        request = clean_request(request)
        if not request or call_id in self.calls:
            return
        self.calls[call_id] = request
        self.out.append({"toolCall": {"functionCalls": [{"id": call_id, "name": TOOL_NAME, "args": {"request": request}}]}})

    # phone → ChatGPT
    def on_tool_response(self, msg: dict[str, Any]) -> None:
        for r in ((msg.get("toolResponse") or {}).get("functionResponses") or []):
            if r.get("name") not in (TOOL_NAME, None) and r.get("id") not in self.calls:
                continue
            resp = r.get("response") or {}
            result = str(resp.get("result") or "").strip()
            scheduling = resp.get("scheduling") or "WHEN_IDLE"
            partial = bool(r.get("willContinue")) or result.startswith("partial:")
            if not result or (partial and scheduling == "SILENT"):
                continue
            if partial:
                text = "Otto agent, partial progress: " + result.removeprefix("partial:").strip()
            elif scheduling == "SILENT":
                text = "Otto agent (no need to say anything about this): " + result
            else:
                req = self.calls.get(str(r.get("id")), "")
                text = ("Otto agent, final result" + (f" for \"{req[:200]}\"" if req else "") + ": " + result[:6000])
            self.actions.append(("appendText", {"text": text, "role": "developer"}))

    def drain(self) -> tuple[list[dict[str, Any]], list[tuple[str, dict[str, Any]]]]:
        out, acts = self.out, self.actions
        self.out, self.actions = [], []
        return out, acts


# MARK: PCM conversion (pure python; frames are small)

def pcm16k_to_48k(pcm: bytes) -> array:
    """16 kHz mono PCM16 → 48 kHz mono samples (linear interpolation, ×3)."""
    src = array("h")
    src.frombytes(pcm[: len(pcm) - len(pcm) % 2])
    if sys.byteorder == "big":
        src.byteswap()
    out = array("h", bytes(6 * len(src)))
    n = len(src)
    for i in range(n):
        a = src[i]
        b = src[i + 1] if i + 1 < n else a
        out[3 * i] = a
        out[3 * i + 1] = (2 * a + b) // 3
        out[3 * i + 2] = (a + 2 * b) // 3
    return out


def pcm48k_to_24k(samples: array, channels: int) -> tuple[bytes, int]:
    """48 kHz interleaved PCM16 (1 or 2 channels) → 24 kHz mono little-endian bytes, and the peak."""
    out = array("h")
    peak = 0
    step = 2 * channels
    for i in range(0, len(samples) - step + 1, step):
        if channels == 2:
            v = (samples[i] + samples[i + 1] + samples[i + 2] + samples[i + 3]) // 4
        else:
            v = (samples[i] + samples[i + 1]) // 2
        out.append(v)
        if v > peak:
            peak = v
        elif -v > peak:
            peak = -v
    if sys.byteorder == "big":
        out.byteswap()
    return out.tobytes(), peak


def parse_phone(msg: Any) -> tuple[str, Any]:
    """Classify a phone message: ('setup', dict) | ('audio', bytes) | ('end', None) |
    ('tool', dict) | ('text', str) | ('ignore', None)."""
    if not isinstance(msg, dict):
        return "ignore", None
    if isinstance(msg.get("setup"), dict):
        return "setup", msg["setup"]
    ri = msg.get("realtimeInput")
    if isinstance(ri, dict):
        a = ri.get("audio")
        if isinstance(a, dict) and isinstance(a.get("data"), str):
            try:
                return "audio", base64.b64decode(a["data"])
            except ValueError:
                return "ignore", None
        if ri.get("audioStreamEnd"):
            return "end", None
    if isinstance(msg.get("toolResponse"), dict):
        return "tool", msg
    cc = msg.get("clientContent")
    if isinstance(cc, dict) and cc.get("turnComplete"):
        texts = [p.get("text", "") for t in cc.get("turns") or [] if isinstance(t, dict)
                 for p in t.get("parts") or [] if isinstance(p, dict)]
        text = " ".join(s for s in texts if s).strip()
        if text:
            return "text", text
    return "ignore", None
