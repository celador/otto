"""Streams Hermes's configured Edge voice as MP3 chunks on stdout.

Run by the relay under the Hermes venv (it has edge_tts and PyYAML):
    ~/.hermes/hermes-agent/venv/bin/python tts_stream_helper.py  < {"text": ..., "home": ...}

Protocol on stdout: one header line, then raw audio/mpeg bytes as Edge produces them.
    "OK audio/mpeg\n"            audio follows
    "ERR <status> <message>\n"   nothing follows (e.g. 409 when the profile's TTS isn't Edge)

Voice/speed resolution mirrors tools/tts_tool_providers._generate_edge_tts so the phone hears
the same voice as Hermes's /api/audio/speak. The request may override it with "voice" (an Edge
ShortName) and "rate" (an Edge rate string like "+20%"); the relay validates both.

{"op": "voices", "home": ..., "list": true} prints one JSON line instead:
    {"provider": ..., "default": <voice>, "voices": [{ShortName, Locale, Gender, ...}]}
("voices" only when "list" is true; the relay caches the list).
"""
from __future__ import annotations

import asyncio
import json
import re
import sys
from pathlib import Path

DEFAULT_EDGE_VOICE = "en-US-AriaNeural"
VOICE_RE = re.compile(r"[a-z]{2,3}-[A-Za-z]{2,4}(-[A-Za-z]+)*-[A-Za-z]+Neural")
RATE_RE = re.compile(r"[+-]\d{1,3}%")
VOICE_FIELDS = ("ShortName", "Locale", "Gender", "LocaleName", "FriendlyName")


def apply_overrides(kwargs: dict, voice, rate) -> dict:
    """Request overrides on top of the profile's settings (invalid values are ignored)."""
    out = dict(kwargs)
    if isinstance(voice, str) and VOICE_RE.fullmatch(voice):
        out["voice"] = voice
    if isinstance(rate, str) and RATE_RE.fullmatch(rate):
        if rate in ("+0%", "-0%"):
            out.pop("rate", None)
        else:
            out["rate"] = rate
    return out


def slim_voice(v: dict) -> dict:
    return {k: v.get(k) for k in VOICE_FIELDS if v.get(k) is not None}


def voices(req: dict, home: Path) -> int:
    try:
        provider, kwargs = tts_settings(load_config(home))
    except Exception:
        provider, kwargs = "edge", {"voice": DEFAULT_EDGE_VOICE}
    out: dict = {"provider": provider, "default": kwargs["voice"]}
    if req.get("list"):
        import edge_tts
        try:
            out["voices"] = [slim_voice(v) for v in asyncio.run(edge_tts.list_voices())]
        except Exception as e:
            out["error"] = f"edge voice list failed: {type(e).__name__}"
    sys.stdout.write(json.dumps(out) + "\n")
    return 0


def tts_settings(config: dict) -> tuple[str, dict]:
    """(provider, edge_communicate_kwargs) from a Hermes config dict."""
    tts = (config or {}).get("tts") or {}
    provider = str(tts.get("provider") or "edge").strip().lower()
    edge = tts.get("edge") or {}
    kwargs: dict = {"voice": str(edge.get("voice") or DEFAULT_EDGE_VOICE)}
    try:
        speed = float(edge.get("speed", tts.get("speed", 1.0)))
    except (TypeError, ValueError):
        speed = 1.0
    if speed != 1.0:
        kwargs["rate"] = f"{round((speed - 1.0) * 100):+d}%"
    return provider, kwargs


def load_config(home: Path) -> dict:
    import yaml
    path = home / "config.yaml"
    if not path.is_file():
        return {}
    with path.open() as f:
        return yaml.safe_load(f) or {}


def header(line: str) -> None:
    sys.stdout.buffer.write((line + "\n").encode())
    sys.stdout.buffer.flush()


LEGACY_HOST = "speech.platform.bing.com"
# Since 2026-10 the legacy host answers the synthesis WebSocket with 403 (edge-tts 7.2.8 and older).
# Edge itself synthesizes through api.msedgeservices.com, which still takes the legacy token as
# Ocp-Apim-Subscription-Key (rany2/edge-tts#490/#491).
ALT_WSS_URL = "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1?Ocp-Apim-Subscription-Key={token}"


def log(msg: str) -> None:
    """One line on stderr (the relay inherits it into kanban-relay.log). Never the text itself."""
    try:
        sys.stderr.write(f"tts_stream_helper: {msg}\n")
        sys.stderr.flush()
    except Exception:
        pass


def wss_urls(edge_tts_module) -> list[str]:
    """Synthesis endpoints to try, in order: the msedgeservices host first while the library still
    points at the legacy host (which 403s), then the library's own URL as the retry."""
    import edge_tts.constants as k
    own = getattr(k, "WSS_URL", "")
    if LEGACY_HOST in own and getattr(k, "TRUSTED_CLIENT_TOKEN", ""):
        return [ALT_WSS_URL.format(token=k.TRUSTED_CLIENT_TOKEN), own]
    return [own, own]  # a fixed library: same URL, one retry


def is_handshake_error(e: BaseException) -> bool:
    return type(e).__name__ in ("WSServerHandshakeError", "SkewAdjustmentError") or "403" in str(e)[:40]


async def stream(text: str, kwargs: dict) -> int:
    import edge_tts
    import edge_tts.communicate as communicate
    out = sys.stdout.buffer
    started = False
    urls = wss_urls(edge_tts)
    last: BaseException | None = None
    for attempt, url in enumerate(urls):
        if url:
            communicate.WSS_URL = url
        try:
            async for chunk in edge_tts.Communicate(text, **kwargs).stream():
                if chunk.get("type") != "audio" or not chunk.get("data"):
                    continue
                if not started:
                    header("OK audio/mpeg")
                    started = True
                out.write(chunk["data"])
                out.flush()
            last = None
            break
        except BrokenPipeError:
            return 0  # the phone hung up (barge-in): fine
        except Exception as e:  # network / service errors
            last = e
            host = url.split("/")[2] if url.count("/") >= 2 else "?"
            log(f"edge attempt {attempt + 1}/{len(urls)} via {host} failed: {type(e).__name__}: {str(e)[:120]}")
            # Retry only a refused handshake, and only before any audio went out.
            if started or not is_handshake_error(e):
                break
    if last is not None:
        if not started:
            header(f"ERR 502 edge-tts failed: {type(last).__name__}")
        return 1
    if not started:
        header("ERR 502 no audio")
        return 1
    return 0


def main() -> int:
    try:
        req = json.loads(sys.stdin.read() or "{}")
        text = str(req.get("text") or "").strip()
        home = Path(str(req.get("home") or ""))
    except (ValueError, TypeError, AttributeError):
        header("ERR 400 bad request")
        return 1
    if req.get("op") == "voices":
        return voices(req, home)
    if not text:
        header("ERR 400 no text")
        return 1
    try:
        provider, kwargs = tts_settings(load_config(home))
        kwargs = apply_overrides(kwargs, req.get("voice"), req.get("rate"))
    except Exception:
        header("ERR 500 could not read tts config")
        return 1
    # An explicit Edge voice from the phone means Edge even when the profile speaks another provider.
    explicit = isinstance(req.get("voice"), str) and VOICE_RE.fullmatch(req["voice"])
    if provider != "edge" and not explicit:
        header(f"ERR 409 tts provider is {provider}, not edge")
        return 1
    return asyncio.run(stream(text, kwargs))


if __name__ == "__main__":
    sys.exit(main())
