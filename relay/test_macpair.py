import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

from macpair import MacPairing, is_direct_loopback
from tvpair import TVPairing

URLS = lambda: ("http://127.0.0.1:8642", "http://127.0.0.1:8650")  # noqa: E731
H = {"Host": "127.0.0.1:8650"}   # what URLSession sends to http://127.0.0.1:8650


class MacPairTests(unittest.TestCase):
    def make(self, answer: bool, seen: list | None = None):
        def confirm(code, name, dismissed):
            if seen is not None:
                seen.append((code, name))
            return answer
        return MacPairing(TVPairing(lambda: "KEY"), URLS, confirm=confirm, run_async=False)

    def test_allow_releases_key_once(self):
        seen: list = []
        mp = self.make(True, seen)
        s, r = mp.start({"name": "Otto"}, "127.0.0.1", H)
        self.assertEqual(s, 200)
        self.assertEqual(seen, [(r["code"], "Otto")])          # the dialog showed the app's code
        s, got = mp.poll(r["id"])
        self.assertEqual(got, {"status": "approved", "gateway": "http://127.0.0.1:8642",
                               "relay": "http://127.0.0.1:8650", "api_key": "KEY"})
        self.assertEqual(mp.poll(r["id"])[1]["status"], "expired")

    def test_deny(self):
        mp = self.make(False)
        _, r = mp.start({}, "127.0.0.1", H)
        self.assertEqual(mp.poll(r["id"]), (200, {"status": "denied"}))
        self.assertEqual(mp.poll(r["id"])[1]["status"], "expired")
        self.assertNotIn("api_key", mp.poll(r["id"])[1])

    def test_pending_until_clicked(self):
        mp = MacPairing(TVPairing(lambda: "KEY"), URLS, confirm=lambda c, n, d: True, run_async=False)
        gate = threading.Event()
        mp.confirm = lambda c, n, d: gate.wait(5)
        mp.run_async = True
        _, r = mp.start({}, "127.0.0.1", H)
        self.assertEqual(mp.poll(r["id"])[1]["status"], "pending")
        self.assertEqual(mp.start({}, "127.0.0.1", H)[0], 409)   # one dialog at a time
        gate.set()
        for _ in range(100):
            st = mp.poll(r["id"])[1]
            if st["status"] != "pending":
                break
            threading.Event().wait(0.02)
        self.assertEqual(st["status"], "approved")

    def test_phone_approval_and_cancel_close_the_dialog(self):
        closed: list = []

        def confirm(code, name, dismissed):
            closed.append(dismissed.wait(5))
            return False
        pool = TVPairing(lambda: "KEY")
        mp = MacPairing(pool, URLS, confirm=confirm)
        _, r = mp.start({}, "127.0.0.1", H)
        self.assertEqual(pool.approve({"code": r["code"], "gateway": "https://g", "relay": "https://r"})[0], 200)
        self.assertEqual(mp.poll(r["id"])[1]["api_key"], "KEY")      # the phone approved it
        for _ in range(100):
            if closed:
                break
            threading.Event().wait(0.02)
        self.assertEqual(closed, [True])
        for _ in range(100):
            if not mp.dialog_open:
                break
            threading.Event().wait(0.02)
        _, r2 = mp.start({}, "127.0.0.1", H)
        self.assertEqual(mp.cancel(r2["id"]), (200, {"ok": True}))
        for _ in range(100):
            if len(closed) == 2:
                break
            threading.Event().wait(0.02)
        self.assertEqual(closed, [True, True])
        self.assertEqual(mp.poll(r2["id"])[1]["status"], "expired")

    def test_osascript_dialog_is_closed_when_dismissed(self):
        import macpair
        import subprocess
        real = subprocess.Popen
        started: list = []

        def fake_popen(args, **kw):
            started.append(args)
            return real(["/bin/sleep", "30"], **kw)
        ev = threading.Event()
        threading.Timer(0.3, ev.set).start()
        macpair.subprocess.Popen = fake_popen
        try:
            self.assertFalse(macpair.osascript_confirm("123456", "Otto", ev))
        finally:
            macpair.subprocess.Popen = real
        self.assertIn("123 456", started[0][2])

    def test_only_direct_loopback(self):
        mp = self.make(True)
        self.assertEqual(mp.start({}, "100.101.102.103", {})[0], 403)
        self.assertEqual(mp.start({}, "127.0.0.1", {**H, "X-Forwarded-For": "100.1.2.3"})[0], 403)
        self.assertEqual(mp.start({}, "127.0.0.1", {**H, "Tailscale-User-Login": "x@y"})[0], 403)
        self.assertTrue(is_direct_loopback("::1", {"Host": "[::1]:8650"}))
        self.assertEqual(mp.start({}, "100.101.102.103", H)[0], 403)

    def test_browser_and_rebinding_requests_refused(self):
        """DNS rebinding: a web page whose hostname resolves to 127.0.0.1 reaches the relay from
        loopback, but its Host is its own domain and the browser adds Origin / Sec-Fetch-*."""
        mp = self.make(True)
        bad = [
            {},                                                     # no Host at all
            {"Host": "rebind.attacker.example:8650"},
            {"Host": "127.0.0.1.attacker.example"},
            {"Host": "127.0.0.1:8650", "Origin": "http://rebind.attacker.example:8650"},
            {"Host": "127.0.0.1:8650", "Origin": "null"},
            {"Host": "127.0.0.1:8650", "Sec-Fetch-Site": "same-origin"},
            {"Host": "127.0.0.1:8650", "Sec-Fetch-Mode": "cors"},
            {"host": "localhost:8650", "sec-fetch-dest": "empty"},  # header names are case-insensitive
            {"Host": "rebind.attacker.example:8650", "Origin": "http://rebind.attacker.example:8650"},
        ]
        for h in bad:
            self.assertEqual(mp.start({"name": "Otto"}, "127.0.0.1", h)[0], 403, h)
            self.assertEqual(mp.guard("127.0.0.1", h)[0], 403, h)
        self.assertEqual(mp.pool.pending, {})                       # nothing was started

    def test_loopback_hosts_allowed(self):
        mp = self.make(True)
        for host in ("127.0.0.1:8650", "127.0.0.1", "localhost:8650", "[::1]:8650"):
            self.assertIsNone(mp.guard("127.0.0.1", {"Host": host}), host)
        s, r = mp.start({}, "127.0.0.1", {"Host": "127.0.0.1:8650"})
        self.assertEqual(s, 200)
        self.assertEqual(mp.poll(r["id"])[1]["api_key"], "KEY")

    def test_dialog_defaults_to_dont_allow(self):
        import macpair
        import subprocess
        real = subprocess.Popen
        started: list = []

        def fake_popen(args, **kw):
            started.append(args)
            return real(["/bin/echo", "button returned:Allow, gave up:false"], **kw)
        macpair.subprocess.Popen = fake_popen
        try:
            self.assertTrue(macpair.osascript_confirm("123456", "Otto"))
        finally:
            macpair.subprocess.Popen = real
        script = started[0][2]
        self.assertIn('default button "Don\'t Allow"', script)
        self.assertNotIn('default button "Allow"', script)

    def test_name_is_sanitized(self):
        seen: list = []
        mp = self.make(True, seen)
        mp.start({"name": 'Otto" & do shell script "x\\'}, "127.0.0.1", H)
        self.assertNotIn('"', seen[0][1])
        self.assertNotIn("\\", seen[0][1])


