#!/usr/bin/env python3
"""Hérmes Kanban relay: exposes a narrow slice of the Hermes dashboard's
Kanban API to the iOS app.

The dashboard (127.0.0.1:9119) authenticates with a session token that
unlocks the whole dashboard (config, keys, profiles). The phone must never
hold that token. This relay:

- listens on 127.0.0.1 only (Tailscale Serve publishes it on the tailnet),
- requires the same bearer the app already uses for the gateway
  (API_SERVER_KEY from ~/.hermes/.env),
- forwards only an allowlist of Kanban routes, adding the dashboard token
  server-side.

Stdlib only. Run: python3 kanban_relay.py [--port 8650]
"""
from __future__ import annotations

import argparse
import threading
import hmac
import json
import os
import re
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ENV_FILE = Path(os.environ.get("HERMES_ENV_FILE", Path.home() / ".hermes" / ".env"))
UPSTREAM = os.environ.get("KANBAN_UPSTREAM", "http://127.0.0.1:9119")
PREFIX = "/api/plugins/kanban"
MAX_BODY = 256 * 1024
MAX_AUDIO_BODY = 12 * 1024 * 1024  # /hermes/transcribe only

TASK_ID = r"t_[A-Za-z0-9]+"
# (method, path regex relative to /kanban). Anything else is 404.
ALLOWED: list[tuple[str, re.Pattern[str]]] = [
    ("GET", re.compile(r"/boards")),
    ("GET", re.compile(r"/board")),
    ("GET", re.compile(r"/assignees")),
    ("GET", re.compile(rf"/tasks/{TASK_ID}")),
    ("POST", re.compile(r"/tasks")),
    ("PATCH", re.compile(rf"/tasks/{TASK_ID}")),
    ("POST", re.compile(rf"/tasks/{TASK_ID}/comments")),
    ("POST", re.compile(rf"/tasks/{TASK_ID}/reclaim")),
    ("DELETE", re.compile(rf"/tasks/{TASK_ID}")),
]
# Query params the app may send; others are dropped.
ALLOWED_QUERY = {"board", "include_archived", "tenant"}
# PATCH fields the app may change (no model/provider overrides, no metadata).
ALLOWED_PATCH_FIELDS = {"status", "assignee", "priority", "title", "body", "result", "block_reason", "summary"}
ALLOWED_STATUSES = {"triage", "todo", "ready", "blocked", "done", "archived"}
ALLOWED_CREATE_FIELDS = {"title", "body", "assignee", "priority", "triage"}


def read_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip("'\"")
    return out


def local_gateway(env: dict[str, str]) -> str:
    """The API server's URL as seen from this Mac (same rules as the app used to apply)."""
    host = env.get("API_SERVER_HOST", "") or "127.0.0.1"
    if host in ("0.0.0.0", "::"):
        host = "127.0.0.1"
    try:
        port = int(env.get("API_SERVER_PORT", "") or 8642)
    except ValueError:
        port = 8642
    return f"http://{host}:{port}"


class Secrets:
    """Re-read .env when it changes so key rotation needs no restart."""

    def __init__(self, path: Path):
        self.path = path
        self.mtime = 0.0
        self.api_key = ""
        self.dashboard_token = ""
        self.gateway = "http://127.0.0.1:8642"
        self.refresh()

    def refresh(self) -> None:
        try:
            m = self.path.stat().st_mtime
        except OSError:
            return
        if m == self.mtime:
            return
        env = read_env(self.path)
        self.api_key = env.get("API_SERVER_KEY", "")
        self.dashboard_token = env.get("HERMES_DASHBOARD_SESSION_TOKEN", "")
        self.gateway = local_gateway(env)
        self.mtime = m


def route_allowed(method: str, sub: str) -> bool:
    return any(m == method and rx.fullmatch(sub) for m, rx in ALLOWED)


def filter_query(query: str) -> str:
    from urllib.parse import parse_qsl, urlencode

    return urlencode([(k, v) for k, v in parse_qsl(query) if k in ALLOWED_QUERY])


