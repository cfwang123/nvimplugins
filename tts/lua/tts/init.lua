---@mod tts Windows SAPI 文本转语音
local engine = require("tts.engine")
local split = require("tts.split")
local ui = require("tts.ui")

local M = {}

local default_config = {
  python = "python",
  volume = 80,
  rate = 0,
  ---@type string|false
  keys_play = "<leader>vo",
  ---@type string|false
  keys_stop = "<leader>vs",
  --- 固定发音人（名称子串或全名）；nil 则用上次选择 / 系统当前
  voice = nil, ---@type string|nil
  --- 控制条界面语言："zh" | "en" | "auto"（auto=跟随系统）
  ui_lang = "auto", ---@type string
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}
--- 会话内记住的发音人（float 选择后更新，并写入磁盘）
local remembered_voice = nil ---@type string|nil
--- 记住的界面语言（用户切换后写入）
local remembered_ui_lang = nil ---@type string|nil

local function prefs_path()
  return vim.fn.stdpath("data") .. "/tts-nvim-prefs.json"
end

local function load_prefs()
  local f = prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" then
    if type(data.voice) == "string" and data.voice ~= "" then
      remembered_voice = data.voice
    end
    if data.ui_lang == "zh" or data.ui_lang == "en" then
      remembered_ui_lang = data.ui_lang
    end
    if type(data.volume) == "number" and not (config and config._user_volume) then
      -- 仅当 setup 未强制时可选恢复音量；保持简单：只恢复 voice / ui_lang
    end
  end
end

local function save_prefs()
  local data = {
    voice = remembered_voice or config.voice,
    volume = config.volume,
    rate = config.rate,
    ui_lang = remembered_ui_lang or (config.ui_lang ~= "auto" and config.ui_lang or nil),
  }
  pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(prefs_path(), ":h"), "p")
    vim.fn.writefile({ vim.json.encode(data) }, prefs_path())
  end)
end

---界面语言切换后写入 prefs
---@param lang string
function M._sync_ui_lang(lang)
  if lang == "zh" or lang == "en" then
    remembered_ui_lang = lang
    config.ui_lang = lang
    save_prefs()
  end
end

---保存发音人（float 选择 / setup 指定后调用）
---@param name string
function M.set_preferred_voice(name)
  if not name or name == "" then
    return
  end
  remembered_voice = name
  config.voice = name
  save_prefs()
end

---@return string|nil
function M.get_preferred_voice()
  return remembered_voice or config.voice
end

