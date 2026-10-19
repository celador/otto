"""The relay's side of Otto local voice (relay/local_voice.py): keeps the daemon running and talks to it.

The relay runs as a LaunchAgent; it starts the local voice daemon as a child the first time it's
needed (or at relay start) and restarts it if it dies, so there is no second LaunchAgent to load.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

URL = os.environ.get("OTTO_LOCAL_VOICE_URL", "http://127.0.0.1:8653")
VENV_PY = Path(os.environ.get("OTTO_LOCAL_VOICE_PY", Path.home() / ".hermes" / "local-voice" / "venv" / "bin" / "python"))
DAEMON = Path(__file__).with_name("local_voice.py")
LOG = Path.home() / ".hermes" / "logs" / "otto-local-voice.log"
PREFIX = "kokoro:"

_proc: subprocess.Popen | None = None
_lock = threading.Lock()
_last_spawn = 0.0


class LocalVoiceError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def installed() -> bool:
    return VENV_PY.exists() and DAEMON.exists()


def _request(method: str, path: str, data: bytes | None = None, ctype: str = "application/json",
             timeout: float = 30) -> tuple[bytes, str]:
    req = urllib.request.Request(URL + path, data=data, method=method, headers={"Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read(), r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read() or b"{}").get("detail", "")
        except Exception:  # noqa: BLE001
            detail = ""
        raise LocalVoiceError(e.code if e.code < 500 else 502, detail or f"local voice error {e.code}") from None
    except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
        raise LocalVoiceError(503, "local voice not running") from None


def health() -> dict | None:
    try:
        return json.loads(_request("GET", "/health", timeout=2)[0])
    except LocalVoiceError:
        return None


def ensure_running() -> None:
    """Start the daemon if it isn't answering (at most every 20 s)."""
    global _proc, _last_spawn
    if not installed() or health() is not None:
        return
    with _lock:
        if _proc is not None and _proc.poll() is None:
            return  # starting up
        if time.time() - _last_spawn < 20:
            return
        _last_spawn = time.time()
        LOG.parent.mkdir(parents=True, exist_ok=True)
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "VIRTUAL_ENV")}
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:" + env.get("PATH", "")
        _proc = subprocess.Popen([str(VENV_PY), str(DAEMON)], stdout=open(LOG, "a"), stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL, env=env, start_new_session=True)
        print(f"local voice: started daemon pid {_proc.pid}", file=sys.stderr, flush=True)


def _ready() -> None:
    h = health()
    if h is None:
        ensure_running()
        raise LocalVoiceError(503, "Local voice is starting on your Mac; try again in a few seconds.")


def status() -> dict:
    if not installed():
        return {"available": False, "reason": "Local voice isn't installed on your Mac."}
    h = health()
    if h is None:
        ensure_running()
        return {"available": False, "starting": True, "reason": "Local voice is starting on your Mac."}
    return {"available": bool(h.get("ready")), "starting": not h.get("ready"), "stt_model": h.get("stt_model"),
            "tts_model": h.get("tts_model"), "default_voice": PREFIX + str(h.get("default_voice") or "")}


def transcribe(audio: bytes, mime: str) -> dict:
    _ready()
    return json.loads(_request("POST", "/stt", audio, ctype=mime, timeout=60)[0])


def is_local_voice(voice) -> bool:
    return isinstance(voice, str) and voice.startswith(PREFIX)


def speak(text: str, voice: str | None, speed: float | None) -> bytes:
    _ready()
    body = {"text": text, "format": "mp3"}
    if voice:
        body["voice"] = voice[len(PREFIX):] if voice.startswith(PREFIX) else voice
    if speed:
        body["speed"] = speed
    return _request("POST", "/tts", json.dumps(body).encode(), timeout=60)[0]


def voices_for_picker() -> list[dict]:
    """Kokoro voices in the relay's /hermes/voices shape (they show under English)."""
    try:
        data = json.loads(_request("GET", "/voices", timeout=2)[0])
    except LocalVoiceError:
        return []
    out = []
    for v in data.get("voices") or []:
        region = "US" if v.get("locale") == "en-US" else "UK"
        out.append({"short_name": PREFIX + v["id"], "locale": v.get("locale", "en-US"),
                    "gender": str(v.get("gender", "")).capitalize(), "name": v.get("name", v["id"]),
                    "locale_name": f"English (On your Mac, {region})"})
    return out
