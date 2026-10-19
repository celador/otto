"""Apple TV pairing: the TV shows a code, an already-connected iPhone/iPad approves it,
and the TV receives the gateway URL + key. Nobody types a key with a TV remote.

- POST /tvpair/start            (no auth; tailnet-only like the rest of the relay) → {id, code, expires_in}
- GET  /tvpair/poll?id=…        (no auth) → {status: pending|approved|expired}; on approved also
                                  {gateway, relay, api_key}, exactly once, then the pairing is gone
- POST /hermes/tvpair/approve   (bearer = API_SERVER_KEY, i.e. an already-connected device)
                                  {code, gateway, relay} → {ok}

Only an authorized device can release the key, codes expire after 10 minutes, and at most
a handful of pairings can be pending at once.
"""
from __future__ import annotations

import secrets
import threading
import time
from typing import Callable
from urllib.parse import urlsplit

TTL = 600
MAX_PENDING = 5
START_LIMIT_PER_MIN = 10


class TVPairing:
    def __init__(self, api_key: Callable[[], str]):
        self.api_key = api_key
        self.lock = threading.Lock()
        self.pending: dict[str, dict] = {}
        self.starts: list[float] = []

    def _sweep(self, now: float) -> None:
        for pid in [p for p, v in self.pending.items() if now - v["created"] > TTL]:
            del self.pending[pid]
        self.starts = [t for t in self.starts if now - t < 60]

    def start(self) -> tuple[int, dict]:
        now = time.time()
        with self.lock:
            self._sweep(now)
            if len(self.starts) >= START_LIMIT_PER_MIN:
                return 429, {"detail": "too many pairing attempts; wait a minute"}
            if len(self.pending) >= MAX_PENDING:
                oldest = min(self.pending, key=lambda p: self.pending[p]["created"])
                del self.pending[oldest]
            self.starts.append(now)
            codes = {v["code"] for v in self.pending.values()}
            code = f"{secrets.randbelow(1_000_000):06d}"
            while code in codes:
                code = f"{secrets.randbelow(1_000_000):06d}"
            pid = secrets.token_urlsafe(24)
            self.pending[pid] = {"code": code, "created": now, "approved": None}
            return 200, {"id": pid, "code": code, "expires_in": TTL}

    def poll(self, pid: str) -> tuple[int, dict]:
        now = time.time()
        with self.lock:
            self._sweep(now)
            p = self.pending.get(pid or "")
            if p is None:
                return 200, {"status": "expired"}
            if p["approved"] is None:
                return 200, {"status": "pending"}
            del self.pending[pid]
            return 200, {"status": "approved", **p["approved"], "api_key": self.api_key()}

    def approve(self, body: dict) -> tuple[int, dict]:
        code = str(body.get("code", "")).strip().replace(" ", "")
        gateway, relay = str(body.get("gateway", "")), str(body.get("relay", ""))
        for u in (gateway, relay):
            parts = urlsplit(u)
            if parts.scheme not in ("https", "http") or not parts.hostname:
                return 400, {"detail": "gateway and relay must be URLs"}
        if len(code) != 6 or not code.isdigit():
            return 400, {"detail": "the code is 6 digits"}
        now = time.time()
        with self.lock:
            self._sweep(now)
            for p in self.pending.values():
                if p["code"] == code:
                    p["approved"] = {"gateway": gateway.rstrip("/"), "relay": relay.rstrip("/")}
                    return 200, {"ok": True}
        return 410, {"detail": "No Apple TV is showing that code. It may have expired; open Hermes on the TV for a new one."}
