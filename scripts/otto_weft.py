#!/usr/bin/env python3
"""Weft side of Otto's release path (scripts/trunk_guard.sh, otto_release.sh, land_card.sh).

    otto_weft.py check --head <sha>      exit 0 ok, 1 refuse, 75 Weft unreachable (caller falls back)
    otto_weft.py note --head <sha> --build 87 --target mac [--devices "GoldBrick,..."]
    otto_weft.py land                    land the merge at rebrand/otto HEAD (weft_land.py)

`check` refuses when Weft has a landing on rebrand/otto (accepted `land` with trunk_ref
refs/heads/rebrand/otto) whose sha is not in <sha>: some card's work is on Weft's trunk but not in
the build ("landed-but-unmerged"). Everything else about the gateway fails OPEN (John's rule):
missing weft checkout, missing token, timeouts and 5xx exit 75 with one log line, and the shell
side keeps its git ancestry check + lock.

Tokens come from ~/.config/weft/hermes-adapter.json via ~/github/weft's weft_land.py and are never
printed. Test hooks: OTTO_WEFT_EVENTS (JSON file of land events instead of the gateway),
OTTO_WEFT_URL (gateway override), OTTO_WEFT_HOME (weft checkout).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

# Scripts run under a minimal PATH pick /usr/bin/python3, whose OpenSSL has no CA bundle
# (CERTIFICATE_VERIFY_FAILED, which used to read as "Weft unreachable"). macOS ships one here.
if not os.environ.get("SSL_CERT_FILE") and os.path.exists("/etc/ssl/cert.pem"):
    os.environ["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"

REPO = "hermes-ios"
TRUNK = "rebrand/otto"
TRUNK_REF = f"refs/heads/{TRUNK}"
UNREACHABLE = 75
LOG = Path(os.environ.get("OTTO_WEFT_LOG", "~/.cache/weft-hermes/otto-release.log")).expanduser()
KANBAN_DB = "~/.hermes/kanban/boards/otto/kanban.db"


def log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def git(repo_dir: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo_dir, *args], capture_output=True, text=True)


def weft_home() -> Path:
    return Path(os.environ.get("OTTO_WEFT_HOME", "~/github/weft")).expanduser()


def gateway():
    """(Gateway, weft_land module) or raise for a fail-open condition."""
    scripts = weft_home() / "packages/adapters/hermes/scripts"
    if not (scripts / "weft_land.py").exists():
        raise RuntimeError(f"no weft checkout at {weft_home()}")
    sys.path.insert(0, str(scripts))
    import weft_land as wl  # noqa: E402
    from install import load_config  # noqa: E402
    cfg = load_config()
    url = os.environ.get("OTTO_WEFT_URL") or cfg.get("url")
    token = wl.cached_token(cfg, cfg.get("url"), REPO) if url else None
    if not (url and token):
        raise RuntimeError("no hermes-ios land token in the adapter config")
    gw = wl.Gateway(url, token, REPO, timeout=float(os.environ.get("OTTO_WEFT_TIMEOUT", "6")))
    return gw, wl


def trunk_lands() -> list:
    """Accepted lands on rebrand/otto, oldest first."""
    fake = os.environ.get("OTTO_WEFT_EVENTS")
    if fake:
        events = json.loads(Path(fake).read_text())
    else:
        gw, _ = gateway()
        events, _ = gw.events(kind="land", status="accepted")
    return [e for e in events if e.get("kind") == "land" and e.get("status", "accepted") == "accepted"
            and (e.get("payload") or {}).get("trunk_ref") == TRUNK_REF and (e.get("payload") or {}).get("sha")]


def missing_lands(repo_dir: str, head: str, lands: list) -> list:
    """Lands whose sha is unknown here or not an ancestor of head."""
    out, seen = [], set()
    for e in lands:
        sha = e["payload"]["sha"]
        if sha in seen:
            continue
        seen.add(sha)
        r = git(repo_dir, "merge-base", "--is-ancestor", sha, head)
        if r.returncode != 0:  # 1 = not an ancestor, 128 = unknown object (never fetched)
            out.append(e)
    return out


def cmd_check(a) -> int:
    try:
        lands = trunk_lands()
    except Exception as err:  # fail open: the git ancestry check + lock still apply
        log(f"check {a.head[:12]}: Weft unreachable, falling back to git check ({type(err).__name__}: {str(err)[:160]})")
        print(f"weft: unreachable ({type(err).__name__}); falling back to the git ancestry check", file=sys.stderr)
        return UNREACHABLE
    miss = missing_lands(a.repo, a.head, lands)
    if miss:
        print("Refusing: Weft has landings on rebrand/otto that this build does not contain:", file=sys.stderr)
        for e in miss[-8:]:
            print(f"  #{e.get('seq')} {e['payload']['sha'][:12]} {e.get('change') or ''}", file=sys.stderr)
        print("  Pull/merge rebrand/otto (git pull origin rebrand/otto) and retry.", file=sys.stderr)
        log(f"check {a.head[:12]}: REFUSED, {len(miss)} landing(s) missing")
        return 1
    log(f"check {a.head[:12]}: ok against {len(lands)} landing(s)")
    print(f"weft: ok ({len(lands)} landings on {TRUNK} all in {a.head[:12]})", file=sys.stderr)
    return 0


def cmd_note(a) -> int:
    install = {"build": a.build, "target": a.target}
    if a.devices:
        install["devices"] = [d for d in a.devices.split(",") if d]
    if os.environ.get("HERMES_KANBAN_TASK"):
        install["task"] = os.environ["HERMES_KANBAN_TASK"]
    try:
        gw, wl = gateway()
        status, rec = wl.note_install(gw, a.head, TRUNK_REF, install)
    except Exception as err:
        log(f"note {install}: Weft unreachable ({type(err).__name__})")
        print(f"weft: could not record the install ({type(err).__name__}); continuing", file=sys.stderr)
        return 0
    ok = status == 200 and isinstance(rec, dict) and rec.get("status") == "accepted"
    log(f"note {install} {a.head[:12]}: " + (f"seq #{rec.get('seq')}" if ok else f"HTTP {status}"))
    print(f"weft: recorded {a.target} build {a.build}" + (f" (#{rec.get('seq')})" if ok else f" FAILED (HTTP {status})"),
          file=sys.stderr)
    return 0


def cmd_land(a) -> int:
    script = weft_home() / "packages/adapters/hermes/scripts/weft_land.py"
    if not script.exists():
        log("land: no weft checkout; skipped (catch up later with --recent)")
        print("weft: no weft checkout; landing not recorded (land_card.sh catches up next time)", file=sys.stderr)
        return 0
    args = [sys.executable, str(script), "--repo", REPO, "--git-dir", a.repo, "--ref", TRUNK, "--trunk-ref", TRUNK,
            "--kanban-db", os.path.expanduser(KANBAN_DB), "--recent", str(a.recent)]
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        log("land: weft_land timed out (fail open)")
        print("weft: landing timed out; recorded next time (idempotent catch-up)", file=sys.stderr)
        return 0
    out = (r.stdout + r.stderr).strip()
    print(out, file=sys.stderr)
    log(f"land: exit {r.returncode}: {out[-300:]}")
    return 0  # fail open: git already holds the merge, the next land_card.sh run re-tries (--recent)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", default=os.getcwd(), help="git checkout (default: cwd)")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check"); c.add_argument("--head", required=True)
    n = sub.add_parser("note"); n.add_argument("--head", required=True); n.add_argument("--build", required=True)
    n.add_argument("--target", required=True); n.add_argument("--devices", default="")
    l = sub.add_parser("land"); l.add_argument("--recent", type=int, default=10)
    a = p.parse_args(argv)
    socket.setdefaulttimeout(float(os.environ.get("OTTO_WEFT_TIMEOUT", "6")))
    return {"check": cmd_check, "note": cmd_note, "land": cmd_land}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
