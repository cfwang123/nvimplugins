# weather.nvim

**English** | [中文](README.zh.md)

Statusline snippet **`city emoji weather temp`**, plus a float **10-day table**.  
Default **`source = "auto"`**: **Chinese system locale → domestic CN source** (fallback Open-Meteo on failure); **otherwise → Open-Meteo**. **No API key**. Caches to disk; refreshes **hourly** by default.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | |
| **Python3** | stdlib only (`scripts/fetch_weather.py`) |
| Network | domestic CN source + optional open-meteo.com |

## Statusline

```vim
set statusline+=\ %{get(g:,'weather_status','')}
```

```lua
vim.o.statusline = vim.o.statusline .. " %{%v:lua.require'weather'.statusline()%}"
```

## Commands

| Command | Description |
|---------|-------------|
| **`:Weather`** | Open 10-day popup |
| **`:Weather Shanghai`** | Set city + open |
| **`:WeatherCity Shanghai`** | Set city + refresh |
| **`:WeatherRefresh`** | Force refresh |
| **`<leader>we`** | Open 10-day forecast (`keys_open`) |

### Popup keys

| Key | Action |
|-----|--------|
| `q` / `Esc` | Close |
| `r` | Refresh |
| **`L`** | Toggle language |

Footer shows **fetch time** (e.g. `Fetched 2026-07-17 16:42:08 (Cache 12m)`) and data source.

## Config

```lua
require("weather").setup({
  city = "Beijing",        -- required to enable; no city → inactive
  -- source: "auto" (default: CN if system Chinese, else Open-Meteo) | "cn" | "open-meteo"
  source = "auto",
  cache_ttl = 3600,
  refresh_ms = 3600 * 1000,
  status_format = "{city} {emoji} {weather} {temp}°",
  ui_lang = "auto",
  auto_start = true,       -- only when city is set
  keys_open = "<leader>we",
})
```

**No `city` → disabled** (no network, empty statusline). Enable via `setup({ city = "..." })`, `:WeatherCity`, or `:Weather <city>` (remembered).

## Cache files

- `stdpath("data")/weather-nvim-cache.json`
- `stdpath("data")/weather-nvim-city.json`
- `stdpath("data")/weather-nvim-prefs.json`

| `source` | Backend |
|----------|---------|
| **`auto`** (default) | **System Chinese → cn** (fallback open-meteo); **else → open-meteo** |
| **`cn`** | China Weather Net data via itboy CDN (`citycode.json`) |
| **`open-meteo`** | [Open-Meteo](https://open-meteo.com/) (global) |

`auto` follows **system locale**, not the UI language toggled by `L`.  
WMO / CN weather text → emoji labels.
