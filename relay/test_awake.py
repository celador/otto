"""Lid-closed mode (awake.py): routes, journal/recovery, backstop, battery and heat rules.

Never runs real pmset or sudo: every test uses FakeMac, a fake command runner with a fake clock.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import awake  # noqa: E402
import companion  # noqa: E402

PMSET_G = "System-wide power settings:\n SleepDisabled\t\t{sd}\nCurrently in use:\n sleep 1\n"
BATT = ("Now drawing from '{src}'\n -InternalBattery-0 (id=1)\t{pct}%; {state}; 3:00 remaining present: true\n")
CUSTOM = "Battery Power:\n Sleep On Power Button 1\n powermode            {lp}\n sleep 1\nAC Power:\n powermode 0\n"


class FakeMac:
    """pmset/sudo as seen through the runner; records every command."""

    def __init__(self, installed=True, revert=False):
        self.installed = installed
        self.sleep_disabled = 0
        self.low_power = 0
        self.battery = (80, False)  # percent, on battery
        self.revert = revert  # macOS sets SleepDisabled back to 0 right after
        self.calls: list[list[str]] = []
        self.t = 1_000_000.0
        self.fail_restore = False

    def clock(self):
        return self.t

    def sleep(self, s):
        self.t += s

    def run(self, argv):
        self.calls.append(list(argv))
        ok = lambda out="": subprocess.CompletedProcess(argv, 0, out, "")  # noqa: E731
        bad = lambda err: subprocess.CompletedProcess(argv, 1, "", err)  # noqa: E731
        if argv[:3] == [awake.SUDO, "-n", "-l"]:
            return ok(" ".join(argv[3:])) if self.installed else bad("sudo: a password is required")
        if argv[:2] == [awake.SUDO, "-n"]:
            if not self.installed:
                return bad("sudo: a password is required")
            cmd = argv[2:]
            assert cmd[0] == awake.PMSET
            if cmd[1:] == ["-a", "disablesleep", "1"]:
                self.sleep_disabled = 0 if self.revert else 1
                return ok()
            if cmd[1:] == ["-a", "disablesleep", "0"]:
                if self.fail_restore:
                    return bad("pmset: busy")
                self.sleep_disabled = 0
                return ok()
            if cmd[1:3] == ["-b", "lowpowermode"]:
                self.low_power = int(cmd[3])
                return ok()
            raise AssertionError(f"unexpected sudo command {argv}")
        if argv == [awake.PMSET, "-g"]:
            return ok(PMSET_G.format(sd=self.sleep_disabled))
        if argv == [awake.PMSET, "-g", "batt"]:
            pct, on_batt = self.battery
            return ok(BATT.format(src="Battery Power" if on_batt else "AC Power", pct=pct,
                                  state="discharging" if on_batt else "charging"))
        if argv == [awake.PMSET, "-g", "custom"]:
            return ok(CUSTOM.format(lp=self.low_power))
        raise AssertionError(f"unexpected command {argv}")

    def privileged(self):
        return [c[2:] for c in self.calls if c[:2] == [awake.SUDO, "-n"] and c[2] != "-l"]


def make(tmp_path, mac=None, working=True, thermal=0, pid=4242, alive=lambda p: True):
    mac = mac or FakeMac()
    state = {"working": working, "thermal": thermal}
    a = awake.Awake(home=tmp_path, runner=mac.run, clock=mac.clock, sleep=mac.sleep,
                    agents=lambda: {"working": state["working"], "chats": int(state["working"]), "kanban": 0},
                    thermal=lambda: state["thermal"], pid=pid, alive=alive)
    return a, mac, state


def journal(tmp_path):
    return json.loads((tmp_path / "journal.json").read_text())


# --- parsing ---

def test_parsers():
    assert awake.parse_sleep_disabled(PMSET_G.format(sd=1)) is True
    assert awake.parse_sleep_disabled(PMSET_G.format(sd=0)) is False
    assert awake.parse_sleep_disabled("nothing") is None
    b = awake.parse_battery(BATT.format(src="Battery Power", pct=37, state="discharging"))
    assert b == {"percent": 37, "on_battery": True, "charging": False}
    assert awake.parse_battery("Now drawing from 'AC Power'\n") is None  # desktop: no battery, no floor
    real = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=37355619)\t80%; AC attached; not charging present: true\n"
    assert awake.parse_battery(real)["on_battery"] is False
    assert awake.parse_low_power(CUSTOM.format(lp=0)) == 0
    assert awake.parse_low_power(CUSTOM.format(lp=2)) == 2
    assert awake.parse_low_power("Battery Power:\n lowpowermode 1\nAC Power:\n") == 1
    assert awake.parse_low_power("AC Power:\n powermode 0\n") is None


# --- not installed: the toggle explains setup and changes nothing ---

def test_not_installed_refuses_and_changes_nothing(tmp_path):
    a, mac, _ = make(tmp_path, FakeMac(installed=False))
    s = a.status()
    assert s["installed"] is False and s["setup"] is None and "setup_command" not in s
    with pytest.raises(awake.AwakeError) as e:
        a.set_plan({"mode": "working"})
    assert e.value.status == 409
    assert mac.privileged() == []
    assert a.set_plan({"mode": "off"})["mode"] == "off"  # off is always allowed
    assert mac.privileged() == []


# --- working mode ---

def test_working_mode_holds_while_agents_work_and_releases_after_grace(tmp_path):
    a, mac, st = make(tmp_path)
    s = a.set_plan({"mode": "working"})
    assert s["holding"] is True and mac.sleep_disabled == 1
    j = journal(tmp_path)
    assert j["sleep_disabled_by_us"] is True and j["hold"]["relay_pid"] == 4242
    assert j["hold"]["until"] == pytest.approx(mac.t + awake.LEASE, abs=5)
    # lease renews while working
    mac.t += 400
    a.tick()
    assert journal(tmp_path)["hold"]["until"] == pytest.approx(mac.t + awake.LEASE)
    # agents stop: hold stays for the grace, then sleep is restored; plan stays armed
    st["working"] = False
    mac.t += 60
    a.tick()
    assert mac.sleep_disabled == 1
    mac.t += awake.IDLE_GRACE
    a.tick()
    assert mac.sleep_disabled == 0
    j = journal(tmp_path)
    assert j["hold"] is None and j["sleep_disabled_by_us"] is False and j["plan"]["mode"] == "working"
    assert j["last"]["reason"] == "agents finished"
    # the next agent run re-arms it
    st["working"] = True
    a.tick()
    assert mac.sleep_disabled == 1 and journal(tmp_path)["hold"]


def test_working_mode_with_nothing_running_waits(tmp_path):
    a, mac, _ = make(tmp_path, working=False)
    s = a.set_plan({"mode": "working"})
    assert s["mode"] == "working" and s["holding"] is False and mac.privileged() == []


def test_off_restores(tmp_path):
    a, mac, _ = make(tmp_path)
    a.set_plan({"mode": "working"})
    s = a.set_plan({"mode": "off"})
    assert mac.sleep_disabled == 0 and s["holding"] is False and s["mode"] == "off"
    assert mac.privileged()[-1] == [awake.PMSET, "-a", "disablesleep", "0"]


# --- timer mode ---

def test_timer_holds_until_end_then_turns_off(tmp_path):
    a, mac, st = make(tmp_path, working=False)
    s = a.set_plan({"mode": "timer", "seconds": 3600})
    assert s["holding"] and mac.sleep_disabled == 1
    until = journal(tmp_path)["hold"]["until"]
    assert until == pytest.approx(mac.t + 3600 - awake.SETTLE, abs=5)
    mac.t += 1800
    a.tick()
    assert mac.sleep_disabled == 1
    mac.t = until + 1
    a.tick()
    j = journal(tmp_path)
    assert mac.sleep_disabled == 0 and j["plan"]["mode"] == "off" and j["last"]["reason"] == "timer ended"


def test_timer_validation(tmp_path):
    a, mac, _ = make(tmp_path)
    for body in ({"mode": "timer"}, {"mode": "timer", "until": mac.t + 5}, {"mode": "nap"},
                 {"mode": "timer", "until": True}):
        with pytest.raises(awake.AwakeError) as e:
            a.set_plan(body)
        assert e.value.status == 400
    a.set_plan({"mode": "timer", "until": mac.t + 30 * 86400})
    assert journal(tmp_path)["plan"]["until"] <= mac.t + awake.MAX_TIMER


# --- journal before change, read-back, failures ---

def test_journal_written_before_pmset(tmp_path):
    seen = {}
    mac = FakeMac()
    real = mac.run

    def run(argv):
        if argv[2:] == [awake.PMSET, "-a", "disablesleep", "1"]:
            seen["journal"] = journal(tmp_path)
        return real(argv)
    a, _, _ = make(tmp_path, mac)
    a.run = run
    a.set_plan({"mode": "working"})
    assert seen["journal"]["sleep_disabled_by_us"] is True


def test_revert_by_macos_is_reported_and_restored(tmp_path):
    a, mac, _ = make(tmp_path, FakeMac(revert=True))
    with pytest.raises(awake.AwakeError) as e:
        a.set_plan({"mode": "timer", "seconds": 600})
    assert e.value.status == 502 and "sleep back on" in e.value.detail
    j = journal(tmp_path)
    assert j["sleep_disabled_by_us"] is False and j["hold"] is None
    assert mac.privileged()[-1] == [awake.PMSET, "-a", "disablesleep", "0"]


def test_failed_restore_keeps_flag_for_retry(tmp_path):
    a, mac, _ = make(tmp_path)
    a.set_plan({"mode": "working"})
    mac.fail_restore = True
    a.set_plan({"mode": "off"})
    assert journal(tmp_path)["sleep_disabled_by_us"] is True  # still dirty: the backstop/next tick retries
    mac.fail_restore = False
    a.tick()
    assert journal(tmp_path)["sleep_disabled_by_us"] is False and mac.sleep_disabled == 0


def test_corrupt_journal_is_treated_as_dirty(tmp_path):
    (tmp_path / "journal.json").write_text("{nope")
    a, mac, _ = make(tmp_path)
    a.tick()  # plan reads as off + dirty → restore
    assert [awake.PMSET, "-a", "disablesleep", "0"] in mac.privileged()


def test_relay_restart_adopts_or_undoes(tmp_path):
    a, mac, _ = make(tmp_path)
    a.set_plan({"mode": "working"})
    b, _, _ = make(tmp_path, mac, pid=5555)  # new relay process, plan still on
    b.recover_on_start()
    assert journal(tmp_path)["hold"]["relay_pid"] == 5555 and mac.sleep_disabled == 1
    # plan off but a hold left behind (crash between writes): undone
    j = journal(tmp_path)
    j["plan"] = {"mode": "off"}
    (tmp_path / "journal.json").write_text(json.dumps(j))
    b.recover_on_start()
    assert mac.sleep_disabled == 0 and journal(tmp_path)["hold"] is None


# --- backstop ---

def test_backstop_waits_while_hold_is_valid_or_relay_alive(tmp_path):
    a, mac, _ = make(tmp_path)
    a.set_plan({"mode": "working"})
    assert awake.backstop(tmp_path, mac.run, mac.clock, alive=lambda p: False) == "hold active"
    mac.t += awake.LEASE + 1
    assert awake.backstop(tmp_path, mac.run, mac.clock, alive=lambda p: p == 4242) == "relay alive, waiting"
    assert mac.sleep_disabled == 1


def test_backstop_restores_after_end_when_relay_gone(tmp_path):
    a, mac, _ = make(tmp_path)
    a.set_plan({"mode": "timer", "seconds": 600})
    mac.t += 601
    assert awake.backstop(tmp_path, mac.run, mac.clock, alive=lambda p: False) == "restored"
    j = journal(tmp_path)
    assert mac.sleep_disabled == 0 and j["sleep_disabled_by_us"] is False and j["plan"]["mode"] == "off"
    assert awake.backstop(tmp_path, mac.run, mac.clock, alive=lambda p: False) == "clean"


def test_backstop_restores_stuck_relay(tmp_path):
    a, mac, _ = make(tmp_path)
    a.set_plan({"mode": "working"})
    mac.t += awake.LEASE + awake.STUCK_GRACE + 1
    assert awake.backstop(tmp_path, mac.run, mac.clock, alive=lambda p: True) == "restored"
    assert mac.sleep_disabled == 0


def test_backstop_restores_low_power_too(tmp_path):
    a, mac, _ = make(tmp_path)
    mac.battery = (30, True)
    a.set_plan({"mode": "working"})
    assert mac.low_power == 1
    mac.t += awake.LEASE + 1
    awake.backstop(tmp_path, mac.run, mac.clock, alive=lambda p: False)
    assert mac.low_power == 0 and mac.sleep_disabled == 0


# --- battery and heat rules ---

def test_floor_rules_table():
    cfg = dict(awake.DEFAULT_CONFIG)
    onb = lambda p: {"percent": p, "on_battery": True, "charging": False}  # noqa: E731
    assert awake.floor_rules(onb(9), 0, cfg).startswith("end:")
    assert awake.floor_rules(onb(39), 0, cfg).startswith("lowpower:")
    assert awake.floor_rules(onb(40), 0, cfg) is None
    assert awake.floor_rules({"percent": 5, "on_battery": False, "charging": True}, 0, cfg) is None
    assert awake.floor_rules(None, 3, cfg) == "end:Mac is critically hot"
    assert awake.floor_rules(None, 2, cfg) == "lowpower:Mac is hot"
    assert awake.floor_rules(onb(None), 0, cfg, battery_misses=2).startswith("end:")
    assert awake.floor_rules(onb(None), 0, cfg, battery_misses=1) is None
    assert awake.floor_rules(None, 3, {**cfg, "thermal_rules": False}) is None
    assert awake.floor_rules(onb(5), 0, {**cfg, "end_floor": 0}).startswith("lowpower:")


def test_config_floors_never_cross(tmp_path):
    (tmp_path / "config.json").write_text(json.dumps({"low_power_floor": 20, "end_floor": 30}))
    cfg = awake.load_config(tmp_path)
    assert cfg["end_floor"] == 30 and cfg["low_power_floor"] == 31


def test_low_battery_low_power_then_end(tmp_path):
    a, mac, _ = make(tmp_path)
    mac.battery = (35, True)
    a.set_plan({"mode": "working"})
    assert mac.low_power == 1 and journal(tmp_path)["low_power_set_by_us"] is True
    mac.battery = (60, False)  # charger in: Low Power Mode off again, hold stays
    a.tick()
    assert mac.low_power == 0 and mac.sleep_disabled == 1
    mac.battery = (35, True)
    a.tick()
    mac.battery = (9, True)
    a.tick()
    j = journal(tmp_path)
    assert mac.sleep_disabled == 0 and mac.low_power == 0 and j["plan"]["mode"] == "off"
    assert "battery below 10%" in j["last"]["reason"]


def test_users_own_low_power_or_high_power_left_alone(tmp_path):
    a, mac, _ = make(tmp_path)
    mac.battery = (30, True)
    mac.low_power = 2  # High Power
    a.set_plan({"mode": "working"})
    assert mac.low_power == 2 and journal(tmp_path)["low_power_set_by_us"] is False
    a.set_plan({"mode": "off"})
    assert mac.low_power == 2 and not any("lowpowermode" in c for c in mac.privileged())


def test_critical_heat_ends_session(tmp_path):
    a, mac, st = make(tmp_path)
    a.set_plan({"mode": "working"})
    st["thermal"] = 2
    a.tick()
    assert mac.low_power == 1 and mac.sleep_disabled == 1
    st["thermal"] = 3
    a.tick()
    j = journal(tmp_path)
    assert mac.sleep_disabled == 0 and j["plan"]["mode"] == "off" and j["last"]["reason"] == "Mac is critically hot"


# --- routes (companion.py), same auth path as every /hermes route ---

def test_routes(tmp_path):
    a, mac, _ = make(tmp_path)
    companion.Companion._awake = a
    try:
        c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
        s = c.handle("GET", "/awake", {}, {})
        assert s["installed"] is True and s["mode"] == "off" and s["agents_working"] is True
        s = c.handle("POST", "/awake", {}, {"mode": "timer", "seconds": 900})
        assert s["mode"] == "timer" and s["holding"] is True and s["sleep_disabled"] is True
        with pytest.raises(companion.RouteError) as e:
            c.handle("POST", "/awake", {}, {"mode": "forever"})
        assert e.value.status == 400
        with pytest.raises(companion.RouteError) as e:
            c.handle("DELETE", "/awake", {}, {})
        assert e.value.status == 405
        s = c.handle("POST", "/awake", {}, {"mode": "off"})
        assert s["sleep_disabled"] is False
        mac.installed = False
        a._installed = None
        with pytest.raises(companion.RouteError) as e:
            c.handle("POST", "/awake", {}, {"mode": "working"})
        assert e.value.status == 409
    finally:
        companion.Companion._awake = None


def test_kanban_running_tasks(tmp_path):
    import sqlite3
    board = tmp_path / "kanban" / "boards" / "otto"
    board.mkdir(parents=True)
    for db in (tmp_path / "kanban.db", board / "kanban.db"):
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE tasks (id TEXT, status TEXT, worker_pid INTEGER)")
        conn.execute("INSERT INTO tasks VALUES ('t_live', 'running', ?)", (os.getpid(),))
        conn.execute("INSERT INTO tasks VALUES ('t_dead', 'running', 999999)")
        conn.execute("INSERT INTO tasks VALUES ('t_done', 'done', ?)", (os.getpid(),))
        conn.commit()
        conn.close()
    assert awake.running_kanban_tasks(tmp_path) == ["t_live", "t_live"]


# --- install / uninstall scripts (dry run: nothing privileged runs) ---

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def test_install_and_uninstall_scripts_dry_run(tmp_path):
    env = {**os.environ, "OTTO_AWAKE_DRY_RUN": "1", "OTTO_AWAKE_DRY_ROOT": str(tmp_path)}
    r = subprocess.run(["bash", str(SCRIPTS / "install_awake.sh")], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    rule = (tmp_path / "etc/sudoers.d/otto-awake").read_text()
    allowed = rule.strip().splitlines()[-1].split("NOPASSWD: ", 1)[1].split(", ")
    assert allowed == ["/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0",
                       "/usr/bin/pmset -b lowpowermode 1", "/usr/bin/pmset -b lowpowermode 0"]
    assert rule.strip().splitlines()[-1].startswith(f"{os.environ.get('USER') or subprocess.getoutput('id -un')} ALL=(root)")
    v = subprocess.run(["/usr/sbin/visudo", "-cf", str(tmp_path / "etc/sudoers.d/otto-awake")], capture_output=True)
    assert v.returncode == 0
    plist = tmp_path / str(Path.home()).lstrip("/") / "Library/LaunchAgents/ai.elier.otto-awake-backstop.plist"
    text = plist.read_text()
    assert "<integer>60</integer>" in text and "awake.py</string>" in text and "--backstop" in text
    assert "DRY: /bin/launchctl bootstrap" in r.stdout
    state = tmp_path / "state"
    state.mkdir()
    (state / "journal.json").write_text('{"low_power_set_by_us": true}')
    r = subprocess.run(["bash", str(SCRIPTS / "uninstall_awake.sh")],
                       env={**env, "OTTO_AWAKE_HOME": "/state"}, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "DRY: sudo /usr/bin/pmset -a disablesleep 0" in r.stdout
    assert "DRY: sudo /usr/bin/pmset -b lowpowermode 0" in r.stdout
    assert not plist.exists() and not (tmp_path / "etc/sudoers.d/otto-awake").exists() and not state.exists()


def test_install_script_osascript_dry_run_and_cancel(tmp_path):
    env = {**os.environ, "OTTO_AWAKE_DRY_RUN": "1", "OTTO_AWAKE_DRY_ROOT": str(tmp_path),
           "OTTO_AWAKE_ELEVATE": "osascript"}
    r = subprocess.run(["bash", str(SCRIPTS / "install_awake.sh")], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "with prompt \"Otto wants to keep this Mac awake with the lid closed.\" with administrator privileges" in r.stdout
    assert "/usr/bin/install -m 0440 -o root -g wheel" in r.stdout and "sudo install" not in r.stdout
    assert (tmp_path / "etc/sudoers.d/otto-awake").exists()
    # cancelled at the prompt: exit 3, no rule, no agent
    other = tmp_path / "other"
    r = subprocess.run(["bash", str(SCRIPTS / "install_awake.sh")],
                       env={**env, "OTTO_AWAKE_DRY_ROOT": str(other), "OTTO_AWAKE_DRY_CANCEL": "1"},
                       capture_output=True, text=True)
    assert r.returncode == 3
    assert not (other / "etc/sudoers.d/otto-awake").exists()
    assert not list(other.rglob("*.plist"))
    # undo through the prompt: one admin command turns sleep on and removes the rule
    r = subprocess.run(["bash", str(SCRIPTS / "uninstall_awake.sh")], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "/usr/bin/pmset -a disablesleep 0; /bin/rm -f /etc/sudoers.d/otto-awake" in r.stdout
    assert "undo the lid-closed setup" in r.stdout and "DRY: sudo" not in r.stdout
    assert not (tmp_path / "etc/sudoers.d/otto-awake").exists()


# --- setup / undo from Otto (POST /hermes/awake/setup|undo), dry run: no real sudo or prompt ---

def dry_awake(tmp_path, cancel=False):
    """An Awake whose scripts run for real in DRY mode; FakeMac's sudo rule follows the dry sudoers file."""
    root = tmp_path / "root"
    mac = FakeMac(installed=False)
    rule = root / "etc/sudoers.d/otto-awake"
    real = mac.run

    def run(argv):
        mac.installed = rule.exists()
        return real(argv)
    env = {"OTTO_AWAKE_DRY_RUN": "1", "OTTO_AWAKE_DRY_ROOT": str(root), "OTTO_AWAKE_HOME": "/state"}
    if cancel:
        env["OTTO_AWAKE_DRY_CANCEL"] = "1"
    calls = []

    def scripts(argv, e):
        calls.append((argv, e))
        return awake.real_script_runner(argv, e)
    home = root / "state"
    a = awake.Awake(home=home, runner=run, clock=mac.clock, sleep=mac.sleep,
                    agents=lambda: {"working": True, "chats": 1, "kanban": 0}, thermal=lambda: 0, pid=4242,
                    alive=lambda p: True, scripts=scripts, script_env=env)
    return a, mac, rule, calls


