# -*- coding: utf-8 -*-
"""Fetch weather: domestic CN source (fast) + Open-Meteo fallback.

  python -X utf8 fetch_weather.py --city 北京 --lang zh --days 10 --source auto

Sources:
  cn          国内：中国天气网数据（t.weather.itboy.net，无需 Key）
  open-meteo  Open-Meteo 公开 HTTP
  auto        由调用方按系统语言决定；脚本侧等同「先 cn 再回退 open-meteo」
              （Lua 在非中文系统上会直接传 open-meteo）

Stdout JSON (ok / error).
"""
from __future__ import annotations

import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# 国内部分站点证书链不完整时仍可访问
_SSL_CTX = ssl.create_default_context()
try:
    _SSL_CTX.check_hostname = True
except Exception:
    pass

_SSL_CTX_INSECURE = ssl._create_unverified_context()

_CITYCODE_CACHE: dict[str, str] | None = None


def http_get_json(url: str, timeout: float = 12.0, insecure: bool = False) -> dict | list:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "nvimplugins-weather/1.1",
            "Accept": "application/json,text/plain,*/*",
        },
    )
    ctx = _SSL_CTX_INSECURE if insecure else _SSL_CTX
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read()
    except (ssl.SSLError, urllib.error.URLError):
        # 证书问题再试一次 insecure
        if not insecure:
            with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CTX_INSECURE) as resp:
                raw = resp.read()
        else:
            raise
    return json.loads(raw.decode("utf-8"))


def load_citycode() -> dict[str, str]:
    global _CITYCODE_CACHE
    if _CITYCODE_CACHE is not None:
        return _CITYCODE_CACHE
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "citycode.json")
    m: dict[str, str] = {}
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                m = {str(k): str(v) for k, v in data.items() if k and v}
        except Exception:
            m = {}
    _CITYCODE_CACHE = m
    return m


def resolve_city_code(city: str) -> tuple[str | None, str]:
    """Return (city_code, display_name). city may be name or 9-digit code."""
    city = (city or "").strip()
    if not city:
        return None, ""
    if re.fullmatch(r"\d{9}", city):
        return city, city

    codes = load_citycode()
    # exact
    if city in codes:
        return codes[city], city
    low = city.lower()
    if low in codes:
        return codes[low], city

    # strip common suffixes
    for suf in (
        "特别行政区",
        "自治州",
        "地区",
        "市",
        "县",
        "区",
        "盟",
        "州",
        "省",
    ):
        if city.endswith(suf) and len(city) > len(suf):
            base = city[: -len(suf)]
            if base in codes:
                return codes[base], base

    # substring: prefer longest name match among codes
    best = None
    best_len = 0
    for name, code in codes.items():
        if not name or name.isascii() and " " not in name and len(name) < 3:
            # skip pure short en keys for fuzzy
            if name.isascii() and len(name) < 4:
                continue
        if name in city or city in name:
            if len(name) > best_len:
                best = (code, name)
                best_len = len(name)
    if best:
        return best[0], best[1]
    return None, city


# 中国天气网文案 → WMO 近似码（供 emoji / 中英映射）
_CN_WMO: list[tuple[str, int]] = [
    ("强雷暴", 99),
    ("雷阵雨伴有冰雹", 96),
    ("雷阵雨", 95),
    ("雷暴", 95),
    ("暴雪", 75),
    ("大雪", 75),
    ("中雪", 73),
    ("小雪", 71),
    ("阵雪", 85),
    ("雨夹雪", 67),
    ("冻雨", 66),
    ("特大暴雨", 65),
    ("大暴雨", 65),
    ("暴雨", 65),
    ("大雨", 65),
    ("中雨", 63),
    ("小雨", 61),
    ("阵雨", 80),
    ("毛毛雨", 51),
    ("雨", 63),
    ("沙尘暴", 45),
    ("浮尘", 45),
    ("扬沙", 45),
    ("霾", 45),
    ("雾", 45),
    ("阴", 3),
    ("多云", 2),
    ("晴", 0),
    ("雪", 73),
]


