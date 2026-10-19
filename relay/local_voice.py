"""Otto local voice: speech-to-text and text-to-speech on this Mac, nothing leaves it.

Runs in its own venv (~/.hermes/local-voice/venv: parakeet-mlx + mlx-audio) as LaunchAgent
`ai.elier.otto-local-voice` on 127.0.0.1:8653. Models stay loaded, so a spoken turn transcribes in
~0.1 s and a sentence renders in ~0.1-0.2 s. Used by:
  - the relay (/hermes/local-voice/*) for Otto's voice mode, dictation and Read aloud,
  - Hermes itself (stt/tts command providers `otto-local`) for Telegram/WhatsApp voice notes.

Routes (localhost only, no auth; the relay is the authenticated front door):
  GET  /health                      {"ready", "stt_model", "tts_model"}
  GET  /voices                      Kokoro English voices
  POST /stt                         body = audio (wav/m4a/mp3/ogg… or raw PCM16 16 kHz mono with
                                    Content-Type audio/L16) -> {"text", "ms"}
  POST /tts                         {"text", "voice"?, "speed"?, "format": "mp3"|"wav"} -> audio
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("OTTO_LOCAL_VOICE_PORT", "8653"))
STT_MODEL = os.environ.get("OTTO_LOCAL_STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
TTS_MODEL = os.environ.get("OTTO_LOCAL_TTS_MODEL", "mlx-community/Kokoro-82M-bf16")
DEFAULT_VOICE = os.environ.get("OTTO_LOCAL_VOICE", "af_heart")
MAX_BODY = 40 * 1024 * 1024
FFMPEG = "/opt/homebrew/bin/ffmpeg"

# Kokoro v1.0 English voices (a = American, b = British) with their published quality grades.
VOICES = [
    ("af_heart", "Heart", "female", "en-US", "A"), ("af_bella", "Bella", "female", "en-US", "A-"),
    ("af_nicole", "Nicole", "female", "en-US", "B-"), ("af_aoede", "Aoede", "female", "en-US", "C+"),
    ("af_kore", "Kore", "female", "en-US", "C+"), ("af_sarah", "Sarah", "female", "en-US", "C+"),
    ("af_nova", "Nova", "female", "en-US", "C"), ("af_sky", "Sky", "female", "en-US", "C-"),
    ("am_fenrir", "Fenrir", "male", "en-US", "C+"), ("am_michael", "Michael", "male", "en-US", "C+"),
    ("am_puck", "Puck", "male", "en-US", "C+"), ("am_echo", "Echo", "male", "en-US", "D"),
    ("am_eric", "Eric", "male", "en-US", "D"), ("am_liam", "Liam", "male", "en-US", "D"),
    ("am_onyx", "Onyx", "male", "en-US", "D"), ("am_adam", "Adam", "male", "en-US", "F+"),
    ("bf_emma", "Emma", "female", "en-GB", "B-"), ("bf_isabella", "Isabella", "female", "en-GB", "C"),
    ("bm_george", "George", "male", "en-GB", "C"), ("bm_fable", "Fable", "male", "en-GB", "C"),
    ("bm_lewis", "Lewis", "male", "en-GB", "D+"), ("bm_daniel", "Daniel", "male", "en-GB", "D"),
]
VOICE_IDS = {v[0] for v in VOICES}

_lock = threading.Lock()   # MLX work is serialized; turns are ~0.1 s so this never queues long
_stt = None
_tts = None
_ready = threading.Event()


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", file=sys.stderr, flush=True)


def load() -> None:
    global _stt, _tts
    t = time.time()
    from parakeet_mlx import from_pretrained
    _stt = from_pretrained(STT_MODEL)
    from mlx_audio.tts.utils import load_model
    _tts = load_model(TTS_MODEL)
    # Warm both (first call compiles kernels).
    with tempfile.NamedTemporaryFile(suffix=".wav") as f:
        _write_wav(f.name, b"\x00\x00" * 16000, 16000)
        _stt.transcribe(f.name)
    list(_tts.generate("Ready.", voice=DEFAULT_VOICE))
    _ready.set()
    log(f"ready in {time.time() - t:.1f}s stt={STT_MODEL} tts={TTS_MODEL}")


def _write_wav(path: str, pcm16: bytes, rate: int) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm16)


def transcribe(body: bytes, content_type: str) -> dict:
    ct = content_type.lower()
    suffix = {"audio/wav": ".wav", "audio/x-wav": ".wav", "audio/mp4": ".m4a", "audio/m4a": ".m4a",
              "audio/x-m4a": ".m4a", "audio/aac": ".aac", "audio/mpeg": ".mp3", "audio/ogg": ".ogg",
              "audio/webm": ".webm", "audio/opus": ".ogg"}.get(ct.split(";")[0].strip(), ".bin")
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "in" + suffix)
        if ct.startswith("audio/l16") or ct.startswith("audio/pcm"):
            rate = 16000
            for part in ct.split(";"):
                if part.strip().startswith("rate="):
                    rate = int(part.split("=", 1)[1])
            path = os.path.join(d, "in.wav")
            _write_wav(path, body, rate)
        else:
            with open(path, "wb") as f:
                f.write(body)
        t = time.time()
        with _lock:
            text = _stt.transcribe(path).text.strip()
        return {"text": text, "ms": round((time.time() - t) * 1000)}


def synthesize(text: str, voice: str, speed: float, fmt: str) -> tuple[bytes, str]:
    import numpy as np
    t = time.time()
    chunks = []
    with _lock:
        for r in _tts.generate(text, voice=voice, speed=speed, lang_code=voice[0]):
            chunks.append(np.asarray(r.audio, dtype=np.float32).reshape(-1))
    audio = np.concatenate(chunks) if chunks else np.zeros(1, dtype=np.float32)
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
    gen_ms = (time.time() - t) * 1000
    if fmt == "wav":
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(pcm)
        data, mime = buf.getvalue(), "audio/wav"
    else:
        data = subprocess.run([FFMPEG, "-loglevel", "error", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", "-",
                               "-c:a", "libmp3lame", "-b:a", "64k", "-f", "mp3", "-"],
                              input=pcm, capture_output=True, check=True).stdout
        mime = "audio/mpeg"
    log(f"tts {len(text)} chars -> {len(pcm) / 48000:.1f}s audio in {gen_ms:.0f} ms ({voice})")
    return data, mime


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code: int, obj) -> None:
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"ready": _ready.is_set(), "stt_model": STT_MODEL, "tts_model": TTS_MODEL,
                                    "default_voice": DEFAULT_VOICE})
        if self.path == "/voices":
            return self._json(200, {"default": DEFAULT_VOICE, "voices": [
                {"id": i, "name": n, "gender": g, "locale": loc, "grade": q} for i, n, g, loc, q in VOICES]})
        self._json(404, {"detail": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            return self._json(413 if n else 400, {"detail": "bad body size"})
        body = self.rfile.read(n)
        if not _ready.wait(timeout=60):
            return self._json(503, {"detail": "models still loading"})
        try:
            if self.path == "/stt":
                return self._json(200, transcribe(body, self.headers.get("Content-Type") or "audio/wav"))
            if self.path == "/tts":
                req = json.loads(body)
                text = str(req.get("text") or "").strip()
                if not text or len(text) > 5000:
                    return self._json(400, {"detail": "text must be 1-5000 chars"})
                voice = req.get("voice") or DEFAULT_VOICE
                if voice not in VOICE_IDS:
                    return self._json(400, {"detail": "unknown voice"})
                speed = float(req.get("speed") or 1.0)
                data, mime = synthesize(text, voice, max(0.5, min(2.0, speed)), req.get("format") or "mp3")
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
        except Exception as e:  # noqa: BLE001
            log(f"{self.path} failed: {e!r}")
            return self._json(500, {"detail": str(e)[:300]})
        self._json(404, {"detail": "not found"})


if __name__ == "__main__":
    threading.Thread(target=load, daemon=True).start()
    log(f"listening on 127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
