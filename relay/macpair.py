"""Otto for Mac pairing. The Mac App Store build is sandboxed, so it can't read ~/.hermes/.env.
Instead it asks the relay on this Mac, and the person at the Mac clicks Allow once:

- POST /macpair/start   (no auth; direct loopback only, never via Tailscale Serve)
                        {name?} → {id, code, expires_in}; the relay shows a macOS dialog with the code
- GET  /macpair/poll?id=…  (no auth) → {status: pending|approved|denied|expired}; on approved also
                        {gateway, relay, api_key}, exactly once, then the pairing is gone
- POST /macpair/cancel?id=…  (no auth; the id is the secret) → drops the pairing, closes the dialog

The key only leaves the relay after a click on this Mac's own screen (or, as a fallback, after an
already-connected iPhone/iPad approves the code with POST /hermes/tvpair/approve: the pairing pool
is shared with the Apple TV flow). Requests that came through Tailscale Serve (X-Forwarded-For /
Tailscale-* headers), from a non-loopback address, with a non-loopback Host (DNS rebinding) or with
Origin / Sec-Fetch-* headers (any browser) are refused on all three routes. The dialog defaults to
Don't Allow, one dialog is shown at a time, and starts are rate-limited by TVPairing.
"""
from __future__ import annotations

import subprocess
import threading
from typing import Callable

from tvpair import TVPairing

DIALOG_SECONDS = 120


_PROXY_HEADERS = ("x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "forwarded",
                  "tailscale-user-login", "tailscale-user-name", "tailscale-headers-info")
_LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "[::1]")


def _loopback_host(host: str | None) -> bool:
    """Host header names this Mac's loopback (optionally with a numeric port). A DNS-rebinding page
    reaches 127.0.0.1 too, but its Host is still its own domain, so this refuses it."""
    h = (host or "").strip().lower()
    if not h:
        return False
    if h.startswith("["):
        name, _, rest = h.partition("]")
        name += "]"
        port = rest[1:] if rest.startswith(":") else (None if not rest else "x")
    else:
        name, sep, port = h.partition(":")
        port = port if sep else None
    if port is not None and not (port.isdigit() and len(port) <= 5):
        return False
    return name in _LOOPBACK_HOSTS


def is_direct_loopback(client_ip: str, headers) -> bool:
    """True only for a native process on this Mac talking to 127.0.0.1 directly:
    - the peer address is loopback;
    - no forwarding headers (Tailscale Serve also connects from 127.0.0.1, but adds them);
    - Host is 127.0.0.1 / localhost / [::1] (blocks DNS rebinding);
    - no Origin or Sec-Fetch-* header: browsers always send them, URLSession never does, so no web
      page (same-origin, rebound or cross-site) can drive pairing."""
    if client_ip not in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
        return False
    lower = {str(k).lower(): v for k, v in (headers.items() if hasattr(headers, "items") else [])}
    if any(h in lower for h in _PROXY_HEADERS):
        return False
    if "origin" in lower or any(k.startswith("sec-fetch-") for k in lower):
        return False
    return _loopback_host(lower.get("host"))


def _clean_name(name: object) -> str:
    s = "".join(ch for ch in str(name or "") if ch.isprintable() and ch not in "\"\\")
    return s.strip()[:40] or "Otto"


def osascript_confirm(code: str, name: str, dismissed: threading.Event | None = None) -> bool:
    """Shows the Allow / Don't Allow dialog on this Mac. Blocks until a click, the timeout, or
    `dismissed` (the app cancelled, or an iPhone approved the code), which closes the dialog."""
    spaced = f"{code[:3]} {code[3:]}"
    msg = (f"{name} wants to connect to Hermes on this Mac.\\n\\n"
           f"Code: {spaced}\\n\\nAllow only if {name} shows the same code.")
    script = (f'display dialog "{msg}" with title "Connect {name}" '
              f'buttons {{"Don\'t Allow", "Allow"}} default button "Don\'t Allow" cancel button "Don\'t Allow" '
              f'with icon caution giving up after {DIALOG_SECONDS}')
    try:
        proc = subprocess.Popen(["/usr/bin/osascript", "-e", script], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return False
    try:
        while True:
            try:
                out, _ = proc.communicate(timeout=0.25)
                break
            except subprocess.TimeoutExpired:
                if dismissed is not None and dismissed.is_set():
                    proc.kill()
                    proc.communicate()
                    return False
    except Exception:  # noqa: BLE001
        proc.kill()
        return False
    return proc.returncode == 0 and "button returned:Allow" in (out or "") and "gave up:true" not in (out or "")


class MacPairing:
    def __init__(self, pool: TVPairing, local_urls: Callable[[], tuple[str, str]],
                 confirm: Callable[[str, str, threading.Event], bool] | None = None, run_async: bool = True):
        self.pool = pool
        self.local_urls = local_urls      # () -> (gateway, relay) as seen from this Mac
        self.confirm = confirm or (lambda code, name, dismissed: osascript_confirm(code, name, dismissed))
        self.run_async = run_async
        self.lock = threading.Lock()
        self.dialog_open = False
        self.denied: set[str] = set()
        self.dismiss: dict[str, threading.Event] = {}

    def start(self, body: dict, client_ip: str, headers) -> tuple[int, dict]:
        refused = self.guard(client_ip, headers)
        if refused:
            return refused
        with self.lock:
            if self.dialog_open:
                return 409, {"detail": "a connect request is already waiting on this Mac's screen"}
            status, r = self.pool.start()
            if status != 200:
                return status, r
            self.dialog_open = True
            self.dismiss[r["id"]] = threading.Event()
        name = _clean_name(body.get("name"))
        if self.run_async:
            threading.Thread(target=self._ask, args=(r["id"], r["code"], name), daemon=True).start()
        else:
            self._ask(r["id"], r["code"], name)
        return 200, r

    def _ask(self, pid: str, code: str, name: str) -> None:
        try:
            allowed = self.confirm(code, name, self.dismiss[pid])
        finally:
            with self.lock:
                self.dialog_open = False
                self.dismiss.pop(pid, None)
        if allowed:
            gateway, relay = self.local_urls()
            self.pool.approve({"code": code, "gateway": gateway, "relay": relay})
        else:
            with self.pool.lock:
                if self.pool.pending.pop(pid, None) is not None:
                    if len(self.denied) > 50:
                        self.denied.clear()
                    self.denied.add(pid)

    def guard(self, client_ip: str, headers) -> tuple[int, dict] | None:
        """Every /macpair route goes through this: None if the request may proceed, else a 403."""
        if not is_direct_loopback(client_ip, headers):
            return 403, {"detail": "pairing a Mac only works from that Mac"}
        return None

    def poll(self, pid: str) -> tuple[int, dict]:
        if pid in self.denied:
            self.denied.discard(pid)
            return 200, {"status": "denied"}
        status, r = self.pool.poll(pid)
        if r.get("status") == "approved":      # approved from an iPhone: close the dialog
            self._close(pid)
        return status, r

    def cancel(self, pid: str) -> tuple[int, dict]:
        """The app gave up waiting (Cancel): drop the pairing and close its dialog."""
        with self.pool.lock:
            self.pool.pending.pop(pid or "", None)
        self._close(pid)
        return 200, {"ok": True}

    def _close(self, pid: str) -> None:
        with self.lock:
            ev = self.dismiss.get(pid or "")
        if ev is not None:
            ev.set()
