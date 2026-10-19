"""Weft auto-config for Otto: `GET /hermes/weft/config` -> {url, token, scope, principal}.

Otto shows a Weft strip in each workspace. It needs the Weft gateway address and a token; John
should never type either. This Mac already has both:

- the gateway URL: `url` in ~/.config/weft/hermes-adapter.json (the Hermes adapter's config);
- an operator (admin) token: ~/.config/weft/preview-admin-token.

The first request mints one HUMAN-scope token for all repos (principal "john", so approve / undo /
pause / message work and are attributed to him) through `POST /v1/admin/tokens`, stores it in
~/.config/weft/otto-human-token.json (mode 600) and reuses it from then on. `?renew=1` checks the
stored token against `/v1/repos` and mints a fresh one if the gateway no longer accepts it (the
app asks for this after a 401). Without an admin token it falls back to
~/.config/weft/observer-all-token (read-only, scope "observe").

Tokens are never logged; error details name files and HTTP statuses only.
"""
from __future__ import annotations

import json
import os
import threading
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

WEFT_DIR = Path(os.environ.get("WEFT_CONFIG_DIR", "~/.config/weft")).expanduser()
DEFAULT_URL = "https://weft-gateway-preview.elier.ai"
PRINCIPAL = "john"
LABEL = "Otto auto-config (relay /hermes/weft/config)"
# Cloudflare refuses urllib's default User-Agent (403).
USER_AGENT = "otto-relay/1 (weft auto-config)"

_lock = threading.Lock()


class WeftConfigError(Exception):
    def __init__(self, status: int, detail: str, reason: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail
        self.reason = reason  # machine-readable: no_url | no_token | gateway_unreachable | gateway_rejected


def _read(path: Path) -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def _write_private(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def gateway_url(weft_dir: Path = WEFT_DIR) -> str:
    try:
        url = json.loads((weft_dir / "hermes-adapter.json").read_text()).get("url") or ""
    except (OSError, json.JSONDecodeError):
        url = ""
    return (url or os.environ.get("WEFT_URL") or DEFAULT_URL).rstrip("/")


Call = Callable[[str, str, str, str, Any], tuple[int, Any]]


def http_call(url: str, token: str, method: str, path: str, body: Any = None) -> tuple[int, Any]:
    """(status, json body). Network failures raise WeftConfigError(gateway_unreachable)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url + path, data=data, method=method, headers={
        "Authorization": f"Bearer {token}", "WCP-Version": "0.1", "User-Agent": USER_AGENT,
        **({"Content-Type": "application/json"} if data is not None else {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except json.JSONDecodeError:
            return e.code, None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise WeftConfigError(502, f"can't reach the Weft gateway ({getattr(e, 'reason', e)})",
                              "gateway_unreachable") from None


def _payload(url: str, token: str, scope: str, principal: str | None) -> dict[str, Any]:
    return {"url": url, "token": token, "scope": scope, "principal": principal, "source": "hermes-host"}


def get_config(renew: bool = False, weft_dir: Path = WEFT_DIR, call: Call = http_call) -> dict[str, Any]:
    url = gateway_url(weft_dir)
    store = weft_dir / "otto-human-token.json"
    with _lock:
        saved: dict[str, Any] = {}
        try:
            saved = json.loads(store.read_text())
        except (OSError, json.JSONDecodeError):
            saved = {}
        if saved.get("token") and saved.get("url") == url:
            if not renew:
                return _payload(url, saved["token"], "human", saved.get("principal") or PRINCIPAL)
            status, _ = call(url, saved["token"], "GET", "/v1/repos", None)
            if status == 200:
                return _payload(url, saved["token"], "human", saved.get("principal") or PRINCIPAL)
            # 401/403: revoked or replaced gateway -> mint again below.

        admin = _read(weft_dir / "preview-admin-token")
        if admin:
            status, body = call(url, admin, "POST", "/v1/admin/tokens",
                                {"principal": PRINCIPAL, "scopes": ["human"], "repos": "*", "label": LABEL})
            if status == 201 and isinstance(body, dict) and body.get("token"):
                info = body.get("info") or {}
                _write_private(store, {"url": url, "token": body["token"], "token_id": info.get("id"),
                                       "principal": PRINCIPAL, "scopes": ["human"], "repos": "*",
                                       "created_at": info.get("created_at")})
                return _payload(url, body["token"], "human", PRINCIPAL)
            if status in (401, 403):
                admin_rejected = True
            else:
                raise WeftConfigError(502, f"the Weft gateway didn't issue a token (HTTP {status})", "gateway_rejected")
        else:
            admin_rejected = False

        observer = _read(weft_dir / "observer-all-token")
        if observer:
            return _payload(url, observer, "observe", None)
        if admin_rejected:
            raise WeftConfigError(503, "the Weft gateway rejected this Mac's admin token", "gateway_rejected")
        raise WeftConfigError(503, f"no Weft token on this Mac (looked in {weft_dir})", "no_token")
