"""What is each running kanban card doing right now? (`GET /hermes/kanban-live?board=<slug>`)

Every kanban worker run is an ordinary Hermes session (source `kanban`, titled after the card), and
its transcript lands in state.db as it goes: the assistant row carrying a tool call is written before
the tool runs, its result row when it finishes. So for each running card this module:

1. links the card's current run to its worker session: `task_runs.metadata.worker_session_id` when
   Hermes recorded it (finished runs), else the `kanban` session whose title is the card title and
   that started with the run (a session that was compressed mid-run continues in a child session
   with `parent_session_id`; we follow it to the newest one);
2. reads that session's newest messages into a "Now" step (current tool call in plain words, how long
   the worker has been on it), a short trail of milestone steps (tests, builds, merges, installs,
   uploads), the last thing the agent said, and when it last produced anything (tool call, result or
   text; a worker heartbeat is not activity);
3. says whether the worker process is still alive (pid probe on this Mac).

Read-only, stdlib only. The app decides what to flag (stall thresholds live in Swift with the UI).
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sqlite3
import time
from pathlib import Path
from typing import Callable

HERMES_HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
STATE_DB = Path(os.environ.get("HERMES_STATE_DB", HERMES_HOME / "state.db"))
BOARD_SLUG = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
MESSAGE_WINDOW = 160  # newest messages read per session (a step trail needs a few dozen tool calls)
TRAIL_LEN = 5


class CardLiveError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status, self.detail = status, detail


def kanban_db_path(board: str, home: Path | None = None) -> Path:
    home = home or HERMES_HOME
    if board == "default":
        return home / "kanban.db"
    return home / "kanban" / "boards" / board / "kanban.db"


def _ro(db: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1.0)
    conn.row_factory = sqlite3.Row
    return conn


# MARK: - Tool call -> plain words

# (pattern on the lowercased command, phrase, wait kind, milestone). First match wins.
# wait kind: "apple" / "network" / "wait" = expected waiting (the app shows it grey, never as a stall);
# "long" = a step that legitimately runs for many minutes without new output (builds, tests).
_COMMANDS: list[tuple[re.Pattern[str], str, str | None, bool]] = [
    (re.compile(r"otto_release\.sh|release_mac\.sh|(^|[/ ])release\.sh"), "Releasing a build", "long", True),
    (re.compile(r"land_card\.sh"), "Landing on trunk", None, True),
    (re.compile(r"xcodebuild\b[^|;&]*\b(test|test-without-building)\b"), "Running tests", "long", True),
    (re.compile(r"xcodebuild\b[^|;&]*-exportarchive"), "Exporting the build", "long", True),
    (re.compile(r"xcodebuild\b[^|;&]*\barchive\b"), "Building an archive", "long", True),
    (re.compile(r"xcodebuild\b"), "Building", "long", True),
    (re.compile(r"\bswift (build|test)\b"), "Building", "long", True),
    (re.compile(r"altool\b[^|;&]*--upload|asc_testflight|--upload-app"), "Uploading to TestFlight", "apple", True),
    (re.compile(r"notarytool\b|altool\b"), "Uploading to Apple", "apple", True),
    (re.compile(r"asc_status|asc_release|asc\.py|appstoreconnect|/v1/builds"), "Waiting for Apple", "apple", False),
    (re.compile(r"\bpytest\b|python3? -m pytest|\bnpm (run )?test\b|\bpnpm test\b|\bcargo test\b|\bgo test\b|test_release_guard"),
     "Running tests", "long", True),
    (re.compile(r"\bgit (merge|rebase)\b"), "Merging", None, True),
    (re.compile(r"\bgit push\b"), "Pushing", "network", True),
    (re.compile(r"\bgit commit\b"), "Committing", None, True),
    (re.compile(r"\bxcodegen\b"), "Generating the project", None, False),
    (re.compile(r"install_mac\.sh|install_ios_device\.sh|devicectl\b[^|;&]*install|simctl install"), "Installing", "long", True),
    (re.compile(r"screencapture|simctl io\b[^|;&]*screenshot|-hermes\.shot"), "Taking screenshots", None, True),
    (re.compile(r"launchctl kickstart|kickstart -k"), "Restarting the relay", None, False),
    (re.compile(r"\bcurl\b|\bwget\b"), "Calling a server", "network", False),
    (re.compile(r"^\s*(sleep|wait)\b|\buntil\b.*\bsleep\b|\bwhile\b.*\bsleep\b"), "Waiting", "wait", False),
]
# A segment that only reads (cat/sed -n/grep… a file that merely *names* land_card.sh is not a landing).
_READER = re.compile(r"^\s*(grep|rg|sed|awk|cat|head|tail|ls|find|wc|less|file|stat|du|tree|diff|jq|"
                     r"git (log|show|diff|status|branch|rev-parse|worktree list|ls-files|blame))\b")
_SKIP = re.compile(r"^\s*(cd|echo|printf|export|set|true|date|mkdir|pwd|source|\.)\b|^\s*$")
_SCRIPT_WORDS = {"python", "python3", "uv", "node", "ruby", "swift", "perl", "bun", "npx", "deno"}


def _segments(cmd: str) -> list[str]:
    return [s for s in re.split(r"&&|\|\||;|\n|\|", cmd) if s.strip()]

_TOOLS: dict[str, tuple[str, str | None, bool]] = {
    "read_file": ("Reading code", None, False),
    "search_files": ("Reading code", None, False),
    "patch": ("Editing code", None, False),
    "write_file": ("Editing code", None, False),
    "skill_view": ("Reading a skill", None, False),
    "skills_list": ("Reading a skill", None, False),
    "web_search": ("Searching the web", "network", False),
    "web_extract": ("Reading the web", "network", False),
    "browser_exec": ("Using the browser", "network", False),
    "vision_analyze": ("Checking a screenshot", None, False),
    "delegate_task": ("Running subagents", "long", True),
    "execute_code": ("Running a script", None, False),
    "kanban_comment": ("Updating the card", None, False),
    "kanban_heartbeat": ("Updating the card", None, False),
    "kanban_show": ("Reading the card", None, False),
    "kanban_create": ("Creating cards", None, True),
    "kanban_complete": ("Finishing up", None, True),
    "kanban_request_review": ("Asking for review", None, True),
    "kanban_block": ("Blocking the card", None, True),
    "todo_list": ("Planning", None, False),
    "clarify": ("Asking a question", "wait", False),
    "text_to_speech": ("Making audio", None, False),
}


def _args(arguments) -> dict:
    try:
        a = json.loads(arguments) if isinstance(arguments, str) else (arguments or {})
    except ValueError:
        return {}
    return a if isinstance(a, dict) else {}


def _first_word(command: str) -> str:
    cmd = command.strip()
    # Skip leading `cd X &&` / env assignments so "cd repo && make" reads as make.
    cmd = re.sub(r"^(cd\s+\S+\s*(&&|;)\s*)+", "", cmd)
    try:
        words = shlex.split(cmd)
    except ValueError:
        words = cmd.split()
    words = [w for w in words if not re.fullmatch(r"[A-Z_][A-Z0-9_]*=.*", w)]
    for w in words:
        if w in ("env", "-u", "sudo", "time", "nohup", "perl", "-e", "exec", "bash", "-c", "sh", "zsh"):
            continue
        if w.startswith("alarm"):
            continue
        return Path(w).name[:40]
    return ""


def summarize(name: str | None, arguments) -> str | None:
    """One line of what the call is about: a command, path, query or URL."""
    a = _args(arguments)
    if name == "patch" or name == "write_file" or name == "read_file":
        p = a.get("path")
        return Path(p).name if isinstance(p, str) and p else None
    if name == "process_manage":
        return " ".join(str(a.get(k)) for k in ("action", "session_id") if a.get(k)) or None
    for k in ("command", "query", "pattern", "url", "goal", "path", "name", "code", "body"):
        v = a.get(k)
        if isinstance(v, str) and v.strip():
            return " ".join(v.split())[:140]
    return None


def classify(name: str | None, arguments) -> dict:
    """{phrase, wait, milestone} for one tool call."""
    name = name or ""
    a = _args(arguments)
    if name == "terminal":
        cmd = str(a.get("command") or "")
        low = cmd.lower()
        # Quoted text is data (a python -c body, a commit message, a grep pattern), not the step, unless the
        # quotes are a shell's own script (`bash -c "xcodebuild test"`).
        if not re.match(r"^\s*(bash|sh|zsh)\s+-l?c\b", low):
            low = re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "''", low)
        readers, other = 0, None
        for seg in _segments(low):
            seg = " ".join(seg.split())
            if _SKIP.match(seg):
                continue
            if _READER.match(seg):
                readers += 1
                continue
            for rx, phrase, wait, milestone in _COMMANDS:
                if rx.search(seg):
                    if phrase == "Building" and re.search(r"-scheme ottomac|platform=macos", seg):
                        phrase = "Building the Mac app"
                    elif phrase == "Building" and re.search(r"iphoneos|platform=ios|-scheme hermes\b", seg):
                        phrase = "Building the iPhone app"
                    return {"phrase": phrase, "wait": wait, "milestone": milestone}
            other = other or seg
        if re.search(r"\b(until|while)\b.*\bsleep\b", " ".join(low.split())):
            return {"phrase": "Waiting", "wait": "wait", "milestone": False}
        if a.get("background"):
            return {"phrase": "Starting a background job", "wait": None, "milestone": False}
        if other is None:
            return {"phrase": "Reading code" if readers else "Running a command", "wait": None, "milestone": False}
        word = _first_word(other)
        if word == "sqlite3":
            return {"phrase": "Reading the database", "wait": None, "milestone": False}
        if word in _SCRIPT_WORDS:
            return {"phrase": "Running a script", "wait": None, "milestone": False}
        return {"phrase": f"Running {word}" if word else "Running a command", "wait": None, "milestone": False}
    if name == "process_manage":
        action = str(a.get("action") or "")
        if action in ("wait", "poll"):
            return {"phrase": "Waiting for a background job", "wait": "wait", "milestone": False}
        return {"phrase": "Checking a background job", "wait": None, "milestone": False}
    if name in _TOOLS:
        phrase, wait, milestone = _TOOLS[name]
        if name in ("patch", "write_file"):
            target = summarize(name, arguments)
            if target:
                phrase = f"Editing {target}"
        return {"phrase": phrase, "wait": wait, "milestone": milestone}
    if name.startswith("kanban_"):
        return {"phrase": "Updating the card", "wait": None, "milestone": False}
    if name.startswith("mcp__") or "__" in name:
        return {"phrase": "Using " + name.split("__")[-1].replace("_", " "), "wait": None, "milestone": False}
    return {"phrase": name.replace("_", " ").capitalize() if name else "Working", "wait": None, "milestone": False}


def _failed(result: str | None) -> bool:
    if not result:
        return False
    try:
        data = json.loads(result)
    except ValueError:
        return False
    if not isinstance(data, dict):
        return False
    code = data.get("exit_code")
    return (isinstance(code, int) and code != 0) or data.get("ok") is False or data.get("success") is False


def _group_key(phrase: str) -> str:
    # Consecutive edits to different files are one "Editing code" step for the timer and the trail.
    return "Editing code" if phrase.startswith("Editing ") else phrase


def activity(messages: list[dict]) -> dict:
    """From a session's newest messages (oldest first): the Now step, the trail, the last words."""
    calls: list[dict] = []
    results: dict[str, dict] = {}
    last_text = None
    last_at = None
    for m in messages:
        ts = m.get("timestamp")
        if isinstance(ts, (int, float)):
            last_at = max(last_at or 0.0, float(ts))
        role = m.get("role")
        if role == "tool" and m.get("tool_call_id"):
            results[m["tool_call_id"]] = {"at": ts, "failed": _failed(m.get("content"))}
        elif role == "assistant":
            text = (m.get("content") or "").strip() or (m.get("reasoning") or "").strip()
            if text:
                line = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
                if line:
                    last_text = {"text": line[:200], "at": ts}
            raw = m.get("tool_calls")
            if raw:
                try:
                    parsed = json.loads(raw) if isinstance(raw, str) else raw
                except ValueError:
                    parsed = []
                for c in parsed or []:
                    fn = c.get("function") or {}
                    calls.append({"id": c.get("id") or c.get("call_id"), "name": fn.get("name"),
                                  "args": fn.get("arguments"), "at": ts})
    steps = []
    for c in calls:
        info = classify(c["name"], c["args"])
        res = results.get(c["id"] or "")
        steps.append({**info, "tool": c["name"], "summary": summarize(c["name"], c["args"]), "started_at": c["at"],
                      "running": res is None, "failed": bool(res and res["failed"]),
                      "ended_at": res["at"] if res else None})
    now_step = None
    if steps:
        cur = steps[-1]
        # How long it's been on this step: back to the first call of the run of same-kind calls.
        since = cur["started_at"]
        for s in reversed(steps[:-1]):
            if _group_key(s["phrase"]) != _group_key(cur["phrase"]):
                break
            since = s["started_at"]
        now_step = {"phrase": cur["phrase"], "tool": cur["tool"], "summary": cur["summary"], "wait": cur["wait"],
                    "running": cur["running"], "since": since, "started_at": cur["started_at"]}
    trail: list[dict] = []
    for s in steps:
        if not s["milestone"]:
            continue
        key = _group_key(s["phrase"])
        state = "running" if s["running"] else ("failed" if s["failed"] else "done")
        if trail and trail[-1]["phrase"] == key:
            trail[-1]["state"] = state  # a retried build/test counts once, with its latest outcome
            trail[-1]["at"] = s["started_at"]
        else:
            trail.append({"phrase": key, "state": state, "at": s["started_at"]})
    return {"now": now_step, "trail": trail[-TRAIL_LEN:], "said": last_text, "last_activity_at": last_at,
            "tool_calls": len(calls)}


