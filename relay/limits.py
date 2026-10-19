"""AI subscription limits for the Hermes iOS app, from CodexBar's CLI (`codexbar usage --json --status`).

Read-only. The phone gets numbers only: provider, plan, each rolling window (used %, reset time),
pace, credits and provider status. Account emails, identities, dashboards and anything credential-like
stay on the Mac. Results are cached so a busy phone (and its widget) can't hammer the providers.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
from typing import Any

CACHE_SECONDS = 60
TIMEOUT_SECONDS = 90
NAMES = {"codex": "Codex", "claude": "Claude", "cursor": "Cursor", "gemini": "Gemini", "copilot": "Copilot",
         "openai": "OpenAI", "openrouter": "OpenRouter", "factory": "Droid", "zai": "z.ai", "kimi": "Kimi",
         "antigravity": "Antigravity", "amp": "Amp", "ollama": "Ollama", "warp": "Warp", "windsurf": "Windsurf",
         "perplexity": "Perplexity", "grok": "Grok", "mistral": "Mistral", "deepseek": "DeepSeek"}
STATUS_INDICATORS = {"none", "minor", "major", "critical", "maintenance", "unknown"}
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
SECRETISH = re.compile(r"(sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|/Users/[^\s'\"]+)")

_lock = threading.Lock()
_cache: tuple[float, dict[str, Any]] | None = None


def _codexbar() -> str | None:
    found = shutil.which("codexbar")
    if found:
        return found
    return "/opt/homebrew/bin/codexbar" if os.path.exists("/opt/homebrew/bin/codexbar") else None


def _clean_text(s: Any, limit: int = 200) -> str | None:
    if not isinstance(s, str) or not s.strip():
        return None
    s = EMAIL.sub("your account", s)
    s = SECRETISH.sub("…", s)
    return s.strip()[:limit]


def _dict(v: Any) -> dict[str, Any]:
    return v if isinstance(v, dict) else {}


def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def window_label(minutes: float | None, slot: str) -> str:
    if minutes is None:
        return {"primary": "Session", "secondary": "Weekly", "tertiary": "Extra"}.get(slot, slot.title())
    m = int(minutes)
    if m < 60:
        return f"{m} min"
    if m < 1440:
        return f"{m // 60}-hour"
    if m == 1440:
        return "Daily"
    if m == 10080:
        return "Weekly"
    if 40000 <= m <= 46000:
        return "Monthly"
    return f"{round(m / 1440)}-day"


def sanitize(raw: Any) -> dict[str, Any]:
    """CodexBar JSON (a list of provider payloads) → the phone's shape."""
    providers = []
    for p in raw if isinstance(raw, list) else []:
        if not isinstance(p, dict):
            continue
        pid = str(p.get("provider") or "")
        if not re.fullmatch(r"[a-z0-9-]{1,32}", pid):
            continue
        usage = _dict(p.get("usage"))
        pace = _dict(p.get("pace"))
        windows = []
        for slot in ("primary", "secondary", "tertiary"):
            w = usage.get(slot)
            if not isinstance(w, dict) or _num(w.get("usedPercent")) is None:
                continue
            minutes = _num(w.get("windowMinutes"))
            pc = _dict(pace.get(slot))
            windows.append({
                "id": slot,
                "label": window_label(minutes, slot),
                "windowMinutes": minutes,
                "usedPercent": max(0.0, min(100.0, _num(w.get("usedPercent")) or 0.0)),
                "resetsAt": w.get("resetsAt") if isinstance(w.get("resetsAt"), str) else None,
                "resetDescription": _clean_text(w.get("resetDescription"), 60),
                "pace": {
                    "stage": _clean_text(pc.get("stage"), 30),
                    "summary": _clean_text(pc.get("summary"), 160),
                    "willLastToReset": pc.get("willLastToReset") if isinstance(pc.get("willLastToReset"), bool) else None,
                    "expectedUsedPercent": _num(pc.get("expectedUsedPercent")),
                } if pc else None,
            })
        credits = _dict(p.get("credits"))
        status = _dict(p.get("status"))
        err = _dict(p.get("error"))
        indicator = status.get("indicator") if status.get("indicator") in STATUS_INDICATORS else None
        providers.append({
            "id": pid,
            "name": NAMES.get(pid, pid.replace("-", " ").title()),
            "plan": _clean_text(usage.get("loginMethod"), 40),
            "source": _clean_text(p.get("source"), 20),
            "windows": windows,
            "credits": _num(credits.get("remaining")),
            "status": {"indicator": indicator, "description": _clean_text(status.get("description"), 80)}
            if indicator else None,
            "error": _clean_text(err.get("message")),
            "updatedAt": usage.get("updatedAt") if isinstance(usage.get("updatedAt"), str) else None,
        })
    return {"providers": providers, "fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}


HERMES_AGENT = os.path.expanduser("~/.hermes/hermes-agent")
HERMES_PY = os.path.join(HERMES_AGENT, "venv", "bin", "python")
CLAUDE_HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude_usage_hermes.py")


def _hermes_claude() -> dict[str, Any] | None:
    """Claude limits via the Claude login Hermes uses (claude_usage_hermes.py), or None."""
    if not os.path.exists(HERMES_PY):
        return None
    try:
        out = subprocess.run([HERMES_PY, CLAUDE_HELPER], cwd=HERMES_AGENT, capture_output=True, text=True,
                             timeout=40, env={k: v for k, v in os.environ.items() if k != "PYTHONPATH"}).stdout
        p = json.loads(out.strip().splitlines()[-1]) if out.strip() else None
    except (subprocess.TimeoutExpired, OSError, json.JSONDecodeError):
        return None
    return p if isinstance(p, dict) and p.get("usage") else None


def _with_hermes_claude(raw: Any) -> Any:
    """When CodexBar has no Claude login (Claude Code signed out), fill Claude from Hermes' own login,
    keeping CodexBar's status line."""
    if not isinstance(raw, list):
        return raw
    for i, p in enumerate(raw):
        if isinstance(p, dict) and p.get("provider") == "claude" and p.get("error") and not p.get("usage"):
            fallback = _hermes_claude()
            if fallback:
                raw[i] = fallback | ({"status": p["status"]} if p.get("status") else {})
    return raw


def fetch(force: bool = False) -> dict[str, Any]:
    global _cache
    with _lock:
        if _cache and not force and time.time() - _cache[0] < CACHE_SECONDS:
            return _cache[1]
        exe = _codexbar()
        if not exe:
            return {"providers": [], "error": "CodexBar isn't installed on your Mac.", "fetchedAt": None}
        try:
            out = subprocess.run([exe, "usage", "--json", "--status", "--no-color"], capture_output=True,
                                 text=True, timeout=TIMEOUT_SECONDS).stdout
            result = sanitize(_with_hermes_claude(json.loads(out or "[]")))
        except subprocess.TimeoutExpired:
            return (_cache[1] | {"stale": True}) if _cache else {"providers": [], "error": "CodexBar took too long."}
        except (json.JSONDecodeError, OSError):
            return (_cache[1] | {"stale": True}) if _cache else {"providers": [], "error": "CodexBar didn't answer."}
        # Force-refreshes are rate limited too: never more than one CodexBar run per 15 s.
        _cache = (time.time() - (CACHE_SECONDS - 15 if force else 0), result)
        return result
