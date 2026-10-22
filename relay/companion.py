"""Companion routes for the Hérmes iOS app: profiles, skills, memory, status, usage.

Mounted by kanban_relay.py under /hermes/... Same rules as the board routes:
bearer = API_SERVER_KEY, an explicit allowlist, the dashboard token added
server-side, and nothing that exposes keys, raw config or credentials.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

HERMES_HOME = Path(os.environ.get("HERMES_HOME_ROOT", Path.home() / ".hermes"))
HERMES_AGENT = HERMES_HOME / "hermes-agent"
HERMES_PY = HERMES_AGENT / "venv" / "bin" / "python"
MEMORY_HELPER = Path(__file__).with_name("memory_helper.py")
SLASH_BRIDGE = Path(__file__).with_name("slash_bridge.py")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")

# Profile fields the phone gets (drops paths, env flags, distribution internals).
PROFILE_FIELDS = ("name", "is_default", "model", "provider", "skill_count", "gateway_running",
                  "description", "display_name", "bot_title", "role")
SKILL_FIELDS = ("name", "description", "category", "enabled", "usage", "provenance")
STATUS_PLATFORM_FIELDS = ("state", "error_message", "needs_attention", "updated_at")
JOB_FIELDS = ("id", "name", "prompt", "skills", "model", "schedule_display", "schedule", "enabled", "state",
              "paused_at", "paused_reason", "created_at", "next_run_at", "last_run_at", "last_status", "last_error",
              "last_delivery_error", "failure_streak", "deliver", "no_agent", "script", "profile", "repeat")
RUN_FIELDS = ("id", "title", "preview", "source", "started_at", "ended_at", "end_reason", "model",
              "message_count", "tool_call_count", "estimated_cost_usd", "is_active")
JOB_UPDATE_FIELDS = {"name", "prompt", "schedule", "deliver"}
JOB_ID = re.compile(r"[A-Za-z0-9_-]{4,64}")
RUN_STEM = re.compile(r"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}")
PLATFORM = re.compile(r"[a-z][a-z0-9_-]{1,31}")


class RawAudio:
    """A binary (non-JSON) response."""

    def __init__(self, data: bytes, mime: str, provider: str | None):
        self.data = data
        self.mime = mime
        self.provider = provider


class RouteError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


TTS_STREAM_HELPER = Path(__file__).with_name("tts_stream_helper.py")
VOICE_NAME = re.compile(r"^[a-z]{2,3}-[A-Z]{2}(-[A-Za-z]+)?-[A-Za-z]+Neural$")
VOICE_LIST_TTL = 24 * 3600
_voice_cache: dict[str, Any] = {"at": 0.0, "voices": None}


def known_voice(name: str) -> bool:
    cached = _voice_cache.get("voices") or []
    return any(v.get("short_name") == name for v in cached)


def check_voice(voice: Any) -> str | None:
    """None (use the profile's voice) or a validated Edge ShortName."""
    if voice is None or voice == "":
        return None
    if isinstance(voice, str) and re.fullmatch(r"kokoro:[a-z]{2}_[a-z]{2,16}", voice):
        return voice  # Otto local voice (validated again by the daemon)
    if not isinstance(voice, str) or len(voice) > 80 or not (VOICE_NAME.fullmatch(voice) or known_voice(voice)):
        raise RouteError(400, "bad voice")
    return voice


def check_rate(rate: Any) -> str | None:
    """None or an Edge rate string. Accepts a speed multiplier (0.5-2.0) or "+20%"-style."""
    if rate is None or rate == "":
        return None
    if isinstance(rate, bool):
        raise RouteError(400, "bad rate")
    if isinstance(rate, (int, float)):
        if not 0.5 <= float(rate) <= 2.0:
            raise RouteError(400, "rate must be 0.5-2.0")
        pct = round((float(rate) - 1.0) * 100)
        return f"{pct:+d}%"
    if isinstance(rate, str) and re.fullmatch(r"[+-]\d{1,3}%", rate) and -50 <= int(rate[:-1]) <= 100:
        return rate
    raise RouteError(400, "bad rate")


def slim_voices(raw: Any) -> list[dict]:
    """Edge's list → what the phone needs, with a short display name ("Valentina")."""
    out = []
    for v in raw if isinstance(raw, list) else []:
        if not isinstance(v, dict) or not isinstance(v.get("ShortName"), str):
            continue
        short = v["ShortName"]
        name = short.rsplit("-", 1)[-1]
        name = name[:-6] if name.endswith("Neural") else name
        name = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name)  # "AvaMultilingual" -> "Ava Multilingual"
        out.append({"short_name": short, "locale": str(v.get("Locale") or ""),
                    "gender": str(v.get("Gender") or ""), "name": name,
                    "locale_name": str(v.get("LocaleName") or "")})
    out.sort(key=lambda v: (v["locale"], v["name"]))
    return out


def decode_audio_body(body: dict) -> tuple[bytes, str]:
    """{audio: base64, mime_type} → (bytes, mime). PCM from the phone is audio/L16;rate=16000."""
    import base64
    import binascii
    audio, mime = body.get("audio"), str(body.get("mime_type") or "audio/wav")
    if not isinstance(audio, str) or not audio or len(audio) > 12_000_000:
        raise RouteError(400, "audio must be base64, under ~9 MB")
    if not re.fullmatch(r"audio/[A-Za-z0-9.+-]{1,32}(;rate=\d{4,5})?", mime):
        raise RouteError(400, "bad mime_type")
    try:
        return base64.b64decode(audio, validate=True), mime
    except (binascii.Error, ValueError):
        raise RouteError(400, "audio is not base64") from None


