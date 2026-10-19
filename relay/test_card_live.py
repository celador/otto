import json
import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import card_live  # noqa: E402
import companion  # noqa: E402


def term(cmd, **kw):
    return json.dumps({"command": cmd, **kw})


@pytest.mark.parametrize("cmd,phrase,wait,milestone", [
    ("xcodebuild test -scheme Hermes -destination 'platform=iOS Simulator,name=iPhone 17'", "Running tests", "long", True),
    ("cd ios && xcodebuild -scheme OttoMac -configuration Debug build", "Building the Mac app", "long", True),
    ("xcodebuild -scheme Hermes -configuration Release archive -archivePath x", "Building an archive", "long", True),
    ("xcodebuild -exportArchive -archivePath x -exportPath y", "Exporting the build", "long", True),
    ("xcrun altool --upload-app --type ios --file Otto.ipa", "Uploading to TestFlight", "apple", True),
    ("xcrun notarytool submit Otto.zip --wait", "Uploading to Apple", "apple", True),
    ("uv run -q asc.py GET /v1/builds", "Waiting for Apple", "apple", False),
    ("cd relay; env -u PYTHONPATH uv run -q --with pytest python -m pytest -q test_x.py", "Running tests", "long", True),
    ("git rebase rebrand/otto", "Merging", None, True),
    ("git merge --no-ff x", "Merging", None, True),
    ("git push origin rebrand/otto", "Pushing", "network", True),
    ("scripts/land_card.sh t_12345678", "Landing on trunk", None, True),
    ("cd ~/code/hermes-ios && scripts/otto_release.sh --mac", "Releasing a build", "long", True),
    ("sleep 30", "Waiting", "wait", False),
    ("until grep -q done x.log; do sleep 5; done", "Waiting", "wait", False),
    ("curl -s https://example.com", "Calling a server", "network", False),
    ("perl -e 'alarm 40; exec @ARGV' xcrun simctl install booted X.app", "Installing", "long", True),
    # Reading a script that merely names a milestone is not that milestone.
    ("sed -n 1,60p scripts/land_card.sh", "Reading code", None, False),
    ("cd x; grep -n xcodebuild docs/release.md | head", "Reading code", None, False),
    ("python3 -c \"import x; print('land_card.sh xcodebuild test')\"", "Running a script", None, False),
    ("bash -c \"xcodebuild test -scheme Hermes\"", "Running tests", "long", True),
    ("sqlite3 -readonly ~/.hermes/state.db 'select 1'", "Reading the database", None, False),
    ("make all", "Running make", None, False),
])
def test_terminal_phrases(cmd, phrase, wait, milestone):
    got = card_live.classify("terminal", term(cmd))
    assert (got["phrase"], got["wait"], got["milestone"]) == (phrase, wait, milestone)


def test_tool_phrases_and_fallback():
    assert card_live.classify("read_file", json.dumps({"path": "/a/b.swift"}))["phrase"] == "Reading code"
    assert card_live.classify("patch", json.dumps({"path": "/a/CardLive.swift"}))["phrase"] == "Editing CardLive.swift"
    assert card_live.classify("process_manage", json.dumps({"action": "wait"}))["wait"] == "wait"
    assert card_live.classify("web_search", "{}")["wait"] == "network"
    assert card_live.classify("delegate_task", "{}")["milestone"] is True
    assert card_live.classify("mcp__slack__channels_list", "{}")["phrase"] == "Using channels list"
    assert card_live.classify("some_new_tool", "{}")["phrase"] == "Some new tool"  # falls back to the tool name
    assert card_live.classify(None, None)["phrase"] == "Working"


def _call(cid, name, args, ts, text=""):
    return {"role": "assistant", "content": text, "tool_calls": json.dumps(
        [{"id": cid, "type": "function", "function": {"name": name, "arguments": args}}]),
        "tool_call_id": None, "timestamp": ts, "reasoning": None}


