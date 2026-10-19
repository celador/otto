"""Tests for the streaming TTS route (/hermes/speak/stream). No network, no audio played:
a fake helper stands in for edge-tts."""
import http.client
import json
import sys
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import companion as c  # noqa: E402
import kanban_relay as r  # noqa: E402
import tts_stream_helper as h  # noqa: E402

FAKE_OK = """
import sys, json, time
req = json.loads(sys.stdin.read())
assert req["text"] and req["home"]
out = sys.stdout.buffer
out.write(b"OK audio/mpeg\\n"); out.flush()
for i in range(3):
    out.write(b"\\xff\\xf3" + bytes([i]) * 100); out.flush(); time.sleep(0.01)
"""
FAKE_409 = 'import sys; sys.stdin.read(); sys.stdout.write("ERR 409 tts provider is openai, not edge\\n")'
FAKE_SILENT = "import sys; sys.stdin.read()"


def write(tmp_path, name, body):
    p = tmp_path / name
    p.write_text(body)
    return p


def test_tts_settings_mirror_hermes():
    assert h.tts_settings({}) == ("edge", {"voice": "en-US-AriaNeural"})
    p, kw = h.tts_settings({"tts": {"provider": "edge", "edge": {"voice": "en-GB-SoniaNeural", "speed": 1.2}}})
    assert p == "edge" and kw == {"voice": "en-GB-SoniaNeural", "rate": "+20%"}
    assert h.tts_settings({"tts": {"speed": 0.9}})[1]["rate"] == "-10%"
    assert h.tts_settings({"tts": {"provider": "OpenAI"}})[0] == "openai"
    assert h.tts_settings({"tts": {"edge": {"speed": "fast"}}})[1] == {"voice": "en-US-AriaNeural"}


def test_stream_reads_chunks(tmp_path):
    s = c.SpeechStream.open("Hello there.", None, python=Path(sys.executable), helper=write(tmp_path, "ok.py", FAKE_OK))
    try:
        data = b"".join(s.chunks())
    finally:
        s.close()
    assert s.mime == "audio/mpeg"
    assert data.startswith(b"\xff\xf3") and len(data) == 3 * 102


def test_stream_errors(tmp_path):
    with pytest.raises(c.RouteError) as e:
        c.SpeechStream.open("Hi", None, python=Path(sys.executable), helper=write(tmp_path, "e.py", FAKE_409))
    assert e.value.status == 409
    with pytest.raises(c.RouteError) as e:
        c.SpeechStream.open("Hi", None, python=Path(sys.executable), helper=write(tmp_path, "s.py", FAKE_SILENT))
    assert e.value.status == 504
    for text in ("", "   ", None, 5, "x" * 4001):
        with pytest.raises(c.RouteError) as e:
            c.SpeechStream.open(text, None)
        assert e.value.status == 400
    with pytest.raises(c.RouteError) as e:
        c.SpeechStream.open("Hi", "../etc")
    assert e.value.status == 400


@pytest.fixture
def relay(tmp_path, monkeypatch):
    env = tmp_path / ".env"
    env.write_text("API_SERVER_KEY=test-key\nHERMES_DASHBOARD_SESSION_TOKEN=dash\n")
    monkeypatch.setattr(c, "HERMES_PY", Path(sys.executable))
    # Never read John's real ~/.hermes config (it may select Otto local voice).
    monkeypatch.setattr(c, "HERMES_HOME", tmp_path)
    import local_voice_client as lv
    monkeypatch.setattr(lv, "voices_for_picker", lambda: [])
    monkeypatch.setattr(c, "TTS_STREAM_HELPER", write(tmp_path, "ok.py", FAKE_OK))
    srv = ThreadingHTTPServer(("127.0.0.1", 0), r.make_handler(r.Secrets(env)))
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv.server_address[1]
    srv.shutdown()


