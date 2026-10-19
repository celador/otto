"""Tests for the Weft auto-config route (no network): mint once, reuse, renew, fall back."""
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import weft_config as w  # noqa: E402

URL = "https://weft.example"


def _dir(admin=True, observer=False, url=URL) -> Path:
    d = Path(tempfile.mkdtemp())
    (d / "hermes-adapter.json").write_text(json.dumps({"url": url, "agents": {}}))
    if admin:
        (d / "preview-admin-token").write_text("ADMIN\n")
    if observer:
        (d / "observer-all-token").write_text("OBS\n")
    return d


class FakeGateway:
    def __init__(self, mint_status=201, repos_status=200):
        self.calls = []
        self.mint_status = mint_status
        self.repos_status = repos_status
        self.n = 0

    def __call__(self, url, token, method, path, body):
        self.calls.append((method, path, token, body))
        if path == "/v1/admin/tokens":
            if self.mint_status != 201:
                return self.mint_status, {"error": {"code": "unauthorized"}}
            self.n += 1
            return 201, {"token": f"HUMAN{self.n}", "info": {"id": f"tok_{self.n}", "created_at": "now"}}
        if path == "/v1/repos":
            return self.repos_status, {"repos": []}
        return 404, None


def test_mints_once_then_reuses():
    d, gw = _dir(), FakeGateway()
    a = w.get_config(weft_dir=d, call=gw)
    assert a == {"url": URL, "token": "HUMAN1", "scope": "human", "principal": "john", "source": "hermes-host"}
    method, path, token, body = gw.calls[0]
    assert (method, path, token) == ("POST", "/v1/admin/tokens", "ADMIN")
    assert body["scopes"] == ["human"] and body["repos"] == "*" and body["principal"] == "john"
    saved = d / "otto-human-token.json"
    assert stat.S_IMODE(os.stat(saved).st_mode) == 0o600
    b = w.get_config(weft_dir=d, call=gw)
    assert b["token"] == "HUMAN1" and len(gw.calls) == 1   # reused, no second mint


def test_renew_keeps_a_working_token_and_replaces_a_revoked_one():
    d, gw = _dir(), FakeGateway()
    w.get_config(weft_dir=d, call=gw)
    assert w.get_config(renew=True, weft_dir=d, call=gw)["token"] == "HUMAN1"
    gw.repos_status = 401
    assert w.get_config(renew=True, weft_dir=d, call=gw)["token"] == "HUMAN2"


def test_new_gateway_url_mints_again():
    d, gw = _dir(), FakeGateway()
    w.get_config(weft_dir=d, call=gw)
    (d / "hermes-adapter.json").write_text(json.dumps({"url": "https://other.example/"}))
    c = w.get_config(weft_dir=d, call=gw)
    assert c["url"] == "https://other.example" and c["token"] == "HUMAN2"


def test_observer_fallback_without_admin():
    c = w.get_config(weft_dir=_dir(admin=False, observer=True), call=FakeGateway())
    assert c["scope"] == "observe" and c["token"] == "OBS" and c["principal"] is None


def test_observer_fallback_when_admin_rejected():
    c = w.get_config(weft_dir=_dir(observer=True), call=FakeGateway(mint_status=401))
    assert c["scope"] == "observe"


def test_no_token_on_host():
    try:
        w.get_config(weft_dir=_dir(admin=False), call=FakeGateway())
    except w.WeftConfigError as e:
        assert e.status == 503 and e.reason == "no_token" and "ADMIN" not in e.detail
    else:
        raise AssertionError("expected WeftConfigError")


def test_gateway_unreachable_is_502():
    def down(*a):
        raise w.WeftConfigError(502, "can't reach the Weft gateway (x)", "gateway_unreachable")
    try:
        w.get_config(weft_dir=_dir(), call=down)
    except w.WeftConfigError as e:
        assert e.status == 502 and e.reason == "gateway_unreachable"
    else:
        raise AssertionError("expected WeftConfigError")


if __name__ == "__main__":
    for n in sorted(dir()):
        if n.startswith("test_"):
            globals()[n]()
    print("ok")