def _result(cid, name, ts, out=None):
    return {"role": "tool", "content": json.dumps(out or {"output": "", "exit_code": 0}), "tool_calls": None,
            "tool_call_id": cid, "timestamp": ts, "reasoning": None, "tool_name": name}


def test_activity_now_step_trail_and_words():
    msgs = [
        {"role": "user", "content": "work", "tool_calls": None, "tool_call_id": None, "timestamp": 100, "reasoning": None},
        _call("a", "terminal", term("git rebase rebrand/otto"), 110, "Rebasing first."), _result("a", "terminal", 112),
        _call("b", "terminal", term("xcodebuild test -scheme Hermes"), 120), _result("b", "terminal", 300,
                                                                                    {"output": "x", "exit_code": 65}),
        _call("c", "terminal", term("xcodebuild test -scheme Hermes"), 310), _result("c", "terminal", 500),
        _call("d", "read_file", json.dumps({"path": "/x/a.swift"}), 510), _result("d", "read_file", 511),
        _call("e", "read_file", json.dumps({"path": "/x/b.swift"}), 520, "Now the Mac build.\nmore"),
        _result("e", "read_file", 521),
        _call("f", "terminal", term("cd ios && xcodebuild -scheme OttoMac build"), 530),
    ]
    out = card_live.activity(msgs)
    now = out["now"]
    assert now["phrase"] == "Building the Mac app" and now["running"] is True and now["since"] == 530
    assert now["wait"] == "long" and now["summary"].startswith("cd ios && xcodebuild")
    # The retried test run counts once, with its latest outcome; reading isn't a milestone.
    assert [(s["phrase"], s["state"]) for s in out["trail"]] == [
        ("Merging", "done"), ("Running tests", "done"), ("Building the Mac app", "running")]
    assert out["said"]["text"] == "Now the Mac build."
    assert out["last_activity_at"] == 530


def test_activity_groups_same_kind_for_the_timer_and_keeps_last_five():
    msgs = []
    t = 0
    for i, cmd in enumerate(["git merge x", "pytest", "xcodebuild -scheme OttoMac build", "git push origin x",
                             "scripts/land_card.sh t_1", "scripts/otto_release.sh --mac"]):
        msgs += [_call(f"m{i}", "terminal", term(cmd), t), _result(f"m{i}", "terminal", t + 1)]
        t += 10
    msgs += [_call("p1", "patch", json.dumps({"path": "/a/One.swift"}), 100), _result("p1", "patch", 101),
             _call("p2", "patch", json.dumps({"path": "/a/Two.swift"}), 140)]
    out = card_live.activity(msgs)
    assert out["now"]["phrase"] == "Editing Two.swift" and out["now"]["since"] == 100  # edits group across files
    assert len(out["trail"]) == card_live.TRAIL_LEN and out["trail"][0]["phrase"] == "Running tests"
    assert card_live.activity([])["now"] is None


def _state_db(path: Path, sessions, messages=()):
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, title TEXT, started_at REAL, "
              "parent_session_id TEXT)")
    c.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, "
              "tool_calls TEXT, tool_call_id TEXT, timestamp REAL, reasoning TEXT, active INTEGER DEFAULT 1)")
    c.executemany("INSERT INTO sessions VALUES (?,?,?,?,?)", sessions)
    for m in messages:
        c.execute("INSERT INTO messages (session_id, role, content, tool_calls, tool_call_id, timestamp, reasoning) "
                  "VALUES (?,?,?,?,?,?,?)", (m["sid"], m["role"], m.get("content"), m.get("tool_calls"),
                                             m.get("tool_call_id"), m["timestamp"], None))
    c.commit()
    c.close()