# MARK: - Card -> worker session

def _norm_title(t: str) -> str:
    t = re.sub(r" #\d+$", "", t.strip())
    return t.rstrip("…").rstrip(".").strip()


def find_session(conn: sqlite3.Connection, title: str, run_started: float | None,
                 hint: str | None = None) -> str | None:
    """The worker session for a run: the recorded id if there is one, else title + start time."""
    sid = None
    if hint:
        row = conn.execute("SELECT id FROM sessions WHERE id = ?", (hint,)).fetchone()
        sid = row["id"] if row else None
    if sid is None and run_started:
        rows = conn.execute(
            "SELECT id, title, started_at FROM sessions WHERE source = 'kanban' AND started_at BETWEEN ? AND ? "
            "ORDER BY started_at", (run_started - 30, run_started + 600)).fetchall()
        want = " ".join(title.split())
        for r in rows:
            t = _norm_title(" ".join((r["title"] or "").split()))
            if t and want.startswith(t):
                sid = r["id"]
                break
    if sid is None:
        return None
    # Compression continues a session in a child: follow it to the newest one.
    for _ in range(20):
        row = conn.execute("SELECT id FROM sessions WHERE parent_session_id = ? AND source = 'kanban' "
                           "ORDER BY started_at DESC LIMIT 1", (sid,)).fetchone()
        if not row:
            break
        sid = row["id"]
    return sid


