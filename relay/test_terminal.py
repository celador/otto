"""Terminal endpoint tests: a real relay on a free port, a minimal WebSocket client, /bin/sh shells."""
import base64
import json
import os
import re
import socket
import tempfile
import threading
import time
import urllib.error
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

import kanban_relay
import terminal

KEY = "test-key-123"


def ws_connect(port, query="", token=KEY, extra=None):
    """Returns (status_line, WebSocket or None)."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    lines = [f"GET /hermes/terminal{('?' + query) if query else ''} HTTP/1.1", f"Host: 127.0.0.1:{port}",
             "Upgrade: websocket", "Connection: Upgrade", f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
    if token:
        lines.append(f"Authorization: Bearer {token}")
    lines += extra or []
    sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
    rfile = sock.makefile("rb")
    status = rfile.readline().decode().strip()
    headers = {}
    while True:
        line = rfile.readline().decode().strip()
        if not line:
            break
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
    if " 101 " not in status + " ":
        sock.close()
        return status, None
    assert headers["sec-websocket-accept"] == terminal.accept_key(key)
    return status, terminal.WebSocket(rfile, sock, client=True)


class Client:
    def __init__(self, ws):
        self.ws = ws
        self.out = b""
        self.control = []
        self.closed = threading.Event()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            while True:
                op, data = self.ws.recv()
                if op == 8:
                    break
                if op == 2:
                    self.out += data
                elif op == 1:
                    self.control.append(json.loads(data))
        except (ConnectionError, OSError):
            pass
        self.closed.set()

    def wait_for(self, needle: bytes, timeout=8.0):
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.out:
                return True
            time.sleep(0.05)
        raise AssertionError(f"{needle!r} not in output: {self.out[-400:]!r}")

    def wait_control(self, kind, timeout=8.0):
        end = time.time() + timeout
        while time.time() < end:
            for c in self.control:
                if c.get("type") == kind:
                    return c
            time.sleep(0.05)
        raise AssertionError(f"no {kind} in {self.control}")

    def type(self, text: str):
        self.ws.send(text.encode(), 2)

    def drop(self):
        """Network blip: the socket goes away without a close frame."""
        self.ws.sock.shutdown(socket.SHUT_RDWR)
        self.ws.sock.close()


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_dead(pid, timeout=6.0):
    end = time.time() + timeout
    while time.time() < end:
        if not alive(pid):
            return True
        time.sleep(0.05)
    return False


class TerminalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        env = Path(cls.tmp.name) / ".env"
        env.write_text(f"API_SERVER_KEY={KEY}\nHERMES_DASHBOARD_SESSION_TOKEN=dash\n")
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), kanban_relay.make_handler(kanban_relay.Secrets(env)))
        cls.srv.daemon_threads = True
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        terminal.terminals().shutdown()
        cls.srv.shutdown()
        cls.tmp.cleanup()

    def setUp(self):
        terminal._terminals = terminal.Terminals(grace=1.5, argv=["/bin/sh", "-i"])

    def tearDown(self):
        terminal.terminals().shutdown()

    def test_auth_required(self):
        status, ws = ws_connect(self.port, token=None)
        self.assertIn("401", status)
        self.assertIsNone(ws)
        status, ws = ws_connect(self.port, token="wrong")
        self.assertIn("401", status)

    def test_browser_refused(self):
        status, ws = ws_connect(self.port, extra=["Origin: https://evil.example"])
        self.assertIn("403", status)
        status, ws = ws_connect(self.port, extra=["Sec-Fetch-Mode: websocket"])
        self.assertIn("403", status)

    def test_plain_get_needs_upgrade(self):
        sock = socket.create_connection(("127.0.0.1", self.port))
        sock.sendall(f"GET /hermes/terminal HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {KEY}\r\n\r\n".encode())
        self.assertIn(b"426", sock.recv(200))
        sock.close()

    def test_spawn_echo_and_cwd(self):
        with tempfile.TemporaryDirectory() as d:
            _, ws = ws_connect(self.port, f"cwd={d}&cols=100&rows=30")
            c = Client(ws)
            hello = c.wait_control("hello")
            self.assertEqual(hello["cwd"], os.path.realpath(d))
            self.assertFalse(hello["reattached"])
            c.type("echo hi-$((40+2)); pwd\n")
            c.wait_for(b"hi-42")
            c.wait_for(os.path.realpath(d).encode())
            ws.send_json({"type": "close"})

    def test_missing_cwd_falls_back_home(self):
        _, ws = ws_connect(self.port, "cwd=/no/such/folder")
        c = Client(ws)
        self.assertEqual(c.wait_control("hello")["cwd"], str(Path.home()))
        ws.send_json({"type": "close"})

    def test_resize(self):
        _, ws = ws_connect(self.port, "cols=100&rows=30")
        c = Client(ws)
        c.wait_control("hello")
        c.type("stty size\n")
        c.wait_for(b"30 100")
        ws.send_json({"type": "resize", "cols": 132, "rows": 41})
        time.sleep(0.2)
        c.type("stty size\n")
        c.wait_for(b"41 132")
        ws.send_json({"type": "close"})

    def test_close_kills_process_group(self):
        _, ws = ws_connect(self.port)
        c = Client(ws)
        pid = c.wait_control("hello")["pid"]
        c.type("sleep 300 & echo BG=$((0))$!\n")
        c.wait_for(b"BG=0")
        time.sleep(0.2)
        bg = int(re.search(rb"BG=0(\d+)", c.out).group(1))
        c.type("sleep 301\n")
        time.sleep(0.4)
        self.assertTrue(alive(pid) and alive(bg))
        ws.send_json({"type": "close"})
        self.assertTrue(wait_dead(pid), "shell still running")
        self.assertTrue(wait_dead(bg), "background job still running")
        self.assertTrue(c.closed.wait(5))
        end = time.time() + 3
        while terminal.terminals().sessions and time.time() < end:
            time.sleep(0.05)
        self.assertEqual(terminal.terminals().sessions, {})

    def test_reattach_after_drop(self):
        _, ws = ws_connect(self.port)
        c = Client(ws)
        hello = c.wait_control("hello")
        c.type("export MARK=kept-$((6*7))\n")
        time.sleep(0.3)
        c.drop()
        time.sleep(0.4)
        self.assertTrue(alive(hello["pid"]))
        _, ws2 = ws_connect(self.port, f"session={hello['session']}")
        c2 = Client(ws2)
        h2 = c2.wait_control("hello")
        self.assertTrue(h2["reattached"])
        self.assertEqual(h2["pid"], hello["pid"])
        c2.wait_for(b"MARK=kept")  # replayed scrollback
        c2.type("echo $MARK\n")
        c2.wait_for(b"kept-42")
        ws2.send_json({"type": "close"})

    def test_drop_without_reattach_kills_after_grace(self):
        _, ws = ws_connect(self.port)
        c = Client(ws)
        pid = c.wait_control("hello")["pid"]
        c.drop()
        time.sleep(0.5)
        self.assertTrue(alive(pid), "killed before the grace period")
        self.assertTrue(wait_dead(pid, timeout=5), "not killed after the grace period")

    def test_shell_exit_reports_code(self):
        _, ws = ws_connect(self.port)
        c = Client(ws)
        c.wait_control("hello")
        c.type("exit 3\n")
        self.assertEqual(c.wait_control("exit")["code"], 3)
        self.assertTrue(c.closed.wait(5))

    def test_unknown_session_starts_fresh(self):
        _, ws = ws_connect(self.port, "session=nope")
        c = Client(ws)
        h = c.wait_control("hello")
        self.assertFalse(h["reattached"])
        self.assertNotEqual(h["session"], "nope")
        ws.send_json({"type": "close"})

    def test_ghostty_config(self):
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d) / "a", Path(d) / "b"
            a.write_text("theme = Monokai Classic\nfont-size = 14\n")
            got = terminal.ghostty_config((a, b))
            self.assertIn("font-size = 14", got["text"])
            self.assertEqual(got["sources"], [str(a)])
        import urllib.request
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/hermes/terminal/config")
        with self.assertRaises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(req)
        self.assertEqual(e.exception.code, 401)
        req.add_header("Authorization", f"Bearer {KEY}")
        self.assertIn("sources", json.loads(urllib.request.urlopen(req).read()))

    def test_login_shell_env(self):
        env = terminal.shell_env("/bin/zsh")
        self.assertEqual(env["TERM"], "xterm-256color")
        self.assertNotIn("PYTHONPATH", env)
        self.assertNotIn("API_SERVER_KEY", env)


if __name__ == "__main__":
    unittest.main()
