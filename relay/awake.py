#!/usr/bin/env python3
"""Keep this Mac awake with the lid closed while Hermes agents work ("lid-closed mode").

Otto's Mac App Store app makes no system changes. This companion module, run by the relay with the
user's own rights, does the one privileged thing: `sudo -n /usr/bin/pmset -a disablesleep 1|0`
(plus `pmset -b lowpowermode 1|0` for the battery/heat rules), allowed by a narrow sudoers rule. The
first time John turns on "Stay awake with lid closed" in Otto, Otto calls POST /hermes/awake/setup and
this module runs scripts/install_awake.sh with OTTO_AWAKE_ELEVATE=osascript: the one privileged step
(installing the rule) goes through the standard macOS administrator prompt, the backstop LaunchAgent is
installed as the user. POST /hermes/awake/undo runs uninstall_awake.sh the same way. Without the rule
every change is refused (409).

Approach adapted from Insomnia by Krish Garg (https://github.com/krishhgg/Insomnia, MIT): the four
sudoers-allowed pmset commands, the journal written before every change and cleared only after the
undo succeeded, the read-back of SleepDisabled after setting it (some macOS builds silently revert
it), the launchd backstop that restores sleep from the journal alone, Low Power Mode read from
`powermode` on macOS 27 (2 = High Power, left alone), and the battery/thermal floors. Insomnia's
app freezing, Docker, mute, brightness, hotspot and tmux extras are deliberately left out.

Model
-----
- A *plan* is what John asked for: off, "working" (hold while agents work, a standing setting) or
  "timer" (hold until a time). It lives in the journal so a relay restart keeps it.
- A *hold* is sleep actually disabled. Each hold has an end time (`until`). A working hold is a
  lease the relay renews on every tick while agents work, so if the relay dies the backstop
  restores sleep at most LEASE seconds later. A timer hold ends at the timer.
- The journal records `sleep_disabled_by_us` / `low_power_set_by_us` BEFORE the pmset call and
  clears them only after the undo ran, so a crash at any point leaves enough to restore.

Routes (companion.py): GET /hermes/awake, POST /hermes/awake {mode: off|working|timer, until?},
POST /hermes/awake/setup, POST /hermes/awake/undo (start the job; GET reports `setup` progress).
Backstop: `python3 awake.py --backstop` (launchd ai.elier.otto-awake-backstop, every 60 s).
Stdlib only.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable

HOME = Path(os.environ.get("OTTO_AWAKE_HOME", Path.home() / ".hermes" / "otto-awake"))
SUDO = "/usr/bin/sudo"
PMSET = "/usr/bin/pmset"
SUDOERS_FILE = Path("/etc/sudoers.d/otto-awake")
BACKSTOP_LABEL = "ai.elier.otto-awake-backstop"
BACKSTOP_PLIST = Path.home() / "Library" / "LaunchAgents" / f"{BACKSTOP_LABEL}.plist"
REPO_RELAY = Path(__file__).resolve().parent
SCRIPTS = REPO_RELAY.parent / "scripts"
INSTALL_SCRIPT = SCRIPTS / "install_awake.sh"
UNINSTALL_SCRIPT = SCRIPTS / "uninstall_awake.sh"
SETUP_TIMEOUT = 600.0  # the administrator prompt waits this long for John

LEASE = 600.0          # a working hold's end time is renewed to now + LEASE on every tick
IDLE_GRACE = 180.0     # a working hold ends this long after the last agent stopped
STUCK_GRACE = 900.0    # the backstop also restores if the relay is alive but this far past `until`
MAX_TIMER = 7 * 86400  # longest timer accepted
SETTLE = 2.0           # seconds before reading SleepDisabled back after setting it
TICK = 30.0

DEFAULT_CONFIG = {"low_power_floor": 40, "end_floor": 10, "thermal_rules": True,
                  "idle_grace": IDLE_GRACE}

THERMAL_NAMES = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}


class AwakeError(Exception):
    def __init__(self, status: int, detail: str, extra: dict | None = None):
        super().__init__(detail)
        self.status = status
        self.detail = detail
        self.extra = extra or {}


# --- system probes (each injectable in tests; tests never run real pmset or sudo) -------------

Runner = Callable[[list[str]], "subprocess.CompletedProcess[str]"]


def real_runner(argv: list[str]) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)


ScriptRunner = Callable[[list[str], dict], "subprocess.CompletedProcess[str]"]


def real_script_runner(argv: list[str], env: dict) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, capture_output=True, text=True, timeout=SETUP_TIMEOUT,
                          stdin=subprocess.DEVNULL, env=env)


def parse_sleep_disabled(pmset_g: str) -> bool | None:
    m = re.search(r"^\s*SleepDisabled\s+(\d)\s*$", pmset_g, re.M)
    return None if not m else m.group(1) == "1"


def parse_battery(pmset_batt: str) -> dict | None:
    """`pmset -g batt` → {percent, on_battery, charging} or None on a Mac with no battery."""
    m = re.search(r"InternalBattery[^\t]*\t\s*(\d{1,3})%;\s*([^;]+);", pmset_batt)
    on_battery = "'Battery Power'" in pmset_batt
    if not m:
        if "InternalBattery" in pmset_batt:  # present but unreadable
            return {"percent": None, "on_battery": on_battery, "charging": False}
        return None
    state = m.group(2).strip().lower()
    return {"percent": int(m.group(1)), "on_battery": on_battery,
            "charging": state in ("charging", "charged", "finishing charge") or "ac attached" in state}


def parse_low_power(pmset_custom: str) -> int | None:
    """Battery Power's Low Power Mode from `pmset -g custom`: 0 off, 1 on, 2 High Power (macOS 27
    prints `powermode`, earlier releases `lowpowermode`). None when it can't be read."""
    m = re.search(r"^Battery Power:\n((?:[ \t].*\n?)*)", pmset_custom, re.M)
    if not m:
        return None
    k = re.search(r"^\s*(?:lowpowermode|powermode)\s+(\d)\s*$", m.group(1), re.M)
    return int(k.group(1)) if k else None


