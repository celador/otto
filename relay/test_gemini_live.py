"""Gemini Live token route: no network, the token request is faked."""
import datetime as dt
import io
import json
import os
import tempfile
from pathlib import Path

import gemini_live


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _with_env(text):
    d = tempfile.mkdtemp()
    p = Path(d) / ".env"
    p.write_text(text)
    gemini_live.ENV_FILE = p


def test_status_without_key():
    _with_env("API_SERVER_KEY=x\n")
    s = gemini_live.status()
    assert s["available"] is False and "GEMINI_API_KEY" in s["reason"]
    assert any(v["name"] == "Charon" for v in s["voices"])


def test_mint_locks_persona_and_returns_setup():
    _with_env("GEMINI_API_KEY='k-123'\nGEMINI_LIVE_VOICE=Puck\nOTTO_USER_TZ=America/Montevideo\n")
    seen = {}

    def opener(req, timeout):
        seen["url"] = req.full_url
        seen["key"] = req.headers.get("X-goog-api-key")
        seen["body"] = json.loads(req.data)
        return FakeResponse(json.dumps({"name": "auth_tokens/abc"}).encode())

    now = dt.datetime(2026, 10, 14, 20, 0, tzinfo=dt.timezone.utc)
    out = gemini_live.mint({}, opener=opener, now=now)
    assert seen["url"].endswith("/v1beta/auth_tokens") and seen["key"] == "k-123"
    b = seen["body"]
    assert b["uses"] == 1 and b["expireTime"] == "2026-10-14T20:30:00Z"
    assert b["newSessionExpireTime"] == "2026-10-14T20:02:00Z"
    assert b["fieldMask"] == "model,generationConfig,systemInstruction,tools"
    locked = b["bidiGenerateContentSetup"]
    assert locked["model"] == "models/gemini-3.8-live"
    assert "ask_otto" in json.dumps(locked["tools"])
    names = [f["name"] for f in locked["tools"][0]["functionDeclarations"]]
    assert "web_search" in names and "weather" in names  # public questions skip the agent
    assert {"googleSearch": {}} not in locked["tools"]  # free Gemini tier: grounding answers 429
    text = locked["systemInstruction"]["parts"][0]["text"]
    assert "web_search" in text and "Wednesday, October 14, 2026, 5:00 PM" in text
    assert locked["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"]["voiceName"] == "Puck"
    assert "realtimeInputConfig" not in locked  # the phone's own VAD/resumption settings still apply
    assert out["token"] == "auth_tokens/abc" and out["voice"] == "Puck"
    assert out["ws_url"].endswith("BidiGenerateContentConstrained")
    vad = out["setup"]["realtimeInputConfig"]["automaticActivityDetection"]
    # HIGH + 900 ms: the turn ends ~1 s after John stops (LOW/1200 never ended with background talk).
    assert vad["endOfSpeechSensitivity"] == "END_SENSITIVITY_HIGH" and vad["silenceDurationMs"] == 900
    # Babble alone shouldn't open a turn (the phone takes over turn-taking in really noisy rooms).
    assert vad["startOfSpeechSensitivity"] == "START_SENSITIVITY_LOW"
    assert "k-123" not in json.dumps(out)


def test_mint_voice_and_silence_checked():
    _with_env("GEMINI_API_KEY=k\n")
    ok = lambda req, timeout: FakeResponse(b'{"name":"t"}')  # noqa: E731
    assert gemini_live.mint({"voice": "Kore"}, opener=ok)["voice"] == "Kore"
    for bad in ({"voice": "../x"}, {"silence_ms": 50}, {"silence_ms": "2000"}):
        try:
            gemini_live.mint(bad, opener=ok)
        except gemini_live.LiveError as e:
            assert e.status == 400
        else:
            raise AssertionError(bad)


def test_mint_custom_silence_in_range():
    _with_env("GEMINI_API_KEY=k\n")
    ok = lambda req, timeout: FakeResponse(b'{"name":"t"}')  # noqa: E731
    for ms in (300, 1500, 4000):
        out = gemini_live.mint({"silence_ms": ms}, opener=ok)
        assert out["setup"]["realtimeInputConfig"]["automaticActivityDetection"]["silenceDurationMs"] == ms
    for bad in (299, 4001):
        try:
            gemini_live.mint({"silence_ms": bad}, opener=ok)
        except gemini_live.LiveError as e:
            assert e.status == 400
        else:
            raise AssertionError(bad)


