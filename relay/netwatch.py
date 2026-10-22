"""Hotspot failover settings + status for Otto (GET/POST /hermes/hotspot, POST /hermes/hotspot/test,
POST /hermes/hotspot/setup).

The work is done by otto-netwatch (netwatch/, installed by scripts/install_netwatch.sh as the LaunchAgent
ai.elier.otto-netwatch): a small non-sandboxed helper that watches whether the internet answers over Wi-Fi
and joins the iPhone Personal Hotspot when it doesn't, then switches back. Otto for Mac is sandboxed and
can't change networks, so it only shows status and edits settings through these routes.

Files (HERMES_HOME/otto-netwatch, owner-only): config.json (written here), status.json (written by the
helper every few seconds), test-request (written here, consumed by the helper). The hotspot password is
never stored in a file or logged: it goes from the request body straight to the helper's stdin
(`otto-netwatch set-password`), which saves it in the login Keychain.

Ported idea: Insomnia's hotspot handoff (https://github.com/krishhgg/Insomnia, MIT); see
THIRD_PARTY_NOTICES.md.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable

HERMES_HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
REPO_RELAY = Path(__file__).resolve().parent
SCRIPTS = REPO_RELAY.parent / "scripts"
INSTALL_SCRIPT = SCRIPTS / "install_netwatch.sh"
UNINSTALL_SCRIPT = SCRIPTS / "uninstall_netwatch.sh"
LABEL = "ai.elier.otto-netwatch"
HELPER = Path.home() / "Library" / "Application Support" / "Otto" / "Otto Network Helper.app" / "Contents" / "MacOS" / "otto-netwatch"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"

#: The helper writes status every 5 s (2 s while busy); older than this = not running.
STALE_AFTER = 30


class NetwatchError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _ssid(v: Any) -> str:
    if not isinstance(v, str):
        raise NetwatchError(400, "hotspot_ssid must be a string")
    s = v.strip()
    if len(s.encode()) > 32:
        raise NetwatchError(400, "A Wi-Fi network name is at most 32 bytes.")
    if any(ord(c) < 32 for c in s):
        raise NetwatchError(400, "The hotspot name has control characters.")
    return s


class Netwatch:
    def __init__(self, home: Path | None = None, helper: Path | None = None, plist: Path | None = None,
                 now: Callable[[], float] = time.time,
                 run: Callable[..., subprocess.CompletedProcess] = subprocess.run):
        self.dir = home or (HERMES_HOME / "otto-netwatch")
        self.helper = helper or HELPER
        self.plist = plist or PLIST
        self.now = now
        self.run = run
        self._mutex = threading.Lock()
        self._job: dict | None = None
        self._job_thread: threading.Thread | None = None

    # --- files ---

    @property
    def config_path(self) -> Path:
        return self.dir / "config.json"

    @property
    def status_path(self) -> Path:
        return self.dir / "status.json"

    @property
    def test_path(self) -> Path:
        return self.dir / "test-request"

    def _read(self, p: Path) -> dict:
        try:
            v = json.loads(p.read_text())
            return v if isinstance(v, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write(self, p: Path, data: dict) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        tmp = p.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1, sort_keys=True)
        os.replace(tmp, p)

    def config(self) -> dict:
        c = self._read(self.config_path)
        return {"enabled": bool(c.get("enabled", False)), "hotspot_ssid": str(c.get("hotspot_ssid") or "")}

    # --- status ---

    def installed(self) -> bool:
        return self.helper.exists() and self.plist.exists()

    def status(self) -> dict:
        cfg = self.config()
        helper = self._read(self.status_path)
        updated = helper.get("updated_at")
        running = isinstance(updated, (int, float)) and self.now() - updated < STALE_AFTER
        out: dict[str, Any] = {
            "installed": self.installed(),
            "running": running,
            "enabled": cfg["enabled"],
            "hotspot_ssid": cfg["hotspot_ssid"],
            "setup": self._job,
        }
        keep = ("link", "phase", "ssid", "home_ssid", "password_saved", "wifi_power", "location",
                "offline_since", "last_failover", "last_switch_back", "last_test", "last_error",
                "join_failures", "next_join_at", "switch_back_failures", "next_switch_back_at", "events",
                "updated_at")
        for k in keep:
            if k in helper:
                out[k] = helper[k]
        if helper.get("hotspot_ssid") != cfg["hotspot_ssid"]:
            # The helper hasn't picked up a just-saved name yet: don't claim a password for it.
            out["password_saved"] = None
        if not running:
            out["link"] = None
        out["test_pending"] = self.test_path.exists()
        return out

    # --- settings ---

    def set(self, body: dict) -> dict:
        if not isinstance(body, dict):
            raise NetwatchError(400, "need a JSON object")
        cfg = self.config()
        if "enabled" in body:
            if not isinstance(body["enabled"], bool):
                raise NetwatchError(400, "enabled must be true or false")
            cfg["enabled"] = body["enabled"]
        if "hotspot_ssid" in body:
            cfg["hotspot_ssid"] = _ssid(body["hotspot_ssid"])
        password = body.get("password")
        if password is not None:
            if not isinstance(password, str):
                raise NetwatchError(400, "password must be a string")
            if password and not 8 <= len(password.encode()) <= 63:
                raise NetwatchError(400, "A hotspot password is 8 to 63 characters.")
            if not cfg["hotspot_ssid"]:
                raise NetwatchError(400, "Enter the hotspot name first.")
            if not self.helper.exists():
                raise NetwatchError(409, "Set up the network helper first.")
            self._password(cfg["hotspot_ssid"], password)
        if cfg["enabled"] and not cfg["hotspot_ssid"]:
            raise NetwatchError(400, "Enter the hotspot name first.")
        with self._mutex:
            prev = self._read(self.config_path)
            self._write(self.config_path, {**prev, **cfg})
        return self.status()

    def _password(self, ssid: str, password: str) -> None:
        """Saves (or with "" clears) the password via the helper, so the Keychain item belongs to the helper
        and it can read it later without a prompt. The password only travels on stdin."""
        args = [str(self.helper), "set-password" if password else "clear-password", "--ssid", ssid]
        try:
            r = self.run(args, input=password if password else "", capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise NetwatchError(500, f"The network helper didn't answer: {e.__class__.__name__}") from None
        if r.returncode != 0:
            msg = (r.stderr or r.stdout or "").strip().splitlines()
            raise NetwatchError(500, f"Couldn't save the password: {msg[-1] if msg else 'exit ' + str(r.returncode)}")

    def test(self) -> dict:
        cfg = self.config()
        if not cfg["hotspot_ssid"]:
            raise NetwatchError(400, "Enter the hotspot name first.")
        if not self.status()["running"]:
            raise NetwatchError(409, "The network helper isn't running. Set it up first.")
        self.dir.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.test_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(str(self.now()))
        return self.status()

    # --- one-time setup (no admin prompt; builds and loads the helper) ---

    def start_setup(self, action: str = "setup") -> dict:
        if action not in ("setup", "undo"):
            raise NetwatchError(400, "action must be setup or undo")
        with self._mutex:
            if self._job and self._job.get("state") == "running":
                raise NetwatchError(409, "Setup is already running.")
            self._job = {"action": action, "state": "running", "detail": None, "at": self.now()}
            self._job_thread = threading.Thread(target=self._run_setup, args=(action,), daemon=True,
                                                name=f"netwatch-{action}")
            self._job_thread.start()
        return self.status()

    def wait_setup(self, timeout: float | None = None) -> None:
        if self._job_thread:
            self._job_thread.join(timeout)

    def _run_setup(self, action: str) -> None:
        script = INSTALL_SCRIPT if action == "setup" else UNINSTALL_SCRIPT
        try:
            r = self.run(["/bin/bash", str(script)], capture_output=True, text=True, timeout=600)
            code, out = r.returncode, ((r.stderr or "").strip() or (r.stdout or "").strip())
        except subprocess.TimeoutExpired:
            code, out = 1, "Setup took too long."
        except OSError as e:
            code, out = 1, str(e)
        if code == 0:
            state, detail = "done", ("The network helper is running." if action == "setup" else "The network helper was removed.")
        else:
            state, detail = "failed", (out.splitlines()[-1] if out else "Setup failed.")[:300]
        with self._mutex:
            self._job = {"action": action, "state": state, "detail": detail, "at": self.now()}
        print(f"netwatch: {action} {state}: {detail}", file=sys.stderr, flush=True)