def post(port, path, body, key=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    conn.request("POST", path, json.dumps(body), headers)
    resp = conn.getresponse()
    return resp, resp.read()


def test_route_needs_bearer(relay):
    resp, _ = post(relay, "/hermes/speak/stream", {"text": "Hello."})
    assert resp.status == 401
    resp, _ = post(relay, "/hermes/speak/stream", {"text": "Hello."}, key="wrong")
    assert resp.status == 401


def test_route_streams_chunked_audio(relay):
    resp, data = post(relay, "/hermes/speak/stream", {"text": "Hello."}, key="test-key")
    assert resp.status == 200
    assert resp.getheader("Content-Type") == "audio/mpeg"
    assert resp.getheader("Transfer-Encoding") == "chunked"
    assert len(data) == 306 and data.startswith(b"\xff\xf3")


def test_route_validates(relay):
    resp, data = post(relay, "/hermes/speak/stream", {"text": ""}, key="test-key")
    assert resp.status == 400
    resp, _ = post(relay, "/hermes/speak/stream?profile=../x", {"text": "Hi"}, key="test-key")
    assert resp.status == 400
    # GET isn't a thing for this route.
    conn = http.client.HTTPConnection("127.0.0.1", relay, timeout=10)
    conn.request("GET", "/hermes/speak/stream", headers={"Authorization": "Bearer test-key"})
    assert conn.getresponse().status in (404, 405)


# --- voice choice -------------------------------------------------------------------------------

FAKE_ECHO = """
import sys, json
req = json.loads(sys.stdin.read())
out = sys.stdout.buffer
out.write(b"OK audio/mpeg\\n")
out.write(json.dumps({"voice": req.get("voice"), "rate": req.get("rate")}).encode()); out.flush()
"""

FAKE_VOICES = """
import sys, json
req = json.loads(sys.stdin.read())
assert req["op"] == "voices"
out = {"provider": "edge", "default": "en-US-AriaNeural"}
if req.get("list"):
    out["voices"] = [
        {"ShortName": "es-UY-ValentinaNeural", "Locale": "es-UY", "Gender": "Female", "LocaleName": "Spanish (Uruguay)"},
        {"ShortName": "en-US-AvaMultilingualNeural", "Locale": "en-US", "Gender": "Female"},
        {"ShortName": "iu-Cans-CA-SiqiniqNeural", "Locale": "iu-Cans-CA", "Gender": "Female"},
        {"bad": 1},
    ]
print(json.dumps(out))
"""


def test_helper_overrides():
    base = {"voice": "en-US-AriaNeural", "rate": "+10%"}
    assert h.apply_overrides(base, "es-UY-ValentinaNeural", "+25%") == {"voice": "es-UY-ValentinaNeural", "rate": "+25%"}
    assert h.apply_overrides(base, "x; rm -rf", "fast") == base
    assert h.apply_overrides(base, None, "+0%") == {"voice": "en-US-AriaNeural"}


def test_check_voice_and_rate():
    assert c.check_voice(None) is None and c.check_voice("") is None
    assert c.check_voice("es-UY-ValentinaNeural") == "es-UY-ValentinaNeural"
    assert c.check_voice("zh-CN-liaoning-XiaobeiNeural") == "zh-CN-liaoning-XiaobeiNeural"
    for bad in ("Aria", "es-UY-Valentina", "../x", 5, "es-UY-ValentinaNeural; x"):
        with pytest.raises(c.RouteError):
            c.check_voice(bad)
    assert c.check_rate(None) is None
    assert c.check_rate(1.25) == "+25%" and c.check_rate(0.8) == "-20%" and c.check_rate(1) == "+0%"
    assert c.check_rate("+30%") == "+30%"
    for bad in (3.0, 0.1, True, "fast", "+500%"):
        with pytest.raises(c.RouteError):
            c.check_rate(bad)


def test_stream_passes_voice_and_rate(tmp_path):
    helper = write(tmp_path, "echo.py", FAKE_ECHO)
    s = c.SpeechStream.open("Hola.", None, python=Path(sys.executable), helper=helper,
                            voice="es-UY-ValentinaNeural", rate=1.2)
    try:
        got = json.loads(b"".join(s.chunks()))
    finally:
        s.close()
    assert got == {"voice": "es-UY-ValentinaNeural", "rate": "+20%"}


def test_voice_info_lists_and_caches(tmp_path, monkeypatch):
    monkeypatch.setattr(c, "_voice_cache", {"at": 0.0, "voices": None})
    helper = write(tmp_path, "v.py", FAKE_VOICES)
    info = c.voice_info(None, python=Path(sys.executable), helper=helper, now=1000.0)
    assert info["default"] == "en-US-AriaNeural" and info["provider"] == "edge"
    names = [v["short_name"] for v in info["voices"]]
    assert names == ["en-US-AvaMultilingualNeural", "es-UY-ValentinaNeural", "iu-Cans-CA-SiqiniqNeural"]
    uy = info["voices"][1]
    assert uy == {"short_name": "es-UY-ValentinaNeural", "locale": "es-UY", "gender": "Female",
                  "name": "Valentina", "locale_name": "Spanish (Uruguay)"}
    assert info["voices"][0]["name"] == "Ava Multilingual"
    # Listed voices pass validation even when the regex doesn't cover them.
    assert c.check_voice("iu-Cans-CA-SiqiniqNeural") == "iu-Cans-CA-SiqiniqNeural"
    # Within 24 h the list isn't re-fetched (a helper without the list still answers).
    no_list = write(tmp_path, "nl.py", FAKE_VOICES.replace('if req.get("list"):', 'if False:'))
    again = c.voice_info(None, python=Path(sys.executable), helper=no_list, now=1000.0 + 3600)
    assert len(again["voices"]) == 3
    # After 24 h it is re-fetched; with nothing cached and no list, that's a 502.
    c._voice_cache.update(voices=None)
    with pytest.raises(c.RouteError) as e:
        c.voice_info(None, python=Path(sys.executable), helper=no_list, now=1000.0 + 25 * 3600)
    assert e.value.status == 502


def test_route_voices_and_voice_param(relay, tmp_path, monkeypatch):
    monkeypatch.setattr(c, "_voice_cache", {"at": 0.0, "voices": None})
    monkeypatch.setattr(c, "TTS_STREAM_HELPER", write(tmp_path, "v.py", FAKE_VOICES))
    conn = http.client.HTTPConnection("127.0.0.1", relay, timeout=10)
    conn.request("GET", "/hermes/voices", headers={"Authorization": "Bearer test-key"})
    resp = conn.getresponse()
    data = json.loads(resp.read())
    assert resp.status == 200 and data["default"] == "en-US-AriaNeural" and len(data["voices"]) == 3
    conn.request("GET", "/hermes/voices")
    assert conn.getresponse().status == 401
    monkeypatch.setattr(c, "TTS_STREAM_HELPER", write(tmp_path, "echo.py", FAKE_ECHO))
    resp, body = post(relay, "/hermes/speak/stream", {"text": "Hola.", "voice": "es-UY-MateoNeural", "rate": 0.9},
                      key="test-key")
    assert resp.status == 200 and json.loads(body) == {"voice": "es-UY-MateoNeural", "rate": "-10%"}
    resp, _ = post(relay, "/hermes/speak/stream", {"text": "Hola.", "voice": "evil"}, key="test-key")
    assert resp.status == 400
    resp, body = post(relay, "/hermes/speak", {"text": "Hola.", "voice": "es-UY-MateoNeural"}, key="test-key")
    assert resp.status == 200 and json.loads(body)["voice"] == "es-UY-MateoNeural"


def _fake_edge(monkeypatch, fail_hosts):
    """Installs a fake edge_tts package whose Communicate fails with a 403 handshake on `fail_hosts`."""
    import asyncio
    import types
    pkg = types.ModuleType("edge_tts")
    consts = types.ModuleType("edge_tts.constants")
    consts.TRUSTED_CLIENT_TOKEN = "TOKEN"
    consts.WSS_URL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=TOKEN"
    comm = types.ModuleType("edge_tts.communicate")
    comm.WSS_URL = consts.WSS_URL
    tried = []

    class WSServerHandshakeError(Exception):
        pass

    class Communicate:
        def __init__(self, text, **kw):
            self.url = comm.WSS_URL

        async def stream(self):
            tried.append(self.url.split("/")[2])
            if any(h_ in self.url for h_ in fail_hosts):
                raise WSServerHandshakeError("403, message='Invalid response status'")
            await asyncio.sleep(0)
            yield {"type": "audio", "data": b"\xff\xf3abc"}

    pkg.Communicate = Communicate
    pkg.constants = consts
    pkg.communicate = comm
    for name, mod in (("edge_tts", pkg), ("edge_tts.constants", consts), ("edge_tts.communicate", comm)):
        monkeypatch.setitem(sys.modules, name, mod)
    return tried


class _Out:
    def __init__(self):
        import io
        self.buffer = io.BytesIO()


def test_helper_uses_msedgeservices_first(monkeypatch):
    import asyncio
    tried = _fake_edge(monkeypatch, fail_hosts=["speech.platform.bing.com"])
    out = _Out()
    monkeypatch.setattr(h.sys, "stdout", out)
    assert asyncio.run(h.stream("hi", {"voice": "en-US-AriaNeural"})) == 0
    assert tried == ["api.msedgeservices.com"]
    assert out.buffer.getvalue().startswith(b"OK audio/mpeg\n\xff\xf3")


def test_helper_retries_handshake_once_then_fails(monkeypatch, capsys):
    import asyncio
    tried = _fake_edge(monkeypatch, fail_hosts=["speech.platform.bing.com", "api.msedgeservices.com"])
    out = _Out()
    monkeypatch.setattr(h.sys, "stdout", out)
    assert asyncio.run(h.stream("hi", {"voice": "en-US-AriaNeural"})) == 1
    assert tried == ["api.msedgeservices.com", "speech.platform.bing.com"]
    assert out.buffer.getvalue() == b"ERR 502 edge-tts failed: WSServerHandshakeError\n"
    assert capsys.readouterr().err.count("tts_stream_helper: edge attempt") == 2


def test_helper_falls_back_to_legacy_host(monkeypatch):
    import asyncio
    tried = _fake_edge(monkeypatch, fail_hosts=["api.msedgeservices.com"])
    out = _Out()
    monkeypatch.setattr(h.sys, "stdout", out)
    assert asyncio.run(h.stream("hi", {})) == 0
    assert tried == ["api.msedgeservices.com", "speech.platform.bing.com"]