def thermal_state() -> int | None:
    """NSProcessInfo.thermalState (0 nominal … 3 critical) through the Objective-C runtime."""
    try:
        import ctypes
        import ctypes.util
        objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc") or "/usr/lib/libobjc.A.dylib")
        ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation")
        objc.objc_getClass.restype = ctypes.c_void_p
        objc.objc_getClass.argtypes = [ctypes.c_char_p]
        objc.sel_registerName.restype = ctypes.c_void_p
        objc.sel_registerName.argtypes = [ctypes.c_char_p]
        addr = ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value
        send_obj = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(addr)
        send_long = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)(addr)
        info = send_obj(objc.objc_getClass(b"NSProcessInfo"), objc.sel_registerName(b"processInfo"))
        if not info:
            return None
        v = int(send_long(info, objc.sel_registerName(b"thermalState")))
        return v if v in THERMAL_NAMES else None
    except Exception:  # noqa: BLE001
        return None


def pid_alive(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def agents_working() -> dict:
    """{working, chats, kanban}: a chat turn with a fresh heartbeat (run_state.py) or a kanban task
    in `running` whose worker process is alive, on any board."""
    chats: list[str] = []
    try:
        sys.path.insert(0, str(REPO_RELAY))
        import run_state
        chats = [r["id"] for r in run_state.running_sessions()]
    except Exception:  # noqa: BLE001
        pass
    kanban = running_kanban_tasks()
    return {"working": bool(chats or kanban), "chats": len(chats), "kanban": len(kanban)}


def running_kanban_tasks(root: Path | None = None) -> list[str]:
    import sqlite3
    root = root or Path(os.environ.get("HERMES_HOME_ROOT", Path.home() / ".hermes"))
    dbs = [root / "kanban.db", *sorted((root / "kanban" / "boards").glob("*/kanban.db"))]
    out: list[str] = []
    for db in dbs:
        if not db.is_file() or db.stat().st_size == 0:
            continue
        try:
            conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1.0)
            try:
                rows = conn.execute("SELECT id, worker_pid FROM tasks WHERE status = 'running'").fetchall()
            finally:
                conn.close()
        except sqlite3.Error:
            continue
        out += [tid for tid, pid in rows if pid_alive(pid)]
    return out


# --- journal ------------------------------------------------------------------------------------

def empty_journal() -> dict:
    return {"version": 1, "plan": {"mode": "off"}, "hold": None, "sleep_disabled_by_us": False,
            "low_power_set_by_us": False, "last": None}


