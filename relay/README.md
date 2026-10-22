# Kanban relay

Lets the Hérmes app read and update the Hermes Kanban board without giving the
phone the dashboard session token (which unlocks the whole dashboard).

- `kanban_relay.py` listens on `127.0.0.1:8650`, requires `Authorization: Bearer <API_SERVER_KEY>`
  (the same key the app uses for the gateway), and forwards only these routes to the dashboard
  (`127.0.0.1:9119/api/plugins/kanban`), adding `X-Hermes-Session-Token` server-side:
  - `GET /kanban/boards`, `/kanban/board?board=`, `/kanban/assignees`, `/kanban/tasks/{id}`
  - `POST /kanban/tasks` (title, body, assignee, priority, triage only)
  - `PATCH /kanban/tasks/{id}` (status ∈ triage/todo/ready/blocked/done/archived, assignee, priority, title, body, result, block_reason, summary)
  - `POST /kanban/tasks/{id}/comments` (author forced to `hermes-ios`)
  Everything else is 404/405. No DELETE.
- Published on the tailnet: `tailscale serve --bg --https=8651 http://127.0.0.1:8650`
  → `https://my-mac.example.ts.net:8651`. The app derives this from the gateway URL (same host, port 8651);
  override in Settings → Board.
- Secrets are read from `~/.hermes/.env` (`API_SERVER_KEY`, `HERMES_DASHBOARD_SESSION_TOKEN`) and re-read when the file changes.

## Run at login