def sanitize_body(method: str, sub: str, body: bytes) -> tuple[bytes | None, str | None]:
    """Returns (body, error). Only JSON objects with allowlisted fields pass."""
    if method in ("GET", "DELETE"):
        return None, None
    try:
        data = json.loads(body or b"{}")
    except json.JSONDecodeError:
        return None, "body must be JSON"
    if not isinstance(data, dict):
        return None, "body must be a JSON object"
    if method == "PATCH":
        extra = set(data) - ALLOWED_PATCH_FIELDS
        if extra:
            return None, f"fields not allowed: {', '.join(sorted(extra))}"
        if "status" in data and data["status"] not in ALLOWED_STATUSES:
            return None, "status not allowed"
    elif sub.endswith("/reclaim"):
        if set(data) - {"reason"}:
            return None, "only a reason is allowed"
        data = {"reason": str(data.get("reason") or "stopped from Hermes iOS")[:500]}
    elif sub == "/tasks":
        extra = set(data) - ALLOWED_CREATE_FIELDS
        if extra:
            return None, f"fields not allowed: {', '.join(sorted(extra))}"
        if not str(data.get("title", "")).strip():
            return None, "title is required"
    else:  # comment
        if set(data) - {"body"} or not str(data.get("body", "")).strip():
            return None, "comment needs a body"
        data["author"] = "hermes-ios"
    return json.dumps(data).encode(), None


