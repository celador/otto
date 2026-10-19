from honcho_memory import HonchoError, HonchoMemory

CFG = {"base": "http://127.0.0.1:8000", "workspace": "hermes", "user": "john", "ai": "hermes", "prefix": "gw_"}


def fake(responses, calls):
    def http(method, url, body=None, timeout=10):
        calls.append((method, url, body))
        for key, value in responses.items():
            if key in url:
                return value
        return {}
    return http


def test_view_dedupes_hides_echoes_and_orders_peers():
    calls = []
    h = HonchoMemory(fake({
        "/peers/list": {"items": [{"id": "hermes"}, {"id": "alex"}, {"id": "gw_x"}, {"id": "john"}], "pages": 1},
        "/card": {"peer_card": ["Lives by the sea"]},
        "/conclusions/list": {"pages": 1, "items": [
            {"id": "a", "content": "john's sister is Alex.", "level": "explicit", "created_at": "2026-10-06T01:00:00Z"},
            {"id": "b", "content": "john's  sister is Alex.", "level": "explicit", "created_at": "2026-10-06T02:00:00Z"},
            {"id": "c", "content": 'john asked, "what coffee do I prefer?" at 2026-10-06 04:02:16.', "created_at": "2026-10-06T03:00:00Z"},
            {"id": "d", "content": "john prefers cortados.", "level": "deductive", "created_at": "2026-10-05T00:00:00Z"},
        ]},
    }, calls), config=lambda: CFG)
    v = h.view(None)
    assert v["peers"] == ["john", "alex"] and v["peer"] == "john"
    assert v["card"] == ["Lives by the sea"]
    assert [f["content"] for f in v["conclusions"]] == ["john's sister is Alex.", "john prefers cortados."]
    assert v["conclusions"][0]["ids"] == ["a", "b"]
    assert any(b == {"filters": {"observed_id": "john"}} for _, _, b in calls)


def test_unknown_peer_falls_back_and_disabled_config():
    h = HonchoMemory(fake({"/peers/list": {"items": [{"id": "john"}]}}, []), config=lambda: CFG)
    assert h.view("../etc")["peer"] == "john"
    assert HonchoMemory(config=lambda: None).view("john")["enabled"] is False


def test_forget_validates_ids():
    calls = []
    h = HonchoMemory(fake({}, calls), config=lambda: CFG)
    assert h.forget(["a", "b"])["forgot"] == 2
    assert [c[0] for c in calls] == ["DELETE", "DELETE"]
    for bad in (None, [], ["../x"], ["a"] * 21):
        try:
            h.forget(bad)
            raise AssertionError("accepted %r" % (bad,))
        except HonchoError as e:
            assert e.status == 400


def test_remote_base_url_refused(tmp_path):
    from honcho_memory import load_config
    p = tmp_path / "h.json"
    p.write_text('{"baseUrl": "https://api.honcho.dev", "hosts": {"hermes": {}}}')
    assert load_config(p) is None
