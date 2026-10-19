"""Read-only-ish view of what Honcho (local, Docker on this Mac) has learned, for the iOS Memory screen.

GET  /hermes/honcho?peer=john          -> {enabled, peers, peer, card, conclusions: [{ids, content, level, created_at}]}
POST /hermes/honcho/forget {peer, ids}  -> deletes those conclusions (one fact can be stored by several observers)

Config comes from ~/.hermes/honcho.json (baseUrl must be loopback; nothing here talks to a remote host).
"""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

CONFIG = Path.home() / ".hermes" / "honcho.json"
MAX_PAGES = 10
# "john asked, "…" at 2026-10-06 04:02:16." — Honcho's verbatim message echoes, not things it learned.
ECHO = re.compile(r'^\S+ (asked|repeated|said|stated|wrote|replied|responded|messaged)\b.*"\s*(at \d{4}-\d\d-\d\d[^.]*)?\.?$', re.S)
SAFE_ID = re.compile(r"[A-Za-z0-9_.:@-]{1,128}")


class HonchoError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def load_config(path: Path = CONFIG) -> dict[str, Any] | None:
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    host = (raw.get("hosts") or {}).get("hermes") or {}
    if not host.get("enabled", True):
        return None
    base = (raw.get("baseUrl") or "").rstrip("/")
    if urllib.parse.urlparse(base).hostname not in ("127.0.0.1", "localhost", "::1"):
        return None  # local-only by design
    return {"base": base, "workspace": host.get("workspace", "hermes"), "user": host.get("peerName", "john"),
            "ai": host.get("aiPeer", "hermes"), "prefix": host.get("runtimePeerPrefix", "gw_")}


def _http(method: str, url: str, body: Any = None, timeout: float = 10) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        raise HonchoError(502 if e.code >= 500 else e.code, f"Honcho said {e.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise HonchoError(503, "Honcho isn't running on the Mac") from None


def tidy(text: str) -> str:
    return " ".join(text.split())


class HonchoMemory:
    def __init__(self, http: Callable[..., Any] = _http, config: Callable[[], dict | None] = load_config):
        self.http = http
        self.config = config

    def _ws(self, cfg: dict) -> str:
        return f"{cfg['base']}/v3/workspaces/{urllib.parse.quote(cfg['workspace'], safe='')}"

    def peers(self, cfg: dict) -> list[str]:
        ws = self._ws(cfg)
        out: list[str] = []
        for page in range(1, MAX_PAGES + 1):
            d = self.http("POST", f"{ws}/peers/list?page={page}&size=100", {})
            out += [p["id"] for p in d.get("items", [])]
            if page >= (d.get("pages") or 1):
                break
        people = [p for p in out if p != cfg["ai"] and not p.startswith(cfg["prefix"])]
        people.sort(key=lambda p: (p != cfg["user"], p))
        return people or [cfg["user"]]

    def view(self, peer: str | None) -> dict[str, Any]:
        cfg = self.config()
        if not cfg:
            return {"enabled": False, "peers": [], "peer": None, "card": [], "conclusions": []}
        peers = self.peers(cfg)
        peer = peer if peer in peers else peers[0]
        ws = self._ws(cfg)
        q = urllib.parse.quote(peer, safe="")
        card = (self.http("GET", f"{ws}/peers/{q}/card") or {}).get("peer_card") or []
        items: list[dict] = []
        for page in range(1, MAX_PAGES + 1):
            d = self.http("POST", f"{ws}/conclusions/list?page={page}&size=100&reverse=true", {"filters": {"observed_id": peer}})
            items += d.get("items", [])
            if page >= (d.get("pages") or 1):
                break
        merged: dict[str, dict] = {}
        for it in items:
            content = tidy(it.get("content") or "")
            if not content or ECHO.match(content):
                continue
            key = content.lower()
            m = merged.get(key)
            if m is None:
                merged[key] = {"ids": [it["id"]], "content": content, "level": it.get("level") or "explicit",
                               "created_at": it.get("created_at")}
            else:
                m["ids"].append(it["id"])
                if (it.get("created_at") or "") > (m["created_at"] or ""):
                    m["created_at"] = it.get("created_at")
        facts = sorted(merged.values(), key=lambda f: f["created_at"] or "", reverse=True)
        return {"enabled": True, "peers": peers, "peer": peer, "card": [tidy(c) for c in card if isinstance(c, str)],
                "conclusions": facts}

    def forget(self, ids: Any) -> dict[str, Any]:
        cfg = self.config()
        if not cfg:
            raise HonchoError(404, "Honcho isn't set up")
        if not isinstance(ids, list) or not 1 <= len(ids) <= 20 or not all(isinstance(i, str) and SAFE_ID.fullmatch(i) for i in ids):
            raise HonchoError(400, "need ids")
        ws = self._ws(cfg)
        for i in ids:
            try:
                self.http("DELETE", f"{ws}/conclusions/{i}")
            except HonchoError as e:
                if e.status != 404:
                    raise
        return {"ok": True, "forgot": len(ids)}
