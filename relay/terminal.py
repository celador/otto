"""Otto terminal: a login shell on this Mac (the Hermes host) in a PTY, streamed over a WebSocket.

Mounted by kanban_relay.py at ``GET /hermes/terminal`` (WebSocket upgrade). The shell runs here, not
inside Otto: the Mac App Store build is sandboxed, and iPad/iPhone can't run a local shell at all.

Auth is the relay's: the same bearer as every /hermes route, loopback/Tailscale Serve only. A request
carrying an Origin or Sec-Fetch-* header (a web page) is refused, so no browser tab can open a shell.

Query: ``cwd`` (start folder; must exist, else ~), ``cols``/``rows`` (initial size), ``session``
(reattach to a live shell; the reply replays the recent output so the screen repaints).

Frames:
  client -> server  binary: keyboard bytes
                    text JSON: {"type": "resize", "cols": C, "rows": R} | {"type": "close"}
  server -> client  binary: terminal output
                    text JSON: {"type": "hello", "session": id, "pid": n, "cwd": path, "reattached": bool}
                               {"type": "exit", "code": n}

A dropped connection keeps the shell for ``GRACE`` seconds (network blip, laptop sleep); reattaching
with the session id resumes it. After that, or on an explicit close, the shell's whole process group
gets SIGHUP, then SIGKILL.

Stdlib only.
"""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import pwd
import secrets
import select
import signal
import socket
import struct
import termios
import threading
import time
import warnings
from pathlib import Path
from typing import Any, Callable

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
GRACE = float(os.environ.get("OTTO_TERMINAL_GRACE", "30"))
REPLAY_BYTES = 256 * 1024
MAX_SESSIONS = 16
MAX_FRAME = 1 << 20


class TerminalError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


# ---------------------------------------------------------------- the Mac's own Ghostty config

GHOSTTY_CONFIGS = (Path.home() / ".config" / "ghostty" / "config",
                   Path.home() / "Library" / "Application Support" / "com.mitchellh.ghostty" / "config")
MAX_CONFIG = 64 * 1024


def ghostty_config(paths: tuple[Path, ...] = GHOSTTY_CONFIGS) -> dict[str, Any]:
    """``GET /hermes/terminal/config``: John's Ghostty config text, so Otto's pane looks like his Ghostty.
    Otto can't read it itself (sandboxed on the Mac, absent on iPhone). Later files override earlier
    ones, as in Ghostty; ``config-file`` includes are not followed."""
    parts, sources = [], []
    for p in paths:
        try:
            text = p.read_text(errors="replace")[:MAX_CONFIG]
        except OSError:
            continue
        parts.append(text)
        sources.append(str(p))
    return {"text": "\n".join(parts), "sources": sources}


# ---------------------------------------------------------------- WebSocket (RFC 6455, server side)