def test_setup_route_installs_through_admin_prompt(tmp_path):
    a, mac, rule, calls = dry_awake(tmp_path)
    companion.Companion._awake = a
    try:
        c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
        assert c.handle("GET", "/awake", {}, {})["installed"] is False
        s = c.handle("POST", "/awake/setup", {}, {})
        assert s["setup"]["action"] == "setup"
        a.wait_setup(30)
        s = c.handle("GET", "/awake", {}, {})
        assert s["setup"]["state"] == "done" and s["installed"] is True, s["setup"]
        assert rule.exists() and calls[0][1]["OTTO_AWAKE_ELEVATE"] == "osascript"
        assert calls[0][0][-1].endswith("install_awake.sh")
        assert mac.privileged() == []  # setup itself changes no power setting
        # now the toggle works
        assert c.handle("POST", "/awake", {}, {"mode": "working"})["holding"] is True
        assert mac.sleep_disabled == 1
        # undo: sleep back on first (the rule still allows it), then the rule goes
        s = c.handle("POST", "/awake/undo", {}, {})
        assert mac.sleep_disabled == 0
        a.wait_setup(30)
        s = c.handle("GET", "/awake", {}, {})
        assert s["setup"]["action"] == "undo" and s["setup"]["state"] == "done", s["setup"]
        assert s["installed"] is False and not rule.exists() and calls[-1][0][-1].endswith("uninstall_awake.sh")
        with pytest.raises(companion.RouteError) as e:
            c.handle("GET", "/awake/setup", {}, {})
        assert e.value.status == 405
    finally:
        companion.Companion._awake = None