def cn_weather_to_wmo(text: str) -> int:
    t = (text or "").strip()
    if not t:
        return 2
    # 阴转多云 → 取前半为主
    if "转" in t:
        t = t.split("转", 1)[0]
    for key, code in _CN_WMO:
        if key in t:
            return code
    return 2


def parse_temp_range(s: str) -> tuple[float | None, float | None]:
    """'高温 29℃' / '低温 23℃' / '24/16℃' """
    if not s:
        return None, None
    nums = re.findall(r"-?\d+(?:\.\d+)?", s)
    if not nums:
        return None, None
    vals = [float(x) for x in nums]
    if len(vals) == 1:
        return vals[0], vals[0]
    return max(vals), min(vals)


def wind_level_to_ms(fl: str) -> float | None:
    """'1级' / '<3级' / '3-4级' → 近似 m/s 中值"""
    if not fl:
        return None
    nums = re.findall(r"\d+", fl)
    if not nums:
        return None
    # 风力等级粗略对应
    table = {
        0: 0.2,
        1: 1.5,
        2: 3.0,
        3: 5.0,
        4: 7.5,
        5: 10.5,
        6: 13.5,
        7: 17.0,
        8: 21.0,
        9: 25.0,
        10: 29.0,
        11: 33.0,
        12: 38.0,
    }
    levels = [int(x) for x in nums]
    mid = sum(levels) / len(levels)
    lo = int(mid)
    hi = min(12, lo + 1)
    a = table.get(lo, mid * 2)
    b = table.get(hi, a)
    frac = mid - lo
    return round(a + (b - a) * frac, 1)


def parse_humidity(s: str) -> float | None:
    if s is None:
        return None
    m = re.search(r"(\d+(?:\.\d+)?)", str(s))
    return float(m.group(1)) if m else None


# ── 国内源：中国天气网数据（itboy CDN）──────────────────────────


def fetch_cn(city: str, days: int = 10) -> dict:
    code, display = resolve_city_code(city)
    if not code:
        raise ValueError(f"city not found in CN city list: {city}")

    # HTTP 在国内更稳；HTTPS 有时握手失败
    urls = [
        f"http://t.weather.itboy.net/api/weather/city/{code}",
        f"https://t.weather.itboy.net/api/weather/city/{code}",
        f"http://t.weather.sojson.com/api/weather/city/{code}",
    ]
    last_err: Exception | None = None
    data = None
    for url in urls:
        try:
            data = http_get_json(url, timeout=10.0, insecure=True)
            if isinstance(data, dict) and (data.get("status") == 200 or data.get("data")):
                break
            last_err = ValueError(f"bad response from {url}")
            data = None
        except Exception as e:
            last_err = e
            data = None
    if not data:
        raise last_err or RuntimeError("CN weather fetch failed")

    body = data.get("data") or {}
    info = data.get("cityInfo") or {}
    name = info.get("city") or display or city
    # 去掉末尾「市」
    if isinstance(name, str) and name.endswith("市") and len(name) > 1:
        name = name[:-1]

    wendu = body.get("wendu")
    try:
        cur_temp = float(wendu) if wendu is not None and str(wendu) != "" else None
    except (TypeError, ValueError):
        cur_temp = None

    forecast = body.get("forecast") or []
    if not isinstance(forecast, list):
        forecast = []

    # 当天天气文案
    today_type = ""
    if forecast:
        today_type = (forecast[0] or {}).get("type") or ""

    days_out = []
    for item in forecast[: max(1, min(15, days))]:
        if not isinstance(item, dict):
            continue
        wtype = item.get("type") or ""
        high = item.get("high") or ""
        low = item.get("low") or ""
        # high/low 各自一条；也兼容 "24/16℃"
        tmax, _ = parse_temp_range(str(high))
        tmin, _ = parse_temp_range(str(low))
        if tmax is None and tmin is None:
            tmax, tmin = parse_temp_range(f"{high}/{low}")
        wind_ms = wind_level_to_ms(str(item.get("fl") or ""))
        days_out.append(
            {
                "date": item.get("ymd") or "",
                "code": cn_weather_to_wmo(wtype),
                "tmax": tmax,
                "tmin": tmin,
                "precip": None,
                "wind": wind_ms,
                "label": wtype,
            }
        )

    out = {
        "ok": True,
        "city": name,
        "country": "中国",
        "admin1": info.get("parent") or "",
        "lat": None,
        "lon": None,
        "city_code": code,
        "current": {
            "temp": cur_temp,
            "code": cn_weather_to_wmo(today_type),
            "humidity": parse_humidity(body.get("shidu")),
            "wind": days_out[0]["wind"] if days_out else None,
            "time": info.get("updateTime") or data.get("time") or "",
            "label": today_type,
            "aqi": body.get("quality"),
            "pm25": body.get("pm25"),
        },
        "daily": days_out,
        "source": "cn/itboy (中国天气网)",
        "fetched_at": int(time.time()),
    }
    return out


