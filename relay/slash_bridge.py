"""Slash commands for the Hermes iOS app, run the way the desktop app runs them.

Run with the Hermes venv python (needs `websockets` and `hermes_cli`). Reads one JSON request on stdin,
prints one JSON reply on stdout:

  {"op": "catalog"}
      -> {"commands": [{"name", "description", "args", "category", "kind"}...]}
         The same list the Telegram bot registers (hermes_cli.commands_platforms.telegram_menu_commands),
         so the phone offers exactly what Telegram offers.

  {"op": "activity", "session_id": "<stored id>"}
      -> {"live": bool, "subagents": [...], "processes": [...]}   (the desktop's Subagents / Background tray)
  {"op": "subagent_tail"|"subagent_steer"|"subagent_stop", "session_id", "subagent_id"[, "text"]}
  {"op": "process_tail"|"process_kill", "session_id", "process_id"}
  {"op": "session_interrupt", "session_id"}   (Stop for a chat running in the desktop/dashboard)
      Read-only listing uses delegation.status + session.active_list (+ process.list for the chat's live
      runtime). Controls attach to the live chat with session.activate (alongside the desktop, never
      session.close: that would end the desktop's chat) because subagent RPCs need an attached transport.

  {"op": "exec", "session_id": "<stored id>", "command": "/compress here 2"}
      -> {"kind": "output"|"send"|"prefill"|"open_session", "text", "message", "notice", "session_id"}

Exec talks JSON-RPC to the local dashboard's /api/ws (the desktop's transport): session.resume the stored
chat, then slash.exec / command.dispatch (or prompt.btw / session.branch, which the desktop also calls
directly), then session.close. Chats on the API server read their history from the session DB on every
run, so transcript edits made here (compress, undo, title) apply to the phone's next message.
The dashboard token comes from the environment (HERMES_DASHBOARD_SESSION_TOKEN) and never leaves the Mac.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import time

DASHBOARD_WS = os.environ.get("HERMES_DASHBOARD_WS", "ws://127.0.0.1:9119/api/ws")
DEADLINE_SECONDS = float(os.environ.get("SLASH_DEADLINE", "170"))
EAGER = {"usage", "rollback", "status"}
NOISE = {"gateway.ready", "sessions.changed", "platforms.changed"}


def catalog() -> dict:
    sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
    import logging
    logging.disable(logging.WARNING)  # skill/command collision notices go to stderr otherwise
    from hermes_cli.commands import COMMAND_REGISTRY
    from hermes_cli.commands_platforms import telegram_menu_commands
    registry = {}
    for c in COMMAND_REGISTRY:
        for n in (c.name, *c.aliases):
            registry.setdefault(n.replace("-", "_"), c)
    menu, _hidden = telegram_menu_commands()
    out = []
    for name, desc in menu:
        c = registry.get(name)
        out.append({"name": name, "description": c.describe() if c else desc,
                    "args": c.args_hint if c else "",
                    "category": c.category if c else "Skills",
                    "kind": "builtin" if c else "skill",
                    "invoke": c.name if c else name})
    return {"commands": out}


class Rpc:
    def __init__(self, ws):
        self.ws, self.n, self.events = ws, 0, []

    async def call(self, method: str, params: dict, timeout: float) -> dict:
        self.n += 1
        rid = self.n
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        end = time.monotonic() + timeout
        while True:
            frame = json.loads(await asyncio.wait_for(self.ws.recv(), max(0.1, end - time.monotonic())))
            if frame.get("id") == rid:
                return frame
            ev = frame.get("params") or {}
            if ev.get("type") not in NOISE:
                self.events.append(ev)

    async def wait_event(self, etype: str, task_id: str | None, timeout: float) -> dict | None:
        end = time.monotonic() + timeout
        while True:
            for ev in self.events:
                p = ev.get("payload") or {}
                if ev.get("type") == etype and (task_id is None or p.get("task_id") == task_id):
                    return p
            self.events.clear()
            if time.monotonic() >= end:
                return None
            frame = json.loads(await asyncio.wait_for(self.ws.recv(), max(0.1, end - time.monotonic())))
            ev = frame.get("params") or {}
            if ev.get("type") not in NOISE:
                self.events.append(ev)


def _compress_text(res: dict) -> str:
    summary = res.get("summary") or {}
    lines = [summary.get("headline"), summary.get("token_line"), summary.get("note")]
    text = "\n".join(line for line in lines if line)
    if text:
        return text
    if res.get("status") == "compressed" and res.get("before_messages") is not None:
        return f"Compressed: {res['before_messages']} → {res.get('after_messages')} messages"
    return res.get("message") or "Nothing to compress yet."


def _reopen(session_id: str) -> None:
    """session.close stamps the stored chat ended ("tui_close"); the phone keeps using it, so undo that."""
    if not session_id:
        return
    try:
        sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
        from hermes_state import SessionDB
        db = SessionDB()
        row = db.get_session(session_id) or {}
        if row.get("end_reason") == "tui_close":
            db.reopen_session(session_id)
    except Exception:
        pass


def _err_text(frame: dict) -> str:
    e = frame.get("error") or {}
    return str(e.get("message") or "Command failed.")


def _from_directive(r: dict) -> dict:
    t = r.get("type")
    if t in ("send", "skill"):
        return {"kind": "send", "message": r.get("message") or "", "notice": r.get("notice")}
    if t == "prefill":
        return {"kind": "prefill", "message": r.get("message") or "", "notice": r.get("notice")}
    text = r.get("output") or r.get("notice") or "(no output)"
    if r.get("warning"):
        text += f"\n\n{r['warning']}"
    return {"kind": "output", "text": text}


async def run_exec(session_id: str, command: str) -> dict:
    import websockets
    token = os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN", "")
    if not token:
        return {"kind": "error", "text": "Dashboard token missing on the Mac."}
    name, _, arg = command.strip().lstrip("/").partition(" ")
    name, arg = name.lower().replace("-", "_"), arg.strip()
    eager = name in EAGER  # these read the live agent (token counters, checkpoints), not just the DB
    deadline = time.monotonic() + DEADLINE_SECONDS
    left = lambda: max(5.0, deadline - time.monotonic())  # noqa: E731
    async with websockets.connect(f"{DASHBOARD_WS}?token={token}", max_size=2 ** 24,
                                  origin="http://127.0.0.1:9119", open_timeout=15) as ws:
        rpc = Rpc(ws)
        if session_id:
            r = await rpc.call("session.resume", {"session_id": session_id, "omit_messages": True, "lazy": not eager,
                                                  "eager_build": eager, "inline_images": False}, 60)
        else:  # a chat the phone hasn't sent anything in yet: global commands still work
            r = await rpc.call("session.create", {}, 60)
        if "error" in r:
            return {"kind": "error", "text": _err_text(r)}
        live = r["result"]["session_id"]
        try:
            if name == "btw":
                if not arg:
                    return {"kind": "output", "text": "Usage: /btw <question>"}
                r = await rpc.call("prompt.btw", {"session_id": live, "text": arg}, 30)
                if "error" in r:
                    return {"kind": "error", "text": _err_text(r)}
                done = await rpc.wait_event("btw.complete", (r.get("result") or {}).get("task_id"), left())
                return {"kind": "output", "text": (done or {}).get("text") or "The side question is still running."}
            if name == "branch":
                here = "--here" in arg.split()
                title = " ".join(w for w in arg.split() if w != "--here") or None
                r = await rpc.call("session.branch", {"session_id": live, **({"name": title} if title else {})}, left())
                if "error" in r:
                    return {"kind": "error", "text": _err_text(r)}
                res = r["result"]
                return {"kind": "open_session", "session_id": res.get("stored_session_id"),
                        "text": f"Branched into “{res.get('title') or 'new chat'}”"
                                + ("" if here else f" ({res.get('message_count', 0)} messages).")}
            if name in ("compress", "compact") and session_id and not any(
                    f in arg.split() for f in ("--preview", "--dry-run", "here")):
                # The desktop's own path: the slash worker answers "(no output)" for long chats.
                r = await rpc.call("session.compress", {"session_id": live, **({"focus_topic": arg} if arg else {})}, left())
                if "error" in r:
                    return {"kind": "error", "text": _err_text(r)}
                return {"kind": "output", "text": _compress_text(r.get("result") or {})}
            r = await rpc.call("slash.exec", {"session_id": live, "command": command.strip()}, left())
            if "error" in r and (r["error"] or {}).get("code") == 4018:
                r = await rpc.call("command.dispatch", {"name": name, "arg": arg, "session_id": live}, left())
            if "error" in r:
                return {"kind": "error", "text": _err_text(r)}
            reply = _from_directive(r.get("result") or {})
            # Compression can move the chat to a continuation session; tell the phone which id is live now.
            t = await rpc.call("session.title", {"session_id": live}, 20)
            current = (t.get("result") or {}).get("session_key")
            if session_id and current and current != session_id:
                reply["session_id"] = current
            return reply
        finally:
            try:
                await rpc.call("session.close", {"session_id": live}, 10)
            except Exception:
                pass
            _reopen(session_id)


# --- Subagents / Background tray (what the desktop shows above its composer) ---------------------

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


SUBAGENT_FIELDS = ("subagent_id", "parent_id", "depth", "goal", "model", "started_at", "status", "tool_count", "last_tool")
PROCESS_FIELDS = ("session_id", "command", "cwd", "pid", "started_at", "uptime_seconds", "status", "exit_code")


async def _connect():
    import websockets
    token = os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN", "")
    if not token:
        raise RuntimeError("Dashboard token missing on the Mac.")
    return await websockets.connect(f"{DASHBOARD_WS}?token={token}", max_size=2 ** 24,
                                    origin="http://127.0.0.1:9119", open_timeout=10)


async def _live_row(rpc: Rpc, stored: str) -> dict | None:
    """The dashboard's live row (id, status working|waiting|starting|idle) for a stored chat that is
    open (desktop or a pop-out), else None."""
    r = await rpc.call("session.active_list", {}, 15)
    for row in (r.get("result") or {}).get("sessions") or []:
        if row.get("session_key") == stored and row.get("id"):
            return row
    return None


async def _live_id(rpc: Rpc, stored: str) -> str | None:
    row = await _live_row(rpc, stored)
    return str(row["id"]) if row else None


def _result(frame: dict) -> dict:
    if "error" in frame:
        raise RuntimeError(_err_text(frame))
    return frame.get("result") or {}


async def run_activity(stored: str) -> dict:
    now = time.time()
    async with await _connect() as ws:
        rpc = Rpc(ws)
        active = _result(await rpc.call("delegation.status", {}, 15)).get("active") or []
        subs = []
        for r in active:
            if r.get("owner_agent_session_id") != stored:
                continue
            row = {k: r.get(k) for k in SUBAGENT_FIELDS}
            started = r.get("started_at")
            row["elapsed_s"] = int(now - float(started)) if isinstance(started, (int, float)) else None
            row["current_tool"] = r.get("last_tool")
            row["id"] = r.get("subagent_id")
            subs.append(row)
        live_row = await _live_row(rpc, stored)
        live = str(live_row["id"]) if live_row else None
        procs = []
        # process.list resolves the chat's agent; only ask when some background process exists at all.
        running = (_result(await rpc.call("agents.list", {}, 15)).get("processes") or [])
        if live and running:
            r = await rpc.call("process.list", {"session_id": live}, 20)
            for p in (r.get("result") or {}).get("processes") or []:
                if p.get("status") != "running":  # finished ones leave the tray, like the desktop
                    continue
                row = {k: p.get(k) for k in PROCESS_FIELDS}
                row["id"] = p.get("session_id")
                procs.append(row)
        return {"live": bool(live), "live_status": (live_row or {}).get("status"), "subagents": subs, "processes": procs}


async def run_control(op: str, stored: str, target: str, text: str = "") -> dict:
    async with await _connect() as ws:
        rpc = Rpc(ws)
        live = await _live_id(rpc, stored)
        if not live:
            return {"error": "That chat isn't open on the Mac right now.", "status": 409}
        if op == "process_tail":
            for p in _result(await rpc.call("process.list", {"session_id": live}, 20)).get("processes") or []:
                if p.get("session_id") == target:
                    return {"id": target, "command": p.get("command"), "status": p.get("status"),
                            "text": ANSI.sub("", p.get("output_tail") or p.get("output_preview") or "")}
            return {"error": "No such process.", "status": 404}
        if op == "session_interrupt":
            _result(await rpc.call("session.interrupt", {"session_id": live}, 30))
            return {"stopped": True}
        if op == "process_kill":
            res = _result(await rpc.call("process.kill", {"session_id": live, "process_id": target}, 30))
            return {"id": target, "status": res.get("status"), "exit_code": res.get("exit_code")}
        # Subagent controls need this socket attached to the chat (alongside the desktop's).
        _result(await rpc.call("session.activate", {"session_id": live, "omit_messages": True}, 30))
        if op == "subagent_tail":
            res = _result(await rpc.call("subagent.tail", {"session_id": live, "subagent_id": target}, 20))
            return {"id": target, "available": bool(res.get("available")), "text": ANSI.sub("", res.get("text") or ""),
                    "truncated": bool(res.get("truncated"))}
        if op == "subagent_steer":
            res = _result(await rpc.call("subagent.steer", {"session_id": live, "subagent_id": target, "text": text}, 20))
            return {"id": target, "status": res.get("status")}
        if op == "subagent_stop":
            res = _result(await rpc.call("subagent.interrupt", {"session_id": live, "subagent_id": target}, 20))
            return {"id": target, "stopped": bool(res.get("found"))}
        return {"error": "unknown op", "status": 400}


# --- Workspaces (Hermes projects): a fixed allowlist of dashboard RPCs ------------------------------

RPC_ALLOWED = {
    "projects.list", "projects.get", "projects.create", "projects.update", "projects.add_folder",
    "projects.set_primary", "projects.archive", "projects.tree", "projects.project_sessions",
    "projects.discover_repos", "session.workspace.move",
}


async def run_rpc(calls: list) -> dict:
    """{"op": "rpc", "calls": [{"method", "params"}...]} -> {"results": [{"result"} | {"error"}...]}.
    One socket for the whole batch; a failed call doesn't stop the next one."""
    out = []
    async with await _connect() as ws:
        rpc = Rpc(ws)
        for c in calls:
            method = str((c or {}).get("method") or "")
            if method not in RPC_ALLOWED:
                out.append({"error": f"method not allowed: {method}"})
                continue
            frame = await rpc.call(method, dict(c.get("params") or {}), 120)
            out.append({"error": _err_text(frame)} if "error" in frame else {"result": frame.get("result")})
    return {"results": out}


def main() -> None:
    try:
        req = json.loads(sys.stdin.read() or "{}")
        if req.get("op") == "rpc":
            out = asyncio.run(run_rpc(list(req.get("calls") or [])))
        elif req.get("op") == "catalog":
            out = catalog()
        elif req.get("op") == "activity":
            out = asyncio.run(run_activity(str(req["session_id"])))
        elif req.get("op") == "session_interrupt":
            out = asyncio.run(run_control("session_interrupt", str(req["session_id"]), ""))
        elif req.get("op") in ("subagent_tail", "subagent_steer", "subagent_stop", "process_tail", "process_kill"):
            out = asyncio.run(run_control(req["op"], str(req["session_id"]), str(req["target"]), str(req.get("text") or "")))
        elif req.get("op") == "exec":
            out = asyncio.run(run_exec(str(req["session_id"]), str(req["command"])))
        else:
            out = {"kind": "error", "text": "unknown op"}
    except asyncio.TimeoutError:
        out = {"kind": "error", "text": "Hermes took too long to answer that command."}
    except Exception as e:  # noqa: BLE001
        out = {"kind": "error", "text": f"Command failed ({type(e).__name__}: {e})"[:300]}
    print(json.dumps(out))


if __name__ == "__main__":
    main()