class Journal:
    """`journal.json` under an flock'd `.lock`, written atomically (temp file + rename)."""

    def __init__(self, home: Path = HOME):
        self.home = home
        self.path = home / "journal.json"
        self.lock_path = home / ".lock"

    @contextmanager
    def locked(self):
        self.home.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def read(self) -> dict:
        try:
            data = json.loads(self.path.read_text())
        except FileNotFoundError:
            return empty_journal()
        except (OSError, ValueError):
            # Unreadable journal: assume the worst (we may have disabled sleep) so it gets undone.
            j = empty_journal()
            j.update(sleep_disabled_by_us=True, low_power_set_by_us=True, last={"reason": "journal unreadable"})
            return j
        if not isinstance(data, dict):
            return self.read_corrupt()
        j = empty_journal()
        j.update({k: v for k, v in data.items() if k in j})
        return j

    def read_corrupt(self) -> dict:
        j = empty_journal()
        j.update(sleep_disabled_by_us=True, low_power_set_by_us=True, last={"reason": "journal unreadable"})
        return j

    def write(self, j: dict) -> None:
        self.home.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, tmp = tempfile.mkstemp(dir=self.home, prefix=".journal.")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(j, f, indent=1, sort_keys=True)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


def load_config(home: Path = HOME) -> dict:
    cfg = dict(DEFAULT_CONFIG)
    try:
        data = json.loads((home / "config.json").read_text())
        if isinstance(data, dict):
            for k in DEFAULT_CONFIG:
                v = data.get(k)
                if isinstance(v, bool) == isinstance(DEFAULT_CONFIG[k], bool) and isinstance(v, (int, float)):
                    cfg[k] = v
    except (OSError, ValueError):
        pass
    cfg["low_power_floor"] = max(0, min(100, int(cfg["low_power_floor"])))
    cfg["end_floor"] = max(0, min(100, int(cfg["end_floor"])))
    if cfg["end_floor"] and cfg["end_floor"] >= cfg["low_power_floor"]:
        cfg["low_power_floor"] = min(100, cfg["end_floor"] + 1)  # floors never cross
    return cfg


def floor_rules(battery: dict | None, thermal: int | None, cfg: dict, battery_misses: int = 0) -> str | None:
    """Spec: battery below end_floor on battery → end; critical heat → end; serious heat or battery
    below low_power_floor on battery → Low Power Mode. Returns "end:<why>", "lowpower:<why>" or None."""
    if battery and battery.get("on_battery"):
        p = battery.get("percent")
        if p is not None and cfg["end_floor"] and p < cfg["end_floor"]:
            return f"end:battery below {cfg['end_floor']}%"
        if p is None and battery_misses >= 2 and cfg["end_floor"]:
            return "end:battery level unreadable"
    if cfg["thermal_rules"] and thermal == 3:
        return "end:Mac is critically hot"
    if cfg["thermal_rules"] and thermal == 2:
        return "lowpower:Mac is hot"
    if battery and battery.get("on_battery") and battery.get("percent") is not None \
            and battery["percent"] < cfg["low_power_floor"]:
        return f"lowpower:battery below {cfg['low_power_floor']}%"
    return None


# --- the controller -----------------------------------------------------------------------------

