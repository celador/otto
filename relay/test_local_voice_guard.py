"""The local voice daemon (127.0.0.1:8653, no auth) refuses browsers, proxies and rebound Hosts."""
import http.client
import json
import threading
from http.server import ThreadingHTTPServer

import pytest

import local_voice


@pytest.fixture()
def server():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), local_voice.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv.server_address[1]
    srv.shutdown()
    srv.server_close()


def _req(port, method, path, headers=None, body=None, host=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.putrequest(method, path, skip_host=True)
    c.putheader("Host", host or f"127.0.0.1:{port}")
    for k, v in (headers or {}).items():
        c.putheader(k, v)
    if body is not None:
        c.putheader("Content-Length", str(len(body)))
    c.endheaders(body)
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, data


def test_native_client_still_works(server):
    status, data = _req(server, "GET", "/voices")
    assert status == 200
    assert json.loads(data)["default"] == local_voice.DEFAULT_VOICE


def test_localhost_host_allowed(server):
    assert _req(server, "GET", "/voices", host="localhost:8653")[0] == 200


@pytest.mark.parametrize("headers", [
    {"Origin": "https://evil.example"},
    {"Sec-Fetch-Site": "cross-site"},
    {"X-Forwarded-For": "100.64.0.9"},
])
def test_browser_or_proxied_post_refused(server, headers):
    body = json.dumps({"text": "hi"}).encode()
    status, _ = _req(server, "POST", "/tts", headers={"Content-Type": "text/plain", **headers}, body=body)
    assert status == 403


def test_rebound_host_refused(server):
    assert _req(server, "GET", "/health", host="evil.example:8653")[0] == 403
    status, _ = _req(server, "POST", "/stt", host="evil.example", body=b"\x00" * 10)
    assert status == 403