local function apply_keys()
  for _, item in ipairs(keys_applied) do
    pcall(vim.keymap.del, item.mode, item.lhs)
  end
  keys_applied = {}

  local function map(mode, lhs, rhs, desc)
    if lhs == false or lhs == nil or lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
    keys_applied[#keys_applied + 1] = { mode = mode, lhs = lhs }
  end

  map("n", config.keys_play, function()
    M.play_buffer()
  end, "tts: play buffer")
  map("x", config.keys_play, function()
    -- 仍在 visual 内，由 play_visual 用 getpos('v')/'.' 取精确范围
    M.play_visual()
  end, "tts: play selection")
  map("n", config.keys_stop, function()
    M.stop_all()
  end, "tts: stop & close")
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  load_prefs()
  -- setup 里写了 voice 则优先生效并持久化
  if user and type(user.voice) == "string" and user.voice ~= "" then
    remembered_voice = user.voice
    save_prefs()
  elseif remembered_voice and (not config.voice or config.voice == "") then
    config.voice = remembered_voice
  end
  -- 界面语言：setup 显式 > 记忆 > auto(系统)
  local lang_opt = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang_opt = user.ui_lang
  elseif remembered_ui_lang then
    lang_opt = remembered_ui_lang
  end
  if lang_opt == "zh" or lang_opt == "en" then
    ui.set_ui_lang(lang_opt)
  else
    ui.set_ui_lang("auto")
  end
  engine.setup({
    python = config.python,
    volume = config.volume,
    rate = config.rate,
  })
  setup_done = true
  apply_keys()
  M._wire_engine()
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

function M._wire_engine()
  engine.on_status(function()
    if ui.is_open() then
      ui.render()
    end
  end)
  engine.on_segment(function(i, _total, _text)
    ui.set_index(i)
    if ui.is_open() then
      ui.render() -- 含原文亮黄高亮
    end
  end)
  engine.on_ended(function()
    -- 播放结束：清原文高亮并刷新控制条（render 内见 status≠playing/paused 也会 clear）
    if ui.is_open() then
      ui.render()
    else
      pcall(function()
        ui.clear_source_hl()
      end)
    end
  end)
end

---当前应使用的发音人：setup.voice / 上次选择 / 引擎当前 / 列表第一项
---@return string|nil
local function resolve_voice()
  local prefer = remembered_voice or config.voice
  engine.ensure()
  local st = engine.get_state()
  if not st.voices or #st.voices == 0 then
    engine.list_voices()
    vim.wait(400, function()
      local s = engine.get_state()
      return s.voices and #s.voices > 0
    end, 40)
    st = engine.get_state()
  end
  if prefer and prefer ~= "" then
    -- 精确或子串匹配已安装列表，避免失效名称
    for _, v in ipairs(st.voices or {}) do
      local name = v.name or ""
      if name == prefer or name:lower():find(prefer:lower(), 1, true) then
        return name
      end
    end
  end
  if st.voice and st.voice ~= "" then
    return st.voice
  end
  if st.voices and st.voices[1] then
    return st.voices[1].name
  end
  return prefer
end

---@param text string
---@param opts? {
---  title?: string,
---  open_ui?: boolean,
---  source_buf?: integer,
---  source_win?: integer,
---  origin?: {line:integer, col:integer},
---  voice?: string,
---  start?: integer,
---  detailed?: table[],
---  ranges?: table[],
---}
function M.play_text(text, opts)
  M.ensure_setup()
  opts = opts or {}
  text = text or ""
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if vim.trim(text) == "" then
    vim.notify(ui.t("empty_text"), vim.log.levels.WARN)
    return
  end

  -- 带原文偏移的分段（高亮与朗读同一套）
  local detailed = opts.detailed or split.segments_detailed(text)
  if #detailed == 0 then
    vim.notify(ui.t("no_segments"), vim.log.levels.WARN)
    return
  end
  local segs = {}
  for _, d in ipairs(detailed) do
    segs[#segs + 1] = d.text
  end

  -- 不再按语言自动切换；固定用记住的发音人
  local voice = opts.voice or resolve_voice()
  if voice then
    remembered_voice = voice
  end

  local open_ui = opts.open_ui
  if open_ui == nil then
    open_ui = true
  end

  local ranges = opts.ranges
  if not ranges and opts.source_buf and vim.api.nvim_buf_is_valid(opts.source_buf) then
    local lines = vim.api.nvim_buf_get_lines(opts.source_buf, 0, -1, false)
    local base = 0
    if opts.origin then
      base = split.linecol_to_byte(lines, opts.origin.line or 1, opts.origin.col or 0)
    end
    ranges = split.ranges_for_buf(lines, detailed, base)
  end

  if open_ui then
    ui.open(segs, {
      title = opts.title or "TTS",
      source_buf = opts.source_buf,
      source_win = opts.source_win,
      origin = opts.origin,
      ranges = ranges,
    })
    ui.set_segments(segs)
  end

  local est = engine.get_state()
  local start = opts.start or 0
  if start < 0 then
    start = 0
  end
  if start >= #segs then
    start = math.max(0, #segs - 1)
  end

  engine.speak(segs, {
    voice = voice,
    volume = est.volume or config.volume,
    rate = est.rate or config.rate,
    start = start,
  })

  vim.notify(
    string.format(ui.t("play_seg"), start + 1, #segs, voice or "?"),
    vim.log.levels.INFO
  )
end

---同步界面调节的语速到 config（下次 play 也沿用）
---@param r number
function M._sync_rate(r)
  if type(r) == "number" then
    config.rate = r
  end
end

function M.cmd_speak(text)
  local buf = vim.api.nvim_get_current_buf()
  M.play_text(text, {
    title = "TTS",
    open_ui = true,
    source_buf = buf,
    source_win = vim.api.nvim_get_current_win(),
    origin = { line = vim.api.nvim_win_get_cursor(0)[1], col = 0 },
  })
end

function M.play_buffer()
  M.ensure_setup()
  local buf = vim.api.nvim_get_current_buf()
  if vim.b[buf].tts_preview then
    vim.notify(ui.t("use_source"), vim.log.levels.INFO)
    return
  end
  local win = vim.api.nvim_get_current_win()
  local text = split.buf_text(buf)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if name == "" then
    name = "[buffer]"
  end

  -- 从光标所在段开始；播放中再次 <leader>vo 可跳到新光标段
  local detailed = split.segments_detailed(text)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local byte0 = split.linecol_to_byte(lines, cursor[1], cursor[2])
  local start = split.segment_index_at(detailed, byte0)

  M.play_text(text, {
    title = name,
    open_ui = true,
    source_buf = buf,
    source_win = win,
    origin = { line = 1, col = 0 },
    detailed = detailed,
    start = start,
  })
end

function M.play_visual()
  M.ensure_setup()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local s = vim.fn.getpos("v")
  local e = vim.fn.getpos(".")
  local mode = vim.fn.mode()
  if not (mode == "v" or mode == "V" or mode == "\22") then
    s = vim.fn.getpos("'<")
    e = vim.fn.getpos("'>")
  end
  local text, origin = split.extract_range(buf, s, e)
  if vim.trim(text) == "" then
    vim.notify(ui.t("empty_sel"), vim.log.levels.WARN)
    return
  end
  -- 退出 visual
  pcall(vim.cmd, "normal! \27")
  M.play_text(text, {
    title = "选区",
    open_ui = true,
    source_buf = buf,
    source_win = win,
    origin = origin,
  })
end

function M.stop_all()
  M.ensure_setup()
  engine.stop()
  ui.close()
  vim.notify(ui.t("msg_stopped"), vim.log.levels.INFO)
end

return M
