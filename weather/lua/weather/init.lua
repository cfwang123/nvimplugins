---@mod weather 状态栏天气 + 10 天预报浮窗（国内源 + Open-Meteo，无 API Key）
local i18n = require("weather.i18n")

local M = {}

local default_config = {
  ---城市名（中英文均可）。默认 nil：未配置则不自动启用、不拉数据
  city = nil, ---@type string|nil
  python = "python",
  ---数据源：auto=系统中文→国内 cn，否则 open-meteo | cn | open-meteo
  ---auto 下中文系统会优先国内源（失败再回退 Open-Meteo）
  source = "auto", ---@type "auto"|"cn"|"open-meteo"
  ---缓存有效期（秒），默认 1 小时
  cache_ttl = 3600,
  ---自动刷新间隔（毫秒），默认 1 小时
  refresh_ms = 3600 * 1000,
  ---状态栏格式：{city} {emoji} {weather} {temp}
  status_format = "{city} {emoji} {weather} {temp}°",
  ---statusline 是否显示 emoji。Windows 终端里 emoji 占位宽度常算错，
  ---会把后面 music 等文字挤乱（如 02:12 / 变成 02:122/）。默认仍开，但会补齐宽度。
  status_emoji = true,
  ui_lang = "auto",
  border = "rounded",
  ---有城市时启动自动拉取；无城市时忽略
  auto_start = true,
  ---打开 10 天预报浮窗的快捷键；false 关闭
  keys_open = "<leader>we",
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}

local state = {
  data = nil, ---@type table|nil
  line = "", ---状态栏字符串
  busy = false,
  timer = nil,
  popup_buf = nil,
  popup_win = nil,
  city = nil, ---@type string|nil
  enabled = false, ---有有效城市后为 true
}

local NS = vim.api.nvim_create_namespace("weather")

local function cache_path()
  return vim.fn.stdpath("data") .. "/weather-nvim-cache.json"
end

local function city_prefs_path()
  return vim.fn.stdpath("data") .. "/weather-nvim-city.json"
end

local function ensure_hl()
  -- nvim 0.9 不支持 force 键，带上会导致 set_hl 整次失败
  local function hl(name, spec)
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
  hl("WeatherNormal", { fg = "#111111", bg = "#ffffff" })
  hl("WeatherTitle", { fg = "#111111", bg = "#ffffff", bold = true })
  hl("WeatherHelp", { fg = "#666666", bg = "#ffffff" })
  hl("WeatherHead", { fg = "#003366", bg = "#e8f0ff", bold = true })
  hl("WeatherBorder", { fg = "#4488aa", bg = "#ffffff" })
  hl("WeatherCur", { fg = "#111111", bg = "#fff8e0", bold = true })
end

local function script_path()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  return vim.fn.fnamemodify(src, ":p:h:h:h") .. "/scripts/fetch_weather.py"
end

local function resolve_python()
  local cands = { config.python, "python", "python3" }
  if vim.fn.has("win32") == 1 then
    table.insert(cands, "py")
  end
  for _, c in ipairs(cands) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      local abs = vim.fn.exepath(c)
      if not abs or abs == "" then
        abs = c
      end
      abs = vim.fn.fnamemodify(abs, ":p")
      if c == "py" or abs:lower():match("[/\\]py%.exe$") then
        return { abs, "-3" }
      end
      return { abs }
    end
  end
  return nil
end

local function load_city_pref()
  local f = city_prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" and type(data.city) == "string" and data.city ~= "" then
    return data.city
  end
  return nil
end

local function save_city_pref(city)
  pcall(function()
    local f = city_prefs_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({ vim.json.encode({ city = city }) }, f)
  end)
end

---@return table|nil
local function load_cache()
  local f = cache_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if not ok or type(data) ~= "table" or not data.ok then
    return nil
  end
  return data
end

---@param data table
local function save_cache(data)
  pcall(function()
    local f = cache_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({ vim.json.encode(data) }, f)
  end)
end

---@param data table|nil
---@return boolean
local function cache_fresh(data)
  if not data or not data.fetched_at then
    return false
  end
  local ttl = tonumber(config.cache_ttl) or 3600
  return (os.time() - tonumber(data.fetched_at)) < ttl
end

-- UTF-8 of U+FE0F（emoji 变体选择符）
local FE0F = "\239\184\143"
---表格里 emoji 列固定显示宽度（含与文字间隔），保证「晴/阴/多云」左缘对齐
local EMOJI_FIELD_W = 3

---去掉变体符后的 emoji 文本
---@param emoji string
---@return string
local function strip_emoji_vs(emoji)
  return (emoji or ""):gsub(FE0F, "")
end

---nvim-qt / Win 下真实视觉宽度（strdisplaywidth 对 ☀☁ 等常偏大）
---@param emoji string  已去 FE0F 亦可
---@return integer
local function emoji_visual_width(emoji)
  local s = strip_emoji_vs(emoji)
  if s == "" then
    return 0
  end
  -- 文本符号类天气图标：GUI 里通常只占 1 格（晴/阴/雪）
  if s == "☀" or s == "☁" or s == "❄" then
    return 1
  end
  local w = vim.fn.strdisplaywidth(s)
  if w < 1 then
    return 1
  end
  -- 彩色 emoji 多数按 2 格；异常偏大时夹紧，避免把文字顶飞
  if w > 2 then
    return 2
  end
  return w
