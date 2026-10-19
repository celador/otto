"""Is a chat running right now, wherever it was started (desktop, Telegram, cron, another device)?

Hermes agents stamp a durable heartbeat on their session row while a turn runs
(`sessions.last_activity_at` + `last_activity_description`, written at most once a minute and
cleared when the turn ends — agent/activity_tracking.py). Every process that runs agents writes it
(dashboard/desktop, the gateway's API server and messaging platforms, cron, kanban workers), so
reading it from state.db is the one cross-process "is this chat busy" signal.

A crashed agent never clears its label, so a stamp counts only while it's recent.
Read-only; stdlib only.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import time
from pathlib import Path

STATE_DB = Path(os.environ.get("HERMES_STATE_DB", Path.home() / ".hermes" / "state.db"))
# Heartbeats land at most every 60 s (SESSION_ACTIVITY_HEARTBEAT_MIN_INTERVAL_SECONDS) and carry the
# time of the last activity, which can itself be a minute old during a long tool call.
FRESH_SECONDS = 240.0
IDLE_LABELS = ("", "context compression completed")


def _connect(db: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1.0)
    conn.row_factory = sqlite3.Row
    return conn


def describe(desc: str | None) -> dict:
    """Turn a heartbeat description into {kind, tool} for the app's status line.

    kind: thinking | tool | subagents | compressing | working."""
    d = (desc or "").strip()
    low = d.lower()
    if low.startswith("delegate_task"):
        return {"kind": "subagents", "tool": "delegate_task"}
    if "compression" in low:
        return {"kind": "compressing", "tool": None}
    if low.startswith("terminal command running"):
        return {"kind": "tool", "tool": "terminal"}
    m = re.match(r"(?:executing tool|sequential tool running \(\d+s\)|tool completed): ([A-Za-z0-9_.:-]+)", d)
    if m:
        kind = "working" if low.startswith("tool completed") else "tool"
        return {"kind": kind, "tool": m.group(1) if kind == "tool" else None}
    m = re.match(r"executing \d+ tools concurrently: ([A-Za-z0-9_.:, -]+)", d)
    if m:
        return {"kind": "tool", "tool": m.group(1).split(",")[0].strip() or None}
    if "stream" in low or "provider response" in low or "api call" in low or "api response" in low:
        return {"kind": "thinking", "tool": None}
    return {"kind": "working", "tool": None}


def _row_running(row: sqlite3.Row, now: float) -> bool:
    desc = (row["last_activity_description"] or "").strip()
    at = row["last_activity_at"]
    return desc.lower() not in IDLE_LABELS and isinstance(at, (int, float)) and now - float(at) < FRESH_SECONDS


def _pending_tool(conn: sqlite3.Connection, session_id: str) -> tuple[str | None, str | None]:
    """The newest tool call without a result yet, as (name, preview), from the stored transcript."""
    rows = conn.execute(
        "SELECT role, tool_calls, tool_call_id FROM messages WHERE session_id = ? "
        "ORDER BY id DESC LIMIT 12", (session_id,)).fetchall()
    answered = set()
    for r in rows:
        if r["role"] == "tool" and r["tool_call_id"]:
            answered.add(r["tool_call_id"])
            continue
        if r["role"] == "assistant" and r["tool_calls"]:
            try:
                calls = json.loads(r["tool_calls"]) or []
            except (ValueError, TypeError):
                return None, None
            for c in calls:
                cid = c.get("id") or c.get("call_id")
                if cid in answered:
                    continue
                fn = c.get("function") or {}
                return fn.get("name"), preview(fn.get("arguments"))
            return None, None
        if r["role"] in ("user", "assistant"):
            return None, None
    return None, None


def preview(arguments) -> str | None:
    """The one argument worth showing: a command, query, path or URL."""
    try:
        args = json.loads(arguments) if isinstance(arguments, str) else (arguments or {})
    except ValueError:
        return None
    if not isinstance(args, dict):
        return None
    for k in ("command", "query", "path", "url", "goal", "code", "pattern", "name"):
        v = args.get(k)
        if isinstance(v, str) and v.strip():
            return " ".join(v.split())[:160]
    return None


def session_run(session_id: str, now: float | None = None, db: Path | None = None) -> dict:
    """{running, kind, tool, preview, started_at, activity_at} for one stored chat."""
    now = time.time() if now is None else now
    out = {"running": False, "kind": None, "tool": None, "preview": None, "started_at": None, "activity_at": None}
    try:
        conn = _connect(db or STATE_DB)
    except sqlite3.Error:
        return out
    try:
        row = conn.execute("SELECT last_activity_at, last_activity_description FROM sessions WHERE id = ?",
                           (session_id,)).fetchone()
        if not row or not _row_running(row, now):
            return out
        info = describe(row["last_activity_description"])
        started = conn.execute("SELECT MAX(timestamp) FROM messages WHERE session_id = ? AND role = 'user'",
                               (session_id,)).fetchone()[0]
        tool, pv = _pending_tool(conn, session_id)
        if tool:
            info = {"kind": "subagents" if tool == "delegate_task" else "tool", "tool": tool}
        out.update(running=True, kind=info["kind"], tool=info["tool"], preview=pv if tool else None,
                   activity_at=float(row["last_activity_at"]),
                   started_at=float(started) if isinstance(started, (int, float)) else None)
        return out
    except sqlite3.Error:
        return out
    finally:
        conn.close()


def running_sessions(now: float | None = None, db: Path | None = None, limit: int = 200) -> list[dict]:
    """Every chat with a fresh heartbeat: [{id, kind, activity_at}] (sidebar dots)."""
    now = time.time() if now is None else now
    try:
        conn = _connect(db or STATE_DB)
    except sqlite3.Error:
        return []
    try:
        rows = conn.execute(
            "SELECT id, source, last_activity_at, last_activity_description FROM sessions "
            "WHERE last_activity_at > ? AND COALESCE(last_activity_description, '') != '' "
            "ORDER BY last_activity_at DESC LIMIT ?", (now - FRESH_SECONDS, limit)).fetchall()
        return [{"id": r["id"], "source": r["source"], "kind": describe(r["last_activity_description"])["kind"],
                 "activity_at": float(r["last_activity_at"])}
                for r in rows if _row_running(r, now)]
    except sqlite3.Error:
        return []
    finally:
        conn.close()