def accept_key(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def check_upgrade(headers: Any) -> str:
    """Returns Sec-WebSocket-Accept, or raises TerminalError for a request that isn't a native WS client."""
    if any(k.lower() == "origin" or k.lower().startswith("sec-fetch-") for k in headers.keys()):
        raise TerminalError(403, "not from a browser")
    if "websocket" not in (headers.get("Upgrade") or "").lower():
        raise TerminalError(426, "websocket upgrade required")
    key = headers.get("Sec-WebSocket-Key") or ""
    try:
        if len(base64.b64decode(key, validate=True)) != 16:
            raise ValueError
    except ValueError:
        raise TerminalError(400, "bad Sec-WebSocket-Key") from None
    return accept_key(key)


def encode_frame(payload: bytes, opcode: int, mask: bool = False) -> bytes:
    head = bytearray([0x80 | opcode])
    n = len(payload)
    mbit = 0x80 if mask else 0
    if n < 126:
        head.append(mbit | n)
    elif n < 1 << 16:
        head.append(mbit | 126)
        head += struct.pack("!H", n)
    else:
        head.append(mbit | 127)
        head += struct.pack("!Q", n)
    if mask:
        key = os.urandom(4)
        head += key
        payload = bytes(b ^ key[i & 3] for i, b in enumerate(payload))
    return bytes(head) + payload


class WebSocket:
    """Blocking frame reader/writer over a connected socket (server side unless ``client=True``)."""

    def __init__(self, rfile, sock: socket.socket, client: bool = False):
        self.rfile = rfile
        self.sock = sock
        self.client = client
        self.lock = threading.Lock()
        self.closed = False

    def _read(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.rfile.read(n - len(buf))
            if not chunk:
                raise ConnectionError("eof")
            buf += chunk
        return buf

    def recv(self) -> tuple[int, bytes]:
        """Next complete message as (opcode, payload); answers pings itself. opcode 8 = close."""
        message = b""
        first_op = 0
        while True:
            b0, b1 = self._read(2)
            fin, op = b0 & 0x80, b0 & 0x0F
            masked, n = b1 & 0x80, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            if n > MAX_FRAME:
                raise ConnectionError("frame too large")
            key = self._read(4) if masked else b""
            data = self._read(n)
            if key:
                data = bytes(b ^ key[i & 3] for i, b in enumerate(data))
            if op == 9:
                self.send(data, 10)
                continue
            if op == 10:
                continue
            if op == 8:
                return 8, data
            if op != 0:
                first_op = op
            message += data
            if len(message) > MAX_FRAME:
                raise ConnectionError("message too large")
            if fin:
                return first_op, message

    def send(self, payload: bytes, opcode: int = 2) -> bool:
        with self.lock:
            if self.closed:
                return False
            try:
                self.sock.sendall(encode_frame(payload, opcode, mask=self.client))
                return True
            except OSError:
                self.closed = True
                return False

    def send_json(self, obj: dict) -> bool:
        return self.send(json.dumps(obj).encode(), 1)

    def close(self, code: int = 1000) -> None:
        self.send(struct.pack("!H", code), 8)
        with self.lock:
            self.closed = True


# ---------------------------------------------------------------- shell sessions

def clean_cwd(raw: str | None) -> str:
    home = str(Path.home())
    if not raw:
        return home
    path = os.path.realpath(os.path.expanduser(raw))
    return path if os.path.isdir(path) else home


def clamp_size(cols: Any, rows: Any) -> tuple[int, int]:
    def num(v: Any, default: int) -> int:
        try:
            return max(2, min(int(v), 1000))
        except (TypeError, ValueError):
            return default
    return num(cols, 80), num(rows, 24)


def login_shell() -> str:
    shell = os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell or "/bin/zsh"
    return shell if os.access(shell, os.X_OK) else "/bin/zsh"


def shell_env(shell: str) -> dict[str, str]:
    """A fresh login environment (the relay's own launchd env and venv vars don't leak in)."""
    pw = pwd.getpwuid(os.getuid())
    env = {
        "HOME": pw.pw_dir, "USER": pw.pw_name, "LOGNAME": pw.pw_name, "SHELL": shell,
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Otto",
        "LANG": os.environ.get("LANG") or "en_US.UTF-8",
    }
    if os.environ.get("TMPDIR"):
        env["TMPDIR"] = os.environ["TMPDIR"]
    return env


class Session:
    def __init__(self, sid: str, cwd: str, cols: int, rows: int, argv: list[str] | None = None,
                 on_gone: Callable[[str], None] | None = None):
        self.id = sid
        self.cwd = cwd
        self.on_gone = on_gone
        self.lock = threading.Lock()
        self.ws: WebSocket | None = None
        self.replay = bytearray()
        self.exit_code: int | None = None
        self.detach_timer: threading.Timer | None = None
        self.created = time.time()
        self.dead = False
        shell = login_shell()
        argv = argv or [shell, "-l"]
        env = shell_env(shell)
        with warnings.catch_warnings():  # the child only chdirs and execs
            warnings.simplefilter("ignore", DeprecationWarning)
            pid, fd = os.forkpty()
        if pid == 0:  # child: exec at once (no Python work between fork and exec in a threaded parent)
            try:
                os.chdir(cwd)
                os.execve(argv[0], argv, env)
            finally:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        self.resize(cols, rows)
        threading.Thread(target=self._pump, daemon=True, name=f"term-{sid[:6]}").start()

    # output: PTY -> replay buffer + attached socket
    def _pump(self) -> None:
        while not self.dead:
            try:
                r, _, _ = select.select([self.fd], [], [], 1.0)
                if not r:
                    if self._reap():
                        break
                    continue
                data = os.read(self.fd, 65536)
            except (OSError, ValueError):
                data = b""
            if not data:
                break
            with self.lock:
                self.replay += data
                if len(self.replay) > REPLAY_BYTES:
                    del self.replay[: len(self.replay) - REPLAY_BYTES]
                ws = self.ws
            if ws:
                ws.send(data)
        self._reap(block=True)
        with self.lock:
            ws = self.ws
        if ws:
            ws.send_json({"type": "exit", "code": self.exit_code if self.exit_code is not None else -1})
            ws.close()
        self.kill()

    def _reap(self, block: bool = False) -> bool:
        if self.exit_code is not None:
            return True
        try:
            pid, status = os.waitpid(self.pid, 0 if block else os.WNOHANG)
        except ChildProcessError:
            self.exit_code = self.exit_code if self.exit_code is not None else -1
            return True
        if pid == 0:
            return False
        self.exit_code = os.waitstatus_to_exitcode(status)
        return True

    def write(self, data: bytes) -> None:
        if self.dead:
            return
        try:
            os.write(self.fd, data)
        except OSError:
            pass

    def resize(self, cols: int, rows: int) -> None:
        if self.dead:
            return
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass

    def size(self) -> tuple[int, int]:
        rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(self.fd, termios.TIOCGWINSZ, b"\0" * 8))
        return cols, rows

    def attach(self, ws: WebSocket) -> bytes:
        with self.lock:
            if self.detach_timer:
                self.detach_timer.cancel()
                self.detach_timer = None
            old, self.ws = self.ws, ws
            replay = bytes(self.replay)
        if old and old is not ws:
            old.close(4000)  # taken over by a newer connection
        return replay

    def detach(self, ws: WebSocket, grace: float) -> None:
        with self.lock:
            if self.ws is not ws:
                return
            self.ws = None
            if self.exit_code is not None:
                return
            self.detach_timer = threading.Timer(grace, self.kill)
            self.detach_timer.daemon = True
            self.detach_timer.start()

    @property
    def alive(self) -> bool:
        return self.exit_code is None and not self._reap()

    def kill(self) -> None:
        """SIGHUP the shell's process group (and the foreground job via the PTY hangup), then SIGKILL.
        Idempotent: the PTY fd is closed exactly once (a second close could hit a reused fd number)."""
        with self.lock:
            if self.dead:
                return
            self.dead = True
            if self.detach_timer:
                self.detach_timer.cancel()
                self.detach_timer = None
        if self.exit_code is None:
            pgids = {self.pid}
            try:
                pgids.add(os.tcgetpgrp(self.fd))  # the foreground job, if it has its own group
            except OSError:
                pass
            for pg in pgids:
                try:
                    os.killpg(pg, signal.SIGHUP)
                except OSError:
                    pass
            deadline = time.time() + 1.5
            while time.time() < deadline and not self._reap():
                time.sleep(0.05)
            for pg in pgids:
                try:
                    os.killpg(pg, signal.SIGKILL)
                except OSError:
                    pass
            self._reap(block=True)
        try:
            os.close(self.fd)
        except OSError:
            pass
        if self.on_gone:
            self.on_gone(self.id)
            self.on_gone = None


class Terminals:
    def __init__(self, grace: float = GRACE, argv: list[str] | None = None):
        self.grace = grace
        self.argv = argv  # tests run a known shell instead of the login shell
        self.sessions: dict[str, Session] = {}
        self.lock = threading.Lock()

    def _gone(self, sid: str) -> None:
        with self.lock:
            self.sessions.pop(sid, None)

    def open(self, query: dict[str, str]) -> tuple[Session, bool]:
        sid = query.get("session") or ""
        with self.lock:
            existing = self.sessions.get(sid) if sid else None
        if existing and existing.alive:
            cols, rows = clamp_size(query.get("cols"), query.get("rows"))
            if query.get("cols"):
                existing.resize(cols, rows)
            return existing, True
        with self.lock:
            if len(self.sessions) >= MAX_SESSIONS:
                raise TerminalError(429, "too many terminals open")
        cols, rows = clamp_size(query.get("cols"), query.get("rows"))
        s = Session(secrets.token_urlsafe(18), clean_cwd(query.get("cwd")), cols, rows, self.argv, self._gone)
        with self.lock:
            self.sessions[s.id] = s
        return s, False

    def serve(self, ws: WebSocket, query: dict[str, str]) -> None:
        """Runs one WebSocket connection to completion (the handshake is already sent)."""
        try:
            session, reattached = self.open(query)
        except TerminalError as e:
            ws.send_json({"type": "error", "detail": e.detail})
            ws.close(4029 if e.status == 429 else 4000)
            return
        replay = session.attach(ws)
        ws.send_json({"type": "hello", "session": session.id, "pid": session.pid, "cwd": session.cwd,
                      "reattached": reattached})
        if reattached and replay:
            ws.send(replay)
        explicit = False
        try:
            while True:
                op, data = ws.recv()
                if op == 8:
                    break
                if op == 2:
                    session.write(data)
                elif op == 1:
                    try:
                        msg = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    kind = msg.get("type") if isinstance(msg, dict) else None
                    if kind == "resize":
                        session.resize(*clamp_size(msg.get("cols"), msg.get("rows")))
                    elif kind == "input" and isinstance(msg.get("data"), str):
                        session.write(msg["data"].encode())
                    elif kind == "close":
                        explicit = True
                        break
        except (ConnectionError, OSError, ValueError):
            pass
        if explicit:
            session.kill()
            ws.close()
        else:
            session.detach(ws, self.grace)

    def shutdown(self) -> None:
        with self.lock:
            sessions = list(self.sessions.values())
        for s in sessions:
            s.kill()


_terminals: Terminals | None = None


def terminals() -> Terminals:
    global _terminals
    if _terminals is None:
        _terminals = Terminals()
    return _terminals


def handle_upgrade(handler, query: dict[str, str]) -> None:
    """Called from the relay's request handler (already authenticated) for GET /hermes/terminal."""
    try:
        accept = check_upgrade(handler.headers)
    except TerminalError as e:
        body = json.dumps({"detail": e.detail}).encode()
        handler.send_response(e.status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
        return
    handler.send_response(101, "Switching Protocols")
    handler.send_header("Upgrade", "websocket")
    handler.send_header("Connection", "Upgrade")
    handler.send_header("Sec-WebSocket-Accept", accept)
    handler.end_headers()
    handler.wfile.flush()
    handler.close_connection = True
    sock = handler.connection
    sock.settimeout(None)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    try:
        terminals().serve(WebSocket(handler.rfile, sock), query)
    finally:
        handler.close_connection = True
