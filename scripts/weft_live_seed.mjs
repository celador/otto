#!/usr/bin/env node
// Seeds a deployed weft-gateway (B2) with a realistic multi-agent scenario for the Hérmes
// "Changes" feed, then optionally keeps appending live events. Card I1b (board `weft`).
//
//   node scripts/weft_live_seed.mjs seed [--suffix x]     # repos ios-demo / ios-site + tokens + scenario
//   node scripts/weft_live_seed.mjs live [--count 6] [--interval 4]
//   node scripts/weft_live_seed.mjs land                  # a throwaway land to undo from the app
//   node scripts/weft_live_seed.mjs bulk [--count 5100]   # repo ios-bulk past the 5000 replay cap
//   node scripts/weft_live_seed.mjs revert-pending        # system revert for every undo request not yet reverted
//
// Admin token: ~/.config/weft/preview-admin-token. Issued tokens and repo names go to
// ~/.config/weft/ios-live.json (mode 600). Never prints a token.

import { readFileSync, writeFileSync, existsSync, chmodSync } from "node:fs";
import { homedir } from "node:os";

const URL_ = process.env.WEFT_URL ?? "https://weft-gateway-preview.elier.ai";
const ADMIN = readFileSync(`${homedir()}/.config/weft/preview-admin-token`, "utf8").trim();
const STATE = `${homedir()}/.config/weft/ios-live.json`;
const [cmd = "seed", ...rest] = process.argv.slice(2);
const arg = (k, d) => {
  const i = rest.indexOf(`--${k}`);
  return i >= 0 ? rest[i + 1] : d;
};

