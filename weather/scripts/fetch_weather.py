# -*- coding: utf-8 -*-
"""Fetch weather via public Open-Meteo HTTP (no API key / no signup).

  python -X utf8 fetch_weather.py --city 北京 --lang zh --days 10

Stdout JSON (ok / error).
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def http_get_json(url: str, timeout: float = 20.0) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "nvimplugins-weather/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8"))


def geocode(city: str, lang: str = "zh") -> dict | None:
    q = urllib.parse.urlencode(
        {
            "name": city,
            "count": 1,
            "language": "zh" if str(lang).startswith("zh") else "en",
            "format": "json",
        }
    )
    url = "https://geocoding-api.open-meteo.com/v1/search?" + q
    data = http_get_json(url)
    results = data.get("results") or []
    if not results:
        return None
    r = results[0]
    return {
        "name": r.get("name") or city,
        "country": r.get("country") or "",
        "admin1": r.get("admin1") or "",
        "lat": r.get("latitude"),
        "lon": r.get("longitude"),
    }


def forecast(lat: float, lon: float, days: int = 10) -> dict:
    q = urllib.parse.urlencode(
        {
            "latitude": lat,
            "longitude": lon,
            "current": "temperature_2m,weather_code,relative_humidity_2m,wind_speed_10m",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max",
            "timezone": "auto",
            "forecast_days": max(1, min(16, days)),
        }
    )
    url = "https://api.open-meteo.com/v1/forecast?" + q
    return http_get_json(url)


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    city = ""
    lat = lon = None
    name = ""
    country = ""
    admin1 = ""
    lang = "zh"
    days = 10
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--city" and i + 1 < len(args):
            city = args[i + 1]
            i += 2
        elif a == "--lat" and i + 1 < len(args):
            lat = float(args[i + 1])
            i += 2
        elif a == "--lon" and i + 1 < len(args):
            lon = float(args[i + 1])
            i += 2
        elif a == "--name" and i + 1 < len(args):
            name = args[i + 1]
            i += 2
        elif a == "--lang" and i + 1 < len(args):
            lang = args[i + 1]
            i += 2
        elif a == "--days" and i + 1 < len(args):
            days = int(args[i + 1])
            i += 2
        else:
            i += 1

    try:
        if lat is None or lon is None:
            if not city:
                print(json.dumps({"ok": False, "error": "need --city or --lat/--lon"}, ensure_ascii=False))
                return 2
            geo = geocode(city, lang=lang)
            if not geo:
                print(json.dumps({"ok": False, "error": f"city not found: {city}"}, ensure_ascii=False))
                return 3
            lat, lon = geo["lat"], geo["lon"]
            name = geo["name"]
            country = geo.get("country") or ""
            admin1 = geo.get("admin1") or ""
        elif not name:
            name = f"{lat:.2f},{lon:.2f}"

        data = forecast(float(lat), float(lon), days=days)
        cur = data.get("current") or {}
        daily = data.get("daily") or {}
        dates = daily.get("time") or []
        codes = daily.get("weather_code") or []
        tmax = daily.get("temperature_2m_max") or []
        tmin = daily.get("temperature_2m_min") or []
        precip = daily.get("precipitation_sum") or []
        wind = daily.get("wind_speed_10m_max") or []

        days_out = []
        for idx, d in enumerate(dates):
            days_out.append(
                {
                    "date": d,
                    "code": codes[idx] if idx < len(codes) else None,
                    "tmax": tmax[idx] if idx < len(tmax) else None,
                    "tmin": tmin[idx] if idx < len(tmin) else None,
                    "precip": precip[idx] if idx < len(precip) else None,
                    "wind": wind[idx] if idx < len(wind) else None,
                }
            )

        out = {
            "ok": True,
            "city": name,
            "country": country,
            "admin1": admin1,
            "lat": lat,
            "lon": lon,
            "current": {
                "temp": cur.get("temperature_2m"),
                "code": cur.get("weather_code"),
                "humidity": cur.get("relative_humidity_2m"),
                "wind": cur.get("wind_speed_10m"),
                "time": cur.get("time"),
            },
            "daily": days_out,
            "source": "open-meteo.com",
            "fetched_at": int(time.time()),
        }
        print(json.dumps(out, ensure_ascii=False))
        return 0
    except urllib.error.HTTPError as e:
        print(json.dumps({"ok": False, "error": f"HTTP {e.code}: {e.reason}"}, ensure_ascii=False))
        return 1
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