class SpeechStream:
    """Edge TTS audio for one sentence, read from the helper as it's generated.

    `open()` waits for the helper's header and the first audio bytes, so a failure (non-Edge
    provider, Edge unreachable) becomes a normal error status before any audio header is sent.
    """

    CHUNK = 4096
    FIRST_AUDIO_TIMEOUT = 20.0

    def __init__(self, proc: subprocess.Popen, first: bytes, mime: str):
        self.proc = proc
        self.first = first
        self.mime = mime

    @classmethod
    def open(cls, text: Any, profile: str | None, python: Path | None = None,
             helper: Path | None = None, voice: Any = None, rate: Any = None) -> "SpeechStream":
        if not isinstance(text, str) or not text.strip() or len(text) > 4000:
            raise RouteError(400, "text must be 1-4000 chars")
        voice, rate = check_voice(voice), check_rate(rate)
        home = profile_home(profile)
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "VIRTUAL_ENV")}
        try:
            proc = subprocess.Popen([str(python or HERMES_PY), str(helper or TTS_STREAM_HELPER)],
                                    # stderr → the relay's log: the helper logs failed Edge attempts there.
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None,
                                    env=env, cwd=str(Path(__file__).parent))
        except OSError:
            raise RouteError(502, "TTS helper failed to start") from None
        try:
            assert proc.stdin and proc.stdout
            req = {"text": text, "home": str(home)}
            if voice:
                req["voice"] = voice
            if rate:
                req["rate"] = rate
            proc.stdin.write(json.dumps(req).encode())
            proc.stdin.close()
            # Edge hanging must not hang the request thread forever.
            import threading
            watchdog = threading.Timer(cls.FIRST_AUDIO_TIMEOUT, proc.kill)
            watchdog.daemon = True
            watchdog.start()
            try:
                head = proc.stdout.readline(256).decode(errors="replace").strip()
                first = b""
                if head.startswith("OK"):
                    first = proc.stdout.read1(cls.CHUNK)  # type: ignore[attr-defined]
            finally:
                watchdog.cancel()
            if not head:
                raise RouteError(504, "TTS timed out")
            if not head.startswith("OK"):
                proc.wait(timeout=5)
                parts = head.split(" ", 2)
                status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 502
                print(f"speak: TTS helper error {head[:120]}", file=sys.stderr, flush=True)
                raise RouteError(status, parts[2] if len(parts) > 2 else "no audio")
            mime = head.split(" ", 1)[1] if " " in head else "audio/mpeg"
            if not first:
                raise RouteError(502, "no audio")
            return cls(proc, first, mime)
        except RouteError:
            proc.kill()
            raise
        except Exception:
            proc.kill()
            raise RouteError(502, "TTS helper failed") from None

    def chunks(self):
        yield self.first
        assert self.proc.stdout
        while True:
            data = self.proc.stdout.read1(self.CHUNK)  # type: ignore[attr-defined]
            if not data:
                break
            yield data

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def voice_info(profile: str | None, python: Path | None = None, helper: Path | None = None,
               now: float | None = None) -> dict:
    """{"default", "provider", "voices"}: the Edge list (cached 24 h) + the profile's voice."""
    import time
    now = time.time() if now is None else now
    home = profile_home(profile)
    need_list = _voice_cache.get("voices") is None or now - _voice_cache.get("at", 0) > VOICE_LIST_TTL
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "VIRTUAL_ENV")}
    try:
        out = subprocess.run([str(python or HERMES_PY), str(helper or TTS_STREAM_HELPER)],
                             input=json.dumps({"op": "voices", "home": str(home), "list": need_list}),
                             capture_output=True, text=True, timeout=30, env=env,
                             cwd=str(Path(__file__).parent)).stdout
        data = json.loads(out.strip().splitlines()[-1])
    except subprocess.TimeoutExpired:
        raise RouteError(504, "voice list timed out") from None
    except (OSError, ValueError, IndexError):
        raise RouteError(502, "voice helper failed") from None
    if need_list:
        voices = slim_voices(data.get("voices"))
        if not voices:
            if _voice_cache.get("voices") is None:
                raise RouteError(502, str(data.get("error") or "no voices"))
        else:
            _voice_cache.update(at=now, voices=voices)
    return {"default": str(data.get("default") or ""), "provider": str(data.get("provider") or ""),
            "voices": _voice_cache["voices"]}


def valid_name(s: str | None) -> bool:
    return bool(s) and bool(NAME.fullmatch(s or "")) and ".." not in (s or "")


def local_default_voice(profile: str | None) -> str | None:
    """'kokoro:af_heart' when the profile's tts.provider is Otto local voice, else None."""
    try:
        text = (profile_home(profile) / "config.yaml").read_text()
    except (OSError, RouteError):
        return None
    m = re.search(r"^tts:\n(?:[ ].*\n)*?  provider: (\S+)", text, re.M)
    if not m or m.group(1).strip("'\"") != "otto-local":
        return None
    v = re.search(r"^tts:\n(?:[ ].*\n)*?    otto-local:\n(?:      .*\n)*?      voice: (\w+)", text, re.M)
    return "kokoro:" + (v.group(1) if v else "af_heart")


