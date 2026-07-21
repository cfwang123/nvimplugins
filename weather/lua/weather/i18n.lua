---@mod weather.i18n
local M = {}
---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    title = " 天气预报 ",
    help = " q 关闭  r 刷新  L 中英 ",
    col_date = "日期",
    col_weather = "天气",
    col_tmax = "最高",
    col_tmin = "最低",
    col_precip = "降水mm",
    col_wind = "风m/s",
    current = "当前",
    humidity = "湿度",
    wind = "风速",
    source = "来源",
    cache = "缓存",
    fetched = "获取时间",
    loading = "天气加载中…",
    fail = "天气获取失败: ",
    city_set = "weather: 城市 → ",
    refreshed = "weather: 已刷新 ",
    no_data = "暂无数据，正在请求…",
    need_python = "weather: 需要 Python3",
    script_missing = "weather: 缺少脚本 ",
    lang_to_en = "weather: UI → English",
    lang_to_zh = "weather: UI → 中文",
    weekday = { "日", "一", "二", "三", "四", "五", "六" },
  },
  en = {
    title = " Weather ",
    help = " q close  r refresh  L lang ",
    col_date = "Date",
    col_weather = "Weather",
    col_tmax = "High",
    col_tmin = "Low",
    col_precip = "Rain mm",
    col_wind = "Wind",
    current = "Now",
    humidity = "Humidity",
    wind = "Wind",
    source = "Source",
    cache = "Cache",
    fetched = "Fetched",
    loading = "Loading weather…",
    fail = "Weather fetch failed: ",
    city_set = "weather: city → ",
    refreshed = "weather: refreshed ",
    no_data = "No data yet, fetching…",
    need_python = "weather: needs Python3",
    script_missing = "weather: missing script ",
    lang_to_en = "weather: UI → English",
    lang_to_zh = "weather: UI → 中文",
    weekday = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
  },
}

-- WMO weather interpretation codes → { zh, en, emoji }
local WMO = {
  [0] = { zh = "晴", en = "Clear", emoji = "☀️" },
  [1] = { zh = "大部晴朗", en = "Mainly clear", emoji = "🌤️" },
  [2] = { zh = "多云", en = "Partly cloudy", emoji = "⛅" },
  [3] = { zh = "阴", en = "Overcast", emoji = "☁️" },
  [45] = { zh = "雾", en = "Fog", emoji = "🌫️" },
  [48] = { zh = "雾凇", en = "Rime fog", emoji = "🌫️" },
  [51] = { zh = "小毛毛雨", en = "Light drizzle", emoji = "🌦️" },
  [53] = { zh = "毛毛雨", en = "Drizzle", emoji = "🌦️" },
  [55] = { zh = "大毛毛雨", en = "Dense drizzle", emoji = "🌧️" },
  [56] = { zh = "冻毛毛雨", en = "Freezing drizzle", emoji = "🌧️" },
  [57] = { zh = "强冻毛毛雨", en = "Freezing drizzle", emoji = "🌧️" },
  [61] = { zh = "小雨", en = "Slight rain", emoji = "🌧️" },
  [63] = { zh = "中雨", en = "Rain", emoji = "🌧️" },
  [65] = { zh = "大雨", en = "Heavy rain", emoji = "🌧️" },
  [66] = { zh = "冻雨", en = "Freezing rain", emoji = "🌧️" },
  [67] = { zh = "强冻雨", en = "Freezing rain", emoji = "🌧️" },
  [71] = { zh = "小雪", en = "Slight snow", emoji = "🌨️" },
  [73] = { zh = "中雪", en = "Snow", emoji = "❄️" },
  [75] = { zh = "大雪", en = "Heavy snow", emoji = "❄️" },
  [77] = { zh = "雪粒", en = "Snow grains", emoji = "🌨️" },
  [80] = { zh = "小阵雨", en = "Rain showers", emoji = "🌦️" },
  [81] = { zh = "阵雨", en = "Rain showers", emoji = "🌧️" },
  [82] = { zh = "强阵雨", en = "Violent showers", emoji = "⛈️" },
  [85] = { zh = "小阵雪", en = "Snow showers", emoji = "🌨️" },
  [86] = { zh = "强阵雪", en = "Snow showers", emoji = "❄️" },
  [95] = { zh = "雷暴", en = "Thunderstorm", emoji = "⛈️" },
  [96] = { zh = "雷暴伴冰雹", en = "Storm + hail", emoji = "⛈️" },
  [99] = { zh = "强雷暴冰雹", en = "Storm + hail", emoji = "⛈️" },
}

function M.detect()
  local cands = { vim.v.lang, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 then
    local ok, out = pcall(vim.fn.system, {
      "powershell",
      "-NoProfile",
      "-Command",
      "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
    })
    if ok and type(out) == "string" and vim.trim(out):lower():match("^zh") then
      return "zh"
    end
  end
  return "zh"
end

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.load_prefs() or M.detect()
  end
  return lang
end

function M.get()
  return lang
end

function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  M.save_prefs()
  return lang
end

function M.t(key)
  local pack = STR[lang] or STR.zh
  return pack[key] or STR.zh[key] or key
end

---@param code any WMO 码；或中文天气文案（国内源）
---@param label_override? string 优先显示的文案（如国内源原始「小雨」）
---@return string emoji
---@return string label
function M.weather_of(code, label_override)
  local c = tonumber(code)
  local info = (c and WMO[c]) or nil
  if not info and type(code) == "string" and code ~= "" then
    -- 国内源可能直接给中文天气
    info = { zh = code, en = code, emoji = "🌡️" }
  end
  info = info or { zh = "未知", en = "Unknown", emoji = "🌡️" }
  local label = label_override
  if not label or label == "" then
    label = (lang == "en") and info.en or info.zh
  elseif lang == "en" and c and WMO[c] then
    -- 有 override 但 UI 英文时仍用 WMO 英文
    label = WMO[c].en
  end
  return info.emoji or "🌡️", label
end

function M.weekday_of(date_str)
  -- date_str: YYYY-MM-DD
  local y, m, d = tostring(date_str or ""):match("^(%d+)%-(%d+)%-(%d+)")
  if not y then
    return ""
  end
  -- Zeller-ish via os.time
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local w = tonumber(os.date("%w", t)) or 0
  local pack = STR[lang] or STR.zh
  local names = pack.weekday or STR.zh.weekday
  return names[w + 1] or ""
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/weather-nvim-prefs.json"
end

function M.load_prefs()
  local f = prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" and (data.ui_lang == "zh" or data.ui_lang == "en") then
    return data.ui_lang
  end
  return nil
end

function M.save_prefs()
  pcall(function()
    local f = prefs_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    local city = nil
    -- city stored separately in weather cache prefs via init
    vim.fn.writefile({ vim.json.encode({ ui_lang = lang }) }, f)
  end)
end

return M
