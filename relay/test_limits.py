import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import limits  # noqa: E402

RAW = [
    {"provider": "claude", "source": "oauth", "version": "1",
     "usage": {"loginMethod": "Claude Max 5x", "accountEmail": "john@example.com",
               "identity": {"accountEmail": "john@example.com"}, "updatedAt": "2026-10-03T13:00:00Z",
               "primary": {"windowMinutes": 300, "usedPercent": 22, "resetsAt": "2026-10-03T20:00:00Z",
                           "resetDescription": "5:00 PM"},
               "secondary": {"windowMinutes": 10080, "usedPercent": 140, "resetsAt": "2026-10-04T06:00:00Z"}},
     "pace": {"secondary": {"stage": "behind", "summary": "20% in reserve", "willLastToReset": True,
                            "expectedUsedPercent": 92}},
     "status": {"indicator": "minor", "description": "Degraded", "url": "https://status.anthropic.com"},
     "openaiDashboard": {"signedInEmail": "john@example.com"}},
    {"provider": "codex", "error": {"message": "token for john@example.com at /Users/sam/.codex/auth.json Bearer abc.def"}},
    {"provider": "../etc", "usage": {}},
    "junk",
]


def test_sanitize_shape_and_privacy():
    out = limits.sanitize(RAW)
    blob = json.dumps(out)
    assert "@" not in blob and "/Users" not in blob and "Bearer abc" not in blob and "status.anthropic" not in blob
    assert [p["id"] for p in out["providers"]] == ["claude", "codex"]
    claude = out["providers"][0]
    assert claude["plan"] == "Claude Max 5x" and claude["status"]["indicator"] == "minor"
    assert [w["label"] for w in claude["windows"]] == ["5-hour", "Weekly"]
    assert claude["windows"][1]["usedPercent"] == 100.0          # clamped
    assert claude["windows"][1]["pace"]["willLastToReset"] is True
    assert claude["windows"][0]["pace"] is None
    assert "your account" in out["providers"][1]["error"]


def test_window_labels():
    assert limits.window_label(300, "primary") == "5-hour"
    assert limits.window_label(10080, "secondary") == "Weekly"
    assert limits.window_label(43200, "tertiary") == "Monthly"
    assert limits.window_label(None, "secondary") == "Weekly"


def test_claude_falls_back_to_hermes_login(monkeypatch):
    import limits
    fb = {"provider": "claude", "source": "hermes",
          "usage": {"primary": {"usedPercent": 5.0, "windowMinutes": 300, "resetsAt": "2026-10-08T06:10:00Z"}}}
    monkeypatch.setattr(limits, "_hermes_claude", lambda: dict(fb))
    raw = [{"provider": "codex", "usage": {}},
           {"provider": "claude", "error": {"message": "No Claude session key found in browser cookies."},
            "status": {"indicator": "minor", "description": "Degraded"}}]
    out = limits.sanitize(limits._with_hermes_claude(raw))
    claude = out["providers"][1]
    assert claude["error"] is None and claude["source"] == "hermes"
    assert claude["windows"][0]["usedPercent"] == 5.0 and claude["status"]["indicator"] == "minor"


def test_working_claude_is_left_alone(monkeypatch):
    import limits
    monkeypatch.setattr(limits, "_hermes_claude", lambda: (_ for _ in ()).throw(AssertionError("called")))
    raw = [{"provider": "claude", "usage": {"primary": {"usedPercent": 1.0}}}]
    assert limits._with_hermes_claude(raw) == raw
