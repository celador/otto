"""voice_user.py: the voice persona's name / place / time zone come from ~/.hermes/.env, never hard-coded."""
import datetime as dt

import chatgpt_live
import gemini_live
import voice_user

NOW = dt.datetime(2026, 10, 14, 20, 0, tzinfo=dt.timezone.utc)


def test_defaults_are_neutral():
    for mod in (gemini_live, chatgpt_live):
        p = mod.persona(NOW, env={})
        assert "the user's voice assistant" in p and "{user}" not in p and "{User}" not in p
        assert "(the user's local time)." in p


def test_configured_user():
    env = {"OTTO_USER_NAME": "Sam", "OTTO_USER_PLACE": "Lisbon, Portugal", "OTTO_USER_TZ": "Europe/Lisbon"}
    for mod in (gemini_live, chatgpt_live):
        p = mod.persona(NOW, env=env)
        assert "You are Otto, Sam's voice assistant" in p
        assert p.endswith("Now: Wednesday, October 14, 2026, 9:00 PM in Lisbon, Portugal (where Sam lives).")


def test_sentence_starts_capitalized_and_bad_tz_falls_back():
    assert voice_user.fill("{User} asks; {user} waits", {}) == "The user asks; the user waits"
    assert voice_user.fill("{User} asks; {user} waits", {"OTTO_USER_NAME": "sam"}) == "Sam asks; sam waits"
    assert voice_user.now_line({"OTTO_USER_TZ": "Not/AZone"}, NOW).startswith("Now: ")