def make_handler(secrets: Secrets, relay_port: int = 8650):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from companion import Companion, RawAudio, RouteError, SpeechStream
    from urllib.parse import parse_qsl

    def _token() -> str:
        secrets.refresh()
        return secrets.dashboard_token

    companion = Companion(UPSTREAM, _token)
    from tvpair import TVPairing

    def _api_key() -> str:
        secrets.refresh()
        return secrets.api_key

    tvpair = TVPairing(_api_key)
    from macpair import MacPairing

    def _local_urls() -> tuple[str, str]:
        secrets.refresh()
        return secrets.gateway, f"http://127.0.0.1:{relay_port}"

    macpair = MacPairing(tvpair, _local_urls)

    class Handler(BaseHTTPRequestHandler):
        server_version = "HermesKanbanRelay/1"
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):  # no bodies or headers in logs
            sys.stderr.write("%s %s\n" % (self.command, urlsplit(self.path).path))

        def _send(self, status: int, payload: dict | bytes, ctype="application/json"):
            body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self) -> bool:
            secrets.refresh()
            if not secrets.api_key:
                return False
            got = self.headers.get("Authorization", "")
            return hmac.compare_digest(got.encode(), f"Bearer {secrets.api_key}".encode())

        def _handle(self):
            parts = urlsplit(self.path)
            if parts.path == "/health":
                return self._send(200, {"ok": True})
            # Apple TV pairing: the TV has no key yet, so these two are unauthenticated (tailnet-only).
            if parts.path == "/tvpair/start" and self.command == "POST":
                return self._send(*tvpair.start())
            if parts.path == "/tvpair/poll" and self.command == "GET":
                return self._send(*tvpair.poll(dict(parse_qsl(parts.query)).get("id", "")))
            # Otto for Mac (sandboxed, can't read .env): a click on this Mac's screen releases the key.
            # Native loopback clients only: loopback Host, no proxy/Origin/Sec-Fetch-* headers.
            if parts.path.startswith("/macpair/"):
                refused = macpair.guard(self.client_address[0], self.headers)
                if refused:
                    return self._send(*refused)
            if parts.path == "/macpair/start" and self.command == "POST":
                length = int(self.headers.get("Content-Length") or 0)
                try:
                    body = json.loads(self.rfile.read(min(length, 4096)) or b"{}") if length else {}
                except json.JSONDecodeError:
                    body = {}
                return self._send(*macpair.start(body if isinstance(body, dict) else {},
                                                 self.client_address[0], self.headers))
            if parts.path == "/macpair/poll" and self.command == "GET":
                return self._send(*macpair.poll(dict(parse_qsl(parts.query)).get("id", "")))
            if parts.path == "/macpair/cancel" and self.command == "POST":
                return self._send(*macpair.cancel(dict(parse_qsl(parts.query)).get("id", "")))
            if not self._authorized():
                return self._send(401, {"detail": "unauthorized"})
            if parts.path == "/hermes/terminal/config" and self.command == "GET":
                import terminal
                return self._send(200, terminal.ghostty_config())
            if parts.path == "/hermes/terminal" and self.command == "GET":
                # Otto's Terminal pane: a login shell on this Mac over a WebSocket (terminal.py).
                import terminal
                return terminal.handle_upgrade(self, dict(parse_qsl(parts.query)))
            if parts.path.startswith("/hermes/") or parts.path == "/hermes":
                return self._companion(parts)
            if not parts.path.startswith("/kanban/") and parts.path != "/kanban":
                return self._send(404, {"detail": "not found"})
            sub = parts.path[len("/kanban"):] or "/"
            if not route_allowed(self.command, sub):
                return self._send(404, {"detail": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                return self._send(413, {"detail": "body too large"})
            raw = self.rfile.read(length) if length else b""
            body, err = sanitize_body(self.command, sub, raw)
            if err:
                return self._send(400, {"detail": err})
            if not secrets.dashboard_token:
                return self._send(503, {"detail": "dashboard token not configured"})
            q = filter_query(parts.query)
            url = f"{UPSTREAM}{PREFIX}{sub}" + (f"?{q}" if q else "")
            req = urllib.request.Request(url, data=body, method=self.command)
            req.add_header("X-Hermes-Session-Token", secrets.dashboard_token)
            if body is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    return self._send(resp.status, resp.read(), resp.headers.get("Content-Type", "application/json"))
            except urllib.error.HTTPError as e:
                return self._send(e.code, e.read() or b"{}", e.headers.get("Content-Type", "application/json"))
            except (urllib.error.URLError, TimeoutError) as e:
                return self._send(502, {"detail": f"dashboard unreachable: {getattr(e, 'reason', e)}"})

        def _companion(self, parts):
            length = int(self.headers.get("Content-Length") or 0)
            if length > (MAX_AUDIO_BODY if parts.path in ("/hermes/transcribe", "/hermes/local-voice/stt") else MAX_BODY):
                return self._send(413, {"detail": "body too large"})
            body: dict = {}
            if length:
                try:
                    body = json.loads(self.rfile.read(length) or b"{}")
                except json.JSONDecodeError:
                    return self._send(400, {"detail": "body must be JSON"})
                if not isinstance(body, dict):
                    return self._send(400, {"detail": "body must be a JSON object"})
            if not secrets.dashboard_token:
                return self._send(503, {"detail": "dashboard token not configured"})
            query = dict(parse_qsl(parts.query))
            if parts.path in ("/hermes/awake/setup", "/hermes/awake/undo") or (
                    parts.path.startswith("/hermes/hotspot") and self.command == "POST"):
                # Starts a system administrator prompt on this Mac: native clients only, never a web page.
                if any(k.lower() == "origin" or k.lower().startswith("sec-fetch-") for k in self.headers.keys()):
                    return self._send(403, {"detail": "not from a browser"})
            if parts.path == "/hermes/tvpair/approve" and self.command == "POST":
                return self._send(*tvpair.approve(body))
            if parts.path == "/hermes/speak/stream" and self.command == "POST":
                return self._speak_stream(body, query.get("profile"))
            if parts.path.startswith("/hermes/voice-live/chatgpt"):
                return self._chatgpt_live(parts.path[len("/hermes/voice-live/chatgpt"):], body)
            try:
                result = companion.handle(self.command, parts.path[len("/hermes"):], query, body)
            except RouteError as e:
                return self._send(e.status, {"detail": e.detail})
            if isinstance(result, RawAudio):
                return self._send(200, result.data, result.mime)
            return self._send(200, result)

        def _chatgpt_live(self, sub: str, body: dict):
            """ChatGPT voice (chatgpt_live.py). The token route needs the Host the phone used, so the
            bridge URL it gets back is on the same tailnet name."""
            import chatgpt_live
            try:
                if self.command == "GET" and sub == "":
                    return self._send(200, chatgpt_live.status())
                if self.command == "POST" and sub == "/token":
                    host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host")
                    return self._send(200, chatgpt_live.mint(body, host=host))
            except chatgpt_live.LiveError as e:
                return self._send(e.status, {"detail": e.detail})
            return self._send(404, {"detail": "not found"})

        def _speak_stream(self, body: dict, profile: str | None):
            """Hermes's Edge voice as chunked audio/mpeg, sent as Edge produces it (first audio
            in a few hundred ms instead of after the whole sentence). Kokoro voices (local) render a
            sentence in ~0.1-0.2 s, so they're sent whole."""
            import local_voice_client as lv
            from companion import local_default_voice
            if not body.get("voice") and (local := local_default_voice(profile)):
                body = {**body, "voice": local}
            if lv.is_local_voice(body.get("voice")):
                try:
                    result = companion.handle("POST", "/speak", {"profile": profile} if profile else {}, body)
                except RouteError as e:
                    return self._send(e.status, {"detail": e.detail})
                return self._send(200, result.data, result.mime)
            try:
                stream = SpeechStream.open(body.get("text"), profile, voice=body.get("voice"),
                                           rate=body.get("rate"))
            except RouteError as e:
                return self._send(e.status, {"detail": e.detail})
            try:
                self.send_response(200)
                self.send_header("Content-Type", stream.mime)
                self.send_header("Transfer-Encoding", "chunked")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                for chunk in stream.chunks():
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                self.close_connection = True  # the phone hung up (barge-in)
            finally:
                stream.close()

        do_GET = _handle
        do_POST = _handle
        do_PATCH = _handle

        def do_PUT(self):
            if urlsplit(self.path).path.startswith("/hermes/"):
                return self._handle()
            self._send(405, {"detail": "method not allowed"})

        def do_DELETE(self):
            # Deleting an automation or a single board task; nothing else (no boards, links, attachments).
            path = urlsplit(self.path).path
            if re.fullmatch(r"/hermes/automations/[A-Za-z0-9_-]+", path) or re.fullmatch(rf"/kanban/tasks/{TASK_ID}", path):
                return self._handle()
            self._send(405, {"detail": "method not allowed"})

    return Handler


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8650)
    args = ap.parse_args()
    secrets = Secrets(ENV_FILE)
    if not secrets.api_key:
        sys.exit("API_SERVER_KEY missing from ~/.hermes/.env")
    srv = ThreadingHTTPServer((args.host, args.port), make_handler(secrets, args.port))
    try:
        import local_voice_client
        threading.Thread(target=local_voice_client.ensure_running, daemon=True).start()
    except Exception as e:  # noqa: BLE001
        print(f"local voice: not started ({e})", file=sys.stderr)
    try:
        import chatgpt_live
        if chatgpt_live.VENV_PY.exists():
            threading.Thread(target=chatgpt_live.ensure_running, daemon=True).start()
    except Exception as e:  # noqa: BLE001
        print(f"chatgpt live: not started ({e})", file=sys.stderr)
    print(f"kanban relay on http://{args.host}:{args.port} -> {UPSTREAM}", file=sys.stderr)
    try:
        # Lid-closed mode: renews the hold while agents work, ends it at the timer / when idle /
        # on the battery and heat rules, and undoes a hold a crashed relay left behind.
        from companion import Companion
        threading.Thread(target=Companion._awake_controller().run_forever, daemon=True, name="awake").start()
    except Exception as e:  # noqa: BLE001
        print(f"awake: not started ({e})", file=sys.stderr)
    srv.serve_forever()


if __name__ == "__main__":
    main()