class Awake:
    def __init__(self, home: Path = HOME, runner: Runner = real_runner, clock: Callable[[], float] = time.time,
                 sleep: Callable[[float], None] = time.sleep, agents: Callable[[], dict] = agents_working,
                 thermal: Callable[[], int | None] = thermal_state, pid: int | None = None,
                 alive: Callable[[Any], bool] = pid_alive, scripts: ScriptRunner = real_script_runner,
                 script_env: dict | None = None):
        self.journal = Journal(home)
        self.home = home
        self.run = runner
        self.now = clock
        self.sleep = sleep
        self.agents = agents
        self.thermal = thermal
        self.pid = pid if pid is not None else os.getpid()
        self.alive = alive
        self._installed: tuple[float, bool] | None = None
        self._battery_misses = 0
        self._mutex = threading.RLock()
        self.scripts = scripts
        self.script_env = script_env or {}
        self._job: dict | None = None
        self._job_thread: threading.Thread | None = None

    # --- probes ---

    def installed(self, force: bool = False) -> bool:
        """The sudoers rule lets this user run the restore command without a password. `sudo -n -l
        <cmd>` only checks; it runs nothing."""
        now = self.now()
        if not force and self._installed and now - self._installed[0] < 30:
            return self._installed[1]
        try:
            ok = self.run([SUDO, "-n", "-l", PMSET, "-a", "disablesleep", "0"]).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            ok = False
        self._installed = (now, ok)
        return ok

    def sleep_disabled(self) -> bool | None:
        try:
            r = self.run([PMSET, "-g"])
        except (OSError, subprocess.TimeoutExpired):
            return None
        return parse_sleep_disabled(r.stdout) if r.returncode == 0 else None

    def battery(self) -> dict | None:
        try:
            r = self.run([PMSET, "-g", "batt"])
            b = parse_battery(r.stdout if r.returncode == 0 else "InternalBattery")
        except (OSError, subprocess.TimeoutExpired):
            b = {"percent": None, "on_battery": False, "charging": False}
        self._battery_misses = self._battery_misses + 1 if b and b.get("percent") is None else 0
        return b

    def low_power(self) -> int | None:
        try:
            r = self.run([PMSET, "-g", "custom"])
        except (OSError, subprocess.TimeoutExpired):
            return None
        return parse_low_power(r.stdout) if r.returncode == 0 else None

    def _pmset(self, *args: str) -> tuple[bool, str]:
        try:
            r = self.run([SUDO, "-n", PMSET, *args])
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, str(e)
        return r.returncode == 0, (r.stderr or r.stdout or "").strip()[:300]

    # --- transitions (call with the journal lock held) ---

    def _disable_sleep(self, j: dict) -> None:
        j["sleep_disabled_by_us"] = True
        self.journal.write(j)  # journal BEFORE the change
        ok, err = self._pmset("-a", "disablesleep", "1")
        if not ok:
            self._restore(j, "pmset refused: " + err)
            raise AwakeError(502, f"pmset -a disablesleep 1 failed: {err}" if err else "pmset failed")
        self.sleep(SETTLE)
        if self.sleep_disabled() is not True:
            self._restore(j, "macOS set SleepDisabled back to 0")
            raise AwakeError(502, "macOS turned sleep back on right away, so a closed lid would still sleep this Mac.")

    def _restore(self, j: dict, reason: str) -> bool:
        """Undo everything the journal says we changed; clear each flag only after its undo ran."""
        clean = True
        if j.get("low_power_set_by_us"):
            ok, _ = self._pmset("-b", "lowpowermode", "0")
            if ok:
                j["low_power_set_by_us"] = False
            clean &= ok
        if j.get("sleep_disabled_by_us"):
            ok, _ = self._pmset("-a", "disablesleep", "0")
            if ok:
                j["sleep_disabled_by_us"] = False
            clean &= ok
        j["hold"] = None
        j["last"] = {"at": self.now(), "reason": reason, "clean": clean}
        self.journal.write(j)
        return clean

    def _set_low_power(self, j: dict, on: bool, why: str) -> None:
        if on:
            if j.get("low_power_set_by_us"):
                return
            if self.low_power() != 0:  # already on (the user's), High Power (2), or unreadable: leave it
                return
            j["low_power_set_by_us"] = True
            j["low_power_reason"] = why
            self.journal.write(j)
            ok, _ = self._pmset("-b", "lowpowermode", "1")
            if not ok:
                j["low_power_set_by_us"] = False
                self.journal.write(j)
        elif j.get("low_power_set_by_us"):
            ok, _ = self._pmset("-b", "lowpowermode", "0")
            if ok:
                j["low_power_set_by_us"] = False
                j.pop("low_power_reason", None)
                self.journal.write(j)

    def _start_hold(self, j: dict, until: float) -> None:
        j["hold"] = {"until": until, "started_at": self.now(), "relay_pid": self.pid,
                     "last_working_at": self.now()}
        if not j.get("sleep_disabled_by_us"):
            self._disable_sleep(j)  # writes the journal first
        else:
            self.journal.write(j)

    # --- API ---

    def status(self) -> dict:
        with self._mutex, self.journal.locked():
            j = self.journal.read()
        installed = self.installed()
        battery = self.battery()
        thermal = self.thermal()
        agents = self.agents()
        hold = j.get("hold")
        return {
            "installed": installed,
            "setup": dict(self._job) if self._job else None,
            "mode": j["plan"].get("mode", "off"),
            "until": j["plan"].get("until"),
            "holding": bool(hold) and bool(j.get("sleep_disabled_by_us")),
            "hold_until": hold.get("until") if hold else None,
            "sleep_disabled": self.sleep_disabled(),
            "low_power_by_us": bool(j.get("low_power_set_by_us")),
            "agents_working": agents["working"],
            "agents": {"chats": agents["chats"], "kanban": agents["kanban"]},
            "battery": battery,
            "thermal": THERMAL_NAMES.get(thermal) if thermal is not None else None,
            "rules": load_config(self.home),
            "last": j.get("last"),
            "now": self.now(),
        }

    def set_plan(self, body: dict) -> dict:
        mode = body.get("mode")
        if mode not in ("off", "working", "timer"):
            raise AwakeError(400, "mode must be off, working or timer")
        until = None
        if mode == "timer":
            until = body.get("until")
            if isinstance(body.get("seconds"), (int, float)) and not isinstance(body.get("seconds"), bool):
                until = self.now() + float(body["seconds"])
            if isinstance(until, bool) or not isinstance(until, (int, float)):
                raise AwakeError(400, "timer needs until (unix time) or seconds")
            until = float(until)
            if until <= self.now() + 30:
                raise AwakeError(400, "until must be at least a minute from now")
            until = min(until, self.now() + MAX_TIMER)
        if mode != "off" and not self.installed(force=True):
            raise AwakeError(409, "Lid-closed mode isn't set up on this Mac yet.")
        with self._mutex, self.journal.locked():
            j = self.journal.read()
            j["plan"] = {"mode": mode, **({"until": until} if until else {}), "set_at": self.now()}
            self.journal.write(j)
            if mode == "off":
                if j.get("sleep_disabled_by_us") or j.get("low_power_set_by_us") or j.get("hold"):
                    self._restore(j, "turned off")
            elif mode == "timer":
                self._start_hold(j, until)
            else:
                self._tick_locked(j)
        return self.status()

    # --- one-time setup / undo (from Otto: the relay shows the system administrator prompt) ---

    def start_setup(self, action: str) -> dict:
        """Starts install_awake.sh (action "setup") or uninstall_awake.sh ("undo") in the background and
        returns status at once; `status()["setup"]` reports {action, state: running|done|cancelled|failed,
        detail, at}. The scripts run as this user with OTTO_AWAKE_ELEVATE=osascript, so the privileged
        step is one macOS administrator prompt (Touch ID or password) on this Mac's screen."""
        if action not in ("setup", "undo"):
            raise AwakeError(400, "action must be setup or undo")
        with self._mutex:
            if self._job and self._job.get("state") == "running":
                raise AwakeError(409, "Otto is already waiting for your approval on this Mac.")
            if action == "undo":
                # Sleep back on first, while the rule still allows it without a prompt.
                if self.installed(force=True):
                    try:
                        self.set_plan({"mode": "off"})
                    except AwakeError:
                        pass
            self._job = {"action": action, "state": "running", "detail": None, "at": self.now()}
            self._job_thread = threading.Thread(target=self._run_setup, args=(action,), daemon=True,
                                                name=f"awake-{action}")
            self._job_thread.start()
        return self.status()

    def wait_setup(self, timeout: float | None = None) -> None:
        """Tests: wait for the background job."""
        if self._job_thread:
            self._job_thread.join(timeout)

    def _run_setup(self, action: str) -> None:
        script = INSTALL_SCRIPT if action == "setup" else UNINSTALL_SCRIPT
        env = {**os.environ, "OTTO_AWAKE_ELEVATE": "osascript", **self.script_env}
        if self.home != HOME:
            env.setdefault("OTTO_AWAKE_HOME", str(self.home))
        try:
            r = self.scripts(["/bin/bash", str(script)], env)
            code, out = r.returncode, ((r.stderr or "").strip() or (r.stdout or "").strip())
        except subprocess.TimeoutExpired:
            code, out = 3, "No one answered the prompt."
        except OSError as e:
            code, out = 1, str(e)
        if code == 0:
            state, detail = "done", ("Lid-closed mode is set up." if action == "setup"
                                     else "Lid-closed setup removed. This Mac sleeps normally.")
        elif code == 3:
            state, detail = "cancelled", "Cancelled. Nothing was changed."
        else:
            state, detail = "failed", (out.splitlines()[-1] if out else "Setup failed.")[:300]
        self._installed = None
        with self._mutex:
            self._job = {"action": action, "state": state, "detail": detail, "at": self.now()}
        print(f"awake: {action} {state}: {detail}", file=sys.stderr, flush=True)

    def tick(self) -> None:
        with self._mutex, self.journal.locked():
            self._tick_locked(self.journal.read())

    def _tick_locked(self, j: dict) -> None:
        now = self.now()
        plan = j.get("plan") or {"mode": "off"}
        mode = plan.get("mode", "off")
        hold = j.get("hold")
        cfg = load_config(self.home)

        if mode == "off":
            if hold or j.get("sleep_disabled_by_us") or j.get("low_power_set_by_us"):
                self._restore(j, "off")
            return

        if mode == "timer" and now >= float(plan.get("until") or 0):
            j["plan"] = {"mode": "off"}
            self._restore(j, "timer ended")
            return

        battery = self.battery()
        rule = floor_rules(battery, self.thermal(), cfg, self._battery_misses)
        if rule and rule.startswith("end:"):
            j["plan"] = {"mode": "off"}
            self._restore(j, rule[4:])
            return

        if mode == "working":
            working = self.agents()["working"]
            if hold:
                last = float(hold.get("last_working_at") or hold.get("started_at") or now)
                if working:
                    last = now
                if not working and now - last >= float(cfg["idle_grace"]):
                    self._restore(j, "agents finished")
                    return
                hold.update(until=now + LEASE, relay_pid=self.pid, last_working_at=last)
                if not j.get("sleep_disabled_by_us"):  # e.g. a failed earlier attempt
                    try:
                        self._disable_sleep(j)
                    except AwakeError:
                        return
                self.journal.write(j)
            elif working:
                try:
                    self._start_hold(j, now + LEASE)
                except AwakeError:
                    return
            else:
                return
        elif hold:
            hold["relay_pid"] = self.pid
            self.journal.write(j)
        elif mode == "timer":
            try:
                self._start_hold(j, float(plan["until"]))
            except AwakeError:
                return

        if j.get("hold"):
            want_low = bool(rule and rule.startswith("lowpower:"))
            self._set_low_power(j, want_low, rule[9:] if want_low and rule else "")

    def recover_on_start(self) -> None:
        """Relay start: a hold left by a previous relay process is adopted (plan still on) or undone."""
        with self._mutex, self.journal.locked():
            j = self.journal.read()
            if (j.get("plan") or {}).get("mode", "off") == "off" and \
                    (j.get("hold") or j.get("sleep_disabled_by_us") or j.get("low_power_set_by_us")):
                self._restore(j, "recovered at relay start")
                return
            self._tick_locked(j)

    def run_forever(self, stop: threading.Event | None = None) -> None:
        stop = stop or threading.Event()
        try:
            self.recover_on_start()
        except Exception as e:  # noqa: BLE001
            print(f"awake: recovery failed: {e}", file=sys.stderr, flush=True)
        while not stop.wait(TICK):
            try:
                self.tick()
            except Exception as e:  # noqa: BLE001
                print(f"awake: tick failed: {e}", file=sys.stderr, flush=True)


