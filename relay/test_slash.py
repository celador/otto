import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import companion  # noqa: E402
import slash_bridge  # noqa: E402


def test_directives_map_to_phone_kinds():
    assert slash_bridge._from_directive({"type": "send", "message": "hi", "notice": "n"}) == \
        {"kind": "send", "message": "hi", "notice": "n"}
    assert slash_bridge._from_directive({"type": "skill", "message": "skill body"})["kind"] == "send"
    assert slash_bridge._from_directive({"type": "prefill", "message": "edit me"})["kind"] == "prefill"
    assert slash_bridge._from_directive({"output": "done", "warning": "careful"}) == \
        {"kind": "output", "text": "done\n\ncareful"}
    assert slash_bridge._from_directive({}) == {"kind": "output", "text": "(no output)"}


def _companion(calls):
    c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
    c.dash = lambda m, p, q=None, b=None: calls.append((m, p)) or {}
    c._bridge = lambda req, timeout: calls.append(("bridge", req)) or {"kind": "output", "text": "ok"}
    return c


def test_slash_validates_and_routes():
    calls = []
    c = _companion(calls)
    with pytest.raises(companion.RouteError):
        c.slash({"session_id": "s1", "command": "status"})
    with pytest.raises(companion.RouteError):
        c.slash({"session_id": "../etc", "command": "/status"})
    assert c.slash({"session_id": "api_1_ab", "command": "/compress here 2"})["text"] == "ok"
    assert calls[-1] == ("bridge", {"op": "exec", "session_id": "api_1_ab", "command": "/compress here 2"})
    c.slash({"session_id": "", "command": "/restart"})
    assert calls[-1] == ("POST", "/api/gateway/restart")


def test_routes_are_mounted():
    calls = []
    c = _companion(calls)
    c.slash_catalog = lambda force=False: {"commands": []}
    assert c.handle("GET", "/commands", {}, {}) == {"commands": []}
    assert c.handle("POST", "/slash", {}, {"session_id": "x1", "command": "/status"})["kind"] == "output"


def test_compress_text():
    assert slash_bridge._compress_text({"summary": {"headline": "Compressed: 462 → 151 messages",
                                                    "token_line": "Approx request size: ~213,202 → ~73,538 tokens"}}) \
        == "Compressed: 462 → 151 messages\nApprox request size: ~213,202 → ~73,538 tokens"
    assert slash_bridge._compress_text({"status": "compressed", "before_messages": 10, "after_messages": 4}) == \
        "Compressed: 10 → 4 messages"
    assert slash_bridge._compress_text({}) == "Nothing to compress yet."
