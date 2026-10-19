"""Fast public lookups for Gemini Live voice mode, so web questions never wait for the agent.

Gemini's own Google Search grounding needs a paid Gemini tier (the free key gets 429 "quota"), and
Hermes's Firecrawl search is out of credits, so voice mode uses two free, keyless sources:
  - web: DuckDuckGo's HTML results (titles + snippets, ~1 s),
  - weather: Open-Meteo geocoding + current conditions and today's forecast (~0.5 s).
Results are short plain text for Gemini to read and answer from.
"""
from __future__ import annotations

import html
import json
import re
import urllib.parse
import urllib.request
from typing import Any, Callable

import voice_user

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
DDG = "https://html.duckduckgo.com/html/"
GEO = "https://geocoding-api.open-meteo.com/v1/search"
METEO = "https://api.open-meteo.com/v1/forecast"

Opener = Callable[..., Any]

# WMO weather codes → words.
WMO = {0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "fog",
       51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 61: "light rain", 63: "rain",
       65: "heavy rain", 66: "freezing rain", 67: "freezing rain", 71: "light snow", 73: "snow",
       75: "heavy snow", 77: "snow grains", 80: "rain showers", 81: "rain showers",
       82: "violent rain showers", 85: "snow showers", 86: "snow showers", 95: "thunderstorms",
       96: "thunderstorms with hail", 99: "thunderstorms with hail"}


class SearchError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _clean(s: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()


def parse_ddg(body: str, limit: int = 6) -> list[dict[str, str]]:
    out = []
    for block in re.split(r'<div class="result results_links', body)[1:]:
        if "result--ad" in block[:200]:
            continue
        title = re.search(r'class="result__a"[^>]*>(.*?)</a>', block, re.S)
        snippet = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', block, re.S)
        site = re.search(r'class="result__url"[^>]*>(.*?)</a>', block, re.S)
        if not title:
            continue
        out.append({"title": _clean(title.group(1)), "snippet": _clean(snippet.group(1)) if snippet else "",
                    "site": _clean(site.group(1)).split("/")[0] if site else ""})
        if len(out) >= limit:
            break
    return out


def web(query: Any, opener: Opener = urllib.request.urlopen) -> dict[str, Any]:
    if not isinstance(query, str) or not query.strip() or len(query) > 300:
        raise SearchError(400, "query must be 1-300 chars")
    req = urllib.request.Request(DDG, data=urllib.parse.urlencode({"q": query.strip(), "kl": "us-en"}).encode(),
                                 headers={"User-Agent": UA})
    try:
        with opener(req, timeout=8) as r:
            body = r.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        raise SearchError(504, f"search unreachable: {e}") from None
    results = parse_ddg(body)
    if not results:
        return {"result": f"No web results for {query!r}."}
    lines = [f"- {r['title']} ({r['site']}): {r['snippet']}" for r in results]
    return {"result": f"Web results for {query!r}:\n" + "\n".join(lines)}


def _get(url: str, params: dict[str, Any], opener: Opener) -> dict[str, Any]:
    req = urllib.request.Request(f"{url}?{urllib.parse.urlencode(params)}", headers={"User-Agent": UA})
    try:
        with opener(req, timeout=8) as r:
            return json.loads(r.read() or b"{}")
    except Exception as e:  # noqa: BLE001
        raise SearchError(504, f"weather unreachable: {e}") from None


def weather(place: Any, opener: Opener = urllib.request.urlopen, env: dict[str, str] | None = None) -> dict[str, Any]:
    """No place given: where the user lives (OTTO_USER_PLACE in ~/.hermes/.env, voice_user.py)."""
    if not (isinstance(place, str) and place.strip()):
        place = voice_user.place(voice_user.load_env() if env is None else env)
        if not place:
            raise SearchError(400, "no place given and OTTO_USER_PLACE is not set: ask the user which place")
    place = place.strip()
    if len(place) > 100:
        raise SearchError(400, "place too long")
    # Open-Meteo matches a bare city name; "Paris, France" → "Paris" (country kept to pick the match).
    name, _, hint = place.partition(",")
    geo = _get(GEO, {"name": name.strip(), "count": 5, "language": "en"}, opener).get("results") or []
    if hint.strip():
        h = hint.strip().lower()
        geo = [g for g in geo if h in (g.get("country", "") + " " + g.get("admin1", "")).lower()] or geo
    if not geo:
        return {"result": f"Couldn't find a place called {place!r}."}
    g = geo[0]
    f = _get(METEO, {
        "latitude": g["latitude"], "longitude": g["longitude"], "timezone": "auto", "forecast_days": 2,
        "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,precipitation",
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code",
    }, opener)
    c, d = f.get("current") or {}, f.get("daily") or {}
    where = ", ".join(x for x in (g.get("name"), g.get("admin1"), g.get("country")) if x)
    def day(i: int) -> str:
        try:
            return (f"{WMO.get(d['weather_code'][i], 'mixed')}, high {round(d['temperature_2m_max'][i])}°C, "
                    f"low {round(d['temperature_2m_min'][i])}°C, {d['precipitation_probability_max'][i]}% chance of rain")
        except (KeyError, IndexError, TypeError):
            return "no forecast"
    now = (f"{round(c.get('temperature_2m', 0))}°C (feels {round(c.get('apparent_temperature', 0))}°C), "
           f"{WMO.get(c.get('weather_code'), 'mixed')}, wind {round(c.get('wind_speed_10m', 0))} km/h")
    return {"result": f"Weather in {where}: now {now}. Today: {day(0)}. Tomorrow: {day(1)}."}