# ── Open-Meteo ──────────────────────────────────────────────────


def geocode_open_meteo(city: str, lang: str = "zh") -> dict | None:
    q = urllib.parse.urlencode(
        {
            "name": city,
            "count": 1,
            "language": "zh" if str(lang).startswith("zh") else "en",
            "format": "json",
        }
    )
    url = "https://geocoding-api.open-meteo.com/v1/search?" + q
    data = http_get_json(url, timeout=15.0)
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


def forecast_open_meteo(lat: float, lon: float, days: int = 10) -> dict:
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
    return http_get_json(url, timeout=15.0)


def fetch_open_meteo(
    city: str,
    lang: str = "zh",
    days: int = 10,
    lat: float | None = None,
    lon: float | None = None,
    name: str = "",
    country: str = "",
    admin1: str = "",
) -> dict:
    if lat is None or lon is None:
        if not city:
            raise ValueError("need --city or --lat/--lon")
        geo = geocode_open_meteo(city, lang=lang)
        if not geo:
            raise ValueError(f"city not found: {city}")
        lat, lon = geo["lat"], geo["lon"]
        name = geo["name"]
        country = geo.get("country") or ""
        admin1 = geo.get("admin1") or ""
    elif not name:
        name = f"{lat:.2f},{lon:.2f}"

    data = forecast_open_meteo(float(lat), float(lon), days=days)
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

    return {
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
    source = "auto"
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
        elif a == "--source" and i + 1 < len(args):
            source = (args[i + 1] or "auto").strip().lower()
            i += 2
        else:
            i += 1

    # 兼容别名
    if source in ("china", "domestic", "itboy", "nmc", "sojson"):
        source = "cn"
    if source in ("om", "openmeteo", "meteo"):
        source = "open-meteo"
    if source not in ("auto", "cn", "open-meteo"):
        source = "auto"

    errors: list[str] = []

    try:
        # 有经纬度时直接走 open-meteo
        if lat is not None and lon is not None:
            out = fetch_open_meteo(
                city=city,
                lang=lang,
                days=days,
                lat=lat,
                lon=lon,
                name=name,
                country=country,
                admin1=admin1,
            )
            print(json.dumps(out, ensure_ascii=False))
            return 0

        if source in ("auto", "cn"):
            try:
                out = fetch_cn(city or name, days=days)
                print(json.dumps(out, ensure_ascii=False))
                return 0
            except Exception as e:
                errors.append(f"cn: {e}")
                if source == "cn":
                    print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
                    return 3

        if source in ("auto", "open-meteo"):
            try:
                out = fetch_open_meteo(city=city, lang=lang, days=days)
                if errors:
                    out["fallback_from"] = "; ".join(errors)
                print(json.dumps(out, ensure_ascii=False))
                return 0
            except Exception as e:
                errors.append(f"open-meteo: {e}")

        print(
            json.dumps(
                {"ok": False, "error": " | ".join(errors) or "fetch failed"},
                ensure_ascii=False,
            )
        )
        return 1
    except urllib.error.HTTPError as e:
        print(json.dumps({"ok": False, "error": f"HTTP {e.code}: {e.reason}"}, ensure_ascii=False))
        return 1
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
