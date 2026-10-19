"""voice_search: parsing and formatting, no network."""
import io
import json

import voice_search as vs


class R(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


DDG_HTML = """
<div class="result results_links results_links_deep result--ad "><a class="result__a" href="x">Ad thing</a>
<a class="result__snippet">buy now</a></div>
<div class="result results_links results_links_deep web-result "><h2><a class="result__a" href="u">Norris wins &amp; <b>Dutch</b> GP</a></h2>
<a class="result__url" href="u">www.formula1.com/en/latest/x</a>
<a class="result__snippet" href="u">Lando <b>Norris</b> won   the race.</a></div>
"""


def test_parse_ddg_skips_ads_and_cleans():
    out = vs.parse_ddg(DDG_HTML)
    assert out == [{"title": "Norris wins & Dutch GP", "snippet": "Lando Norris won the race.", "site": "www.formula1.com"}]


def test_web_formats_and_validates():
    seen = {}
    def opener(req, timeout):
        seen["data"] = req.data
        return R(DDG_HTML.encode())
    r = vs.web("f1 winner", opener=opener)["result"]
    assert b"q=f1+winner" in seen["data"] and "Norris won the race" in r
    for bad in ("", None, "x" * 301):
        try:
            vs.web(bad, opener=opener)
        except vs.SearchError as e:
            assert e.status == 400
        else:
            raise AssertionError(bad)


def test_weather_defaults_to_montevideo_and_formats():
    urls = []
    def opener(req, timeout):
        urls.append(req.full_url)
        if "geocoding" in req.full_url:
            return R(json.dumps({"results": [
                {"name": "Paris", "admin1": "Texas", "country": "United States", "latitude": 1, "longitude": 2},
                {"name": "Paris", "admin1": "Ile-de-France", "country": "France", "latitude": 3, "longitude": 4}]}).encode())
        return R(json.dumps({"current": {"temperature_2m": 15.4, "apparent_temperature": 12, "weather_code": 3,
                                         "wind_speed_10m": 25},
                             "daily": {"weather_code": [61, 0], "temperature_2m_max": [16, 20],
                                       "temperature_2m_min": [10, 9], "precipitation_probability_max": [70, 5]}}).encode())
    r = vs.weather("Paris, France", opener=opener)["result"]
    assert "name=Paris&" in urls[0] and "latitude=3" in urls[1]
    assert r.startswith("Weather in Paris, Ile-de-France, France: now 15°C (feels 12°C), overcast")
    assert "Tomorrow: clear, high 20°C" in r
    vs.weather("", opener=opener, env={"OTTO_USER_PLACE": "Lisbon, Portugal"})
    assert "name=Lisbon" in urls[2]
    try:
        vs.weather("", opener=opener, env={})
        raise AssertionError("expected SearchError")
    except vs.SearchError as e:
        assert e.status == 400


def test_companion_routes_map_errors_and_methods():
    import companion
    c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
    seen = []

    def web(q):
        seen.append(("web", q))
        if q == "boom":
            raise vs.SearchError(504, "search unreachable")
        return {"result": "ok " + q}

    c.voice_web = web
    c.voice_weather = lambda p: seen.append(("weather", p)) or {"result": "sunny"}
    assert c.handle("POST", "/voice-live/search", {}, {"query": "f1"}) == {"result": "ok f1"}
    assert c.handle("POST", "/voice-live/weather", {}, {"place": "Paris"}) == {"result": "sunny"}
    assert seen == [("web", "f1"), ("weather", "Paris")]
    for method, sub, body, status in [("GET", "/voice-live/search", {}, 405),
                                      ("POST", "/voice-live/search", {"query": "boom"}, 504)]:
        try:
            c.handle(method, sub, {}, body)
            raise AssertionError("expected RouteError")
        except companion.RouteError as e:
            assert e.status == status


def test_companion_search_validates_query():
    import companion
    c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
    try:
        c.handle("POST", "/voice-live/search", {}, {"query": ""})
        raise AssertionError("expected RouteError")
    except companion.RouteError as e:
        assert e.status == 400
