"""relay/netwatch.py + the /hermes/hotspot routes. Run: python3 -m pytest relay/test_netwatch.py"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import companion  # noqa: E402
import netwatch  # noqa: E402


class FakeRun:
    """Stands in for subprocess.run: records argv + stdin, never runs anything."""

    def __init__(self, code: int = 0, stderr: str = ""):
        self.calls: list[tuple[list[str], str | None]] = []
        self.code = code
        self.stderr = stderr

    def __call__(self, args, input=None, **kw):
        self.calls.append((list(args), input))
        return subprocess.CompletedProcess(args, self.code, stdout="saved\n", stderr=self.stderr)


@pytest.fixture
def nw(tmp_path):
    helper = tmp_path / "app" / "otto-netwatch"
    helper.parent.mkdir()
    helper.write_text("#!/bin/sh\n")
    plist = tmp_path / "ai.elier.otto-netwatch.plist"
    plist.write_text("<plist/>")
    clock = {"t": 1_800_000_000.0}
    n = netwatch.Netwatch(home=tmp_path / "otto-netwatch", helper=helper, plist=plist,
                          now=lambda: clock["t"], run=FakeRun())
    n.clock = clock
    return n


def helper_status(n, **kw):
    s = {"updated_at": n.now(), "link": "wifi", "phase": "watching", "hotspot_ssid": n.config()["hotspot_ssid"],
         "password_saved": True, "location": "allowed", "events": []}
    s.update(kw)
    n.dir.mkdir(parents=True, exist_ok=True)
    (n.dir / "status.json").write_text(json.dumps(s))


def test_status_before_anything(nw):
    s = nw.status()
    assert s["installed"] is True
    assert s["running"] is False
    assert s["enabled"] is False
    assert s["hotspot_ssid"] == ""
    assert s["link"] is None


def test_not_installed(tmp_path):
    n = netwatch.Netwatch(home=tmp_path / "x", helper=tmp_path / "nope", plist=tmp_path / "nope.plist")
    assert n.status()["installed"] is False


def test_running_and_stale(nw):
    nw.set({"hotspot_ssid": "Sam's iPhone"})
    helper_status(nw, link="hotspot", last_failover={"at": nw.now(), "ok": True})
    s = nw.status()
    assert s["running"] is True
    assert s["link"] == "hotspot"
    assert s["password_saved"] is True
    assert s["last_failover"]["ok"] is True
    nw.clock["t"] += netwatch.STALE_AFTER + 1
    s = nw.status()
    assert s["running"] is False
    assert s["link"] is None


def test_password_saved_unknown_until_helper_sees_new_name(nw):
    nw.set({"hotspot_ssid": "Old"})
    helper_status(nw)
    nw.set({"hotspot_ssid": "New"})
    assert nw.status()["password_saved"] is None


def test_set_writes_owner_only_config_and_keeps_tuning(nw):
    nw.dir.mkdir(parents=True)
    (nw.dir / "config.json").write_text(json.dumps({"outage_seconds": 40}))
    nw.set({"enabled": True, "hotspot_ssid": "  Sam's iPhone "})
    cfg = json.loads((nw.dir / "config.json").read_text())
    assert cfg == {"enabled": True, "hotspot_ssid": "Sam's iPhone", "outage_seconds": 40}
    assert stat.S_IMODE(os.stat(nw.dir / "config.json").st_mode) == 0o600
    assert stat.S_IMODE(os.stat(nw.dir).st_mode) == 0o700


def test_password_goes_to_helper_stdin_only(nw):
    secret = "correct horse 42"
    s = nw.set({"hotspot_ssid": "Sam's iPhone", "password": secret, "enabled": True})
    (args, stdin), = nw.run.calls
    assert args == [str(nw.helper), "set-password", "--ssid", "Sam's iPhone"]
    assert stdin == secret
    assert secret not in " ".join(args)
    for f in nw.dir.iterdir():
        assert secret not in f.read_text()
    assert "password" not in s


def test_empty_password_clears(nw):
    nw.set({"hotspot_ssid": "Sam's iPhone", "password": ""})
    (args, _), = nw.run.calls
    assert args[1] == "clear-password"


@pytest.mark.parametrize("body,code", [
    ({"enabled": "yes"}, 400),
    ({"hotspot_ssid": 3}, 400),
    ({"hotspot_ssid": "x" * 33}, 400),
    ({"hotspot_ssid": "a\nb"}, 400),
    ({"hotspot_ssid": "Sam's iPhone", "password": "short"}, 400),
    ({"hotspot_ssid": "Sam's iPhone", "password": "x" * 64}, 400),
    ({"password": "longenough"}, 400),        # no name yet
    ({"enabled": True}, 400),                 # no name yet
])
def test_set_validation(nw, body, code):
    with pytest.raises(netwatch.NetwatchError) as e:
        nw.set(body)
    assert e.value.status == code
    assert nw.run.calls == []


def test_password_needs_helper(tmp_path):
    n = netwatch.Netwatch(home=tmp_path / "x", helper=tmp_path / "missing", plist=tmp_path / "p", run=FakeRun())
    with pytest.raises(netwatch.NetwatchError) as e:
        n.set({"hotspot_ssid": "Sam's iPhone", "password": "longenough"})
    assert e.value.status == 409


def test_helper_failure_is_reported_without_password(nw):
    nw.run = FakeRun(code=1, stderr="keychain: The user name or passphrase you entered is not correct.")
    with pytest.raises(netwatch.NetwatchError) as e:
        nw.set({"hotspot_ssid": "Sam's iPhone", "password": "secret-pass-1"})
    assert e.value.status == 500
    assert "secret-pass-1" not in e.value.detail


def test_test_now(nw):
    with pytest.raises(netwatch.NetwatchError):
        nw.test()                                   # no name
    nw.set({"hotspot_ssid": "Sam's iPhone"})
    with pytest.raises(netwatch.NetwatchError) as e:
        nw.test()                                   # helper not running
    assert e.value.status == 409
    helper_status(nw)
    s = nw.test()
    assert s["test_pending"] is True
    assert (nw.dir / "test-request").exists()
    assert stat.S_IMODE(os.stat(nw.dir / "test-request").st_mode) == 0o600


def test_setup_job(nw):
    s = nw.start_setup("setup")
    assert s["setup"]["state"] in ("running", "done")
    nw.wait_setup(5)
    s = nw.status()
    assert s["setup"]["state"] == "done"
    (args, _), = nw.run.calls
    assert args[-1].endswith("scripts/install_netwatch.sh")
    nw.run = FakeRun(code=1, stderr="Needs the Swift toolchain (xcode-select --install).")
    nw.start_setup("setup")
    nw.wait_setup(5)
    assert nw.status()["setup"] == {"action": "setup", "state": "failed",
                                     "detail": "Needs the Swift toolchain (xcode-select --install).",
                                     "at": nw.now()}
    with pytest.raises(netwatch.NetwatchError):
        nw.start_setup("reboot")


def test_scripts_exist():
    assert netwatch.INSTALL_SCRIPT.exists()
    assert netwatch.UNINSTALL_SCRIPT.exists()


def test_install_script_dry_run(tmp_path):
    """Builds the helper and assembles the signed bundle + LaunchAgent into a scratch root."""
    if not Path("/usr/bin/swift").exists():
        pytest.skip("no swift")
    env = {**os.environ, "OTTO_NETWATCH_DRY_RUN": "1", "OTTO_NETWATCH_DRY_ROOT": str(tmp_path),
           "OTTO_NETWATCH_SIGN": "-"}
    r = subprocess.run(["/bin/bash", str(netwatch.INSTALL_SCRIPT)], env=env, capture_output=True, text=True,
                       timeout=600)
    assert r.returncode == 0, r.stderr
    app = tmp_path / str(Path.home()).lstrip("/") / "Library/Application Support/Otto/Otto Network Helper.app"
    assert (app / "Contents/MacOS/otto-netwatch").exists()
    info = (app / "Contents/Info.plist").read_text()
    assert "ai.elier.otto.netwatch" in info and "NSLocationUsageDescription" in info
    plist = (tmp_path / str(Path.home()).lstrip("/") / "Library/LaunchAgents/ai.elier.otto-netwatch.plist").read_text()
    assert "<string>run</string>" in plist and "KeepAlive" in plist
    assert str(tmp_path) not in plist                 # real paths, not the scratch root
    assert "DRY: launchctl bootstrap" in r.stdout


# --- routes ---

class Comp(companion.Companion):
    def __init__(self, nw):
        companion.Companion._netwatch = nw


def test_routes(nw):
    c = Comp(nw)
    assert c.handle("GET", "/hotspot", {}, {})["installed"] is True
    s = c.handle("POST", "/hotspot", {}, {"hotspot_ssid": "Sam's iPhone", "enabled": True})
    assert s["enabled"] is True and s["hotspot_ssid"] == "Sam's iPhone"
    with pytest.raises(companion.RouteError) as e:
        c.handle("POST", "/hotspot/test", {}, {})
    assert e.value.status == 409
    with pytest.raises(companion.RouteError) as e:
        c.handle("GET", "/hotspot/test", {}, {})
    assert e.value.status == 405
    with pytest.raises(companion.RouteError) as e:
        c.handle("POST", "/hotspot", {}, {"enabled": 1})
    assert e.value.status == 400
    s = c.handle("POST", "/hotspot/setup", {}, {})
    nw.wait_setup(5)
    assert s["setup"]["action"] == "setup"
    companion.Companion._netwatch = None