def profile_home(profile: str | None) -> Path:
    if not profile or profile == "default":
        return HERMES_HOME
    if not valid_name(profile):
        raise RouteError(400, "bad profile name")
    home = HERMES_HOME / "profiles" / profile
    if not home.is_dir():
        raise RouteError(404, "no such profile")
    return home


class Companion:
    def __init__(self, upstream: str, token: Callable[[], str]):
        self.upstream = upstream
        self.token = token
        self._artifacts = None

    @property
    def artifacts(self):
        if self._artifacts is None:
            from artifacts import ArtifactIndex
            self._artifacts = ArtifactIndex(self.dash)
        return self._artifacts

    # --- dashboard plumbing ---------------------------------------------------

    def dash(self, method: str, path: str, query: dict[str, Any] | None = None, body: Any = None) -> Any:
        q = urllib.parse.urlencode({k: v for k, v in (query or {}).items() if v is not None})
        url = f"{self.upstream}{path}" + (f"?{q}" if q else "")
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("X-Hermes-Session-Token", self.token())
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            detail = "dashboard error"
            try:
                detail = json.loads(e.read() or b"{}").get("detail") or detail
            except Exception:
                pass
            raise RouteError(e.code, str(detail)) from None
        except (urllib.error.URLError, TimeoutError) as e:
            raise RouteError(502, f"dashboard unreachable: {getattr(e, 'reason', e)}") from None
        return json.loads(raw or b"null")

    # --- slash commands (Telegram's set, run like the desktop runs them) ---------

    _slash_cache: tuple[float, Any] | None = None

    def _bridge(self, request: dict, timeout: float) -> dict:
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "VIRTUAL_ENV")}
        env["HERMES_DASHBOARD_SESSION_TOKEN"] = self.token()
        try:
            out = subprocess.run([str(HERMES_PY), str(SLASH_BRIDGE)], input=json.dumps(request), capture_output=True,
                                 text=True, timeout=timeout, cwd=str(HERMES_AGENT), env=env).stdout
            return json.loads(out.strip().splitlines()[-1])
        except subprocess.TimeoutExpired:
            raise RouteError(504, "Hermes took too long to answer that command.") from None
        except (OSError, json.JSONDecodeError, IndexError):
            raise RouteError(502, "The slash-command helper failed on the Mac.") from None

    def slash_catalog(self, force: bool = False) -> Any:
        import time
        if not force and Companion._slash_cache and time.time() - Companion._slash_cache[0] < 600:
            return Companion._slash_cache[1]
        data = self._bridge({"op": "catalog"}, 60)
        if not isinstance(data.get("commands"), list):
            raise RouteError(502, "No command list from Hermes.")
        Companion._slash_cache = (time.time(), data)
        return data

    def slash(self, body: dict[str, Any]) -> Any:
        sid, command = str(body.get("session_id") or ""), str(body.get("command") or "").strip()
        if not command.startswith("/") or len(command) > 8000 or "\x00" in command:
            raise RouteError(400, "command must start with /")
        name, _, arg = command[1:].partition(" ")
        name, arg = name.lower().replace("-", "_"), arg.strip()
        # Gateway-wide controls the desktop's session transport doesn't run: do them here.
        if name == "pause":
            off = arg.lower() in ("off", "resume", "stop")
            cmd = [str(HERMES_PY), "-m", "hermes_cli.main", "resume"] if off else \
                [str(HERMES_PY), "-m", "hermes_cli.main", "pause", *(["--reason", arg[:200]] if arg else [])]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, cwd=str(HERMES_AGENT),
                               env={k: v for k, v in os.environ.items() if k != "PYTHONPATH"})
            text = (r.stdout or r.stderr).strip() or ("Resumed." if off else "Paused new work.")
            return {"kind": "output", "text": text[-2000:]}
        if name == "restart":
            self.dash("POST", "/api/gateway/restart")
            return {"kind": "output", "text": "Restarting the Hermes gateway. The app reconnects in a few seconds."}
        if name == "update":
            self.dash("POST", "/api/hermes/update")
            return {"kind": "output", "text": "Hermes update started on your Mac; the gateway restarts when it's done."}
        if sid and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", sid):
            raise RouteError(400, "bad session id")
        return self._bridge({"op": "exec", "session_id": sid, "command": command}, 185)

    # --- Subagents / Background tray --------------------------------------------

    _activity_cache: dict[str, tuple[float, Any]] = {}
    _activity_bridge_last: dict[str, dict] = {}
    ACTIVITY_ID = re.compile(r"[A-Za-z0-9_.:-]{1,128}")

    def activity(self, method: str, sub: str, query: dict[str, str], body: dict[str, Any]) -> Any:
        """GET /activity?session=<id>; GET .../subagent/<id>/tail; POST .../subagent/<id>/steer|stop;
        GET .../process/<id>/tail; POST .../process/<id>/kill. All need ?session=<stored chat id>."""
        import time
        sid = query.get("session") or str(body.get("session") or "")
        if not self.ACTIVITY_ID.fullmatch(sid or ""):
            raise RouteError(400, "need session")
        if method == "GET" and sub == "/activity":
            hit = Companion._activity_cache.get(sid)
            if hit and time.time() - hit[0] < 1.5:  # several windows/devices polling the same chat
                return hit[1]
            import run_state
            run = run_state.session_run(sid)
            prev = (Companion._activity_bridge_last.get(sid) or {})
            # The dashboard round trip (a subprocess) only while something runs or the tray still lists
            # something; an idle open chat costs one read-only SQLite query per poll.
            if run["running"] or prev.get("subagents") or prev.get("processes") or query.get("full") == "1":
                out = self._bridge({"op": "activity", "session_id": sid}, 30)
                if "kind" in out and out.get("kind") == "error":
                    raise RouteError(502, out.get("text") or "activity failed")
                Companion._activity_bridge_last[sid] = out
            else:
                out = {"live": bool(prev.get("live")), "subagents": [], "processes": []}
                Companion._activity_bridge_last.pop(sid, None)
            out = dict(out)
            live_status = out.pop("live_status", None)
            if live_status in ("working", "waiting", "starting") and not run["running"]:
                run.update(running=True, kind="thinking")  # desktop turn that hasn't stamped a heartbeat yet
            run["waiting"] = live_status == "waiting"
            # Stop reaches only turns the dashboard itself runs (desktop chats); a chat merely open there
            # while the gateway runs it (Telegram, API) would be interrupted in the wrong process.
            run["can_stop"] = live_status in ("working", "waiting", "starting")
            out["run"] = run
            Companion._activity_cache[sid] = (time.time(), out)
            return out
        if method == "POST" and sub == "/activity/stop":
            out = self._bridge({"op": "session_interrupt", "session_id": sid}, 45)
            if out.get("kind") == "error":
                raise RouteError(502, out.get("text") or "failed")
            if "error" in out:
                raise RouteError(int(out.get("status") or 502), str(out["error"]))
            Companion._activity_cache.pop(sid, None)
            return out
        m = re.fullmatch(r"/activity/(subagent|process)/([A-Za-z0-9_.:-]{1,128})/(tail|steer|stop|kill)", sub)
        if not m:
            raise RouteError(404, "not found")
        kind, target, action = m.groups()
        allowed = {("subagent", "tail"): "GET", ("subagent", "steer"): "POST", ("subagent", "stop"): "POST",
                   ("process", "tail"): "GET", ("process", "kill"): "POST"}
        if allowed.get((kind, action)) != method:
            raise RouteError(405, "method not allowed")
        req = {"op": f"{kind}_{action}", "session_id": sid, "target": target}
        if action == "steer":
            text = body.get("message")
            if not isinstance(text, str) or not text.strip() or len(text) > 4000:
                raise RouteError(400, "need message")
            req["text"] = text.strip()
        out = self._bridge(req, 60)
        if out.get("kind") == "error":
            raise RouteError(502, out.get("text") or "failed")
        if "error" in out:
            raise RouteError(int(out.get("status") or 502), str(out["error"]))
        Companion._activity_cache.pop(sid, None)
        return out

    # --- routes ---------------------------------------------------------------

    _workspaces = None
    _awake = None

    @staticmethod
    def _awake_controller():
        """One controller per relay process (kanban_relay.py also runs its tick thread)."""
        if Companion._awake is None:
            import awake
            Companion._awake = awake.Awake()
        return Companion._awake

    @property
    def awake(self):
        return Companion._awake_controller()

    _netwatch = None

    @property
    def netwatch(self):
        """One Netwatch per relay (its setup job lives on it)."""
        if Companion._netwatch is None:
            import netwatch
            Companion._netwatch = netwatch.Netwatch()
        return Companion._netwatch

    @property
    def workspaces(self):
        if self._workspaces is None:
            from workspaces import Workspaces

            def rpc(calls: list[dict]) -> list[dict]:
                out = self._bridge({"op": "rpc", "calls": calls}, 150)
                if out.get("kind") == "error" or not isinstance(out.get("results"), list):
                    raise RouteError(502, str(out.get("text") or "Hermes didn't answer."))
                return out["results"]
            self._workspaces = Workspaces(rpc, self.dash)
        return self._workspaces

    # Overridable in tests (no network).
    @staticmethod
    def voice_web(query: Any) -> dict[str, Any]:
        import voice_search
        return voice_search.web(query)

    @staticmethod
    def voice_weather(place: Any) -> dict[str, Any]:
        import voice_search
        return voice_search.weather(place)

    def handle(self, method: str, sub: str, query: dict[str, str], body: dict[str, Any]) -> Any:
        """sub is the path after /hermes (e.g. "/profiles")."""
        if sub == "/activity" or sub.startswith("/activity/"):
            return self.activity(method, sub, query, body)
        if method == "GET" and sub == "/kanban-live":
            # What each running card is doing now + its worker session (card_live.py). Read-only.
            import card_live
            try:
                return card_live.live(query.get("board"))
            except card_live.CardLiveError as e:
                raise RouteError(e.status, e.detail) from None
        if sub == "/workspaces" or sub.startswith("/workspaces/"):
            from workspaces import WorkspaceError
            try:
                return self.workspaces.handle(method, sub, query, body)
            except WorkspaceError as e:
                raise RouteError(e.status, e.detail) from None
        profile = query.get("profile") or None
        if profile and profile != "default" and not valid_name(profile):
            raise RouteError(400, "bad profile name")

        if method == "GET" and sub == "/profiles":
            data = self.dash("GET", "/api/profiles")
            active = self.dash("GET", "/api/profiles/active")
            profiles = [{k: p.get(k) for k in PROFILE_FIELDS} for p in data.get("profiles", [])]
            return {"profiles": profiles, "active": active.get("active", "default")}

        m = re.fullmatch(r"/profiles/([^/]+)/model", sub)
        if m and method == "PUT":
            name = m.group(1)
            if name != "default" and not valid_name(name):
                raise RouteError(400, "bad profile name")
            provider, model = body.get("provider"), body.get("model")
            ok = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}")
            if not isinstance(provider, str) or not isinstance(model, str) or not ok.fullmatch(provider) or not ok.fullmatch(model):
                raise RouteError(400, "need provider and model")
            r = self.dash("PUT", f"/api/profiles/{name}/model", None, {"provider": provider, "model": model})
            return {"ok": bool(r.get("ok", True)), "provider": provider, "model": model}

        if method == "GET" and sub == "/skills":
            skills = self.dash("GET", "/api/skills", {"profile": profile})
            return {"skills": [{k: s.get(k) for k in SKILL_FIELDS} for s in skills or []]}

        if method == "GET" and sub == "/skills/content":
            name = query.get("name")
            if not valid_name(name):
                raise RouteError(400, "bad skill name")
            data = self.dash("GET", "/api/skills/content", {"name": name, "profile": profile})
            return {"name": data.get("name"), "content": data.get("content", "")}

        if method == "PUT" and sub == "/skills/toggle":
            name = body.get("name")
            if not valid_name(name) or not isinstance(body.get("enabled"), bool):
                raise RouteError(400, "need name and enabled")
            return self.dash("PUT", "/api/skills/toggle", {"profile": profile},
                             {"name": name, "enabled": body["enabled"], "profile": profile})

        if sub == "/memory":
            if method == "GET":
                return self.memory({"op": "list"}, profile)
            if method == "POST":
                op = body.get("op")
                if op not in ("add", "replace", "remove") or body.get("target") not in ("memory", "user"):
                    raise RouteError(400, "op must be add/replace/remove; target memory/user")
                req = {k: body.get(k) for k in ("op", "target", "content", "old_text") if body.get(k) is not None}
                for k in ("content", "old_text"):
                    if k in req and (not isinstance(req[k], str) or len(req[k]) > 4000):
                        raise RouteError(400, f"{k} must be text under 4000 chars")
                return self.memory(req, profile)

        if method == "GET" and sub == "/status":
            s = self.dash("GET", "/api/status")
            platforms = {
                name: {k: p.get(k) for k in STATUS_PLATFORM_FIELDS}
                for name, p in (s.get("gateway_platforms") or {}).items()
            }
            return {"version": s.get("version"), "release_date": s.get("release_date"),
                    "gateway_running": s.get("gateway_running"), "gateway_state": s.get("gateway_state"),
                    "can_update": s.get("can_update_hermes"), "platforms": platforms}

        # --- Honcho: what Hermes has learned (local Honcho in Docker) ---
        if sub in ("/honcho", "/honcho/forget"):
            from honcho_memory import HonchoError, HonchoMemory
            try:
                if method == "GET" and sub == "/honcho":
                    peer = query.get("peer")
                    return HonchoMemory().view(peer if peer and len(peer) <= 128 else None)
                if method == "POST" and sub == "/honcho/forget":
                    return HonchoMemory().forget(body.get("ids"))
            except HonchoError as e:
                raise RouteError(e.status, str(e)) from None

        # --- artifacts (same list as the desktop app's Artifacts page) ---
        if method == "GET" and sub == "/artifacts":
            return self.artifacts.build(force=query.get("refresh") == "1")

        if method == "GET" and sub == "/artifacts/file":
            value = query.get("value", "")
            if not value or len(value) > 2000:
                raise RouteError(400, "need value")
            try:
                data, mime, _name = self.artifacts.file(value)
            except PermissionError:
                raise RouteError(403, "not an artifact") from None
            except FileNotFoundError:
                raise RouteError(404, "file no longer exists") from None
            except ValueError as e:
                raise RouteError(413, str(e)) from None
            return RawAudio(data, mime, None)

        if method == "POST" and sub == "/voice-diag":
            text, device = body.get("text"), str(body.get("device") or "device")
            if not isinstance(text, str) or len(text) > 600_000:
                raise RouteError(400, "text must be a string under 600 KB")
            d = HERMES_HOME / "logs" / "otto-voice-diag"
            d.mkdir(parents=True, exist_ok=True)
            import time as _t
            name = re.sub(r"[^A-Za-z0-9._-]", "_", device)[:40] or "device"
            (d / f"{_t.strftime('%Y%m%d-%H%M%S')}-{name}.log").write_text(text)
            for old in sorted(d.glob("*.log"))[:-30]:
                old.unlink()
            return {"ok": True}

        if method == "GET" and sub == "/sessions/archived":
            # The gateway's /api/sessions never lists archived chats; the dashboard's does.
            try:
                limit = max(1, min(100, int(query.get("limit") or 100)))
                offset = max(0, int(query.get("offset") or 0))
            except ValueError:
                raise RouteError(400, "bad limit/offset") from None
            data = self.dash("GET", "/api/sessions", {"archived": "only", "order": "recent",
                                                      "limit": limit, "offset": offset}) or {}
            keep = ("id", "source", "title", "preview", "model", "started_at", "last_active", "message_count",
                    "pinned", "archived")
            rows = [{k: s.get(k) for k in keep} for s in data.get("sessions") or [] if s.get("archived")]
            return {"data": rows, "total": data.get("total"), "has_more": offset + limit < (data.get("total") or 0)}

        # --- lid-closed mode (awake.py): keep the Mac awake while agents work, lid closed ---
        if sub == "/awake":
            import awake
            try:
                if method == "GET":
                    return self.awake.status()
                if method == "POST":
                    return self.awake.set_plan(body)
            except awake.AwakeError as e:
                raise RouteError(e.status, e.detail) from None
            raise RouteError(405, "method not allowed")
        if sub in ("/awake/setup", "/awake/undo"):
            # One-time lid-closed setup / undo, started from Otto. The relay (not the sandboxed app) runs
            # install_awake.sh / uninstall_awake.sh; macOS shows its administrator prompt on this Mac.
            import awake
            if method != "POST":
                raise RouteError(405, "method not allowed")
            try:
                return self.awake.start_setup(sub.rsplit("/", 1)[1])
            except awake.AwakeError as e:
                raise RouteError(e.status, e.detail) from None

        # --- hotspot failover (netwatch.py → the otto-netwatch helper): join the iPhone hotspot when Wi-Fi dies ---
        if sub in ("/hotspot", "/hotspot/test", "/hotspot/setup", "/hotspot/undo"):
            import netwatch
            try:
                if sub == "/hotspot" and method == "GET":
                    return self.netwatch.status()
                if method != "POST":
                    raise RouteError(405, "method not allowed")
                if sub == "/hotspot":
                    return self.netwatch.set(body)
                if sub == "/hotspot/test":
                    return self.netwatch.test()
                return self.netwatch.start_setup(sub.rsplit("/", 1)[1])
            except netwatch.NetwatchError as e:
                raise RouteError(e.status, e.detail) from None

        if sub == "/weft/config":
            # Otto's Weft strip: gateway URL + a human token minted once on this Mac (weft_config.py).
            import weft_config
            if method != "GET":
                raise RouteError(405, "method not allowed")
            try:
                return weft_config.get_config(renew=query.get("renew") == "1")
            except weft_config.WeftConfigError as e:
                raise RouteError(e.status, e.detail) from None

        if method == "GET" and sub == "/running":
            import run_state
            return {"sessions": run_state.running_sessions()}

        if method == "GET" and sub == "/commands":
            return self.slash_catalog(force=query.get("refresh") == "1")
        if method == "POST" and sub == "/slash":
            return self.slash(body)

        if method == "GET" and sub == "/model-options":
            # The desktop's catalog: explicit_only keeps providers John configured himself and drops
            # ambient-credential ones (Nous Portal, Copilot) the gateway's /api/model/options still lists.
            return self.dash("GET", "/api/model/options", {
                "explicit_only": "true", "profile": profile,
                "refresh": "true" if query.get("refresh") == "1" else None})
        if method == "GET" and sub == "/model-visibility":
            import model_visibility
            return model_visibility.fetch(force=query.get("refresh") == "1")
        if method == "GET" and sub == "/limits":
            import limits
            return limits.fetch(force=query.get("refresh") == "1")

        if method == "GET" and sub == "/usage":
            days = query.get("days", "30")
            if not days.isdigit() or not 1 <= int(days) <= 365:
                raise RouteError(400, "days must be 1-365")
            usage = self.dash("GET", "/api/analytics/usage", {"days": days, "profile": profile})
            models = self.dash("GET", "/api/analytics/models", {"days": days, "profile": profile})
            return {"daily": usage.get("daily", []), "totals": usage.get("totals"),
                    "models": models.get("models", []), "period_days": int(days)}

        # --- voice: Gemini Live (speech-to-speech front end that delegates to Hermes) ---
        if sub in ("/voice-live/gemini", "/voice-live/gemini/token"):
            import gemini_live
            try:
                if method == "GET" and sub == "/voice-live/gemini":
                    return gemini_live.status()
                if method == "POST" and sub == "/voice-live/gemini/token":
                    return gemini_live.mint(body)
            except gemini_live.LiveError as e:
                raise RouteError(e.status, e.detail) from None

        # Gemini Live's blocking web_search / weather functions: fast keyless lookups so public
        # questions never wait for the agent.
        if sub in ("/voice-live/search", "/voice-live/weather"):
            if method != "POST":
                raise RouteError(405, "method not allowed")
            import voice_search
            try:
                if sub == "/voice-live/search":
                    return self.voice_web(body.get("query"))
                return self.voice_weather(body.get("place"))
            except voice_search.SearchError as e:
                raise RouteError(e.status, e.detail) from None

        # --- voice: Hermes's configured text-to-speech ---
        if method == "GET" and sub == "/voices":
            import local_voice_client as lv
            local = local_default_voice(profile)
            try:
                info = voice_info(profile)
            except RouteError:
                if not local:
                    raise
                info = {"default": "", "provider": "otto-local", "voices": []}
            if local:
                info = {**info, "default": local, "provider": "otto-local"}
            return {**info, "voices": lv.voices_for_picker() + list(info.get("voices") or [])}

        # --- voice: Otto local voice (Parakeet speech-to-text + Kokoro speech, on this Mac) ---
        if sub in ("/local-voice", "/local-voice/stt"):
            import local_voice_client as lv
            try:
                if method == "GET" and sub == "/local-voice":
                    return lv.status()
                if method == "POST" and sub == "/local-voice/stt":
                    return lv.transcribe(*decode_audio_body(body))
            except lv.LocalVoiceError as e:
                raise RouteError(e.status, e.detail) from None

        if method == "POST" and sub == "/speak":
            text = body.get("text")
            if not isinstance(text, str) or not text.strip() or len(text) > 4000:
                raise RouteError(400, "text must be 1-4000 chars")
            import local_voice_client as lv
            if not body.get("voice") and (local := local_default_voice(profile)):
                body = {**body, "voice": local}
            if lv.is_local_voice(body.get("voice")):
                check_voice(body.get("voice")), check_rate(body.get("rate"))
                try:
                    return RawAudio(lv.speak(text, body["voice"], body.get("rate") if isinstance(body.get("rate"), (int, float)) else None),
                                    "audio/mpeg", "kokoro")
                except lv.LocalVoiceError as e:
                    raise RouteError(e.status, e.detail) from None
            if body.get("voice") or body.get("rate"):
                # A chosen voice/speed: the dashboard can't take one, so use the Edge helper whole.
                stream = SpeechStream.open(text, profile, voice=body.get("voice"), rate=body.get("rate"))
                try:
                    return RawAudio(b"".join(stream.chunks()), stream.mime, "edge")
                finally:
                    stream.close()
            data = self.dash("POST", "/api/audio/speak", {"profile": profile}, {"text": text})
            url = (data or {}).get("data_url", "")
            if not url.startswith("data:") or "," not in url:
                raise RouteError(502, "no audio")
            import base64
            header, encoded = url.split(",", 1)
            mime = header[5:].split(";", 1)[0] or "audio/mpeg"
            return RawAudio(base64.b64decode(encoded), mime, (data or {}).get("provider"))

        if method == "POST" and sub == "/speak/stream":
            # Handled by the relay's streaming path (kanban_relay._speak_stream); reaching here means
            # a caller used handle() directly.
            raise RouteError(405, "use the streaming handler")

        # --- voice: Hermes's configured speech-to-text (for the watch) ---
        if method == "POST" and sub == "/transcribe":
            audio = body.get("audio")
            mime = str(body.get("mime_type") or "audio/mp4")
            if not isinstance(audio, str) or not audio or len(audio) > 12_000_000:
                raise RouteError(400, "audio must be base64, under ~9 MB")
            if not re.fullmatch(r"audio/[a-z0-9.+-]{1,32}", mime):
                raise RouteError(400, "bad mime_type")
            import local_voice_client as lv
            if lv.health():
                # Parakeet on this Mac: ~0.1 s, far better than the agent's default local Whisper.
                try:
                    return {"transcript": lv.transcribe(*decode_audio_body(body))["text"]}
                except lv.LocalVoiceError as e:
                    print(f"transcribe: local voice failed ({e.detail}); using Hermes STT", file=sys.stderr, flush=True)
            data = self.dash("POST", "/api/audio/transcribe", {"profile": profile},
                             {"data_url": f"data:{mime};base64,{audio}", "mime_type": mime})
            return {"transcript": (data or {}).get("transcript", "")}

        # --- automations (cron) ---
        if method == "GET" and sub == "/automations":
            jobs = self.dash("GET", "/api/cron/jobs", {"profile": profile or "all"})
            return {"jobs": [{k: j.get(k) for k in JOB_FIELDS} for j in jobs or []]}

        if method == "GET" and sub == "/automations/targets":
            return self.dash("GET", "/api/cron/delivery-targets", {"profile": profile})

        if method == "GET" and sub == "/automations/blueprints":
            data = self.dash("GET", "/api/cron/blueprints", {"profile": profile})
            keep = ("key", "title", "description", "category", "fields", "scheduleHuman")
            return {"blueprints": [{k: b.get(k) for k in keep} for b in data.get("blueprints", [])]}

        if method == "POST" and sub == "/automations/blueprints":
            key = body.get("blueprint")
            values = body.get("values") or {}
            if not valid_name(key) or not isinstance(values, dict) \
                    or any(not isinstance(v, (str, int, float, bool)) or len(str(v)) > 2000 for v in values.values()):
                raise RouteError(400, "need blueprint and simple values")
            job = self.dash("POST", "/api/cron/blueprints/instantiate", {"profile": profile or "default"},
                            {"blueprint": key, "values": values})
            return {k: (job or {}).get(k) for k in JOB_FIELDS}

        m = re.fullmatch(r"/automations/([^/]+)(?:/(runs|output|pause|resume|run))?", sub)
        if m:
            job_id, action = m.group(1), m.group(2)
            if not JOB_ID.fullmatch(job_id):
                raise RouteError(400, "bad automation id")
            base = f"/api/cron/jobs/{job_id}"
            if method == "GET" and action == "runs":
                limit = query.get("limit", "20")
                if not limit.isdigit() or not 1 <= int(limit) <= 50:
                    raise RouteError(400, "limit must be 1-50")
                data = self.dash("GET", f"{base}/runs", {"profile": profile, "limit": limit})
                return {"runs": [{k: r.get(k) for k in RUN_FIELDS} for r in data.get("runs", [])]}
            if method == "GET" and action == "output":
                return self.run_output(job_id, query.get("run", ""), profile)
            if method == "POST" and action in ("pause", "resume"):
                job = self.dash("POST", f"{base}/{action}", {"profile": profile})
                return {k: (job or {}).get(k) for k in JOB_FIELDS}
            if method == "POST" and action == "run":
                job = self.dash("POST", f"{base}/trigger", {"profile": profile})
                return {k: (job or {}).get(k) for k in JOB_FIELDS} if isinstance(job, dict) else {"ok": True}
            if method == "PATCH" and action is None:
                updates = {k: v for k, v in body.items() if k in JOB_UPDATE_FIELDS}
                extra = set(body) - JOB_UPDATE_FIELDS
                if extra or not updates:
                    raise RouteError(400, "editable: name, prompt, schedule, deliver")
                if any(not isinstance(v, str) or len(v) > 20000 for v in updates.values()):
                    raise RouteError(400, "values must be text")
                job = self.dash("PUT", base, {"profile": profile}, {"updates": updates})
                return {k: (job or {}).get(k) for k in JOB_FIELDS}
            if method == "DELETE" and action is None:
                self.dash("DELETE", base, {"profile": profile})
                return {"ok": True}

        # --- messaging access (pairing) ---
        if method == "GET" and sub == "/pairing":
            data = self.dash("GET", "/api/pairing", {"profile": profile})
            return {"pending": data.get("pending", []), "approved": data.get("approved", [])}

        if method == "POST" and sub in ("/pairing/approve", "/pairing/revoke", "/pairing/deny"):
            platform = str(body.get("platform", "")).lower()
            if not PLATFORM.fullmatch(platform):
                raise RouteError(400, "bad platform")
            if sub == "/pairing/approve":
                rid = str(body.get("request_id", ""))
                if not re.fullmatch(r"[A-Za-z0-9_-]{4,128}", rid):
                    raise RouteError(400, "need request_id")
                return self.dash("POST", "/api/pairing/approve", None,
                                 {"platform": platform, "request_id": rid, "profile": profile})
            if sub == "/pairing/revoke":
                uid = str(body.get("user_id", ""))
                if not uid or len(uid) > 128:
                    raise RouteError(400, "need user_id")
                return self.dash("POST", "/api/pairing/revoke", None,
                                 {"platform": platform, "user_id": uid, "profile": profile})

        raise RouteError(404, "not found")

    def run_output(self, job_id: str, run: str, profile: str | None) -> Any:
        """Text of a script-only run (cron_output:<job>:<stem>). Agent runs are
        normal sessions; the app reads those from the gateway."""
        parts = run.split(":")
        if len(parts) != 3 or parts[0] != "cron_output" or parts[1] != job_id:
            raise RouteError(400, "bad run id")
        stem = parts[2]
        if not RUN_STEM.fullmatch(stem):
            return {"text": "", "note": "No saved output for this run."}
        path = profile_home(profile) / "cron" / "output" / job_id / f"{stem}.md"
        try:
            doc = path.read_text(errors="replace")
        except OSError:
            return {"text": "", "note": "This run's output was cleaned up."}
        return {"text": extract_run_text(doc)[:60000]}

    def memory(self, req: dict[str, Any], profile: str | None) -> Any:
        env = dict(os.environ, HERMES_HOME=str(profile_home(profile)), PYTHONPATH=str(HERMES_AGENT))
        try:
            out = subprocess.run([str(HERMES_PY), str(MEMORY_HELPER)], input=json.dumps(req),
                                 capture_output=True, text=True, timeout=30, env=env, cwd=str(HERMES_AGENT))
        except subprocess.TimeoutExpired:
            raise RouteError(504, "memory timed out") from None
        lines = [l for l in out.stdout.strip().splitlines() if l.startswith("{")]
        if not lines:
            raise RouteError(500, "memory helper failed")
        result = json.loads(lines[-1])
        if not result.get("success", True) and req.get("op") != "list":
            raise RouteError(400, result.get("error") or "memory change refused")
        return result


def extract_run_text(doc: str) -> str:
    """The useful part of a cron output doc: Response, else Script Output, else status."""
    sections: dict[str, str] = {}
    current = None
    buf: list[str] = []
    for line in doc.splitlines():
        if line.startswith("## "):
            if current:
                sections[current] = "\n".join(buf).strip()
            current, buf = line[3:].strip().lower(), []
        elif current:
            buf.append(line)
    if current:
        sections[current] = "\n".join(buf).strip()
    for key in ("response", "script output", "output"):
        if sections.get(key):
            return sections[key]
    status = re.search(r"\*\*Status:\*\*\s*(.+)", doc)
    return f"Status: {status.group(1).strip()}" if status else ""