def backstop(home: Path = HOME, runner: Runner = real_runner, clock: Callable[[], float] = time.time,
             alive: Callable[[Any], bool] = pid_alive) -> str:
    """launchd, every minute, no relay needed: restore sleep from the journal alone when the hold's
    end time has passed and the relay that owns it is gone (or stuck far past the end)."""
    a = Awake(home=home, runner=runner, clock=clock, sleep=lambda s: None, agents=lambda: {"working": False},
              thermal=lambda: None, pid=0, alive=alive)
    with a.journal.locked():
        j = a.journal.read()
        dirty = bool(j.get("sleep_disabled_by_us") or j.get("low_power_set_by_us"))
        if not dirty:
            return "clean"
        hold = j.get("hold") or {}
        now = clock()
        until = hold.get("until")
        owner = hold.get("relay_pid")
        expired = not isinstance(until, (int, float)) or now >= float(until)
        if not expired:
            return "hold active"
        if alive(owner) and now < float(until) + STUCK_GRACE:
            return "relay alive, waiting"
        if (j.get("plan") or {}).get("mode") == "timer":
            j["plan"] = {"mode": "off"}
        clean = a._restore(j, "backstop: relay gone after end time")
        return "restored" if clean else "restore failed"


def main(argv: list[str]) -> int:
    if argv[1:2] == ["--backstop"]:
        result = backstop()
        if result not in ("clean", "hold active", "relay alive, waiting"):
            print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} backstop: {result}", flush=True)
        return 0 if result != "restore failed" else 1
    if argv[1:2] == ["--status"]:
        print(json.dumps(Awake().status(), indent=1))
        return 0
    if argv[1:2] == ["--off"]:
        print(json.dumps(Awake().set_plan({"mode": "off"}), indent=1))
        return 0
    print("usage: awake.py --backstop | --status | --off", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