def test_mint_without_key_is_409():
    _with_env("")
    try:
        gemini_live.mint({})
    except gemini_live.LiveError as e:
        assert e.status == 409
    else:
        raise AssertionError


if __name__ == "__main__":
    for n, f in list(globals().items()):
        if n.startswith("test_"):
            f()
    print("ok")


def test_google_search_opt_in():
    _with_env("GEMINI_API_KEY=k\nGEMINI_LIVE_GOOGLE_SEARCH=1\n")
    seen = {}
    def opener(req, timeout):
        seen["body"] = json.loads(req.data)
        return FakeResponse(b'{"name":"t"}')
    gemini_live.mint({}, opener=opener)
    assert {"googleSearch": {}} in seen["body"]["bidiGenerateContentSetup"]["tools"]


# --- Turn detection mirror (relay/turn_detect.py == the phone's NoiseFloor + TurnEndpointer) ---

import random  # noqa: E402

import turn_detect  # noqa: E402


def _feed(d, seconds, levels, client=False, heard=True, rng=None):
    """100 ms chunks; levels is a list cycled, or a callable(i). Returns [(t, event)]."""
    out = []
    for i in range(int(round(seconds * 10))):
        db = levels(i) if callable(levels) else levels[i % len(levels)]
        r = d.feed(db, 0.1, server_heard=heard, client=client)
        if r:
            out.append((round((i + 1) / 10, 1), r))
    return out


def _babble(center, spread, seed=1):
    rng = random.Random(seed)
    return lambda i: center + rng.uniform(-spread, spread)


def test_client_turns_in_steady_babble_end_after_the_utterance():
    # Airport: babble around -40 dBFS (+-4 dB), John's 2 s utterance ~12 dB above it.
    d = turn_detect.TurnDetector()
    assert _feed(d, 3, _babble(-40, 4), client=True) == [], "babble alone opens no turn"
    ev = _feed(d, 2, _babble(-28, 3, seed=2), client=True)
    assert ev and ev[0][1] == "start" and ev[0][0] <= 0.5
    ev = _feed(d, 4, _babble(-40, 4, seed=3), client=True)
    assert ev and ev[0][1] == "end:quiet"
    # endOfTurnDelay (1.5 s of quiet) + at most 1 s
    assert ev[0][0] <= turn_detect.TurnDetector.CLIENT_QUIET_TO_END + 1.0


def test_far_field_talkers_dont_hold_the_turn_open():
    # Someone talking nearby keeps transcribing words, but at babble level (far field): after John
    # stops, the turn still ends.
    d = turn_detect.TurnDetector()
    _feed(d, 2, _babble(-42, 3), client=True)
    assert _feed(d, 2, [-27, -25, -29, -26], client=True)[0][1] == "start"
    far = _babble(-38, 5, seed=4)  # louder than the room floor, well under John's voice
    ev = _feed(d, 4, far, client=True)
    assert ev and ev[0][1] == "end:quiet" and ev[0][0] <= 2.5


def test_noise_floor_learns_sustained_babble():
    # Babble that is "voice" by the calibration floor for > 2.5 s becomes the floor.
    f = turn_detect.NoiseFloor()
    for _ in range(10):
        f.observe(-60, dur=0.1)
    assert f.calibrated and f.floor < -58
    babble = _babble(-38, 3)
    for i in range(60):
        f.observe(babble(i), dur=0.1)
    assert f.floor > -46, f.floor
    assert not f.is_voice(-38)


def test_client_turn_has_a_hard_upper_bound():
    d = turn_detect.TurnDetector()
    _feed(d, 1, [-60], client=True)
    ev = _feed(d, 30, [-20, -22, -24, -21, -50], client=True)  # nonstop talk, only syllable gaps
    assert ev[0][1] == "start" and ("end:max" in [e for _, e in ev])
    assert [t for t, e in ev if e == "end:max"][0] <= turn_detect.TurnDetector.MAX_TURN + 0.5


def test_server_mode_backup_unchanged_in_a_quiet_room():
    d = turn_detect.TurnDetector()
    assert _feed(d, 2.5, [-60]) == []
    assert _feed(d, 1, [-20]) == []
    assert _feed(d, 3, [-58]) == [(1.5, "end:quiet")]
    assert _feed(d, 3, [-58]) == []  # no second end without new speech
    d = turn_detect.TurnDetector()
    _feed(d, 2.5, [-60])
    assert _feed(d, 1, [-20], heard=False) == [] and _feed(d, 3, [-58], heard=False) == []