def test_setup_cancelled_changes_nothing(tmp_path):
    a, mac, rule, _ = dry_awake(tmp_path, cancel=True)
    a.start_setup("setup")
    a.wait_setup(30)
    s = a.status()
    assert s["setup"]["state"] == "cancelled" and "Cancelled" in s["setup"]["detail"]
    assert s["installed"] is False and not rule.exists() and mac.privileged() == []


def test_setup_one_at_a_time_and_failures(tmp_path):
    import threading
    gate = threading.Event()

    def slow(argv, env):
        gate.wait(10)
        return subprocess.CompletedProcess(argv, 1, "", "Couldn't install the rule: boom")
    a, mac, _ = make(tmp_path, FakeMac(installed=False))
    a.scripts = slow
    a.start_setup("setup")
    with pytest.raises(awake.AwakeError) as e:
        a.start_setup("setup")
    assert e.value.status == 409
    with pytest.raises(awake.AwakeError) as e:
        a.start_setup("nap")
    assert e.value.status == 400
    gate.set()
    a.wait_setup(10)
    s = a.status()["setup"]
    assert s["state"] == "failed" and "boom" in s["detail"]

    def timeout(argv, env):
        raise subprocess.TimeoutExpired(argv, 600)
    a.scripts = timeout
    a.start_setup("setup")
    a.wait_setup(10)
    assert a.status()["setup"]["state"] == "cancelled"
