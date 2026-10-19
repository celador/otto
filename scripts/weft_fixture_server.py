#!/usr/bin/env python3
"""Local Weft gateway stand-in for developing the Hermes "Changes" feed.

Serves the WCP v0.1 observer + human API (spec §9, ~/github/weft/docs/protocol/wcp-v0.md)
from a scripted scenario: two agents collide on `refreshToken` (squiggle + blocked edit),
negotiate an overload, a third candidate gets a stale-read warning, a human approves, two
changes land, a planted bug auto-reverts, and the human steers the agent. Part of the log
exists at start; the rest is appended live so the feed's live rows and resume can be seen.

    python3 scripts/weft_fixture_server.py --port 8796            # token "dev" (human scope)
    python3 scripts/weft_fixture_server.py --live-interval 3 --preload 14

Endpoints: GET /v1/repos, /v1/repos/{repo}/events[?after|before|tail&limit&include=diff&kind&agent&task&status],
/v1/repos/{repo}/events/{seq}, WS /v1/repos/{repo}/stream?after=, GET /v1/feed[?tail=1|after=cursor],
POST /v1/repos/{repo}/actions. Stdlib only.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import queue
import socket
import struct
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

TASKS = {
    "T-1": "Retry budget for token refresh",
    "T-2": "Retry 401s in the API client",
    "T-7": "Docs: observer API page",
}

EVIDENCE = {
    "I4f2a": {"preview_url": "https://i4f2a.weft-demo.pages.dev", "tests": {"passed": 48, "failed": 0, "total": 48},
              "review": {"verdict": "approve", "summary": "Overload keeps old callers working; retry budget is bounded."},
              "cost_usd": 0.41},
    "I7d3e": {"preview_url": "https://i7d3e.weft-demo.pages.dev", "tests": {"passed": 46, "failed": 2, "total": 48},
              "review": {"verdict": "request_changes", "summary": "Retries without backoff; two session tests fail."},
              "cost_usd": 0.33},
    "I9c01": {"preview_url": "https://i9c01.weft-demo.pages.dev", "tests": {"passed": 48, "failed": 0, "total": 48},
              "review": {"verdict": "approve", "summary": "Small change in fetchWithAuth."}, "cost_usd": 0.18},
    "Ia11b": {"preview_url": "https://ia11b.weft-site.pages.dev", "tests": {"passed": 12, "failed": 0, "total": 12}},
}

AGENTS = {
    "claude-a": ("claude-code", "T-1", "I4f2a", "s1"),
    "codex-b": ("codex", "T-2", "I9c01", "s2"),
    "gemini-c": ("gemini", "T-1", "I7d3e", "s3"),
    "hermes-d": ("hermes", "T-7", "Ia11b", "s4"),
}

DIFF_SIG = """diff --git a/src/auth/session.ts b/src/auth/session.ts
--- a/src/auth/session.ts
+++ b/src/auth/session.ts
@@ -8,9 +8,16 @@ import { http } from "../api/http";
 
