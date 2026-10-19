"""Claude limits straight from Anthropic, using the Claude login Hermes itself already uses.

Run with the Hermes venv python (it imports Hermes' credential resolver). Prints one CodexBar-shaped
provider payload as JSON; the token never leaves this process. Used by limits.py when CodexBar has no
Claude login (Claude Code logged out on the Mac, so ~/.claude/.credentials.json is gone).
"""
import json
import sys
import urllib.request
from datetime import datetime, timezone

WINDOWS = (("five_hour", "primary", 300), ("seven_day", "secondary", 10080),
           ("seven_day_opus", "tertiary", 10080))


def _iso(s):
    try:
        return datetime.fromisoformat(s).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None


def main():
    import os
    sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
    from agent.anthropic_credentials import resolve_anthropic_token, _is_oauth_token
    token = resolve_anthropic_token()
    if not token or not _is_oauth_token(token):
        print(json.dumps({"provider": "claude", "source": "hermes",
                          "error": {"message": "Hermes has no Claude subscription login."}}))
        return
    req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage", headers={
        "Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-code/2.1"})
    data = json.load(urllib.request.urlopen(req, timeout=20))
    usage = {}
    for key, slot, minutes in WINDOWS:
        w = data.get(key)
        if isinstance(w, dict) and isinstance(w.get("utilization"), (int, float)):
            usage[slot] = {"usedPercent": float(w["utilization"]), "windowMinutes": minutes,
                           "resetsAt": _iso(w.get("resets_at"))}
    usage["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(json.dumps({"provider": "claude", "source": "hermes", "usage": usage}))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 — report, never crash the relay
        print(json.dumps({"provider": "claude", "source": "hermes",
                          "error": {"message": f"Anthropic usage check failed ({type(e).__name__})."}}))
        sys.exit(0)
