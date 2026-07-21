# weather.nvim

[English](README.md) | **中文**

状态栏显示 **`城市 天气emoji 天气 温度`**，命令弹窗用表格查看 **10 天预报**。  
默认 **`source = "auto"`**：**系统语言为中文 → 国内源**（中国天气网 / itboy，失败再回退 Open-Meteo）；**否则 → Open-Meteo**。**均无需 API Key**。结果缓存到本地，**默认每小时**刷新。

## 依赖

| 组件 | 说明 |
|------|------|
| Neovim 0.9+ | |
| **Python3** | 标准库 `urllib`（`scripts/fetch_weather.py`） |
| 网络 | 国内源 + 可选 open-meteo.com |

## 安装

```vim
Plug '/path/to/nvimplugins/weather'
" 或整仓 nvimplugins
```

### 状态栏

数据在 `g:weather_status`。若使用 **vim-airline**（会接管 `statusline`），不要只改 `o.statusline`，应挂到 airline 分区：

```vim
" plug#end() 之后
autocmd User AirlineAfterInit let g:airline_section_x = '%{get(g:, "weather_status", "")}'
" 或拼在 filetype 后面：
" autocmd User AirlineAfterInit let g:airline_section_x .= ' %{get(g:, "weather_status", "")}'
```

```lua
-- plug#end() 之后
vim.api.nvim_create_autocmd("User", {
  pattern = "AirlineAfterInit",
  callback = function()
    -- 占用 section_x（原 filetype 区）；想保留 filetype 可改 section_y / z
    vim.g.airline_section_x = [[%{get(g:, "weather_status", "")}]]
  end,
})
```

未使用 airline 时：

```vim
set statusline+=\ %{get(g:,'weather_status','')}
```

## 命令

| 命令 | 说明 |
|------|------|
| **`:Weather`** | 打开 10 天预报浮窗 |
| **`:Weather 上海`** | 切换城市并打开浮窗 |
| **`:WeatherCity 上海`** | 只切换城市并刷新 |
| **`:WeatherRefresh`** | 强制刷新（忽略缓存） |
| **`<leader>we`** | 打开 10 天预报（`keys_open`，可改） |

### 浮窗按键

| 键 | 作用 |
|----|------|
| `q` / `Esc` | 关闭 |
| `r` | 强制刷新 |
| **`L`** | 中/英文 |

浮窗底部显示 **获取时间**（如 `获取时间 2026-07-17 16:42:08 (缓存 12m)`）与数据来源。

## 配置

```lua
require("weather").setup({
  city = "北京",           -- 必填才会启用；不配则不拉数据、状态栏为空
  -- 数据源：auto（默认：系统中文→国内，否则 Open-Meteo）| cn | open-meteo
  source = "auto",
  cache_ttl = 3600,        -- 缓存秒数
  refresh_ms = 3600 * 1000,-- 自动刷新间隔
  status_format = "{city} {emoji} {weather} {temp}°",
  -- Windows 终端里 emoji 占位宽度常算错，会把后面 music 进度挤乱
  -- （如 02:12／ 显示成 02:122/）。可关掉 emoji：
  -- status_emoji = false,
  ui_lang = "auto",
  auto_start = true,       -- 仅在已配置 city 时生效
  python = "python",
  keys_open = "<leader>we", -- 打开 10 天预报；false 关闭
})
```

**未配置 `city` 时默认不启用**（不请求网络、状态栏为空）。通过 `setup({ city = "..." })`、`:WeatherCity` 或 `:Weather 城市` 设置后启用并记忆。

**与 music 状态栏同开时**：若进度时间显示粘连/错位，优先试 `status_emoji = false`，或更新本插件（已对 emoji 去变体符并补显示宽度）。

## 缓存

| 文件 | 内容 |
|------|------|
| `stdpath("data")/weather-nvim-cache.json` | 当前天气 + 10 天预报 + `fetched_at` |
| `stdpath("data")/weather-nvim-city.json` | 记忆城市 |
| `stdpath("data")/weather-nvim-prefs.json` | 界面语言 |

启动时先读缓存上状态栏；过期或满 1 小时再 HTTP 请求。

## 数据说明

| `source` | 说明 |
|----------|------|
| **`auto`**（默认） | **系统中文 → cn**（失败再回退 open-meteo）；**非中文 → open-meteo** |
| **`cn`** | 强制国内：中国天气网数据（`t.weather.itboy.net`），城市码见 `scripts/citycode.json` |
| **`open-meteo`** | 强制 [Open-Meteo](https://open-meteo.com/)（全球） |

- 国内源适合中国城市，延迟通常明显低于 Open-Meteo。
- `auto` 看**系统 locale**，不受浮窗 `L` 切换界面语言影响。
- 天气码映射为中英文文案 + emoji；国内源保留原始中文天气文案。