def _messages(conn: sqlite3.Connection, sid: str) -> list[dict]:
    rows = conn.execute(
        "SELECT role, content, tool_calls, tool_call_id, timestamp, reasoning FROM messages "
        "WHERE session_id = ? AND COALESCE(active, 1) = 1 ORDER BY id DESC LIMIT ?", (sid, MESSAGE_WINDOW)).fetchall()
    out = []
    for r in reversed(rows):
        content = r["content"]
        out.append({"role": r["role"], "content": content if r["role"] != "tool" else (content or "")[:4000],
                    "tool_calls": r["tool_calls"], "tool_call_id": r["tool_call_id"], "timestamp": r["timestamp"],
                    "reasoning": r["reasoning"]})
    return out


def pid_alive(pid) -> bool | None:
    if not isinstance(pid, int) or pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return None
    return True


def live(board: str | None, *, home: Path | None = None, state_db: Path | None = None,
         now: float | None = None, alive: Callable[[object], bool | None] = pid_alive) -> dict:
    board = (board or "default").strip().lower()
    if not BOARD_SLUG.fullmatch(board):
        raise CardLiveError(400, "bad board")
    now = time.time() if now is None else now
    kdb = kanban_db_path(board, home)
    if not kdb.exists():
        raise CardLiveError(404, "no such board")
    try:
        kc = _ro(kdb)
    except sqlite3.Error as e:
        raise CardLiveError(503, f"board unreadable: {e}") from None
    try:
        tasks = kc.execute(
            "SELECT t.id, t.title, t.current_run_id, t.worker_pid AS task_pid, r.started_at AS run_started, "
            "r.worker_pid AS run_pid, r.metadata AS metadata, r.last_heartbeat_at AS beat "
            "FROM tasks t LEFT JOIN task_runs r ON r.id = t.current_run_id WHERE t.status = 'running'").fetchall()
    except sqlite3.Error as e:
        raise CardLiveError(503, f"board unreadable: {e}") from None
    finally:
        kc.close()
    cards: dict[str, dict] = {}
    try:
        sc = _ro(state_db or STATE_DB)
    except sqlite3.Error:
        sc = None
    try:
        for t in tasks:
            hint = None
            try:
                hint = (json.loads(t["metadata"] or "{}") or {}).get("worker_session_id")
            except (ValueError, AttributeError):
                hint = None
            pid = t["run_pid"] or t["task_pid"]
            card = {"run_id": t["current_run_id"], "run_started_at": t["run_started"], "heartbeat_at": t["beat"],
                    "worker_alive": alive(pid), "session_id": None, "now": None, "trail": [], "said": None,
                    "last_activity_at": None}
            if sc is not None:
                try:
                    sid = find_session(sc, t["title"] or "", t["run_started"], hint if isinstance(hint, str) else None)
                    if sid:
                        card["session_id"] = sid
                        card.update({k: v for k, v in activity(_messages(sc, sid)).items() if k != "tool_calls"})
                except sqlite3.Error:
                    pass
            cards[t["id"]] = card
    finally:
        if sc is not None:
            sc.close()
    return {"board": board, "now": now, "cards": cards}
