# weather.nvim

**English** | [中文](README.zh.md)

Statusline snippet **`city emoji weather temp`**, plus a float **10-day table**.  
Fetches from public [Open-Meteo](https://open-meteo.com/) over HTTP (**no API key**). Caches to disk; refreshes **hourly** by default.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | |
| **Python3** | stdlib only (`scripts/fetch_weather.py`) |
| Network | open-meteo.com |

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

Data source: **Open-Meteo** public HTTP (WMO weather codes → emoji).