def test_find_session_by_title_and_start_and_follows_compression(tmp_path):
    db = tmp_path / "state.db"
    title = "Watch running cards: live 'Now' line + step trail + stall signals; click a card to watch its session live"
    _state_db(db, [
        ("old", "kanban", title[:90] + "…", 500.0, None),                 # an earlier run of the same card
        ("chat", "api", title[:90] + "…", 1001.0, None),                  # not a worker
        ("w1", "kanban", "Some other card", 1002.0, None),
        ("w2", "kanban", title[:90] + "… #2", 1004.0, None),               # this run (titles are unique: #2)
        ("w2b", "kanban", None, 1500.0, "w2"),                             # compressed continuation
        ("sub", "subagent", None, 1600.0, "w2b"),                          # a subagent: not followed
    ])
    conn = card_live._ro(db)
    assert card_live.find_session(conn, title, 1000.0) == "w2b"
    assert card_live.find_session(conn, title, 400.0) == "old"
    assert card_live.find_session(conn, title, 5000.0) is None
    assert card_live.find_session(conn, title, 5000.0, hint="w1") == "w1"   # the recorded id wins
    assert card_live.find_session(conn, title, 1000.0, hint="gone") == "w2b"
    conn.close()


def _kanban_db(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE tasks (id TEXT, title TEXT, status TEXT, current_run_id INTEGER, worker_pid INTEGER)")
    c.execute("CREATE TABLE task_runs (id INTEGER, started_at INTEGER, worker_pid INTEGER, metadata TEXT, "
              "last_heartbeat_at INTEGER)")
    for tid, title, status, run, pid, started in rows:
        c.execute("INSERT INTO tasks VALUES (?,?,?,?,?)", (tid, title, status, run, pid))
        c.execute("INSERT INTO task_runs VALUES (?,?,?,?,?)", (run, started, pid, None, started + 5))
    c.commit()
    c.close()


def test_live_board(tmp_path):
    home = tmp_path
    _kanban_db(home / "kanban" / "boards" / "otto" / "kanban.db", [
        ("t_aaaaaaaa", "Card A", "running", 1, 111, 1000),
        ("t_bbbbbbbb", "Card B", "running", 2, 222, 2000),
        ("t_cccccccc", "Card C", "done", 3, None, 900),
    ])
    db = home / "state.db"
    _state_db(db, [("sa", "kanban", "Card A", 1003.0, None)], [
        {"sid": "sa", "role": "assistant", "content": "Running the suite.",
         "tool_calls": json.dumps([{"id": "x", "function": {"name": "terminal", "arguments": term("pytest -q")}}]),
         "timestamp": 1010.0}])
    out = card_live.live("otto", home=home, state_db=db, now=1100.0, alive=lambda pid: pid == 111)
    assert set(out["cards"]) == {"t_aaaaaaaa", "t_bbbbbbbb"}
    a, b = out["cards"]["t_aaaaaaaa"], out["cards"]["t_bbbbbbbb"]
    assert a["session_id"] == "sa" and a["worker_alive"] is True and a["now"]["phrase"] == "Running tests"
    assert a["now"]["running"] is True and a["last_activity_at"] == 1010.0 and a["said"]["text"] == "Running the suite."
    assert b["session_id"] is None and b["worker_alive"] is False and b["now"] is None
    with pytest.raises(card_live.CardLiveError) as e:
        card_live.live("../etc", home=home, state_db=db)
    assert e.value.status == 400
    with pytest.raises(card_live.CardLiveError) as e:
        card_live.live("nope", home=home, state_db=db)
    assert e.value.status == 404


def test_pid_alive():
    import os
    assert card_live.pid_alive(os.getpid()) is True
    assert card_live.pid_alive(None) is None
    assert card_live.pid_alive(2 ** 22 + 12345) is False


def test_companion_route(monkeypatch):
    c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
    seen = {}
    monkeypatch.setattr(card_live, "live", lambda board: seen.setdefault("board", board) and {"cards": {}})
    assert c.handle("GET", "/kanban-live", {"board": "otto"}, {}) == {"cards": {}}
    assert seen["board"] == "otto"

    def bad(board):
        raise card_live.CardLiveError(400, "bad board")
    monkeypatch.setattr(card_live, "live", bad)
    with pytest.raises(companion.RouteError) as e:
        c.handle("GET", "/kanban-live", {"board": "x/y"}, {})
    assert e.value.status == 400
