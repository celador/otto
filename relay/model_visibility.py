"""The Hermes desktop app's model shortlist (Edit Models, favorites, custom models), for the iOS picker.

The desktop app keeps these in its Electron localStorage (LevelDB under
~/Library/Application Support/Hermes/Local Storage/leveldb), not on the gateway. We copy the
directory (the running app holds the LOCK), read the four keys with plyvel through `uv`, and
return the raw stored values; the app resolves them against the catalog it shows, exactly like
`apps/desktop/src/store/model-visibility.ts`. Cached until the LevelDB files change.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any

LEVELDB = Path.home() / "Library/Application Support/Hermes/Local Storage/leveldb"
KEYS = {
    "visible": "hermes.desktop.visible-models",
    "known": "hermes.desktop.known-models",
    "favorites": "hermes.desktop.favorite-models",
    "custom": "hermes.desktop.custom-models",
}
UV_CANDIDATES = [str(Path.home() / ".local/bin/uv"), "/opt/homebrew/bin/uv"]

READER = r"""
import json, sys, plyvel
want = json.loads(sys.argv[2])
db = plyvel.DB(sys.argv[1])
out = {}
for k, v in db:
    for name, key in want.items():
        if k.endswith(b"\x00\x01" + key.encode()):
            raw = v[1:].decode("latin-1") if v[:1] == b"\x01" else v[1:].decode("utf-16-le")
            out[name] = raw
db.close()
print(json.dumps(out))
"""

_lock = threading.Lock()
_cache: tuple[float, dict[str, Any]] | None = None


def _uv() -> str | None:
    return shutil.which("uv") or next((p for p in UV_CANDIDATES if os.path.exists(p)), None)


def _stamp(d: Path) -> float:
    return max((f.stat().st_mtime for f in d.iterdir() if f.is_file()), default=0.0)


def _parse(raw: dict[str, str]) -> dict[str, Any]:
    def arr(name: str) -> list | None:
        try:
            v = json.loads(raw[name])
        except (KeyError, ValueError):
            return None
        return v if isinstance(v, list) else None

    strings = lambda v: [x for x in (v or []) if isinstance(x, str)]
    visible, known = arr("visible"), arr("known")
    custom = [{"provider": c["provider"], "model": c["model"]} for c in (arr("custom") or [])
              if isinstance(c, dict) and isinstance(c.get("provider"), str) and isinstance(c.get("model"), str)]
    return {
        "available": True,
        "visible": strings(visible) if visible is not None else None,
        "known": strings(known) if known is not None else None,
        "favorites": strings(arr("favorites")),
        "custom": custom,
    }


def read(leveldb: Path = LEVELDB) -> dict[str, Any]:
    if not leveldb.is_dir():
        return {"available": False, "reason": "Hermes desktop app not found on this Mac"}
    uv = _uv()
    if not uv:
        return {"available": False, "reason": "uv not installed"}
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / "db"
        shutil.copytree(leveldb, copy, ignore=shutil.ignore_patterns("LOCK"))
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "VIRTUAL_ENV")}
        r = subprocess.run([uv, "run", "-q", "--no-project", "--with", "plyvel-ci", "python", "-c", READER,
                            str(copy), json.dumps(KEYS)],
                           capture_output=True, text=True, timeout=120, env=env)
    if r.returncode != 0:
        return {"available": False, "reason": "couldn't read the desktop app's settings"}
    return _parse(json.loads(r.stdout or "{}"))


def fetch(force: bool = False) -> dict[str, Any]:
    global _cache
    with _lock:
        stamp = _stamp(LEVELDB) if LEVELDB.is_dir() else 0.0
        if not force and _cache and _cache[0] == stamp:
            return _cache[1]
        result = read()
        if result.get("available"):
            _cache = (stamp, result)
        return result
