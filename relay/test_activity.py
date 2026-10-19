import asyncio
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import companion  # noqa: E402
import slash_bridge  # noqa: E402


def _companion(reply):
    calls = []
    c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
    c._bridge = lambda req, timeout: calls.append(req) or reply
    companion.Companion._activity_cache.clear()
    return c, calls


def _running(monkeypatch, running=True, **kw):
    import run_state
    run = {"running": running, "kind": "tool" if running else None, "tool": "terminal" if running else None,
           "preview": None, "started_at": 1.0 if running else None, "activity_at": None, **kw}
    monkeypatch.setattr(run_state, "session_run", lambda sid: dict(run))


def test_activity_list_route_and_cache(monkeypatch):
    _running(monkeypatch)
    companion.Companion._activity_bridge_last.clear()
    c, calls = _companion({"live": True, "live_status": "working", "subagents": [], "processes": []})
    out = c.handle("GET", "/activity", {"session": "api_1_ab"}, {})
    assert out["live"] is True and out["run"]["running"] is True and out["run"]["can_stop"] is True
    companion.Companion._activity_cache.clear()
    c._bridge = lambda req, timeout: calls.append(req) or {"live": True, "live_status": "idle", "subagents": [], "processes": []}
    assert c.handle("GET", "/activity", {"session": "api_1_ab"}, {})["run"]["can_stop"] is False  # gateway run, open in desktop
    calls.pop()
    assert "live_status" not in out
    assert calls == [{"op": "activity", "session_id": "api_1_ab"}]
    c.handle("GET", "/activity", {"session": "api_1_ab"}, {})
    assert len(calls) == 1  # second poll within 1.5 s is served from the cache


def test_activity_idle_chat_skips_the_dashboard(monkeypatch):
    _running(monkeypatch, running=False)
    companion.Companion._activity_bridge_last.clear()
    c, calls = _companion({"live": False, "subagents": [], "processes": []})
    out = c.handle("GET", "/activity", {"session": "s_idle"}, {})
    assert calls == [] and out["run"]["running"] is False and out["subagents"] == []


def test_activity_waiting_desktop_chat_counts_as_running(monkeypatch):
    _running(monkeypatch, running=False)
    companion.Companion._activity_bridge_last.clear()
    c, calls = _companion({"live": True, "live_status": "waiting", "subagents": [], "processes": []})
    out = c.handle("GET", "/activity", {"session": "s_wait", "full": "1"}, {})
    assert out["run"]["running"] is True and out["run"]["waiting"] is True


def test_activity_stop_route(monkeypatch):
    c, calls = _companion({"stopped": True})
    assert c.handle("POST", "/activity/stop", {"session": "s1"}, {}) == {"stopped": True}
    assert calls == [{"op": "session_interrupt", "session_id": "s1"}]


def test_run_state_from_heartbeat(tmp_path):
    import sqlite3
    import run_state
    db = tmp_path / "state.db"
    conn = sqlite3.connect(db)
    conn.execute("CREATE TABLE sessions (id TEXT, source TEXT, last_activity_at REAL, last_activity_description TEXT)")
    conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, tool_calls TEXT, "
                 "tool_call_id TEXT, timestamp REAL)")
    now = 10_000.0
    conn.executemany("INSERT INTO sessions VALUES (?,?,?,?)", [
        ("busy", "desktop", now - 30, "terminal command running (25s elapsed)"),
        ("stale", "telegram", now - 3600, "receiving stream response"),  # crashed agent: label never cleared
        ("idle", "api_server", now - 5, ""),
        ("calls", "cli", now - 10, "starting new turn"),
    ])
    calls = '[{"id": "c1", "function": {"name": "web_search", "arguments": "{\\"query\\": \\"espresso\\"}"}}]'
    conn.executemany("INSERT INTO messages (session_id, role, tool_calls, tool_call_id, timestamp) VALUES (?,?,?,?,?)", [
        ("busy", "user", None, None, now - 40),
        ("calls", "user", None, None, now - 20),
        ("calls", "assistant", calls, None, now - 15),
    ])
    conn.commit()
    busy = run_state.session_run("busy", now=now, db=db)
    assert busy["running"] and busy["kind"] == "tool" and busy["tool"] == "terminal" and busy["started_at"] == now - 40
    assert not run_state.session_run("stale", now=now, db=db)["running"]
    assert not run_state.session_run("idle", now=now, db=db)["running"]
    pending = run_state.session_run("calls", now=now, db=db)
    assert pending["tool"] == "web_search" and pending["preview"] == "espresso"
    assert {r["id"] for r in run_state.running_sessions(now=now, db=db)} == {"busy", "calls"}
    assert not run_state.session_run("missing", now=now, db=tmp_path / "nope.db")["running"]


def test_describe_heartbeats():
    import run_state
    assert run_state.describe("receiving stream response")["kind"] == "thinking"
    assert run_state.describe("executing tool: read_file") == {"kind": "tool", "tool": "read_file"}
    assert run_state.describe("sequential tool running (12s): patch") == {"kind": "tool", "tool": "patch"}
    assert run_state.describe("delegate_task: subagent running terminal (iteration 5/250)")["kind"] == "subagents"
    assert run_state.describe("context compression in progress")["kind"] == "compressing"


