"""Who the voice persona is talking to, from ~/.hermes/.env (all optional):

  OTTO_USER_NAME   the user's first name (default: "the user")
  OTTO_USER_PLACE  where they live, for local questions, e.g. "Lisbon, Portugal" (default: unsaid)
  OTTO_USER_TZ     IANA time zone for "Now: ..." (default: this Mac's time zone)

Both voice engines (gemini_live, chatgpt_live) fill their persona from this.
"""
from __future__ import annotations

import datetime as dt
import os
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def load_env() -> dict[str, str]:
    """~/.hermes/.env (or $HERMES_ENV_FILE) as a dict; empty if missing."""
    path = Path(os.environ.get("HERMES_ENV_FILE", Path.home() / ".hermes" / ".env"))
    out: dict[str, str] = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    return out


def place(env: dict[str, str]) -> str:
    return (env.get("OTTO_USER_PLACE") or "").strip()


def name(env: dict[str, str]) -> str:
    return (env.get("OTTO_USER_NAME") or "").strip() or "the user"


def now_line(env: dict[str, str], now: dt.datetime | None = None) -> str:
    """'Now: Wednesday, October 14, 2026, 5:00 PM in Lisbon, Portugal (where Sam lives).'"""
    now = now or dt.datetime.now(dt.timezone.utc)
    tz = None
    if (env.get("OTTO_USER_TZ") or "").strip():
        try:
            tz = ZoneInfo(env["OTTO_USER_TZ"].strip())
        except (ZoneInfoNotFoundError, ValueError):
            tz = None
    local = now.astimezone(tz)  # None -> the system's local time zone
    line = f"Now: {local.strftime('%A, %B %-d, %Y, %-I:%M %p')}"
    place = (env.get("OTTO_USER_PLACE") or "").strip()
    if place:
        line += f" in {place} (where {name(env)} lives)"
    else:
        line += " (the user's local time)"
    return line + "."


def fill(template: str, env: dict[str, str]) -> str:
    """Template placeholders: {user} (name or "the user"), {User} (capitalized for sentence starts)."""
    n = name(env)
    return template.replace("{User}", n[:1].upper() + n[1:]).replace("{user}", n)
