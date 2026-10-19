"""Otto local voice routes: no models loaded, the daemon is faked."""
import base64
import json
import tempfile
from pathlib import Path

import companion
import local_voice_client as lv


def test_check_voice_accepts_kokoro_only_in_shape():
    assert companion.check_voice("kokoro:af_heart") == "kokoro:af_heart"
    for bad in ("kokoro:../x", "kokoro:", "kokoro:AF_HEART"):
        try:
            companion.check_voice(bad)
        except companion.RouteError as e:
            assert e.status == 400
        else:
            raise AssertionError(bad)


def test_local_default_voice_reads_profile_config():
    d = Path(tempfile.mkdtemp())
    old = companion.HERMES_HOME
    companion.HERMES_HOME = d
    try:
        (d / "config.yaml").write_text("tts:\n  provider: edge\n  edge:\n    voice: en-US-AriaNeural\n")
        assert companion.local_default_voice(None) is None
        (d / "config.yaml").write_text(
            "tts:\n  provider: otto-local\n  providers:\n    otto-local:\n      type: command\n"
            "      command: \"x\"\n      voice: am_puck\n  edge:\n    voice: en-US-AriaNeural\nstt:\n  provider: local\n")
        assert companion.local_default_voice(None) == "kokoro:am_puck"
        (d / "config.yaml").write_text("tts:\n  provider: otto-local\n")
        assert companion.local_default_voice("default") == "kokoro:af_heart"
    finally:
        companion.HERMES_HOME = old


def test_decode_audio_body():
    pcm = b"\x01\x00\x02\x00"
    data, mime = companion.decode_audio_body({"audio": base64.b64encode(pcm).decode(), "mime_type": "audio/L16;rate=16000"})
    assert data == pcm and mime == "audio/L16;rate=16000"
    for bad in ({"audio": "!!!", "mime_type": "audio/wav"}, {"audio": "AAAA", "mime_type": "text/html"}, {}):
        try:
            companion.decode_audio_body(bad)
        except companion.RouteError as e:
            assert e.status == 400
        else:
            raise AssertionError(bad)


def test_voices_for_picker_shape():
    orig = lv._request
    lv._request = lambda *a, **k: (json.dumps({"voices": [
        {"id": "af_heart", "name": "Heart", "gender": "female", "locale": "en-US"},
        {"id": "bm_george", "name": "George", "gender": "male", "locale": "en-GB"}]}).encode(), "application/json")
    try:
        v = lv.voices_for_picker()
    finally:
        lv._request = orig
    assert v[0] == {"short_name": "kokoro:af_heart", "locale": "en-US", "gender": "Female", "name": "Heart",
                    "locale_name": "English (On your Mac, US)"}
    assert v[1]["locale_name"] == "English (On your Mac, UK)"


def test_local_voice_down_is_503_not_crash():
    orig_url, orig_installed = lv.URL, lv.installed
    lv.URL, lv.installed = "http://127.0.0.1:9", (lambda: False)
    try:
        assert lv.health() is None
        assert lv.status()["available"] is False
        try:
            lv.transcribe(b"x", "audio/wav")
        except lv.LocalVoiceError as e:
            assert e.status == 503
        else:
            raise AssertionError
    finally:
        lv.URL, lv.installed = orig_url, orig_installed


if __name__ == "__main__":
    for n, f in list(globals().items()):
        if n.startswith("test_"):
            f()
    print("ok")