def test_activity_validates_session_and_methods():
    c, _ = _companion({})
    with pytest.raises(companion.RouteError) as e:
        c.handle("GET", "/activity", {}, {})
    assert e.value.status == 400
    with pytest.raises(companion.RouteError):
        c.handle("GET", "/activity", {"session": "../etc/passwd"}, {})
    with pytest.raises(companion.RouteError) as e:
        c.handle("GET", "/activity/process/p1/kill", {"session": "s1"}, {})
    assert e.value.status == 405
    with pytest.raises(companion.RouteError) as e:
        c.handle("POST", "/activity/process/p1/rm", {"session": "s1"}, {})
    assert e.value.status == 404


def test_activity_controls_map_to_bridge_ops():
    c, calls = _companion({"id": "x", "status": "queued"})
    c.handle("GET", "/activity/subagent/sa-0-1/tail", {"session": "s1"}, {})
    c.handle("POST", "/activity/subagent/sa-0-1/steer", {"session": "s1"}, {"message": "  focus on tests  "})
    c.handle("POST", "/activity/subagent/sa-0-1/stop", {"session": "s1"}, {})
    c.handle("GET", "/activity/process/proc_1/tail", {"session": "s1"}, {})
    c.handle("POST", "/activity/process/proc_1/kill", {"session": "s1"}, {})
    assert [r["op"] for r in calls] == ["subagent_tail", "subagent_steer", "subagent_stop", "process_tail", "process_kill"]
    assert calls[1]["text"] == "focus on tests" and calls[4]["target"] == "proc_1"
    with pytest.raises(companion.RouteError):
        c.handle("POST", "/activity/subagent/sa-0-1/steer", {"session": "s1"}, {"message": "  "})


def test_activity_bridge_errors_become_http_errors():
    c, _ = _companion({"error": "That chat isn't open on the Mac right now.", "status": 409})
    with pytest.raises(companion.RouteError) as e:
        c.handle("POST", "/activity/process/p1/kill", {"session": "s1"}, {})
    assert e.value.status == 409


class FakeWS:
    """Answers JSON-RPC calls from a table, like the dashboard's /api/ws."""

    def __init__(self, table):
        self.table, self.sent, self.queue = table, [], []

    async def send(self, raw):
        msg = json.loads(raw)
        self.sent.append((msg["method"], msg["params"]))
        self.queue.append({"jsonrpc": "2.0", "id": msg["id"], "result": self.table[msg["method"]]})

    async def recv(self):
        return json.dumps(self.queue.pop(0))

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False


def test_run_activity_filters_to_the_chat(monkeypatch):
    ws = FakeWS({
        "delegation.status": {"active": [
            {"subagent_id": "sa-1", "goal": "Build it", "started_at": 100.0, "status": "running", "tool_count": 3,
             "last_tool": "terminal", "owner_agent_session_id": "api_1"},
            {"subagent_id": "sa-2", "goal": "Other chat", "started_at": 100.0, "owner_agent_session_id": "api_2"}]},
        "session.active_list": {"sessions": [{"id": "live9", "session_key": "api_1"}]},
        "agents.list": {"processes": [{"session_id": "proc_a"}]},
        "process.list": {"processes": [
            {"session_id": "proc_a", "command": "sleep 300", "status": "running", "output_tail": "x" * 5000},
            {"session_id": "proc_b", "command": "done", "status": "exited"}]},
    })

    async def connect():
        return ws
    monkeypatch.setattr(slash_bridge, "_connect", connect)
    monkeypatch.setattr(slash_bridge.time, "time", lambda: 160.0)
    out = asyncio.run(slash_bridge.run_activity("api_1"))
    assert [s["id"] for s in out["subagents"]] == ["sa-1"]
    assert out["subagents"][0]["elapsed_s"] == 60 and out["subagents"][0]["current_tool"] == "terminal"
    assert [p["id"] for p in out["processes"]] == ["proc_a"] and "output_tail" not in out["processes"][0]
    assert ("process.list", {"session_id": "live9"}) in ws.sent
    assert not any(m == "session.close" for m, _ in ws.sent)  # never ends the desktop's chat


def test_controls_attach_without_closing(monkeypatch):
    ws = FakeWS({
        "session.active_list": {"sessions": [{"id": "live9", "session_key": "api_1"}]},
        "session.activate": {},
        "subagent.steer": {"status": "queued"},
    })

    async def connect():
        return ws
    monkeypatch.setattr(slash_bridge, "_connect", connect)
    out = asyncio.run(slash_bridge.run_control("subagent_steer", "api_1", "sa-1", "hi"))
    assert out == {"id": "sa-1", "status": "queued"}
    assert [m for m, _ in ws.sent] == ["session.active_list", "session.activate", "subagent.steer"]
