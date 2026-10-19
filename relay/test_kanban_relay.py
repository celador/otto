"""Tests for the Kanban relay's allowlist and body filtering (no network)."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import kanban_relay as r  # noqa: E402


def test_routes():
    ok = [("GET", "/boards"), ("GET", "/board"), ("GET", "/assignees"), ("GET", "/tasks/t_abc123"),
          ("POST", "/tasks"), ("PATCH", "/tasks/t_abc123"), ("POST", "/tasks/t_abc123/comments"),
          ("DELETE", "/tasks/t_abc"), ("POST", "/tasks/t_abc/reclaim")]
    for m, p in ok:
        assert r.route_allowed(m, p), (m, p)
    bad = [("GET", "/config"), ("DELETE", "/boards/x"), ("DELETE", "/links"), ("DELETE", "/attachments/1"),
           ("DELETE", "/tasks/t_abc/comments"), ("POST", "/boards"), ("POST", "/dispatch"),
           ("GET", "/tasks/../config"), ("POST", "/tasks/t_abc/reassign"), ("GET", "/profiles"),
           ("PATCH", "/boards/x"), ("GET", "/tasks/t_abc/log")]
    for m, p in bad:
        assert not r.route_allowed(m, p), (m, p)


def test_query_filter():
    assert r.filter_query("board=webmaster&include_archived=false&evil=1") == "board=webmaster&include_archived=false"


def test_patch_fields():
    body, err = r.sanitize_body("PATCH", "/tasks/t_x", b'{"status":"done","summary":"ok"}')
    assert err is None and json.loads(body) == {"status": "done", "summary": "ok"}
    assert r.sanitize_body("PATCH", "/tasks/t_x", b'{"model_override":"x"}')[1]
    assert r.sanitize_body("PATCH", "/tasks/t_x", b'{"status":"running"}')[1]
    assert r.sanitize_body("PATCH", "/tasks/t_x", b'[1]')[1]


def test_delete_and_reclaim_bodies():
    assert r.sanitize_body("DELETE", "/tasks/t_x", b"") == (None, None)
    body, err = r.sanitize_body("POST", "/tasks/t_x/reclaim", b'{}')
    assert err is None and json.loads(body) == {"reason": "stopped from Hermes iOS"}
    assert r.sanitize_body("POST", "/tasks/t_x/reclaim", b'{"reason":"x","force":true}')[1]


def test_create_and_comment():
    body, err = r.sanitize_body("POST", "/tasks", b'{"title":"Hi","triage":true}')
    assert err is None and json.loads(body)["title"] == "Hi"
    assert r.sanitize_body("POST", "/tasks", b'{"title":"  "}')[1]
    assert r.sanitize_body("POST", "/tasks", b'{"title":"x","workspace_path":"/"}')[1]
    body, err = r.sanitize_body("POST", "/tasks/t_x/comments", b'{"body":"nice"}')
    assert err is None and json.loads(body) == {"body": "nice", "author": "hermes-ios"}
    assert r.sanitize_body("POST", "/tasks/t_x/comments", b'{"body":"x","author":"john"}')[1]


def test_companion_validation():
    import companion as c
    assert c.valid_name("webmaster") and c.valid_name("ios-app-store-release")
    assert not c.valid_name("../etc") and not c.valid_name("") and not c.valid_name("a/b")
    comp = c.Companion("http://127.0.0.1:1", lambda: "x")
    for method, sub, q, body in [
        ("GET", "/config", {}, {}),
        ("GET", "/env", {}, {}),
        ("POST", "/memory", {}, {"op": "reset", "target": "memory"}),
        ("POST", "/memory", {}, {"op": "add", "target": "secrets"}),
        ("GET", "/skills/content", {"name": "../../x"}, {}),
        ("GET", "/skills", {"profile": "../x"}, {}),
        ("GET", "/usage", {"days": "9999"}, {}),
        ("PUT", "/skills/toggle", {}, {"name": "x"}),
    ]:
        try:
            comp.handle(method, sub, q, body)
        except c.RouteError as e:
            assert e.status in (400, 404), (sub, e.status)
        else:
            raise AssertionError(f"{method} {sub} should be refused")


def test_automation_validation():
    import companion as c
    comp = c.Companion("http://127.0.0.1:1", lambda: "x")
    for method, sub, q, body in [
        ("PATCH", "/automations/abcd1234", {}, {"script": "rm -rf /"}),
        ("PATCH", "/automations/abcd1234", {}, {"workdir": "/"}),
        ("PATCH", "/automations/abcd1234", {}, {}),
        ("GET", "/automations/../../etc/runs", {}, {}),
        ("GET", "/automations/abcd1234/output", {"run": "cron_output:other:2026-09-30_22-57-57"}, {}),
        ("GET", "/automations/abcd1234/runs", {"limit": "500"}, {}),
        ("POST", "/automations/blueprints", {}, {"blueprint": "../x"}),
        ("POST", "/pairing/approve", {}, {"platform": "telegram"}),
        ("POST", "/pairing/approve", {}, {"platform": "Tele gram", "request_id": "abcd"}),
        ("POST", "/pairing/clear", {}, {}),
    ]:
        try:
            comp.handle(method, sub, q, body)
        except c.RouteError as e:
            assert e.status in (400, 404), (sub, e.status)
        else:
            raise AssertionError(f"{method} {sub} {body} should be refused")


def test_extract_run_text():
    import companion as c
    doc = "# Cron Job: X\n\n**Status:** ok\n\n## Prompt\n\nlong prompt\n\n## Response\n\nHello **John**\n"
    assert c.extract_run_text(doc) == "Hello **John**"
    assert c.extract_run_text("# X\n**Mode:** no_agent\n**Status:** silent (empty output)\n") == "Status: silent (empty output)"
    assert c.extract_run_text("# X\n## Script Output\nall good\n") == "all good"


def test_profile_model_route():
    sys.path.insert(0, str(Path(__file__).parent))
    from companion import Companion, RouteError
    calls = []
    c = Companion("http://dash", lambda: "tok")
    c.dash = lambda method, path, query=None, body=None: calls.append((method, path, body)) or {"ok": True}
    out = c.handle("PUT", "/profiles/arq/model", {}, {"provider": "anthropic", "model": "claude-opus-5-5"})
    assert out == {"ok": True, "provider": "anthropic", "model": "claude-opus-5-5"}
    assert calls == [("PUT", "/api/profiles/arq/model", {"provider": "anthropic", "model": "claude-opus-5-5"})]
    for bad_name, body in [("../x", {"provider": "a", "model": "b"}), ("arq", {"provider": "a"}),
                           ("arq", {"provider": "a; rm", "model": "b"}), ("arq", {"provider": "a", "model": 3})]:
        try:
            c.handle("PUT", f"/profiles/{bad_name}/model", {}, body)
            assert False, (bad_name, body)
        except RouteError as e:
            assert e.status in (400, 404)
    try:
        c.handle("DELETE", "/profiles/arq/model", {}, {})
        assert False
    except RouteError:
        pass