end

---将 emoji 垫到固定显示列宽，使后续文字从同一列开始
---@param emoji string
---@param field_w? integer
---@return string
local function pad_emoji_field(emoji, field_w)
  field_w = field_w or EMOJI_FIELD_W
  local s = strip_emoji_vs(emoji)
  if s == "" then
    return string.rep(" ", field_w)
  end
  local ew = emoji_visual_width(s)
  local n = field_w - ew
  if n < 1 then
    n = 1
  end
  return s .. string.rep(" ", n)
end

---按显示宽度右补空格（勿依赖后方 local pad，Lua 作用域）
---@param s string
---@param w integer
---@return string
local function pad_dw(s, w)
  s = tostring(s or "")
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then
    return s
  end
  return s .. string.rep(" ", w - dw)
end

---表格「天气」单元格：固定 emoji 列 + 文案，再 pad 到列宽
---@param emoji string
---@param label string
---@param total_w integer
---@return string
local function format_weather_cell(emoji, label, total_w)
  return pad_dw(pad_emoji_field(emoji, EMOJI_FIELD_W) .. tostring(label or ""), total_w)
end

---statusline 用 emoji：去掉变体选择符，并补足显示宽度，避免挤坏后面的 music 进度
---@param emoji string
---@return string
local function statusline_emoji(emoji)
  if config.status_emoji == false then
    return ""
  end
  -- 固定 2 格宽字段 + 1 缓冲空格
  return pad_emoji_field(emoji, 2) .. " "
end

---@param data table|nil
local function update_statusline(data)
  if not data or not data.current then
    state.line = ""
    vim.g.weather_status = ""
    return
  end
  local city = data.city or state.city or ""
  local emoji, weather = i18n.weather_of(data.current.code, data.current.label)
  emoji = statusline_emoji(emoji)
  local temp = data.current.temp
  if temp ~= nil then
    temp = string.format("%.0f", tonumber(temp) or 0)
  else
    temp = "?"
  end
  local fmt = config.status_format or "{city} {emoji} {weather} {temp}°"
  if config.status_emoji == false then
    -- 去掉可能残留的双空格
    fmt = fmt:gsub("%s*{emoji}%s*", " ")
  end
  local s = fmt
  s = s:gsub("{city}", city)
  s = s:gsub("{emoji}", emoji)
  s = s:gsub("{weather}", weather)
  s = s:gsub("{temp}", temp)
  s = s:gsub("%s+", " ")
  s = vim.trim(s)
  state.line = s
  vim.g.weather_status = s
  -- 触发状态栏刷新（含 vim-airline）
  pcall(vim.cmd, "redrawstatus!")
  if vim.g.loaded_airline == 1 or vim.g.airline_section_a then
    pcall(vim.cmd, "silent! AirlineRefresh")
  end
end

---状态栏用：返回 `城市 emoji 天气 温度`
function M.statusline()
  if state.line and state.line ~= "" then
    return state.line
  end
  return vim.g.weather_status or ""
end

---解析实际数据源：auto 时按**系统语言**（非 UI 切换）
---中文系统 → cn；否则 → open-meteo
---@return string "cn"|"open-meteo"|"auto"
local function resolve_source()
  local source = config.source or "auto"
  if source == "china" or source == "domestic" or source == "itboy" then
    return "cn"
  end
  if source == "om" or source == "openmeteo" or source == "open-meteo" then
    return "open-meteo"
  end
  if source == "cn" then
    return "cn"
  end
  -- auto：看系统 locale，不看 L 切换后的 UI 语言
  local sys = i18n.detect()
  if sys == "zh" then
    return "auto" -- 先 cn 再回退 open-meteo
  end
  return "open-meteo"
end

-- ── 异步外部命令 / HTTP（不阻塞 UI）──────────────────────────

