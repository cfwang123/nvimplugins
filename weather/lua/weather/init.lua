---@mod weather 状态栏天气 + 10 天预报浮窗（公开 HTTP，无 API Key）
local i18n = require("weather.i18n")

local M = {}

local default_config = {
  ---城市名（中英文均可）。默认 nil：未配置则不自动启用、不拉数据
  city = nil, ---@type string|nil
  python = "python",
  ---缓存有效期（秒），默认 1 小时
  cache_ttl = 3600,
  ---自动刷新间隔（毫秒），默认 1 小时
  refresh_ms = 3600 * 1000,
  ---状态栏格式：{city} {emoji} {weather} {temp}
  status_format = "{city} {emoji} {weather} {temp}°",
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
  pcall(vim.api.nvim_set_hl, 0, "WeatherNormal", { fg = "#111111", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "WeatherTitle", { fg = "#111111", bg = "#ffffff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "WeatherHelp", { fg = "#666666", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "WeatherHead", { fg = "#003366", bg = "#e8f0ff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "WeatherBorder", { fg = "#4488aa", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "WeatherCur", { fg = "#111111", bg = "#fff8e0", bold = true, force = true })
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

---@param data table|nil
local function update_statusline(data)
  if not data or not data.current then
    state.line = ""
    vim.g.weather_status = ""
    return
  end
  local city = data.city or state.city or ""
  local emoji, weather = i18n.weather_of(data.current.code)
  local temp = data.current.temp
  if temp ~= nil then
    temp = string.format("%.0f", tonumber(temp) or 0)
  else
    temp = "?"
  end
  local fmt = config.status_format or "{city} {emoji} {weather} {temp}°"
  local s = fmt
  s = s:gsub("{city}", city)
  s = s:gsub("{emoji}", emoji)
  s = s:gsub("{weather}", weather)
  s = s:gsub("{temp}", temp)
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

---@param on_done? fun(ok: boolean, data: table|nil, err?: string)
local function fetch_remote(on_done)
  on_done = on_done or function() end
  if state.busy then
    return
  end
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
  state.busy = true
  local city = state.city or config.city or "北京"
  local lang = i18n.get()
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
  })

  local function finish(ok, data, err)
    state.busy = false
    if ok and data then
      data.query_city = state.city or config.city
      state.data = data
      save_cache(data)
      update_statusline(data)
      if state.popup_win and vim.api.nvim_win_is_valid(state.popup_win) then
        M._render_popup()
      end
    end
    on_done(ok, data, err)
  end

  -- jobstart 更稳（Windows vim.system 易 -1）
  local chunks, err_chunks = {}, {}
  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          chunks[#chunks + 1] = line
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          err_chunks[#err_chunks + 1] = line
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local out = table.concat(chunks, "\n"):gsub("^\239\187\191", ""):gsub("\r", "")
        local json_str = vim.trim(out)
        local last = json_str:match("(%b{})%s*$")
        if last then
          json_str = last
        end
        local okj, data = pcall(vim.json.decode, json_str)
        if not okj or type(data) ~= "table" then
          local err = table.concat(err_chunks, " ")
          if err == "" then
            err = "bad json / exit " .. tostring(code)
          end
          finish(false, nil, err)
          return
        end
        if data.ok == false then
          finish(false, nil, tostring(data.error or "fetch failed"))
          return
        end
        finish(true, data, nil)
      end)
    end,
  })
  if job <= 0 then
    state.busy = false
    on_done(false, nil, "jobstart failed")
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

  if not force then
    local cached = state.data or load_cache()
    if cached and cache_fresh(cached) and (cached.query_city == want or cached.query_city == nil) then
      state.data = cached
      update_statusline(cached)
      on_done(true, cached, nil)
      return
    end
  end

  fetch_remote(function(ok, data, err)
    if ok and data then
      data.query_city = want
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
    local emoji, weather = i18n.weather_of(data.current.code)
    local cur = string.format(
      "%s  %s %s %s  %s %s%%  %s %s  [%s]",
      i18n.t("current"),
      emoji,
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

    -- 表头
    local head = table.concat({
      pad(i18n.t("col_date"), 14),
      pad(i18n.t("col_weather"), 16),
      pad(i18n.t("col_tmax"), 8),
      pad(i18n.t("col_tmin"), 8),
      pad(i18n.t("col_precip"), 10),
      pad(i18n.t("col_wind"), 8),
    }, " ")
    lines[#lines + 1] = head
    lines[#lines + 1] = string.rep("─", vim.fn.strdisplaywidth(head))

    for _, day in ipairs(data.daily or {}) do
      local em, lab = i18n.weather_of(day.code)
      local wd = i18n.weekday_of(day.date)
      local date_s = string.format("%s(%s)", day.date or "", wd)
      local weather_s = em .. " " .. lab
      local row = table.concat({
        pad(date_s, 14),
        pad(weather_s, 16),
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
