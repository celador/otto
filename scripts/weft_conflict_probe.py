#!/usr/bin/env python3
"""Live proof that Weft guards hermes-ios: two sessions edit the same file, the second is told.

Two real Weft adapter sessions (profiles `default` and `backend`, i.e. agents hermes-default and
hermes-backend, each with its own probe "card") edit the same new file in two throwaway worktrees
of this repo, against the real gateway with the repo's real mode from
~/.config/weft/hermes-adapter.json (must be `enforce`). Steps:

  1. A writes scratch-weft-probe/Probe.swift (accepted; A now holds the file's claim)
  2. B, whose base predates A's edit, writes the same file -> B's pre-check is BLOCKED (enforce)
     or B's tool result carries a conflict diagnostic, before B can commit
  3. A's change lands on trunk (system `land`, trunk_ref rebrand/otto, as land_card.sh does)
  4. B edits the file again on its pre-landing base -> BLOCKED with stale_overwrite (enforce)
  5. B retries without rebasing -> still blocked, and B's `git commit` is refused by the commit
     gate until B rebases onto trunk (a new commit lifts the rebase floor)
Then both probe changes are landed so no real card ever waits on their keys, and the worktrees
and branches are removed. Tokens are read from the config and never printed.

    python3 scripts/weft_conflict_probe.py [--weft ~/github/weft]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MAIN = Path(subprocess.run(["git", "-C", str(REPO), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True, check=True).stdout.strip()).parent
REL = f"scratch-weft-probe/Probe{int(time.time())}.swift"  # fresh path per run: earlier runs landed theirs


def sh(*args, cwd=MAIN):
    return subprocess.run(list(args), cwd=cwd, capture_output=True, text=True)


def edit(adapter, path: Path, content: str, call_id: str):
    args = {"path": str(path), "content": content}
    block = adapter.pre_tool_call(tool_name="write_file", args=args, tool_call_id=call_id)
    if block:
        return "blocked", block["message"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    adapter.post_tool_call(tool_name="write_file", args=args, tool_call_id=call_id, result='{"ok": true}')
    out = adapter.transform_tool_result(tool_name="write_file", args=args, result='{"ok": true}', tool_call_id=call_id)
    return "applied", (json.loads(out).get("weft_diagnostics") if out else None)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weft", default="~/github/weft")
    a = ap.parse_args()
    sys.path.insert(0, str(Path(a.weft).expanduser() / "packages/adapters/hermes/plugin"))
    sys.path.insert(0, str(Path(a.weft).expanduser() / "packages/adapters/hermes/scripts"))
    from weft.adapter import Config, WeftAdapter  # noqa: E402
    import weft_land as wl  # noqa: E402
    from install import load_config  # noqa: E402
    raw = load_config()
    token = wl.cached_token(raw, raw["url"], "hermes-ios")
    if not token:
        print("no hermes-ios land token (run scripts/land_card.sh once, or weft_land.py --repo hermes-ios)"); return 2
    gw = wl.Gateway(raw["url"], token, "hermes-ios")
    sha = sh("git", "rev-parse", "HEAD", cwd=REPO).stdout.strip()

    stamp = int(time.time())
    wts = {}
    for side in ("a", "b"):
        wt = MAIN / ".worktrees" / f"weft-probe-{side}-{stamp}"
        r = sh("git", "worktree", "add", "-q", "-b", f"weft-probe/{side}-{stamp}", str(wt), "HEAD")
        if r.returncode:
            print(r.stderr); return 2
        wts[side] = wt

    adapters = {}
    results = []
    try:
        for side, profile in (("a", "default"), ("b", "backend")):
            os.environ["HERMES_KANBAN_TASK"] = f"weft-probe-{side}-{stamp}"
            os.environ["HERMES_KANBAN_WORKSPACE"] = str(wts[side])
            os.environ.pop("HERMES_KANBAN_DB", None)
            base = Config.load(profile=profile)
            cfg = base.for_repo("hermes-ios") if base else None
            if not cfg:
                print(f"no hermes-ios token for profile {profile}"); return 2
            cfg.log_path = None
            adapters[side] = WeftAdapter(cfg, heartbeat=False)
        A, B = adapters["a"], adapters["b"]
        print(f"mode for hermes-ios: {A.cfg.mode}")

        # B opens its session before A edits, so B's base predates A's write.
        B.ensure_session()
        r = edit(A, wts["a"] / REL, "// probe A\nlet probe = 1\n", "a1")
        results.append(("A writes the file -> applied", r[0] == "applied"))
        print("A:", r[0], (r[1] or "")[:300])
        r = edit(B, wts["b"] / REL, "// probe B\nlet probe = 2\n", "b1")
        told = r[0] == "blocked" or bool(r[1])
        results.append(("B (stale base, same file) is blocked or told before commit", told))
        print("B:", r[0], (r[1] or "")[:600])
        out, rec = wl.post_land(gw, A.change, sha, trunk_ref="refs/heads/rebrand/otto")
        results.append(("A's change lands on trunk", out == "landed"))
        print("A land:", out, (rec or {}).get("seq"))
        r = edit(B, wts["b"] / REL, "// probe B\nlet probe = 3\n", "b2")
        results.append(("B edits on its pre-landing base -> BLOCKED (stale_overwrite)",
                        r[0] == "blocked" and "stale_overwrite" in r[1]))
        print("B after land:", r[0], (r[1] or "")[:600])
        r = edit(B, wts["b"] / REL, "// probe B\nlet probe = 3\n", "b3")
        results.append(("B's retry without rebasing -> still blocked", r[0] == "blocked"))
        print("B retry:", r[0], (r[1] or "")[:200])
        gate = B.pre_tool_call(tool_name="terminal", args={"command": "git commit -qam probe", "workdir": str(wts["b"])},
                               tool_call_id="b4")
        results.append(("B's git commit is refused while the stale_overwrite is open", bool(gate)))
        print("B git commit gate:", "BLOCKED " + gate["message"][:300] if gate else "open")
    finally:
        for side, ad in adapters.items():
            try:
                if ad.session:  # land the probe change so its keys never hold up a real card
                    print(f"cleanup land {side}:", wl.post_land(gw, ad.change, sha, trunk_ref="refs/heads/rebrand/otto")[0])
            finally:
                ad.close()
        for side, wt in wts.items():
            sh("git", "worktree", "remove", "--force", str(wt))
            sh("git", "branch", "-D", f"weft-probe/{side}-{stamp}")
    failed = [n for n, ok in results if not ok]
    for n, ok in results:
        print(("PASS " if ok else "FAIL ") + n)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