---@param cmd string[]
---@param opts? { timeout_ms?: integer }
---@param on_exit fun(res: { code: integer, stdout: string, stderr: string })
local function run_async(cmd, opts, on_exit)
  opts = opts or {}
  local finished = false
  local function finish(res)
    if finished then
      return
    end
    finished = true
    vim.schedule(function()
      on_exit(res)
    end)
  end

  -- Windows 上 vim.system 偶发 -1，优先 jobstart
  local out_chunks, err_chunks = {}, {}
  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= nil then
          out_chunks[#out_chunks + 1] = line
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= nil then
          err_chunks[#err_chunks + 1] = line
        end
      end
    end,
    on_exit = function(_, code)
      if out_chunks[#out_chunks] == "" then
        out_chunks[#out_chunks] = nil
      end
      if err_chunks[#err_chunks] == "" then
        err_chunks[#err_chunks] = nil
      end
      finish({
        code = code or -1,
        stdout = table.concat(out_chunks, "\n"),
        stderr = table.concat(err_chunks, "\n"),
      })
    end,
  })
  if job <= 0 then
    finish({ code = -1, stdout = "", stderr = "jobstart failed" })
    return
  end
  local timeout = tonumber(opts.timeout_ms)
  if timeout and timeout > 0 then
    vim.defer_fn(function()
      if finished then
        return
      end
      if vim.fn.jobwait({ job }, 0)[1] == -1 then
        pcall(vim.fn.jobstop, job)
      end
    end, timeout)
  end
end

---Windows 优先 curl.exe，避免进 PowerShell 的 curl 别名
---@return string|nil
local function resolve_curl()
  if vim.fn.has("win32") == 1 and vim.fn.executable("curl.exe") == 1 then
    return "curl.exe"
  end
  if vim.fn.executable("curl") == 1 then
    return "curl"
  end
  return nil
end

---@param url string
---@param opts? { timeout?: number, insecure?: boolean }
---@param on_done fun(ok: boolean, body?: string, err?: string)
local function http_get(url, opts, on_done)
  opts = opts or {}
  local timeout = tonumber(opts.timeout) or 12
  local curl = resolve_curl()
  if not curl then
    on_done(false, nil, "no curl")
    return
  end
  local cmd = {
    curl,
    "-sS",
    "-L",
    "--max-time",
    tostring(timeout),
    "-A",
    "nvimplugins-weather/1.2",
    "-H",
    "Accept: application/json,text/plain,*/*",
  }
  if opts.insecure then
    cmd[#cmd + 1] = "-k"
  end
  cmd[#cmd + 1] = url
  run_async(cmd, { timeout_ms = math.floor((timeout + 3) * 1000) }, function(res)
    local body = (res.stdout or ""):gsub("^\239\187\191", ""):gsub("\r", "")
    if (res.code or -1) ~= 0 and body == "" then
      local err = vim.trim(res.stderr or "")
      if err == "" then
        err = "curl exit " .. tostring(res.code)
      end
      on_done(false, nil, err)
      return
    end
    on_done(true, body, nil)
  end)
end

---@param url string
---@param opts? { timeout?: number, insecure?: boolean }
---@param on_done fun(ok: boolean, data?: table, err?: string)
local function http_get_json(url, opts, on_done)
  http_get(url, opts, function(ok, body, err)
    if not ok then
      on_done(false, nil, err)
      return
    end
    local text = vim.trim(body or "")
    local okj, data = pcall(vim.json.decode, text)
    if not okj or type(data) ~= "table" then
      on_done(false, nil, "bad json")
      return
    end
    on_done(true, data, nil)
  end)
end

---依次尝试多个 URL，返回第一个合法 JSON
---@param urls string[]
---@param opts? { timeout?: number, insecure?: boolean }
---@param accept? fun(data: table): boolean
---@param on_done fun(ok: boolean, data?: table, err?: string)
local function http_get_json_first(urls, opts, accept, on_done)
  local i = 1
  local last_err = "no urls"
  local function try_next()
    if i > #urls then
      on_done(false, nil, last_err)
      return
    end
    local url = urls[i]
    i = i + 1
    http_get_json(url, opts, function(ok, data, err)
      if ok and data and (not accept or accept(data)) then
        on_done(true, data, nil)
        return
      end
      last_err = err or "reject"
      try_next()
    end)
  end
  try_next()
end

-- ── citycode / CN 解析 ──────────────────────────────────────

local citycode_map ---@type table<string,string>|nil

local function citycode_path()
  return vim.fn.fnamemodify(script_path(), ":h") .. "/citycode.json"
end

---@return table<string,string>
local function load_citycode()
  if citycode_map then
    return citycode_map
  end
  citycode_map = {}
  local path = citycode_path()
  if vim.fn.filereadable(path) == 1 then
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if ok and type(data) == "table" then
      for k, v in pairs(data) do
        if k and v then
          citycode_map[tostring(k)] = tostring(v)
        end
      end
    end
  end
  return citycode_map
end

---@param city string
---@return string|nil code
---@return string display
local function resolve_city_code(city)
  city = vim.trim(city or "")
  if city == "" then
    return nil, ""
  end
  if city:match("^%d%d%d%d%d%d%d%d%d$") then
    return city, city
  end
  local codes = load_citycode()
  if codes[city] then
    return codes[city], city
  end
  local low = city:lower()
  if codes[low] then
    return codes[low], city
  end
  local function ends_with(s, suf)
    return #s >= #suf and s:sub(-#suf) == suf
  end
  for _, suf in ipairs({
    "特别行政区",
    "自治州",
    "地区",
    "市",
    "县",
    "区",
    "盟",
    "州",
    "省",
  }) do
    if ends_with(city, suf) and #city > #suf then
      local base = city:sub(1, #city - #suf)
      if codes[base] then
        return codes[base], base
      end
    end
  end
  local best_code, best_name, best_len = nil, nil, 0
  for name, code in pairs(codes) do
    if type(name) == "string" and name ~= "" then
      local skip = name:match("^[%w%s%-]+$") and #name < 4
      if not skip and (city:find(name, 1, true) or name:find(city, 1, true)) then
        if #name > best_len then
          best_code, best_name, best_len = code, name, #name
        end
      end
    end
  end
  if best_code then
    return best_code, best_name or city
  end
  return nil, city
end

-- 中国天气网文案 → WMO 近似码
local CN_WMO = {
  { "强雷暴", 99 },
  { "雷阵雨伴有冰雹", 96 },
  { "雷阵雨", 95 },
  { "雷暴", 95 },
  { "暴雪", 75 },
  { "大雪", 75 },
  { "中雪", 73 },
  { "小雪", 71 },
  { "阵雪", 85 },
  { "雨夹雪", 67 },
  { "冻雨", 66 },
  { "特大暴雨", 65 },
  { "大暴雨", 65 },
  { "暴雨", 65 },
  { "大雨", 65 },
  { "中雨", 63 },
  { "小雨", 61 },
  { "阵雨", 80 },
  { "毛毛雨", 51 },
  { "雨", 63 },
  { "沙尘暴", 45 },
  { "浮尘", 45 },
  { "扬沙", 45 },
  { "霾", 45 },
  { "雾", 45 },
  { "阴", 3 },
  { "多云", 2 },
  { "晴", 0 },
  { "雪", 73 },
}

---@param text string
---@return integer
local function cn_weather_to_wmo(text)
  local t = vim.trim(text or "")
  if t == "" then
    return 2
  end
  if t:find("转", 1, true) then
    t = t:match("^(.-)转") or t
  end
  for _, pair in ipairs(CN_WMO) do
    if t:find(pair[1], 1, true) then
      return pair[2]
    end
  end
  return 2
end

---@param s string
---@return number|nil, number|nil
local function parse_temp_range(s)
  if not s or s == "" then
    return nil, nil
  end
  local vals = {}
  for n in tostring(s):gmatch("%-?%d+%.?%d*") do
    vals[#vals + 1] = tonumber(n)
  end
  if #vals == 0 then
    return nil, nil
  end
  if #vals == 1 then
    return vals[1], vals[1]
  end
  return math.max(vals[1], vals[2]), math.min(vals[1], vals[2])
end

local WIND_LEVEL_MS = {
  [0] = 0.2,
  [1] = 1.5,
  [2] = 3.0,
  [3] = 5.0,
  [4] = 7.5,
  [5] = 10.5,
  [6] = 13.5,
  [7] = 17.0,
  [8] = 21.0,
  [9] = 25.0,
  [10] = 29.0,
  [11] = 33.0,
  [12] = 38.0,
}

---@param fl string
---@return number|nil
local function wind_level_to_ms(fl)
  if not fl or fl == "" then
    return nil
  end
  local levels = {}
  for n in tostring(fl):gmatch("%d+") do
    levels[#levels + 1] = tonumber(n)
  end
  if #levels == 0 then
    return nil
  end
  local sum = 0
  for _, v in ipairs(levels) do
    sum = sum + v
  end
  local mid = sum / #levels
  local lo = math.floor(mid)
  local hi = math.min(12, lo + 1)
  local a = WIND_LEVEL_MS[lo] or (mid * 2)
  local b = WIND_LEVEL_MS[hi] or a
  local frac = mid - lo
  return math.floor((a + (b - a) * frac) * 10 + 0.5) / 10
end

---@param s any
---@return number|nil
local function parse_humidity(s)
  if s == nil then
    return nil
  end
  local m = tostring(s):match("(%d+%.?%d*)")
  return m and tonumber(m) or nil
end

---@param city string
---@param days integer
---@param raw table
---@param display string
---@param code string
---@return table
local function parse_cn_payload(city, days, raw, display, code)
  local body = raw.data or {}
  local info = raw.cityInfo or {}
  local name = info.city or display or city
  if type(name) == "string" and #name > 3 and name:sub(-3) == "市" then
    name = name:sub(1, #name - 3)
  end
  local cur_temp = tonumber(body.wendu)

  local forecast = body.forecast or {}
  if type(forecast) ~= "table" then
    forecast = {}
  end
  local today_type = ""
  if forecast[1] and type(forecast[1]) == "table" then
    today_type = forecast[1].type or ""
  end

  local days_out = {}
  local limit = math.max(1, math.min(15, days or 10))
  for idx, item in ipairs(forecast) do
    if idx > limit then
      break
    end
    if type(item) == "table" then
      local wtype = item.type or ""
      local high = tostring(item.high or "")
      local low = tostring(item.low or "")
      local tmax = select(1, parse_temp_range(high))
      local tmin = select(1, parse_temp_range(low))
      if tmax == nil and tmin == nil then
        tmax, tmin = parse_temp_range(high .. "/" .. low)
      end
      days_out[#days_out + 1] = {
        date = item.ymd or "",
        code = cn_weather_to_wmo(wtype),
        tmax = tmax,
        tmin = tmin,
        precip = nil,
        wind = wind_level_to_ms(tostring(item.fl or "")),
        label = wtype,
      }
    end
  end

  return {
    ok = true,
    city = name,
    country = "中国",
    admin1 = info.parent or "",
    lat = nil,
    lon = nil,
    city_code = code,
    current = {
      temp = cur_temp,
      code = cn_weather_to_wmo(today_type),
      humidity = parse_humidity(body.shidu),
      wind = days_out[1] and days_out[1].wind or nil,
      time = info.updateTime or raw.time or "",
      label = today_type,
      aqi = body.quality,
      pm25 = body.pm25,
    },
    daily = days_out,
    source = "cn/itboy (中国天气网)",
    fetched_at = os.time(),
  }
end

---@param city string
---@param days integer
---@param on_done fun(ok: boolean, data?: table, err?: string)
local function fetch_cn_async(city, days, on_done)
  local code, display = resolve_city_code(city)
  if not code then
    on_done(false, nil, "city not found in CN city list: " .. tostring(city))
    return
  end
  local urls = {
    "http://t.weather.itboy.net/api/weather/city/" .. code,
    "https://t.weather.itboy.net/api/weather/city/" .. code,
    "http://t.weather.sojson.com/api/weather/city/" .. code,
  }
  http_get_json_first(urls, { timeout = 10, insecure = true }, function(data)
    return data.status == 200 or data.data ~= nil
  end, function(ok, raw, err)
    if not ok or not raw then
      on_done(false, nil, err or "CN weather fetch failed")
      return
    end
    local parsed = parse_cn_payload(city, days, raw, display, code)
    on_done(true, parsed, nil)
  end)
end

---@param lat number
---@param lon number
---@param days integer
---@param meta { name: string, country?: string, admin1?: string }
---@param on_done fun(ok: boolean, data?: table, err?: string)
local function forecast_open_meteo_async(lat, lon, days, meta, on_done)
  local q = vim.fn.printf(
    "latitude=%s&longitude=%s&current=temperature_2m,weather_code,relative_humidity_2m,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_speed_10m_max&timezone=auto&forecast_days=%d",
    tostring(lat),
    tostring(lon),
    math.max(1, math.min(16, days or 10))
  )
  local url = "https://api.open-meteo.com/v1/forecast?" .. q
  http_get_json(url, { timeout = 15 }, function(ok, data, err)
    if not ok or not data then
      on_done(false, nil, err or "open-meteo forecast failed")
      return
    end
    local cur = data.current or {}
    local daily = data.daily or {}
    local dates = daily.time or {}
    local codes = daily.weather_code or {}
    local tmax = daily.temperature_2m_max or {}
    local tmin = daily.temperature_2m_min or {}
    local precip = daily.precipitation_sum or {}
    local wind = daily.wind_speed_10m_max or {}
    local days_out = {}
    for idx, d in ipairs(dates) do
      days_out[#days_out + 1] = {
        date = d,
        code = codes[idx],
        tmax = tmax[idx],
        tmin = tmin[idx],
        precip = precip[idx],
        wind = wind[idx],
      }
    end
    on_done(true, {
      ok = true,
      city = meta.name,
      country = meta.country or "",
      admin1 = meta.admin1 or "",
      lat = lat,
      lon = lon,
      current = {
        temp = cur.temperature_2m,
        code = cur.weather_code,
        humidity = cur.relative_humidity_2m,
        wind = cur.wind_speed_10m,
        time = cur.time,
      },
      daily = days_out,
      source = "open-meteo.com",
      fetched_at = os.time(),
    }, nil)
  end)
end

---@param city string
---@param lang string
---@param days integer
---@param on_done fun(ok: boolean, data?: table, err?: string)
local function fetch_open_meteo_async(city, lang, days, on_done)
  local language = (tostring(lang or ""):sub(1, 2) == "zh") and "zh" or "en"
  -- curl -G --data-urlencode：中文城市名安全编码，且全程异步
  local curl = resolve_curl()
  if not curl then
    on_done(false, nil, "no curl")
    return
  end
  local geo_cmd = {
    curl,
    "-sS",
    "-L",
    "--max-time",
    "15",
    "-A",
    "nvimplugins-weather/1.2",
    "-G",
    "https://geocoding-api.open-meteo.com/v1/search",
    "--data-urlencode",
    "name=" .. city,
    "--data-urlencode",
    "count=1",
    "--data-urlencode",
    "language=" .. language,
    "--data-urlencode",
    "format=json",
  }
  run_async(geo_cmd, { timeout_ms = 18000 }, function(res)
    local body = (res.stdout or ""):gsub("^\239\187\191", ""):gsub("\r", "")
    if (res.code or -1) ~= 0 and body == "" then
      on_done(false, nil, (res.stderr ~= "" and res.stderr) or "geocode failed")
      return
    end
    local okj, data = pcall(vim.json.decode, vim.trim(body))
    if not okj or type(data) ~= "table" then
      on_done(false, nil, "geocode bad json")
      return
    end
    local results = data.results or {}
    local r = results[1]
    if type(r) ~= "table" or r.latitude == nil or r.longitude == nil then
      on_done(false, nil, "city not found: " .. tostring(city))
      return
    end
    forecast_open_meteo_async(r.latitude, r.longitude, days, {
      name = r.name or city,
      country = r.country or "",
      admin1 = r.admin1 or "",
    }, on_done)
  end)
end

---Python 回退（无 curl 或 Lua 路径失败时）
---@param city string
---@param lang string
---@param source string
---@param on_done fun(ok: boolean, data?: table, err?: string)
local function fetch_via_python(city, lang, source, on_done)
  local py = resolve_python()
  if not py then
    on_done(false, nil, i18n.t("need_python"))
    return
  end
  local script = vim.fn.fnamemodify(script_path(), ":p")
  if vim.fn.filereadable(script) ~= 1 then
    on_done(false, nil, i18n.t("script_missing") .. script)
    return
  end
  local cmd = {}
  for _, a in ipairs(py) do
    cmd[#cmd + 1] = a
  end
  vim.list_extend(cmd, {
    "-X",
    "utf8",
    script,
    "--city",
    city,
    "--lang",
    lang,
    "--days",
    "10",
    "--source",
    source,
  })
  run_async(cmd, { timeout_ms = 60000 }, function(res)
    local out = (res.stdout or ""):gsub("^\239\187\191", ""):gsub("\r", "")
    local json_str = vim.trim(out)
    local last = json_str:match("(%b{})%s*$")
    if last then
      json_str = last
    end
    local okj, data = pcall(vim.json.decode, json_str)
    if not okj or type(data) ~= "table" then
      local err = vim.trim(res.stderr or "")
      if err == "" then
        err = "bad json / exit " .. tostring(res.code)
      end
      on_done(false, nil, err)
      return
    end
    if data.ok == false then
      on_done(false, nil, tostring(data.error or "fetch failed"))
      return
    end
    on_done(true, data, nil)
  end)
end

---@param on_done? fun(ok: boolean, data: table|nil, err?: string)
local function fetch_remote(on_done)
  on_done = on_done or function() end
  if state.busy then
    return
  end
  state.busy = true
  local city = state.city or config.city or "北京"
  local lang = i18n.get()
  local source = resolve_source()
  local days = 10

  local function finish(ok, data, err)
    state.busy = false
    if ok and data then
      data.query_city = state.city or config.city
      data.query_source = config.source or "auto"
      state.data = data
      save_cache(data)
      update_statusline(data)
      if state.popup_win and vim.api.nvim_win_is_valid(state.popup_win) then
        M._render_popup()
      end
    end
    on_done(ok, data, err)
  end

  local function via_python(prev_err)
    fetch_via_python(city, lang, source, function(ok, data, err)
      if ok then
        finish(true, data, nil)
      else
        local msg = err or "fetch failed"
        if prev_err and prev_err ~= "" then
          msg = prev_err .. " | " .. msg
        end
        finish(false, nil, msg)
      end
    end)
  end

  if not resolve_curl() then
    via_python(nil)
    return
  end

  local errors = {}

  local function try_open_meteo()
    fetch_open_meteo_async(city, lang, days, function(ok, data, err)
      if ok and data then
        if #errors > 0 then
          data.fallback_from = table.concat(errors, "; ")
        end
        finish(true, data, nil)
        return
      end
      errors[#errors + 1] = "open-meteo: " .. tostring(err or "fail")
      -- curl 路径失败时再试 Python
      via_python(table.concat(errors, " | "))
    end)
  end

  local function try_cn()
    fetch_cn_async(city, days, function(ok, data, err)
      if ok and data then
        finish(true, data, nil)
        return
      end
      errors[#errors + 1] = "cn: " .. tostring(err or "fail")
      if source == "cn" then
        via_python(table.concat(errors, " | "))
        return
      end
      try_open_meteo()
    end)
  end

  if source == "open-meteo" then
    try_open_meteo()
  elseif source == "cn" then
    try_cn()
  else
    -- auto：先 cn 再 open-meteo
    try_cn()
  end
end

---@return boolean
local function has_city()
  local c = state.city or config.city
  return type(c) == "string" and vim.trim(c) ~= ""
end

---@param force? boolean
---@param on_done? fun(ok: boolean, data?: table, err?: string)
function M.refresh(force, on_done)
  M.ensure_setup()
  on_done = on_done or function() end
  if not has_city() then
    state.line = ""
    vim.g.weather_status = ""
    on_done(false, nil, "no city")
    return
  end
  local want = vim.trim(state.city or config.city or "")
  local want_source = config.source or "auto"

  if not force then
    local cached = state.data or load_cache()
    if
      cached
      and cache_fresh(cached)
      and (cached.query_city == want or cached.query_city == nil)
      and (cached.query_source == nil or cached.query_source == want_source)
    then
      state.data = cached
      update_statusline(cached)
      on_done(true, cached, nil)
      return
    end
  end

  fetch_remote(function(ok, data, err)
    if ok and data then
      data.query_city = want
      data.query_source = want_source
      state.data = data
      save_cache(data)
      update_statusline(data)
      if force then
        vim.notify(i18n.t("refreshed") .. (data.city or ""), vim.log.levels.INFO)
      end
    elseif err and force then
      vim.notify(i18n.t("fail") .. tostring(err), vim.log.levels.WARN)
    end
    on_done(ok, data, err)
  end)
end

local function pad(s, w)
  s = tostring(s or "")
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then
    return s
  end
  return s .. string.rep(" ", w - dw)
end

local function fmt_num(n, unit)
  if n == nil then
    return "-"
  end
  local v = tonumber(n)
  if not v then
    return "-"
  end
  return string.format("%.0f%s", v, unit or "")
end

function M._render_popup()
  if not state.popup_buf or not vim.api.nvim_buf_is_valid(state.popup_buf) then
    return
  end
  ensure_hl()
  local data = state.data
  local lines = {}
  lines[#lines + 1] = i18n.t("title") .. "  " .. (state.city or "")
  lines[#lines + 1] = i18n.t("help")
  lines[#lines + 1] = string.rep("─", 72)

  if not data or not data.current then
    lines[#lines + 1] = i18n.t("no_data")
  else
    local emoji, weather = i18n.weather_of(data.current.code, data.current.label)
    -- 与表格相同：emoji 固定列宽，文案左对齐
    local cur = string.format(
      "%s  %s%s  %s  %s %s%%  %s %s  [%s]",
      i18n.t("current"),
      pad_emoji_field(emoji, EMOJI_FIELD_W),
      weather,
      fmt_num(data.current.temp, "°C"),
      i18n.t("humidity"),
      tostring(data.current.humidity or "-"),
      i18n.t("wind"),
      fmt_num(data.current.wind, ""),
      data.city or ""
    )
    lines[#lines + 1] = cur
    lines[#lines + 1] = ""

    -- 表头（天气列加宽一点，容纳固定 emoji 列 + 中文）
    local WEATHER_COL_W = 16
    local head = table.concat({
      pad(i18n.t("col_date"), 14),
      pad(i18n.t("col_weather"), WEATHER_COL_W),
      pad(i18n.t("col_tmax"), 8),
      pad(i18n.t("col_tmin"), 8),
      pad(i18n.t("col_precip"), 10),
      pad(i18n.t("col_wind"), 8),
    }, " ")
    lines[#lines + 1] = head
    lines[#lines + 1] = string.rep("─", vim.fn.strdisplaywidth(head))

    for _, day in ipairs(data.daily or {}) do
      local em, lab = i18n.weather_of(day.code, day.label)
      local wd = i18n.weekday_of(day.date)
      local date_s = string.format("%s(%s)", day.date or "", wd)
      -- emoji 固定 3 显示格，后面文字列对齐
      local weather_s = format_weather_cell(em, lab, WEATHER_COL_W)
      local row = table.concat({
        pad(date_s, 14),
        weather_s,
        pad(fmt_num(day.tmax, "°"), 8),
        pad(fmt_num(day.tmin, "°"), 8),
        pad(fmt_num(day.precip, ""), 10),
        pad(fmt_num(day.wind, ""), 8),
      }, " ")
      lines[#lines + 1] = row
    end

    lines[#lines + 1] = ""
    local fetched_at = tonumber(data.fetched_at)
    local age_s = ""
    local when_s = "-"
    if fetched_at and fetched_at > 0 then
      when_s = os.date("%Y-%m-%d %H:%M:%S", fetched_at)
      local age = math.max(0, os.time() - fetched_at)
      if age < 60 then
        age_s = string.format("%s %ds", i18n.t("cache"), age)
      elseif age < 3600 then
        age_s = string.format("%s %dm", i18n.t("cache"), math.floor(age / 60))
      else
        age_s = string.format("%s %dh%dm", i18n.t("cache"), math.floor(age / 3600), math.floor((age % 3600) / 60))
      end
    end
    -- 获取时间 + 缓存年龄 + 数据源
    local meta = string.format(
      "%s %s",
      i18n.t("fetched"),
      when_s
    )
    if age_s ~= "" then
      meta = meta .. "  (" .. age_s .. ")"
    end
    meta = meta .. "  " .. i18n.t("source") .. " " .. (data.source or "open-meteo.com")
    lines[#lines + 1] = meta
  end

  vim.bo[state.popup_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.popup_buf, 0, -1, false, lines)
  vim.bo[state.popup_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.popup_buf, NS, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, state.popup_buf, NS, 0, 0, {
    end_col = #lines[1],
    hl_group = "WeatherTitle",
  })
  pcall(vim.api.nvim_buf_set_extmark, state.popup_buf, NS, 1, 0, {
    end_col = #lines[2],
    hl_group = "WeatherHelp",
  })
  -- 表头行高亮
  for i, l in ipairs(lines) do
    if l:find(i18n.t("col_date"), 1, true) and l:find(i18n.t("col_tmax"), 1, true) then
      pcall(vim.api.nvim_buf_set_extmark, state.popup_buf, NS, i - 1, 0, {
        end_col = #l,
        hl_group = "WeatherHead",
      })
      break
    end
  end
  if data and data.current then
    pcall(vim.api.nvim_buf_set_extmark, state.popup_buf, NS, 3, 0, {
      end_col = #(lines[4] or ""),
      hl_group = "WeatherCur",
    })
    -- 底部「获取时间」行
    local last = #lines
    if last > 0 and (lines[last] or ""):find(i18n.t("fetched"), 1, true) then
      pcall(vim.api.nvim_buf_set_extmark, state.popup_buf, NS, last - 1, 0, {
        end_col = #lines[last],
        hl_group = "WeatherHelp",
      })
    end
  end

  if state.popup_win and vim.api.nvim_win_is_valid(state.popup_win) then
    local w = 0
    for _, l in ipairs(lines) do
      w = math.max(w, vim.fn.strdisplaywidth(l))
    end
    w = math.min(math.max(w + 2, 60), vim.o.columns - 4)
    local h = math.min(#lines + 2, vim.o.lines - 4)
    pcall(vim.api.nvim_win_set_config, state.popup_win, {
      relative = "editor",
      width = w,
      height = h,
      row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    })
  end
end

local function close_popup()
  if state.popup_win and vim.api.nvim_win_is_valid(state.popup_win) then
    pcall(vim.api.nvim_win_close, state.popup_win, true)
  end
  if state.popup_buf and vim.api.nvim_buf_is_valid(state.popup_buf) then
    pcall(vim.api.nvim_buf_delete, state.popup_buf, { force = true })
  end
  state.popup_win, state.popup_buf = nil, nil
end

---打开 10 天预报浮窗
function M.open()
  M.ensure_setup()
  if not has_city() then
    vim.ui.input({
      prompt = (i18n.get() == "en") and "Weather city: " or "天气城市: ",
    }, function(input)
      if not input or vim.trim(input) == "" then
        vim.notify(
          (i18n.get() == "en") and "weather: city not set (setup city=... or :WeatherCity)"
            or "weather: 未配置城市（setup city=... 或 :WeatherCity）",
          vim.log.levels.WARN
        )
        return
      end
      M.set_city(vim.trim(input))
      M.open()
    end)
    return
  end
  ensure_hl()
  close_popup()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "weather"
  pcall(vim.api.nvim_buf_set_name, buf, "weather://forecast")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 70,
    height = 18,
    row = 2,
    col = 4,
    style = "minimal",
    border = config.border or "rounded",
    title = i18n.t("title"),
    title_pos = "center",
    zindex = 60,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].cursorline = true
    vim.wo[win].winhighlight =
      "Normal:WeatherNormal,NormalFloat:WeatherNormal,FloatBorder:WeatherBorder,FloatTitle:WeatherTitle"
  end)

  state.popup_buf = buf
  state.popup_win = win

  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "q", close_popup, vim.tbl_extend("force", o, { desc = "weather: close" }))
  vim.keymap.set("n", "<Esc>", close_popup, vim.tbl_extend("force", o, { desc = "weather: close" }))
  vim.keymap.set("n", "r", function()
    M.refresh(true, function()
      M._render_popup()
    end)
  end, vim.tbl_extend("force", o, { desc = "weather: refresh" }))
  vim.keymap.set("n", "L", function()
    local l = i18n.toggle()
    vim.notify(l == "en" and i18n.t("lang_to_en") or i18n.t("lang_to_zh"), vim.log.levels.INFO)
    update_statusline(state.data)
    M._render_popup()
  end, vim.tbl_extend("force", o, { desc = "weather: lang" }))

  -- 先显示缓存，后台刷新
  if not state.data then
    local cached = load_cache()
    if cached then
      state.data = cached
      update_statusline(cached)
    end
  end
  M._render_popup()
  if not state.data or not cache_fresh(state.data) then
    M.refresh(true, function()
      M._render_popup()
    end)
  end
end

---@param city string
function M.set_city(city)
  M.ensure_setup()
  city = vim.trim(city or "")
  if city == "" then
    return
  end
  state.city = city
  config.city = city
  state.enabled = true
  save_city_pref(city)
  vim.notify(i18n.t("city_set") .. city, vim.log.levels.INFO)
  M.refresh(true)
  start_timer()
end

local function start_timer()
  if state.timer then
    pcall(function()
      vim.fn.timer_stop(state.timer)
    end)
    state.timer = nil
  end
  local ms = tonumber(config.refresh_ms) or (3600 * 1000)
  if ms < 60000 then
    ms = 60000
  end
  state.timer = vim.fn.timer_start(ms, function()
    vim.schedule(function()
      M.refresh(false)
    end)
  end, { ["repeat"] = -1 })
end

local function apply_keys()
  for _, lhs in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", lhs)
  end
  keys_applied = {}
  local lhs = config.keys_open
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, function()
      M.open()
    end, { silent = true, desc = "weather: 10-day forecast" })
    keys_applied[#keys_applied + 1] = lhs
  end
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  local lang = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang = user.ui_lang
  end
  if lang == "zh" or lang == "en" then
    i18n.setup(lang)
  else
    i18n.setup("auto")
  end

  -- 城市：仅 setup 显式指定 或 本地记忆；默认不启用
  local remembered = load_city_pref()
  local city
  if user and type(user.city) == "string" and vim.trim(user.city) ~= "" then
    city = vim.trim(user.city)
  elseif remembered and vim.trim(remembered) ~= "" then
    city = vim.trim(remembered)
  elseif type(config.city) == "string" and vim.trim(config.city) ~= "" then
    city = vim.trim(config.city)
  else
    city = nil
  end
  state.city = city
  config.city = city
  state.enabled = city ~= nil

  apply_keys()

  if not state.enabled then
    -- 未配置城市：清空状态栏，不拉网、不定时
    state.data = nil
    state.line = ""
    vim.g.weather_status = ""
    if state.timer then
      pcall(vim.fn.timer_stop, state.timer)
      state.timer = nil
    end
    setup_done = true
    return config
  end

  -- 有城市：读缓存立刻上状态栏
  local cached = load_cache()
  if cached and cache_fresh(cached) and (cached.query_city == city or cached.query_city == nil) then
    state.data = cached
    update_statusline(cached)
  end

  if config.auto_start ~= false then
    vim.defer_fn(function()
      if has_city() then
        M.refresh(false)
        start_timer()
      end
    end, 800)
  end

  setup_done = true
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

function M.get_data()
  return state.data
end

return M