class RelayRouteTests(unittest.TestCase):
    """The real handler: /macpair/* is reachable without a bearer, nothing else is."""

    def test_routes(self):
        import kanban_relay
        import macpair
        with TemporaryDirectory() as d:
            env = Path(d) / ".env"
            env.write_text("API_SERVER_KEY=KEY\nHERMES_DASHBOARD_SESSION_TOKEN=T\nAPI_SERVER_PORT=8642\n")
            secrets = kanban_relay.Secrets(env)
            orig = macpair.osascript_confirm
            calls: list = []
            macpair.osascript_confirm = lambda c, n, d=None: calls.append(c) or True
            srv = ThreadingHTTPServer(("127.0.0.1", 0), kanban_relay.make_handler(secrets, 8650))
            port = srv.server_address[1]
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            base = f"http://127.0.0.1:{port}"

            def call(method, path, body=None, headers=None):
                req = urllib.request.Request(base + path, method=method,
                                             data=json.dumps(body).encode() if body is not None else None,
                                             headers=headers or {})
                try:
                    with urllib.request.urlopen(req, timeout=5) as r:
                        return r.status, json.loads(r.read())
                except urllib.error.HTTPError as e:
                    return e.code, json.loads(e.read())

            try:
                s, r = call("POST", "/macpair/start", {"name": "Otto"})
                self.assertEqual(s, 200)
                for _ in range(100):
                    s, got = call("GET", f"/macpair/poll?id={r['id']}")
                    if got["status"] != "pending":
                        break
                    threading.Event().wait(0.02)
                self.assertEqual(calls, [r["code"]])
                self.assertEqual(got["api_key"], "KEY")
                self.assertEqual(got["gateway"], "http://127.0.0.1:8642")
                self.assertEqual(got["relay"], "http://127.0.0.1:8650")
                self.assertEqual(call("POST", "/macpair/start", {}, {"X-Forwarded-For": "100.64.0.1"})[0], 403)
                evil = {"Host": "rebind.attacker.example:8650"}
                browser = {"Origin": "http://rebind.attacker.example:8650"}
                fetch = {"Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors"}
                for h in (evil, browser, fetch):
                    self.assertEqual(call("POST", "/macpair/start", {}, h)[0], 403, h)
                    self.assertEqual(call("GET", f"/macpair/poll?id={r['id']}", None, h)[0], 403, h)
                    self.assertEqual(call("POST", f"/macpair/cancel?id={r['id']}", None, h)[0], 403, h)
                self.assertEqual(call("POST", "/macpair/start", {"name": "Otto"},
                                      {"Host": "127.0.0.1:8650"})[0], 200)
                self.assertEqual(call("GET", "/hermes/status")[0], 401)
            finally:
                srv.shutdown()
                macpair.osascript_confirm = orig


class LocalGatewayTests(unittest.TestCase):
    def test_defaults(self):
        from kanban_relay import local_gateway
        self.assertEqual(local_gateway({}), "http://127.0.0.1:8642")
        self.assertEqual(local_gateway({"API_SERVER_HOST": "0.0.0.0", "API_SERVER_PORT": "9000"}), "http://127.0.0.1:9000")
        self.assertEqual(local_gateway({"API_SERVER_PORT": "x"}), "http://127.0.0.1:8642")


if __name__ == "__main__":
    unittest.main()