async function call(method, path, token, body, extra = {}) {
  const r = await fetch(URL_ + path, {
    method,
    headers: { "wcp-version": "0.1", authorization: `Bearer ${token}`, ...(body ? { "content-type": "application/json" } : {}), ...extra },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await r.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = { raw: text }; }
  if (r.status >= 400) console.log(`  ! ${method} ${path} → ${r.status} ${JSON.stringify(json).slice(0, 200)}`);
  return { status: r.status, body: json };
}
const load = () => JSON.parse(readFileSync(STATE, "utf8"));
const save = (s) => { writeFileSync(STATE, JSON.stringify(s, null, 2)); chmodSync(STATE, 0o600); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const caps = { level: 3, observe: "sync", inject: "immediate", deny_edit: true, refuse_stop: true, commit_gate: "tool_interception" };
const S = "src/auth/session.ts";
const RT = `${S}#refreshToken`;
const FW = "src/api/client.ts#fetchWithAuth";

/** One agent session: tracks delivered_through so base_seq is always valid. */
class Agent {
  constructor(repo, token, id, harness, task, change) { Object.assign(this, { repo, token, id, harness, task, change }); }
  async hello() {
    const w = (await call("POST", `/v1/repos/${this.repo}/sessions`, this.token, {
      type: "hello", protocol: "wcp/0.1", agent: { id: this.id, harness: this.harness }, capabilities: caps,
      task: { id: this.task }, change: this.change,
    })).body;
    this.session = w.session;
    this.base = w.delivered_through;
    return this;
  }
  async submit(event, mode = "commit") {
    const v = (await call("POST", `/v1/repos/${this.repo}/sessions/${this.session}/events`, this.token,
      { type: "submit", mode, event: { base_seq: this.base, ...event }, ...(this.ack ? { inbox_ack: this.ack } : {}) },
      { "idempotency-key": `${this.id}-${Date.now()}-${Math.random()}` })).body;
    if (v?.delivered_through !== undefined) this.base = v.delivered_through;
    if (v?.inbox?.length) this.ack = v.inbox.at(-1).id;
    if (!this.quiet) console.log(`  ${this.repo} #${v?.seq ?? "-"} ${this.id} ${event.kind} ${v?.verdict ?? ""} ${(v?.diagnostics ?? []).map((d) => d.code).join(",")}`);
    return v;
  }
  async drain() {
    const b = (await call("POST", `/v1/repos/${this.repo}/sessions/${this.session}/inbox`, this.token,
      { type: "inbox.drain", ...(this.ack ? { ack: this.ack } : {}) })).body;
    if (b?.items?.length) this.ack = b.items.at(-1).id;
    if (b?.delivered_through !== undefined) this.base = b.delivered_through;
    return b;
  }
}

const diffSig = `--- a/${S}
+++ b/${S}
@@ -38,9 +38,16 @@ export class SessionStore {
-export async function refreshToken(token: string): Promise<Session> {
-  const res = await post("/oauth/refresh", { token });
-  return parseSession(res);
+export interface RefreshOpts {
+  retries?: number;
+  backoffMs?: number;
+}
+
+export async function refreshToken(token: string, opts: RefreshOpts = {}): Promise<Session> {
+  const { retries = 2, backoffMs = 250 } = opts;
+  for (let attempt = 0; ; attempt++) {
+    try { return parseSession(await post("/oauth/refresh", { token })); }
+    catch (e) { if (attempt >= retries) throw e; await sleep(backoffMs * 2 ** attempt); }
+  }
 }
`;
const diffFetch = `--- a/src/api/client.ts
+++ b/src/api/client.ts
@@ -12,7 +12,12 @@ export async function fetchWithAuth(input: RequestInfo, init: RequestInit = {}) {
   const session = await sessions.get();
-  return fetch(input, withBearer(init, session.accessToken));
+  const res = await fetch(input, withBearer(init, session.accessToken));
+  if (res.status !== 401) return res;
+  // Retry a 401 once with a fresh token.
+  const fresh = await refreshToken(session.refreshToken);
+  return fetch(input, withBearer(init, fresh.accessToken));
 }
`;
const diffOverload = `--- a/${S}
+++ b/${S}
@@ -44,6 +44,10 @@ export interface RefreshOpts {
+/** @deprecated pass RefreshOpts; kept so existing callers compile. */
+export async function refreshToken(token: string): Promise<Session>;
+export async function refreshToken(token: string, opts?: RefreshOpts): Promise<Session>;
+
 export async function refreshToken(token: string, opts: RefreshOpts = {}): Promise<Session> {
`;
const diffDocs = `--- a/docs/observer.md
+++ b/docs/observer.md
@@ -1,3 +1,9 @@
 # Watching agents
+
+## From a phone
+Open Changes, then add the gateway URL and an observer token. The feed resumes
+from the last record it saw, so it is safe to lock the phone mid-run.
`;

async function seed() {
  const sfx = arg("suffix", "");
  const repos = { demo: `ios-demo${sfx}`, site: `ios-site${sfx}` };
  for (const r of Object.values(repos)) await call("POST", "/v1/admin/repos", ADMIN, { repo: r });
  const tok = async (spec) => (await call("POST", "/v1/admin/tokens", ADMIN, spec)).body.token;
  const all = Object.values(repos);
  const st = {
    url: URL_, repos,
    observer: await tok({ principal: "hermes-phone", scopes: ["observe"], repos: all }),
    human: await tok({ principal: "reviewer", scopes: ["human"], repos: all }),
    system: await tok({ principal: "land-workflow", scopes: ["system"], repos: all }),
    agents: {},
  };
  for (const [id, r] of [["claude-a", repos.demo], ["codex-b", repos.demo], ["gemini-c", repos.demo], ["hermes-d", repos.site]])
    st.agents[id] = await tok({ principal: id, scopes: ["agent"], repos: [r], agent: id });
  save(st);
  console.log(`tokens saved to ${STATE}`);

  const D = repos.demo;
  const A = await new Agent(D, st.agents["claude-a"], "claude-a", "claude-code", "T-1", "I-a").hello();
  const B = await new Agent(D, st.agents["codex-b"], "codex-b", "codex", "T-2", "I-b").hello();
  const C = await new Agent(D, st.agents["gemini-c"], "gemini-c", "gemini-cli", "T-3", "I-c").hello();
  await A.submit({ kind: "claim", writes: [{ key: RT, kind: "signature" }], payload: { firm: true, source: "explicit", ttl_ms: 600000 } });
  await B.submit({ kind: "intent", intent: "retry 401s once", reads: [RT], writes: [{ key: FW, kind: "body" }] });
  await B.submit({ kind: "edit", intent: "retry 401s once", reads: [RT], writes: [{ key: FW, kind: "body" }], diff: diffFetch, files: ["src/api/client.ts"] });
  await A.submit({ kind: "edit", intent: "add a retry budget to refreshToken", writes: [{ key: RT, kind: "signature" }, { key: `${S}#RefreshOpts`, kind: "new" }], diff: diffSig, files: [S] });
  await B.submit({ kind: "edit", intent: "use the fresh token on retry", reads: [RT], writes: [{ key: FW, kind: "body" }], files: ["src/api/client.ts"] });
  await C.submit({ kind: "edit", intent: "retry refresh 3 times in SessionStore.get", reads: [RT], writes: [{ key: `${S}#SessionStore.get`, kind: "body" }], files: [S] });
  const prop = await B.submit({ kind: "negotiate.propose", payload: { to: { agent: "claude-a" }, keys: [RT], terms: { kind: "overload", text: "Keep refreshToken(token) as an overload so my callers compile." } } });
  await A.drain();
  await A.submit({ kind: "negotiate.accept", payload: { reply_to: prop.seq } });
  await A.submit({ kind: "edit", intent: "keep refreshToken(token) callers compiling (negotiated)", writes: [{ key: RT, kind: "body" }], diff: diffOverload, files: [S] });
  await B.drain();
  await B.submit({ kind: "edit", intent: "pass { retries: 1 } to refreshToken", reads: [RT], writes: [{ key: FW, kind: "body" }], diff: diffFetch, files: ["src/api/client.ts"] });
  await A.submit({ kind: "checkpoint", payload: { sha: "4f2c9e1a", ref: "refs/weft/I-a" } });
  await B.submit({ kind: "checkpoint", payload: { sha: "b81d07c3", ref: "refs/weft/I-b" } });
  await call("POST", `/v1/repos/${D}/actions`, st.human, { type: "action", action: "approve", change: "I-a", task: "T-1", note: "tests green, ship it" });
  const head = (await call("GET", `/v1/repos/${D}/events?tail=1&limit=1`, st.observer)).body.head_seq;
  await call("POST", `/v1/repos/${D}/system/events`, st.system, { kind: "land", base_seq: head, change: "I-a", payload: { sha: "4f2c9e1a", op_id: `op_${Date.now()}` } });
  await call("POST", `/v1/repos/${D}/actions`, st.human, { type: "action", action: "message", to: { agent: "codex-b" }, text: "Use the overload for now; drop the manual retry loop.", intent: "steer" });

  await site(st, repos);
  await evidence(st);
  console.log("seeded", JSON.stringify(repos));
}

// Task titles + candidate evidence. weft-gateway keeps `payload` verbatim but drops unknown top-level
// fields, so the x_ vendor extensions (docs/weft.md) ride inside payload.
const TITLES = { "T-1": "Retry budget for token refresh", "T-2": "Retry 401s in fetchWithAuth", "T-3": "Cache refreshed sessions", "T-9": "Docs: watching agents from a phone" };
async function evidence(st = load()) {
  const D = st.repos.demo;
  const ev = {
    "claude-a": { task: "T-1", change: "I-a", h: "claude-code", sha: "4f2c9e1a", x: { preview_url: "https://i-a.preview.example.dev", tests: { passed: 148, failed: 0, total: 148 }, review: { verdict: "approve", summary: "Retry budget is bounded; overload keeps old callers compiling." }, cost_usd: 0.42 } },
    "codex-b": { task: "T-2", change: "I-b", h: "codex", sha: "b81d07c3", x: { preview_url: "https://i-b.preview.example.dev", tests: { passed: 146, failed: 2, total: 148 }, review: { verdict: "changes", summary: "Two auth tests fail when the refresh endpoint is slow." }, cost_usd: 0.31 } },
    "gemini-c": { task: "T-3", change: "I-c", h: "gemini-cli", sha: "7c3e5a90", x: { tests: { passed: 148, failed: 0, total: 148 }, cost_usd: 0.18 } },
  };
  for (const [id, e] of Object.entries(ev)) {
    const a = await new Agent(D, st.agents[id], id, e.h, e.task, e.change).hello();
    await a.submit({ kind: "checkpoint", payload: { sha: e.sha, ref: `refs/weft/${e.change}`, x_task_title: TITLES[e.task], x_evidence: e.x } });
  }
  const H = await new Agent(st.repos.site, st.agents["hermes-d"], "hermes-d", "hermes", "T-9", "I-d").hello();
  await H.submit({ kind: "intent", intent: "link the observer doc from the README", payload: { x_task_title: TITLES["T-9"] } });
}

async function site(st = load(), repos = st.repos) {
  const H = await new Agent(repos.site, st.agents["hermes-d"], "hermes-d", "hermes", "T-9", "I-d").hello();
  await H.submit({ kind: "intent", intent: "document watching agents from a phone", writes: [{ key: "docs/observer.md#from-a-phone", kind: "new" }] });
  await H.submit({ kind: "edit", intent: "document watching agents from a phone", writes: [{ key: "docs/observer.md#from-a-phone", kind: "new" }], diff: diffDocs, files: ["docs/observer.md"] });
  await H.submit({ kind: "checkpoint", payload: { sha: "0aa71d2e" } });
}

async function live() {
  const st = load();
  const n = Number(arg("count", 6)), every = Number(arg("interval", 4)) * 1000;
  const C = await new Agent(st.repos.demo, st.agents["gemini-c"], "gemini-c", "gemini-cli", "T-3", "I-c").hello();
  const steps = [
    { kind: "intent", intent: "cache the refreshed session for 30 s" },
    { kind: "edit", intent: "cache the refreshed session for 30 s", writes: [{ key: `${S}#SessionStore.get`, kind: "body" }], files: [S] },
    { kind: "edit", intent: "invalidate the cache on sign-out", writes: [{ key: `${S}#SessionStore.clear`, kind: "body" }], files: [S] },
    { kind: "checkpoint", payload: { sha: Math.random().toString(16).slice(2, 10) } },
  ];
  for (let i = 0; i < n; i++) {
    await C.submit(steps[i % steps.length]);
    if (i < n - 1) await sleep(every);
  }
}

async function land() {
  const st = load();
  const D = st.repos.demo;
  const head = (await call("GET", `/v1/repos/${D}/events?tail=1&limit=1`, st.observer)).body.head_seq;
  const r = await call("POST", `/v1/repos/${D}/system/events`, st.system, { kind: "land", base_seq: head, change: "I-b", payload: { sha: Math.random().toString(16).slice(2, 10), op_id: `op_${Date.now()}` } });
  console.log(`land → ${r.status} seq ${r.body?.seq ?? r.body?.record?.seq}`);
}

/** Plays the revert workflow (B8 isn't built): one system revert per human undo control not yet reverted. */
async function revertPending() {
  const st = load();
  for (const repo of Object.values(st.repos)) {
    const evs = (await call("GET", `/v1/repos/${repo}/events?after=0&limit=500`, st.observer)).body.events;
    const reverted = new Set(evs.filter((e) => e.kind === "revert").map((e) => e.payload?.reverts_seq));
    for (const c of evs.filter((e) => e.kind === "control" && e.payload?.action === "undo")) {
      const t = c.payload.target ?? {};
      const target = t.seq ?? evs.find((e) => e.kind === "land" && e.payload?.op_id === t.op_id)?.seq;
      const land = evs.find((e) => e.seq === target);
      if (!land || reverted.has(target)) continue;
      const head = (await call("GET", `/v1/repos/${repo}/events?tail=1&limit=1`, st.observer)).body.head_seq;
      const r = await call("POST", `/v1/repos/${repo}/system/events`, st.system, {
        kind: "revert", base_seq: head, change: land.change, writes: land.writes,
        payload: { op_id: `op_${Date.now()}`, reverts_seq: target, reason: c.payload.reason ?? "undo", requested_by: c.actor },
      });
      console.log(`revert of ${repo} #${target} → ${r.status}`);
    }
  }
}

async function bulk() {
  const st = load();
  const repo = arg("repo", "ios-bulk");
  const n = Number(arg("count", 5100));
  await call("POST", "/v1/admin/repos", ADMIN, { repo });
  const human = await (await call("POST", "/v1/admin/tokens", ADMIN, { principal: "bulk-writer", scopes: ["human"], repos: [repo] })).body.token;
  st.bulk = { repo };
  // Observer that also sees the bulk repo (keep it out of screenshots: use `observer` for those).
  st.observer_all = (await call("POST", "/v1/admin/tokens", ADMIN, { principal: "hermes-phone-bulk", scopes: ["observe"], repos: [...Object.values(st.repos), repo] })).body.token;
  save(st);
  // Messages need a known target, so the volume comes from agent sessions (intents), 8 in parallel.
  let done = 0;
  const worker = async (w) => {
    const id = `load-${w}`;
    const t = (await call("POST", "/v1/admin/tokens", ADMIN, { principal: id, scopes: ["agent"], repos: [repo], agent: id })).body.token;
    const ag = await new Agent(repo, t, id, "load", `T-load`, `I-load-${w}`).hello();
    ag.quiet = true;
    while (done < n) {
      const i = done++;
      await ag.submit({ kind: "intent", intent: `bulk ${i}` });
      if (i % 500 === 0) console.log(`  ${i}/${n}`);
    }
  };
  await Promise.all(Array.from({ length: 8 }, (_, w) => worker(w)));
  console.log(`bulk: ${n} records in ${repo}`);
}

const cmds = { seed, site: () => site(), evidence: () => evidence(), live, land, bulk, "revert-pending": revertPending };
if (!cmds[cmd]) { console.error(`unknown command ${cmd}`); process.exit(2); }
if (cmd !== "seed" && cmd !== "bulk" && !existsSync(STATE)) { console.error("run seed first"); process.exit(2); }
await cmds[cmd]();