`~/Library/LaunchAgents/ai.elier.hermes-kanban-relay.plist` is written. Load it once from a normal Terminal
(the Hermes gateway refuses to run launchctl bootstrap itself):

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.elier.hermes-kanban-relay.plist
```

If a relay is already running on 8650 (started by Hermes), stop it first: `pkill -f kanban_relay.py`.

## Tests

```bash
cd relay && python3 -c "import test_kanban_relay as t; [getattr(t,n)() for n in dir(t) if n.startswith('test_')]; print('ok')"
```

## Pairing Otto for Mac (`macpair.py`)

The Mac App Store build is sandboxed and can't read `~/.hermes/.env`, so it asks the relay on the same Mac.
These three routes need no bearer (the app has no key yet) and only answer direct loopback requests:
anything that came through Tailscale Serve (`X-Forwarded-*`, `Tailscale-*` headers) or from another address,
any `Host` other than `127.0.0.1` / `localhost` / `[::1]` (DNS rebinding), and any request carrying `Origin` or
`Sec-Fetch-*` (i.e. from a browser) gets 403. The dialog's default button is Don't Allow; Allow needs a click.

| Route | Does |
|---|---|
| `POST /macpair/start` | `{name?}` → `{id, code, expires_in}`; shows an Allow / Don't Allow dialog with the code on this Mac (`osascript`, 120 s). One dialog at a time (409), starts rate-limited. |
| `GET /macpair/poll?id=` | `pending` / `denied` / `expired`, or `approved` + `{gateway, relay, api_key}` exactly once. |
| `POST /macpair/cancel?id=` | The app stopped waiting: drop the pairing, close the dialog. |

The pending pool is the Apple TV one (`tvpair.py`), so an already-connected iPhone can also approve the
code with `POST /hermes/tvpair/approve` (the dialog then closes). Tests: `test_macpair.py`.

## Companion routes (/hermes/...)

Same key and port as the board. Implemented in `companion.py`; anything not listed is 404.

| Route | Does |
|---|---|
| `GET /hermes/profiles` | Agents (profiles): name, model, skill count, gateway running. No paths or env. |
| `GET /hermes/skills?profile=` | Skills with category, enabled, usage. |
| `GET /hermes/skills/content?name=&profile=` | A skill's SKILL.md. |
| `PUT /hermes/skills/toggle?profile=` | `{name, enabled}`. |
| `GET /hermes/memory?profile=` | Memory + user entries and limits. |
| `POST /hermes/memory?profile=` | `{op: add\|replace\|remove, target: memory\|user, content?, old_text?}`. Runs Hermes's own MemoryStore (`memory_helper.py`, Hermes venv) so locks, limits and the threat scan apply. |
| `GET /hermes/status` | Version, gateway, messaging platform states. |
| `GET /hermes/usage?days=&profile=` | Daily usage, totals, per-model cost. |
| `GET /hermes/weft/config?renew=` | Weft gateway URL + a human token minted once on this Mac (`weft_config.py`); Otto's zero-entry Weft. |
| `GET /hermes/kanban-live?board=` | For each running card: its worker session id, the current step in plain words (`Running tests`, `Building the Mac app`, `Waiting for Apple`) with when it began, the last 5 milestone steps, the agent's last line, the time of the last real activity (heartbeats don't count) and whether the worker pid is alive. Read-only from the board's kanban.db + state.db (`card_live.py`). |

| `GET /hermes/automations` | Every agent's automations. |
| `GET /hermes/automations/{id}/runs` | Run history (agent sessions + script-only runs). |
| `GET /hermes/automations/{id}/output?run=` | Output text of a script-only run. |
| `POST /hermes/automations/{id}/run\|pause\|resume` | Run now / pause / resume. |
| `PATCH /hermes/automations/{id}` | Only name, prompt, schedule, deliver (no scripts, workdir, model). |
| `DELETE /hermes/automations/{id}` | Delete an automation (the only DELETE allowed). |
| `GET/POST /hermes/automations/blueprints` | Templates, and create one from a template. |
| `GET /hermes/automations/targets` | Where results can be sent. |
| `GET /hermes/pairing`, `POST /hermes/pairing/approve\|revoke` | Who may message your bots. |

### Workspaces (Hermes projects) — `workspaces.py`

Otto's workspaces are Hermes projects (`~/.hermes/projects.db`), read and written through the
dashboard's own JSON-RPC (`projects.*`, `session.workspace.move`) via `slash_bridge.py`'s allowlisted
`rpc` op, so the Hermes desktop shows the same projects. No Otto-only store: a chat belongs to a
workspace by its stored working folder, and moving it re-homes the session in Hermes.

| Route | Does |
|---|---|
| `GET /hermes/workspaces[?refresh=1]` | Projects (archived last) + session count, last active, 5 recent chats, every claimed session id. 3 s cache. |
| `POST /hermes/workspaces` | `{name, path, icon?, color?, description?, board_slug?, create_board?}`. Path must be an existing folder (not home). `create_board` makes the kanban board if that slug doesn't exist (existing boards are never modified). |
| `GET /hermes/workspaces/folders` | Repos to pick from (`projects.discover_repos` with a scan of the configured roots). |
| `GET\|PATCH /hermes/workspaces/{id}` | One project / change name, icon, color, description, board (`""` clears), `path` (becomes the primary folder), `create_board`. |
| `POST /hermes/workspaces/{id}/archive` | `{restore?}`. |
| `GET /hermes/workspaces/{id}/sessions` | The project's chats (any source), newest first. |
| `POST /hermes/workspaces/{id}/move-session` | `{session_id}` → `session.workspace.move` into the primary folder. |
| `POST /hermes/workspaces/unassign-session` | `{session_id}` → back to the home folder ("Other chats"). |

Icons are the desktop's codicon names (`device-mobile`, `repo`, …; Otto draws SF Symbols) and colors its
`hsl(h 68% 58%)` swatches, so both apps agree. API-server runs don't take a working folder, so Otto adds a
per-turn instruction naming the workspace folder.

Never exposed: config, env/keys, credentials, plugin installs, raw logs.

### Lid-closed mode (keep the Mac awake while agents work) — `awake.py`

| Route | Does |
|---|---|
| `GET /hermes/awake` | `{installed, setup{action,state,detail,at}, mode, until, holding, hold_until, sleep_disabled, low_power_by_us, agents_working, agents{chats,kanban}, battery{percent,on_battery,charging}, thermal, rules, last{at,reason}}` |
| `POST /hermes/awake` | `{mode: off\|working\|timer, until?: unix time, seconds?}`. 409 when not set up (nothing changes), 400 on bad input, 502 if pmset failed or macOS reverted it. |
| `POST /hermes/awake/setup` | Starts the one-time setup in the background and returns status; `setup.state` goes `running` → `done` \| `cancelled` \| `failed`. 409 while one is already waiting. Refused (403) with an `Origin`/`Sec-Fetch-*` header. |
| `POST /hermes/awake/undo` | Sleep back on (`mode: off`), then removes the rule, the backstop and the journal, the same way. |

Otto for Mac's "Stay awake with lid closed" calls these; the sandboxed app itself changes nothing on the
system and never requests root. The relay runs `sudo -n /usr/bin/pmset -a disablesleep 1|0` (and
`-b lowpowermode 1|0` for the battery/heat rules), allowed by `/etc/sudoers.d/otto-awake` (exactly those four
commands for John's user). The first time John turns the toggle on, `/setup` runs `scripts/install_awake.sh`
with `OTTO_AWAKE_ELEVATE=osascript`: the rule is checked with `visudo -cf`, then installed through
`osascript … with administrator privileges` (prompt: "Otto wants to keep this Mac awake with the lid
closed.", Touch ID or password), and the backstop LaunchAgent is installed as the user with no prompt. Exit 3
= cancelled. On a headless Mac the same scripts run in a terminal and use `sudo` instead.

- `working` is a standing plan: sleep is disabled while a chat turn has a fresh heartbeat (`run_state.py`) or a
  kanban task is `running` with a live worker, and restored 3 min after the last one stops. Each hold has a
  10-min lease renewed every 30 s by the relay's `awake` thread. `timer` holds until `until`, then turns off.
- Journal `~/.hermes/otto-awake/journal.json` (flock'd, atomic): `sleep_disabled_by_us` / `low_power_set_by_us`
  are written BEFORE each pmset call and cleared only after the undo succeeded. After setting, SleepDisabled is
  read back (some macOS builds silently revert it).
- Backstop: `~/Library/LaunchAgents/ai.elier.otto-awake-backstop.plist` runs `awake.py --backstop` every 60 s and
  restores sleep (and Low Power Mode) when the hold's end time has passed and the relay is gone, or the relay is
  15 min past it. Log: `~/.hermes/logs/otto-awake-backstop.log`.
- Rules (`~/.hermes/otto-awake/config.json` overrides `low_power_floor` 40, `end_floor` 10, `thermal_rules`,
  `idle_grace` 180): on battery below 40% Low Power Mode on, below 10% end; serious heat Low Power Mode, critical
  heat end. Low Power Mode is only touched when it was off (`powermode 0`); the user's own or High Power is left.
- CLI: `python3 awake.py --status | --off`. Tests: `test_awake.py` (fake pmset runner + fake clock).
- Adapted from Insomnia (MIT, see THIRD_PARTY_NOTICES.md); its app freezing, Docker, mute, brightness and tmux
  extras are not included. Its hotspot handoff is ported separately (below).

### iPhone hotspot failover (`netwatch.py`, `GET/POST /hermes/hotspot`)

When this Mac's Wi-Fi stops reaching the internet for ~25 s, join the iPhone Personal Hotspot; when the original
Wi-Fi has been visible and working for 2 min, switch back. The work is done by **otto-netwatch** (`netwatch/`, Swift),
a per-user LaunchAgent (`ai.elier.otto-netwatch`, no admin rights) installed by `scripts/install_netwatch.sh`
(undo: `scripts/uninstall_netwatch.sh [--purge]`). The relay only reads/writes its files and starts the installer.

- `GET /hermes/hotspot` → `{installed, running, enabled, hotspot_ssid, setup, link (wifi|hotspot|offline), phase
  (watching|joining|on_hotspot|switching_back|testing), ssid, home_ssid, password_saved, location, last_failover,
  last_switch_back, last_test, last_error, events[], test_pending}`.
- `POST /hermes/hotspot {enabled?, hotspot_ssid?, password?}`: the password is piped to `otto-netwatch
  set-password` on stdin (login Keychain, service `otto-hotspot`, item owned by the helper so it reads it without a
  prompt); `""` clears it. Never written to a file, an argument, a log or a response.
- `POST /hermes/hotspot/test`: writes `test-request`; the helper joins the hotspot, checks the internet, switches back.
- `POST /hermes/hotspot/setup|undo`: runs the install/uninstall script in the background (`setup.state`).
- POSTs refuse browser requests (Origin / Sec-Fetch-* headers), like `/hermes/awake/setup`.
- Files: `~/.hermes/otto-netwatch/{config.json,status.json,netwatch.log}` (0600, dir 0700).
- Online = `http://captive.apple.com/hotspot-detect.html` says Success or `https://1.1.1.1/cdn-cgi/trace` answers
  (a captive portal counts as offline). Hotspot = its SSID or the 172.20.10.1 router every iPhone hotspot uses.
- Backoff: failed joins wait 30 s, 1, 2, 5, then 10 min; a switch back that fails (or whose Wi-Fi dies again within
  5 min) waits 5, 10, 20, 30, then 60 min. Never loops.
- Location Services: macOS hides Wi-Fi names unless it's on (system-wide) and allowed for "Otto Network Helper".
  Without it the helper still fails over, but can't tell which Wi-Fi to go back to, so after 10 min it cycles Wi-Fi
  and lets macOS pick its preferred network (macOS ranks ordinary Wi-Fi above hotspots).
- Tests: `test_netwatch.py`; the state machine: `cd netwatch && swift test` (fake network + clock).