-export async function refreshToken(token: string): Promise<Session> {
-  const res = await http.post("/oauth/refresh", { token });
-  return Session.from(res);
+export interface RefreshOpts {
+  retries: number; // retry budget per refresh
+  backoffMs?: number;
+}
+
+export async function refreshToken(token: string, opts: RefreshOpts): Promise<Session> {
+  for (let attempt = 0; attempt <= opts.retries; attempt++) {
+    const res = await http.post("/oauth/refresh", { token });
+    if (res.ok) return Session.from(res);
+    await sleep((opts.backoffMs ?? 200) * 2 ** attempt);
+  }
+  throw new AuthError("refresh budget exhausted");
 }
"""

DIFF_FETCH = """diff --git a/src/api/client.ts b/src/api/client.ts
--- a/src/api/client.ts
+++ b/src/api/client.ts
@@ -36,8 +36,13 @@ export async function fetchWithAuth(req: Request): Promise<Response> {
   const session = await store.current();
-  return fetch(withBearer(req, session.token));
+  const res = await fetch(withBearer(req, session.token));
+  if (res.status !== 401) return res;
+  // one retry with a fresh token
+  const fresh = await refreshToken(session.refresh);
+  await store.save(fresh);
+  return fetch(withBearer(req, fresh.token));
 }
"""

DIFF_FETCH_V2 = """diff --git a/src/api/client.ts b/src/api/client.ts
--- a/src/api/client.ts
+++ b/src/api/client.ts
@@ -36,8 +36,13 @@ export async function fetchWithAuth(req: Request): Promise<Response> {
   const session = await store.current();
-  return fetch(withBearer(req, session.token));
+  const res = await fetch(withBearer(req, session.token));
+  if (res.status !== 401) return res;
+  const fresh = await refreshToken(session.refresh, { retries: 1 });
+  await store.save(fresh);
+  return fetch(withBearer(req, fresh.token)); // replays POST bodies too
 }
"""

DIFF_OVERLOAD = """diff --git a/src/auth/session.ts b/src/auth/session.ts
--- a/src/auth/session.ts
+++ b/src/auth/session.ts
@@ -14,6 +14,11 @@ export interface RefreshOpts {
 
+/** @deprecated pass RefreshOpts; kept so existing callers compile (negotiated with codex-b, #13). */
+export async function refreshToken(token: string): Promise<Session>;
+export async function refreshToken(token: string, opts: RefreshOpts = { retries: 2 }): Promise<Session> {
+  return refreshWithBudget(token, opts);
+}
"""

DIFF_GEMINI = """diff --git a/src/auth/session.ts b/src/auth/session.ts
--- a/src/auth/session.ts
+++ b/src/auth/session.ts
@@ -40,7 +40,10 @@ export class SessionStore {
   async get(): Promise<Session> {
-    return this.cache ?? (this.cache = await refreshToken(this.refresh));
+    for (let i = 0; i < 3; i++) {
+      try { return this.cache ?? (this.cache = await refreshToken(this.refresh)); }
+      catch (e) { if (i === 2) throw e; }
+    }
   }
"""

DIFF_DOCS = """diff --git a/docs/protocol/observer.md b/docs/protocol/observer.md
new file mode 100644
--- /dev/null
+++ b/docs/protocol/observer.md
@@ -0,0 +1,9 @@
+# Watching agents from a phone
+
+Observer tokens read the change log; human tokens can also act.
+
+```http
+GET /v1/repos/weft-demo/events?tail=1&limit=50
+```
+
+Reconnect the stream with `after=<last seq>` and de-duplicate by seq.
"""


def diag(severity, code, file, symbol, message, cause_seq, cause_agent, cause_task=None, suggestion=None, line=41):
    d = {"severity": severity, "code": code, "file": file, "symbol": symbol, "message": message,
         "caused_by_seq": cause_seq, "caused_by_agent": cause_agent,
         "range": {"start": {"line": line, "character": 10}, "end": {"line": line, "character": 22}}}
    if cause_task:
        d["caused_by_task"] = cause_task
    if suggestion:
        d["suggestion"] = suggestion
    return d


def scenario():
    """(repo, draft) in log order. Drafts omit seq/ts/repo; the server stamps them."""
    A, B, C, D = "claude-a", "codex-b", "gemini-c", "hermes-d"
    S = "src/auth/session.ts"
    RT = f"{S}#refreshToken"
    FW = "src/api/client.ts#fetchWithAuth"
    out = []

    def ev(repo, agent, kind, summary, **kw):
        d = {"kind": kind, "summary": summary, "agent_id": agent}
        d.update(kw)
        out.append((repo, d))

    ev("weft-demo", A, "join", "claude-a joined (Claude Code, level 3)", payload={"harness": "claude-code", "level": 3})
    ev("weft-demo", B, "join", "codex-b joined (Codex, level 2)", payload={"harness": "codex", "level": 2})
    ev("weft-demo", C, "join", "gemini-c joined (Gemini CLI, level 2)", payload={"harness": "gemini", "level": 2})
    ev("weft-site", D, "join", "hermes-d joined (Hermes, level 3)", payload={"harness": "hermes", "level": 3})
    ev("weft-demo", A, "intent", "claude-a plans: add a retry budget to token refresh",
       intent="Add a retry budget to token refresh; touch session.ts refreshToken only", reads=[RT], files=[S])
    ev("weft-demo", B, "intent", "codex-b plans: retry 401s once in fetchWithAuth",
       intent="Retry a request once on 401 after refreshing the token", reads=[RT, FW], files=["src/api/client.ts"])
    ev("weft-site", D, "intent", "hermes-d plans: document the observer API",
       intent="Write docs/protocol/observer.md from spec §9", files=["docs/protocol/observer.md"])
    ev("weft-demo", A, "claim", "claude-a firmly claimed refreshToken in src/auth/session.ts",
       writes=[{"key": RT, "kind": "signature"}], payload={"firm": True, "source": "explicit", "ttl_ms": 600000})
    ev("weft-demo", B, "edit", "codex-b changed body of fetchWithAuth in src/api/client.ts — retry 401s once",
       intent="retry 401s once", reads=[RT], writes=[{"key": FW, "kind": "body"}], files=["src/api/client.ts"],
       diff=DIFF_FETCH, tool={"name": "apply_patch", "call_id": "call_7Qx", "harness_event": "PostToolUse"})
    ev("weft-demo", A, "edit", "claude-a changed signature of refreshToken in src/auth/session.ts — add a retry budget",
       intent="add a retry budget to token refresh", reads=[f"{S}#RefreshOpts"],
       writes=[{"key": RT, "kind": "signature"}, {"key": f"{S}#RefreshOpts", "kind": "new"}], files=[S],
       diff=DIFF_SIG, tool={"name": "Edit", "call_id": "toolu_01", "harness_event": "PostToolUse"},
       transcript={"uri": "r2://weft-transcripts/I4f2a/claude-a.jsonl", "offset": 1824})
    ev("weft-demo", B, "edit", "Blocked: codex-b edited fetchWithAuth in src/api/client.ts — pass the refresh token through",
       status="rejected", mode="check", intent="pass the refresh token through", reads=[RT],
       writes=[{"key": FW, "kind": "body"}], files=["src/api/client.ts"],
       diagnostics=[diag("error", "stale_assumption", "src/api/client.ts", RT,
                         "You call src/auth/session.ts#refreshToken, whose signature changed in #{A_SIG} by claude-a after your base.",
                         "{A_SIG}", A, "T-1",
                         "Read the new refreshToken (event #{A_SIG}) and update this call site, or negotiate with claude-a.")],
       tool={"name": "apply_patch", "call_id": "call_8Rz", "harness_event": "PreToolUse"}, ref="B_BLOCK")
    ev("weft-site", D, "edit", "hermes-d added docs/protocol/observer.md",
       writes=[{"key": "docs/protocol/observer.md#Watching agents from a phone", "kind": "new"}],
       files=["docs/protocol/observer.md"], diff=DIFF_DOCS, tool={"name": "write_file", "harness_event": "post_tool_call"})
    ev("weft-demo", C, "edit", "gemini-c changed body of SessionStore.get in src/auth/session.ts — retry refresh 3 times",
       intent="retry refresh 3 times in SessionStore.get", reads=[RT], writes=[{"key": f"{S}#SessionStore.get", "kind": "body"}],
       files=[S], diff=DIFF_GEMINI,
       diagnostics=[diag("warning", "stale_read", S, RT,
                         "You read src/auth/session.ts#refreshToken, whose body changed in #{A_SIG} by claude-a after your base.",
                         "{A_SIG}", A, "T-1", "Re-read refreshToken before relying on its retry behaviour.", line=42)],
       tool={"name": "replace", "harness_event": "AfterTool"})
    ev("weft-demo", B, "negotiate.propose", "codex-b proposed to claude-a: keep refreshToken(token) as an overload",
       payload={"to": {"agent": A}, "keys": [RT], "terms": {"kind": "overload",
                "text": "Keep refreshToken(token) as an overload that forwards with default opts, so fetchWithAuth keeps compiling."}},
       ref="PROPOSE")
    ev("weft-demo", A, "negotiate.counter", "claude-a countered codex-b: add the overload, land first",
       payload={"reply_to": "{PROPOSE}", "terms": {"kind": "sequence",
                "text": "I'll add the overload in this change and land first; then switch your call site to pass { retries: 1 }."}},
       ref="COUNTER")
    ev("weft-demo", B, "negotiate.accept", "codex-b accepted claude-a's terms", payload={"reply_to": "{COUNTER}"})
    ev("weft-demo", A, "edit", "claude-a added an overload of refreshToken in src/auth/session.ts — keep old callers compiling",
       intent="keep refreshToken(token) callers compiling (negotiated)", writes=[{"key": RT, "kind": "body"}],
       files=[S], diff=DIFF_OVERLOAD, tool={"name": "Edit", "call_id": "toolu_02", "harness_event": "PostToolUse"})
    ev("weft-demo", B, "edit", "codex-b changed body of fetchWithAuth in src/api/client.ts — pass { retries: 1 }",
       intent="pass { retries: 1 } to refreshToken", reads=[RT], writes=[{"key": FW, "kind": "body"}],
       files=["src/api/client.ts"], diff=DIFF_FETCH_V2, tool={"name": "apply_patch", "call_id": "call_9Ka", "harness_event": "PostToolUse"})
    ev("weft-demo", A, "checkpoint", "claude-a pushed 3f9a2c1 to weft/I4f2a",
       payload={"sha": "3f9a2c1d", "ref": "refs/heads/weft/I4f2a"}, evidence="I4f2a")
    ev("weft-demo", C, "checkpoint", "gemini-c pushed 71be09a to weft/I7d3e",
       payload={"sha": "71be09ae", "ref": "refs/heads/weft/I7d3e"}, evidence="I7d3e")
    ev("weft-site", D, "checkpoint", "hermes-d pushed c0ffee1 to weft/Ia11b",
       payload={"sha": "c0ffee12", "ref": "refs/heads/weft/Ia11b"}, evidence="Ia11b")
    # ---- live from here (by default) ----
    ev("weft-demo", "john", "control", "john approved I4f2a (claude-a) for T-1", actor_type="human",
       payload={"action": "approve", "target": {"change": "I4f2a"}, "reason": "previews and tests look right"},
       task_override="T-1", change_override="I4f2a")
    ev("weft-demo", "landing-queue", "land", "claude-a landed I4f2a (3 symbols)", actor_type="system", agent_override=A,
       writes=[{"key": RT, "kind": "signature"}, {"key": f"{S}#RefreshOpts", "kind": "new"}], files=[S],
       payload={"sha": "9e1b77a0c4", "op_id": "op_000021", "trunk_ref": "refs/heads/main"}, evidence="I4f2a")
    ev("weft-site", "landing-queue", "land", "hermes-d landed Ia11b (1 page)", actor_type="system", agent_override=D,
       files=["docs/protocol/observer.md"], payload={"sha": "5d2e81f", "op_id": "op_000006", "trunk_ref": "refs/heads/main"})
    ev("weft-demo", "landing-queue", "land", "codex-b landed I9c01 (1 symbol)", actor_type="system", agent_override=B,
       writes=[{"key": FW, "kind": "body"}], files=["src/api/client.ts"],
       payload={"sha": "b41c2d9e07", "op_id": "op_000023", "trunk_ref": "refs/heads/main"}, evidence="I9c01", ref="LAND_B")
    ev("weft-demo", "revert-workflow", "revert",
       "Reverted #{LAND_B}: 5xx rate 4.1% on POST /api/orders after landing", actor_type="system", agent_override=B,
       writes=[{"key": FW, "kind": "body"}], files=["src/api/client.ts"],
       payload={"op_id": "op_000024", "reverts_seq": "{LAND_B}", "sha": "e7a90c13",
                "reason": "5xx rate 4.1% on POST /api/orders after landing (Tail Worker alert)"})
    ev("weft-demo", "john", "message", "john → codex-b (steer): only retry idempotent requests", actor_type="human",
       payload={"to": {"agent": B}, "intent": "steer",
                "text": "Reverted: fetchWithAuth replays POST bodies. Only retry GET/HEAD on 401."},
       task_override="T-2", change_override="I9c01", agent_override=B)
    ev("weft-demo", B, "intent", "codex-b plans: retry only GET/HEAD on 401",
       intent="Retry only idempotent requests (GET/HEAD) after a 401 refresh", reads=[RT, FW], files=["src/api/client.ts"])
    return out


class Log:
    def __init__(self, preload: int, live_interval: float, ping_every: float):
        self.lock = threading.Lock()
        self.repos: dict[str, list[dict]] = {"weft-demo": [], "weft-site": []}
        self.full: dict[tuple[str, int], dict] = {}
        self.subs: dict[str, list[queue.Queue]] = {r: [] for r in self.repos}
        self.refs: dict[str, int] = {}
        self.pending = scenario()
        self.live_interval = live_interval
        self.ping_every = ping_every
        start = datetime.now(timezone.utc) - timedelta(minutes=3 * preload + 2)
        for i in range(min(preload, len(self.pending))):
            self._append(*self.pending[i], ts=start + timedelta(minutes=3 * i, seconds=17 * i % 50))
        self.pending = self.pending[preload:]

    @staticmethod
    def _iso(t: datetime) -> str:
        return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"

    def _resolve(self, v):
        if isinstance(v, str):
            for k, n in self.refs.items():
                if v == "{" + k + "}":
                    return n
                v = v.replace("{" + k + "}", str(n))
            return v
        if isinstance(v, list):
            return [self._resolve(x) for x in v]
        if isinstance(v, dict):
            return {k: self._resolve(x) for k, x in v.items()}
        return v

    def _append(self, repo: str, draft: dict, ts: datetime | None = None) -> dict:
        d = dict(draft)
        who = d.pop("agent_id")
        actor_type = d.pop("actor_type", "agent")
        ref = d.pop("ref", None)
        evidence = d.pop("evidence", None)
        agent = d.pop("agent_override", who if actor_type == "agent" else None)
        harness, task, change, session = AGENTS.get(agent or "", (None, None, None, None))
        task = d.pop("task_override", task)
        change = d.pop("change_override", change)
        rows = self.repos[repo]
        seq = len(rows) + 1
        if d.get("kind") == "edit" and who == "claude-a" and "A_SIG" not in self.refs and any(
                w["kind"] == "signature" for w in d.get("writes", [])):
            self.refs["A_SIG"] = seq
        d = self._resolve(d)
        actor = {"type": actor_type, "id": who}
        if actor_type == "agent" and harness:
            actor["harness"] = harness
        rec = {"seq": seq, "repo": repo, "status": d.pop("status", "accepted"), "kind": d.pop("kind"),
               "ts": self._iso(ts or datetime.now(timezone.utc)), "actor": actor,
               "base_seq": max(0, seq - 2), "files": d.pop("files", []), "reads": d.pop("reads", []),
               "writes": d.pop("writes", []), "summary": d.pop("summary"), "diagnostics": d.pop("diagnostics", [])}
        if agent:
            rec["agent"] = agent
        if task:
            rec["task"] = task
            rec["x_task_title"] = TASKS.get(task)
        if change:
            rec["change"] = change
        if actor_type == "agent":
            rec["session"] = session
            rec["mode"] = d.pop("mode", "commit")
        for k in ("intent", "diff", "payload", "tool", "transcript"):
            if k in d:
                rec[k] = d.pop(k)
        if evidence:
            rec["x_evidence"] = EVIDENCE[evidence]
        if ref:
            self.refs[ref] = seq
        rows.append(rec)
        self.full[(repo, seq)] = rec
        for q in list(self.subs[repo]):
            q.put({"type": "event", "event": self.list_view(rec)})
        return rec

    def append(self, repo, draft):
        with self.lock:
            return self._append(repo, draft)

    @staticmethod
    def list_view(rec: dict, include_diff=False) -> dict:
        r = dict(rec)
        if "diff" in r and not include_diff:
            r.pop("diff")
            r["has_diff"] = True
        return r

    def head(self, repo):
        return len(self.repos[repo])

    def live_loop(self):
        while self.pending:
            time.sleep(self.live_interval)
            repo, draft = self.pending.pop(0)
            rec = self.append(repo, draft)
            print(f"  live: {repo} #{rec['seq']} {rec['kind']}: {rec['summary'][:70]}", flush=True)


LOG: Log
TOKENS: dict[str, str] = {}
REPLAY_CAP = 1000


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("  " + self.address_string() + " " + (fmt % args), flush=True)

    # ---- helpers
    def scope(self) -> str | None:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        return TOKENS.get(auth[7:])

    def send_json(self, code: int, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("WCP-Version", "0.1")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, code: int, err: str, message: str):
        self.send_json(code, {"type": "error", "error": {"code": err, "message": message, "retryable": False}})

    # ---- routes
    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(u.query).items()}
        parts = [p for p in u.path.split("/") if p]
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket(parts, q)
        if not self.scope():
            return self.error(401, "unauthorized", "missing or invalid token")
        if parts == ["v1", "repos"]:
            with LOG.lock:
                repos = []
                for r, rows in LOG.repos.items():
                    agents = {e.get("agent") for e in rows if e["kind"] == "join"}
                    repos.append({"repo": r, "head_seq": len(rows), "active_agents": len(agents),
                                  "active_changes": len({e.get("change") for e in rows if e.get("change")}),
                                  "open_conflicts": sum(1 for e in rows[-10:] if e["status"] == "rejected"),
                                  "last_event_at": rows[-1]["ts"] if rows else None,
                                  "policy": {"arbitration": "wound-wait"}})
            return self.send_json(200, {"type": "repos", "repos": repos})
        if len(parts) >= 4 and parts[:2] == ["v1", "repos"] and parts[3] == "events":
            repo = parts[2]
            if repo not in LOG.repos:
                return self.error(404, "repo_not_found", repo)
            if len(parts) == 5:
                rec = LOG.full.get((repo, int(parts[4]))) if parts[4].isdigit() else None
                return self.send_json(200, rec) if rec else self.error(404, "not_found", f"no event {parts[4]}")
            return self.send_json(200, self.page(repo, q))
        if parts == ["v1", "feed"]:
            return self.send_json(200, self.feed(q))
        return self.error(404, "not_found", u.path)

    def do_POST(self):
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        scope = self.scope()
        if not scope:
            return self.error(401, "unauthorized", "missing or invalid token")
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if len(parts) == 4 and parts[:2] == ["v1", "repos"] and parts[3] == "actions":
            if scope != "human":
                return self.error(403, "forbidden", "observer tokens are read-only")
            repo = parts[2]
            if repo not in LOG.repos:
                return self.error(404, "repo_not_found", repo)
            return self.action(repo, body)
        return self.error(404, "not_found", u.path)

    def page(self, repo, q):
        limit = min(int(q.get("limit", 100)), 500)
        include = q.get("include") == "diff"
        filt = {k: set(q[k].split(",")) for k in ("kind", "agent", "task", "change", "status") if k in q}
        with LOG.lock:
            rows = LOG.repos[repo]
            head = len(rows)

            def ok(e):
                return all(str(e.get(k)) in v for k, v in filt.items())

            if q.get("tail") == "1":
                sel = [e for e in rows if ok(e)][-limit:]
                nxt, more = head, False
            elif "before" in q:
                b = int(q["before"])
                sel = [e for e in rows if e["seq"] < b and ok(e)][-limit:]
                nxt, more = head, False
            else:
                a = int(q.get("after", 0))
                examined = [e for e in rows if e["seq"] > a][:limit]
                sel = [e for e in examined if ok(e)]
                nxt = examined[-1]["seq"] if examined else max(a, 0)
                more = nxt < head
            return {"type": "events", "repo": repo, "events": [Log.list_view(e, include) for e in sel],
                    "head_seq": head, "next_after": nxt, "has_more": more}

    def feed(self, q):
        limit = min(int(q.get("limit", 100)), 500)
        with LOG.lock:
            cursor = {}
            c = q.get("after")
            if c and c.startswith("v0."):
                pad = c[3:] + "=" * (-len(c[3:]) % 4)
                cursor = json.loads(base64.urlsafe_b64decode(pad))
            rows = [e for r, es in LOG.repos.items() for e in es if q.get("tail") == "1" or e["seq"] > cursor.get(r, 0)]
            rows.sort(key=lambda e: (e["ts"], e["repo"], e["seq"]))
            page = rows[-limit:] if q.get("tail") == "1" else rows[:limit]
            nxt = {r: len(es) for r, es in LOG.repos.items()} if q.get("tail") == "1" else dict(cursor)
            if q.get("tail") != "1":
                for e in page:
                    nxt[e["repo"]] = max(nxt.get(e["repo"], 0), e["seq"])
            enc = "v0." + base64.urlsafe_b64encode(json.dumps(dict(sorted(nxt.items())), separators=(",", ":")).encode()).decode().rstrip("=")
            return {"type": "feed", "events": [Log.list_view(e) for e in page], "cursor": enc,
                    "has_more": q.get("tail") != "1" and len(rows) > limit}

    def action(self, repo, body):
        a = body.get("action")
        human = "john"
        if a == "approve":
            change = body.get("change")
            draft = {"kind": "control", "agent_id": human, "actor_type": "human",
                     "summary": f"{human} approved {change}", "change_override": change, "task_override": body.get("task"),
                     "payload": {"action": "approve", "target": {"change": change}, **({"reason": body["note"]} if body.get("note") else {})}}
        elif a in ("pause", "resume"):
            agent = body.get("agent")
            draft = {"kind": "control", "agent_id": human, "actor_type": "human", "agent_override": agent,
                     "summary": f"{human} {'paused' if a == 'pause' else 'resumed'} {agent}",
                     "payload": {"action": a, "target": {"agent": agent}, **({"reason": body["reason"]} if body.get("reason") else {})}}
        elif a == "message":
            to = (body.get("to") or {}).get("agent")
            if not body.get("text"):
                return self.error(400, "invalid_message", "text is required")
            draft = {"kind": "message", "agent_id": human, "actor_type": "human", "agent_override": to,
                     "summary": f"{human} → {to} ({body.get('intent', 'info')}): {body['text'][:80]}",
                     "payload": {"to": {"agent": to}, "text": body["text"], "intent": body.get("intent", "info")}}
        elif a == "undo":
            seq = body.get("seq")
            target = LOG.full.get((repo, seq))
            if not target or target["kind"] != "land":
                return self.error(422, "invalid_reference", "undo target must be a land")
            draft = {"kind": "control", "agent_id": human, "actor_type": "human", "agent_override": target.get("agent"),
                     "summary": f"{human} asked to undo #{seq}: {body.get('reason', '')}",
                     "payload": {"action": "undo", "target": {"seq": seq, "op_id": target["payload"]["op_id"]}, "reason": body.get("reason", "")}}

            def later():
                time.sleep(2)
                LOG.append(repo, {"kind": "revert", "agent_id": "revert-workflow", "actor_type": "system",
                                  "agent_override": target.get("agent"), "writes": target["writes"], "files": target["files"],
                                  "summary": f"Reverted #{seq}: {body.get('reason', '')}",
                                  "payload": {"op_id": f"op_{int(time.time()) % 100000:06d}", "reverts_seq": seq,
                                              "reason": body.get("reason", ""), "requested_by": {"type": "human", "id": human}}})
            threading.Thread(target=later, daemon=True).start()
        else:
            return self.error(400, "invalid_message", f"unknown action {a!r}")
        rec = LOG.append(repo, draft)
        return self.send_json(200, {"type": "action.result", "seq": rec["seq"], "record": rec})

    # ---- WebSocket (RFC 6455, server side, text frames only)
    def websocket(self, parts, q):
        if not (len(parts) == 4 and parts[:2] == ["v1", "repos"] and parts[3] == "stream"):
            return self.error(404, "not_found", self.path)
        if not self.scope():
            return self.error(401, "unauthorized", "missing or invalid token")
        repo = parts[2]
        if repo not in LOG.repos:
            return self.error(404, "repo_not_found", repo)
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.send_header("WCP-Version", "0.1")
        self.end_headers()
        self.wfile.flush()
        sock = self.connection
        after = int(q.get("after", 0))
        inbox: queue.Queue = queue.Queue()
        closed = threading.Event()
        send_lock = threading.Lock()

        def send(obj=None, opcode=1, payload=b""):
            data = json.dumps(obj).encode() if obj is not None else payload
            hdr = bytes([0x80 | opcode])
            n = len(data)
            hdr += bytes([n]) if n < 126 else (bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n))
            with send_lock:
                sock.sendall(hdr + data)

        def reader():
            try:
                while not closed.is_set():
                    h = recv_exact(2)
                    op, ln = h[0] & 0x0F, h[1] & 0x7F
                    if ln == 126:
                        ln = struct.unpack(">H", recv_exact(2))[0]
                    elif ln == 127:
                        ln = struct.unpack(">Q", recv_exact(8))[0]
                    mask = recv_exact(4) if h[1] & 0x80 else b"\0\0\0\0"
                    data = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(ln)))
                    if op == 8:
                        break
                    if op == 9:
                        send(opcode=10, payload=data)
            except Exception:
                pass
            closed.set()

        def recv_exact(n):
            buf = b""
            while len(buf) < n:
                chunk = sock.recv(n - len(buf))
                if not chunk:
                    raise ConnectionError
                buf += chunk
            return buf

        with LOG.lock:
            backlog = [e for e in LOG.repos[repo] if e["seq"] > after]
            if len(backlog) > REPLAY_CAP:
                send(opcode=8, payload=struct.pack(">H", 4413) + b"payload_too_large")
                return
            LOG.subs[repo].append(inbox)
        print(f"  ws: {repo} after={after} replay={len(backlog)}", flush=True)
        threading.Thread(target=reader, daemon=True).start()
        try:
            for e in backlog:
                send({"type": "event", "event": Log.list_view(e)})
            send({"type": "replay.done", "head_seq": LOG.head(repo)})
            last = time.time()
            while not closed.is_set():
                try:
                    frame = inbox.get(timeout=1)
                    if frame["event"]["seq"] > after:
                        send(frame)
                        after = frame["event"]["seq"]
                except queue.Empty:
                    pass
                if time.time() - last > LOG.ping_every:
                    send({"type": "ping", "head_seq": LOG.head(repo)})
                    last = time.time()
        except (BrokenPipeError, ConnectionError, OSError):
            pass
        finally:
            closed.set()
            with LOG.lock:
                if inbox in LOG.subs[repo]:
                    LOG.subs[repo].remove(inbox)
            self.close_connection = True
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main():
    global LOG, REPLAY_CAP
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8796)
    ap.add_argument("--token", default="dev", help="human-scope token (read + actions)")
    ap.add_argument("--observer-token", default="observer", help="read-only token")
    ap.add_argument("--preload", type=int, default=21, help="scenario events in the log at start; the rest arrive live")
    ap.add_argument("--live-interval", type=float, default=8.0, help="seconds between live events")
    ap.add_argument("--ping", type=float, default=20.0, help="seconds between idle pings")
    ap.add_argument("--replay-cap", type=int, default=1000)
    args = ap.parse_args()
    TOKENS[args.token] = "human"
    TOKENS[args.observer_token] = "observe"
    REPLAY_CAP = args.replay_cap
    LOG = Log(args.preload, args.live_interval, args.ping)
    threading.Thread(target=LOG.live_loop, daemon=True).start()
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print(f"weft fixture gateway on http://{args.host}:{args.port}  repos={list(LOG.repos)}  "
          f"preloaded={sum(map(len, LOG.repos.values()))}  live={len(LOG.pending)} every {args.live_interval}s", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
