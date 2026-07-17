---@mod tts.ui 控制条预览 + 原文高亮 + 可点按钮 + 发音人 float
local engine = require("tts.engine")

local M = {}

local NS_UI = vim.api.nvim_create_namespace("tts_ui")
local NS_SRC = vim.api.nvim_create_namespace("tts_src_hl")
local NS_VOICE = vim.api.nvim_create_namespace("tts_voice")

---@class TtsHit
---@field row integer 0-based
---@field col integer 0-based byte
---@field end_col integer
---@field action string

local state = {
  buf = nil, ---@type integer|nil
  win = nil, ---@type integer|nil
  source_buf = nil, ---@type integer|nil
  source_win = nil, ---@type integer|nil
  segments = {}, ---@type string[]
  --- 每段在原文 buffer 中的范围 {line, col, end_line, end_col} 0-based col，1-based line
  ranges = {}, ---@type table[]
  index = 0,
  source_label = "",
  hits = {}, ---@type TtsHit[]
  voice_win = nil,
  voice_buf = nil,
  --- 源 buffer 上临时语速键
  source_rate_maps = false,
  --- 正在关闭，防止 WinClosed ↔ stop_all 重入
  closing = false,
  close_augroup = nil, ---@type integer|nil
  --- 界面语言 "zh" | "en"；nil 表示尚未初始化
  ui_lang = nil, ---@type string|nil
}

local SOURCE_RATE_KEYS = { "+", "=", "-", "_", "<kPlus>", "<kMinus>" }

---界面文案
local I18N = {
  zh = {
    playing = "▶ 播放中",
    paused = "⏸ 暂停",
    stopped = "■ 停止",
    idle = "· 空闲",
    volume = "音量",
    rate = "语速",
    voice = "发音人",
    no_text = "(无文本)",
    btn_prev = " ◀上一段 ",
    btn_toggle = " 空格:暂停 ",
    btn_next = " 下一段▶ ",
    btn_vol_up = " ↑音量+ ",
    btn_vol_down = " ↓音量- ",
    btn_rate_up = " 语速+ ",
    btn_rate_down = " 语速- ",
    btn_voice = " v发音人 ",
    btn_lang = " EN ",
    btn_stop = " q停止 ",
    voice_title = " TTS 发音人 ",
    voice_hint = " 选择发音人  (Enter/点击 · q 取消)",
    no_voices = "tts: 无可用发音人",
    voice_saved = "tts: 已记住发音人 · ",
    lang_switched = "tts: 界面 → English",
    empty_text = "tts: 空文本",
    no_segments = "tts: 无分段",
    play_seg = "tts: 第 %d/%d 段 · %s",
    use_source = "tts: 请在源 buffer 上按 <leader>vo",
    empty_sel = "tts: 空选区",
    msg_stopped = "tts: 已停止",
    py_missing = "tts: 未找到 python",
    script_missing = "tts: 缺少 ",
    daemon_fail = "tts: 无法启动 SAPI 守护进程",
  },
  en = {
    playing = "▶ Playing",
    paused = "⏸ Paused",
    stopped = "■ Stopped",
    idle = "· Idle",
    volume = "Vol",
    rate = "Rate",
    voice = "Voice",
    no_text = "(empty)",
    btn_prev = " ◀Prev ",
    btn_toggle = " Space:Pause ",
    btn_next = " Next▶ ",
    btn_vol_up = " ↑Vol+ ",
    btn_vol_down = " ↓Vol- ",
    btn_rate_up = " Rate+ ",
    btn_rate_down = " Rate- ",
    btn_voice = " v Voice ",
    btn_lang = " 中文 ",
    btn_stop = " q Stop ",
    voice_title = " TTS Voices ",
    voice_hint = " Select voice  (Enter/click · q cancel)",
    no_voices = "tts: no voices available",
    voice_saved = "tts: remembered voice · ",
    lang_switched = "tts: UI → 中文",
    empty_text = "tts: empty text",
    no_segments = "tts: no segments",
    play_seg = "tts: segment %d/%d · %s",
    use_source = "tts: press <leader>vo on the source buffer",
    empty_sel = "tts: empty selection",
    msg_stopped = "tts: stopped",
    py_missing = "tts: python not found",
    script_missing = "tts: missing ",
    daemon_fail = "tts: failed to start SAPI daemon",
  },
}

local function detect_system_ui_lang()
  local cands = {
    vim.v.lang,
    vim.v.ctype,
    vim.env.LANG,
    vim.env.LC_ALL,
    vim.env.LC_MESSAGES,
    vim.env.LANGUAGE,
  }
  for _, s in ipairs(cands) do
    if type(s) == "string" and s ~= "" and s ~= "C" and s ~= "POSIX" then
      local low = s:lower()
      -- 优先匹配语言前缀，避免误匹配子串
      if low:match("^zh")
        or low:match("chinese")
        or low:match("^chs")
        or low:match("^cht")
        or low:match("zh[_%-]")
        or low:match("[_%-]cn[_%-%.]")
        or low:match("[_%-]cn$")
      then
        return "zh"
      end
      if low:match("^en") or low:match("english") or low:match("en[_%-]") then
        return "en"
      end
    end
  end
  -- Windows UI culture
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    local ok, out = pcall(vim.fn.system, {
      "powershell",
      "-NoProfile",
      "-Command",
      "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
    })
    if ok and type(out) == "string" then
      local low = vim.trim(out):lower()
      if low:match("^zh") then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  return "zh"
end

local function ensure_ui_lang()
  if state.ui_lang == "zh" or state.ui_lang == "en" then
    return state.ui_lang
  end
  state.ui_lang = detect_system_ui_lang()
  return state.ui_lang
end

---@param key string
---@return string
local function T(key)
  local lang = ensure_ui_lang()
  local pack = I18N[lang] or I18N.zh
  return pack[key] or I18N.zh[key] or key
end

---供 init/engine 取界面文案
function M.t(key)
  return T(key)
end

---@param lang? string "zh"|"en"|nil  nil/"auto"=按系统
---@param opts? { persist?: boolean }
function M.set_ui_lang(lang, opts)
  opts = opts or {}
  if lang == nil or lang == "auto" then
    state.ui_lang = detect_system_ui_lang()
  elseif lang == "zh" or lang == "en" then
    state.ui_lang = lang
  else
    return
  end
  if opts.persist then
    pcall(function()
      require("tts")._sync_ui_lang(state.ui_lang)
    end)
  end
  if M.is_open() then
    M.render()
  end
end

function M.get_ui_lang()
  return ensure_ui_lang()
end

function M.toggle_ui_lang()
  local cur = ensure_ui_lang()
  local next_lang = cur == "zh" and "en" or "zh"
  M.set_ui_lang(next_lang, { persist = true })
  if next_lang == "en" then
    vim.notify("tts: UI → English", vim.log.levels.INFO)
  else
    vim.notify("tts: UI → 中文", vim.log.levels.INFO)
  end
end

local function clear_source_rate_maps()
  local sbuf = state.source_buf
  if not state.source_rate_maps or not sbuf or not vim.api.nvim_buf_is_valid(sbuf) then
    state.source_rate_maps = false
    return
  end
  for _, lhs in ipairs(SOURCE_RATE_KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = sbuf })
  end
  state.source_rate_maps = false
end

local function ensure_hl()
  -- 控制条：白底 + 黑/灰字（少用彩色）；force 覆盖旧主题定义
  local function hl(name, spec)
    spec.default = false
    spec.force = true
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
  hl("TtsNormal", { fg = "#111111", bg = "#ffffff" })
  hl("TtsTitle", { fg = "#111111", bg = "#ffffff", bold = true })
  hl("TtsMeta", { fg = "#666666", bg = "#ffffff" })
  hl("TtsPlaying", { fg = "#111111", bg = "#ffffff", bold = true })
  hl("TtsPaused", { fg = "#444444", bg = "#ffffff", bold = true })
  hl("TtsBar", { fg = "#555555", bg = "#ffffff" })
  hl("TtsBtn", { fg = "#111111", bg = "#e8e8e8", bold = true })
  hl("TtsBtnDanger", { fg = "#111111", bg = "#d0d0d0", bold = true })
  hl("TtsHint", { fg = "#888888", bg = "#ffffff" })
  -- 原文当前段仍用浅黄，便于跟读（控制条本身不花哨）
  hl("TtsSourceSeg", { fg = "#000000", bg = "#fff59d", bold = true })
  hl("TtsVoiceSel", { fg = "#000000", bg = "#dddddd", bold = true })
  hl("TtsVoiceFloat", { fg = "#111111", bg = "#ffffff" })
  hl("TtsBorder", { fg = "#999999", bg = "#ffffff" })
end

local function bar(idx, total, width)
  width = math.max(8, width or 24)
  if total <= 0 then
    return string.rep("─", width)
  end
  local filled = math.floor((idx + 1) / total * width + 0.5)
  filled = math.max(0, math.min(width, filled))
  return string.rep("█", filled) .. string.rep("─", width - filled)
end

local function status_label(st)
  if st.status == "playing" then
    return T("playing"), "TtsPlaying"
  end
  if st.status == "paused" then
    return T("paused"), "TtsPaused"
  end
  if st.status == "stopped" then
    return T("stopped"), "TtsMeta"
  end
  return T("idle"), "TtsMeta"
end

---joined 文本 0-based 字节 → (line 1-based, col 0-based)
local function byte_to_linecol(lines, byte0)
  local pos = 0
  for i, line in ipairs(lines) do
    local len = #line
    if byte0 <= pos + len then
      return i, byte0 - pos
    end
    pos = pos + len + 1 -- \n
  end
  if #lines == 0 then
    return 1, 0
  end
  return #lines, #lines[#lines]
end

---在 source buffer 中按顺序定位各段（从 origin 起搜）
---@param buf integer
---@param segments string[]
---@param origin? {line:integer, col:integer} 1-based line, 0-based col
---@return table[] ranges
function M.locate_segments(buf, segments, origin)
  local ranges = {}
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return ranges
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local full = table.concat(lines, "\n")
  local search_from = 1 -- 1-based for string.find
  if origin and origin.line then
    local pos = 0
    for i = 1, math.max(0, (origin.line or 1) - 1) do
      pos = pos + #(lines[i] or "") + 1
    end
    pos = pos + math.max(0, origin.col or 0)
    search_from = pos + 1
  end

  for _, seg in ipairs(segments or {}) do
    local needle = (seg or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if needle == "" then
      ranges[#ranges + 1] = nil
    else
      local s, e = full:find(needle, search_from, true)
      if s and e then
        local l1, c1 = byte_to_linecol(lines, s - 1)
        local l2, c2 = byte_to_linecol(lines, e - 1)
        ranges[#ranges + 1] = {
          line = l1,
          col = c1,
          end_line = l2,
          end_col = c2 + 1, -- exclusive
        }
        search_from = e + 1
      else
        ranges[#ranges + 1] = nil
      end
    end
  end
  return ranges
end

function M.clear_source_hl()
  local buf = state.source_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS_SRC, 0, -1)
  end
end

---在原文高亮第 index 段（0-based）
---@param index integer
function M.highlight_source(index)
  M.clear_source_hl()
  local buf = state.source_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local r = state.ranges[index + 1]
  if not r then
    return
  end
  ensure_hl()
  local ok = pcall(vim.api.nvim_buf_set_extmark, buf, NS_SRC, r.line - 1, r.col, {
    end_row = r.end_line - 1,
    end_col = r.end_col,
    hl_group = "TtsSourceSeg",
    priority = 200,
  })
  if not ok then
    -- 退化：整行高亮
    pcall(vim.api.nvim_buf_set_extmark, buf, NS_SRC, r.line - 1, 0, {
      end_row = r.end_line - 1,
      line_hl_group = "TtsSourceSeg",
      priority = 200,
    })
  end
  -- 滚到可见
  local win = state.source_win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    pcall(vim.api.nvim_win_set_cursor, win, { r.line, r.col })
    pcall(vim.fn.win_execute, win, "normal! zz")
  else
    -- 找显示该 buffer 的窗
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        pcall(vim.api.nvim_win_set_cursor, w, { r.line, r.col })
        pcall(vim.fn.win_execute, w, "normal! zz")
        state.source_win = w
        break
      end
    end
  end
end

function M.is_open()
  return state.buf
    and vim.api.nvim_buf_is_valid(state.buf)
    and state.win
    and vim.api.nvim_win_is_valid(state.win)
end

function M.close_voice_float()
  if state.voice_win and vim.api.nvim_win_is_valid(state.voice_win) then
    pcall(vim.api.nvim_win_close, state.voice_win, true)
  end
  if state.voice_buf and vim.api.nvim_buf_is_valid(state.voice_buf) then
    pcall(vim.api.nvim_buf_delete, state.voice_buf, { force = true })
  end
  state.voice_win, state.voice_buf = nil, nil
end

local function clear_close_autocmd()
  if state.close_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.close_augroup)
    state.close_augroup = nil
  end
end

---控制条被关掉（:q / Ctrl-W c / 点关闭等）时：停播 + 清高亮
local function on_control_closed()
  if state.closing then
    return
  end
  state.closing = true
  clear_close_autocmd()
  -- 立刻停播
  pcall(function()
    engine.stop()
  end)
  M.close_voice_float()
  M.clear_source_hl()
  clear_source_rate_maps()
  local buf = state.buf
  state.buf, state.win = nil, nil
  state.hits = {}
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  state.closing = false
end

function M.close()
  if state.closing then
    return
  end
  state.closing = true
  clear_close_autocmd()
  M.close_voice_float()
  M.clear_source_hl()
  clear_source_rate_maps()
  local win = state.win
  local buf = state.buf
  state.buf, state.win = nil, nil
  state.hits = {}
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  state.closing = false
end

local function do_action(action)
  local st = engine.get_state()
  if action == "stop" then
    require("tts").stop_all()
  elseif action == "toggle" then
    engine.toggle()
  elseif action == "prev" then
    engine.goto_index(math.max(0, (st.index or 0) - 1))
  elseif action == "next" then
    engine.goto_index((st.index or 0) + 1)
  elseif action == "vol_down" then
    engine.set_volume(math.max(0, (st.volume or 80) - 5))
  elseif action == "vol_up" then
    engine.set_volume(math.min(100, (st.volume or 80) + 5))
  elseif action == "rate_down" then
    local r = math.max(-10, (st.rate or 0) - 1)
    engine.set_rate(r)
    pcall(function()
      require("tts")._sync_rate(r)
    end)
  elseif action == "rate_up" then
    local r = math.min(10, (st.rate or 0) + 1)
    engine.set_rate(r)
    pcall(function()
      require("tts")._sync_rate(r)
    end)
  elseif action == "voice" then
    M.open_voice_float()
  elseif action == "lang" then
    M.toggle_ui_lang()
  end
end

local function bind_source_rate_maps()
  clear_source_rate_maps()
  local sbuf = state.source_buf
  if not sbuf or not vim.api.nvim_buf_is_valid(sbuf) then
    return
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = sbuf, silent = true, nowait = true, desc = desc })
  end
  local function rate_up()
    do_action("rate_up")
    if M.is_open() then
      M.render()
    end
  end
  local function rate_down()
    do_action("rate_down")
    if M.is_open() then
      M.render()
    end
  end
  map("+", rate_up, "tts: rate+")
  map("=", rate_up, "tts: rate+")
  map("-", rate_down, "tts: rate-")
  map("_", rate_down, "tts: rate-")
  map("<kPlus>", rate_up, "tts: rate+")
  map("<kMinus>", rate_down, "tts: rate-")
  state.source_rate_maps = true
end

---@param segments string[]
---@param opts? {
---  title?: string,
---  source_buf?: integer,
---  source_win?: integer,
---  origin?: {line:integer, col:integer},
---  ranges?: table[],
---}
function M.open(segments, opts)
  opts = opts or {}
  ensure_hl()
  state.segments = segments or {}
  state.index = 0
  state.source_label = opts.title or "TTS"
  state.source_buf = opts.source_buf
  state.source_win = opts.source_win
  -- 优先用分段时算好的区间（与朗读文本一一对应）
  if opts.ranges and #opts.ranges > 0 then
    state.ranges = opts.ranges
  else
    state.ranges = M.locate_segments(state.source_buf, state.segments, opts.origin)
  end

  if not M.is_open() then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "tts"
    vim.b[buf].tts_preview = true
    pcall(vim.api.nvim_buf_set_name, buf, "tts://control")

    -- 底部矮控制条（不显示全文）
    vim.cmd("botright 7split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    pcall(function()
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].wrap = false
      vim.wo[win].cursorline = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].winfixheight = true
      vim.api.nvim_win_set_height(win, 7)
      -- 强制白底黑字，不受 colorscheme 影响
      vim.wo[win].winhl = table.concat({
        "Normal:TtsNormal",
        "NormalNC:TtsNormal",
        "EndOfBuffer:TtsNormal",
        "SignColumn:TtsNormal",
        "StatusLine:TtsMeta",
        "StatusLineNC:TtsMeta",
        "WinSeparator:TtsBorder",
        "VertSplit:TtsBorder",
      }, ",")
    end)
    pcall(function()
      vim.bo[buf].modifiable = false
    end)
    pcall(function()
      if not tostring(vim.o.mouse or ""):find("a", 1, true) then
        vim.o.mouse = "a"
      end
    end)
    state.buf = buf
    state.win = win
    M._maps(buf)
    -- 误入 visual/select 立即退出
    vim.api.nvim_create_autocmd("ModeChanged", {
      buffer = buf,
      callback = function()
        local m = vim.fn.mode()
        if m == "v" or m == "V" or m == "\22" or m == "s" or m == "S" then
          vim.schedule(function()
            if vim.api.nvim_get_current_buf() == buf then
              pcall(vim.cmd, "normal! \27")
            end
          end)
        end
      end,
    })
    -- 关闭控制窗 → 立即停播并清高亮
    clear_close_autocmd()
    local gid = vim.api.nvim_create_augroup("tts_control_close_" .. tostring(buf), { clear = true })
    state.close_augroup = gid
    vim.api.nvim_create_autocmd("WinClosed", {
      group = gid,
      pattern = tostring(win),
      callback = function()
        vim.schedule(on_control_closed)
      end,
    })
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      group = gid,
      buffer = buf,
      callback = function()
        vim.schedule(on_control_closed)
      end,
    })
  else
    state.segments = segments or state.segments
    if opts.ranges and #opts.ranges > 0 then
      state.ranges = opts.ranges
    else
      state.ranges = M.locate_segments(state.source_buf, state.segments, opts.origin)
    end
  end
  bind_source_rate_maps()
  M.render()
  local st0 = engine.get_state()
  local idx0 = st0.index or 0
  if st0.status == "playing" or st0.status == "paused" then
    M.highlight_source(idx0)
  end
  return state.buf
end

function M._maps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", opts, { desc = desc }))
  end

  -- 禁止选择文字：禁用 visual 入口 + 鼠标拖选
  vim.keymap.set("n", "V", "<Nop>", opts)
  vim.keymap.set("n", "<C-v>", "<Nop>", opts)
  vim.keymap.set("n", "<C-V>", "<Nop>", opts)
  vim.keymap.set("n", "gv", "<Nop>", opts)
  pcall(vim.keymap.set, "x", "<Esc>", "<Esc>", opts)
  pcall(vim.keymap.set, "s", "<Esc>", "<Esc>", opts)
  pcall(vim.keymap.set, "x", "v", "<Esc>", opts)
  pcall(vim.keymap.set, "x", "V", "<Esc>", opts)
  -- 禁止鼠标拖拽选区（仍可用单击按钮）
  pcall(vim.keymap.set, "n", "<LeftDrag>", "<Nop>", opts)
  pcall(vim.keymap.set, "n", "<RightDrag>", "<Nop>", opts)
  pcall(vim.keymap.set, "n", "<S-LeftMouse>", "<Nop>", opts)
  pcall(vim.keymap.set, "n", "<S-LeftDrag>", "<Nop>", opts)

  map("q", function()
    require("tts").stop_all()
  end, "tts: stop & exit")
  map("<Esc>", function()
    require("tts").stop_all()
  end, "tts: stop & exit")
  map("<Space>", function()
    engine.toggle()
  end, "tts: pause/resume")

  -- 左/右：上下一段
  map("<Left>", function()
    do_action("prev")
  end, "tts: prev segment")
  map("<Right>", function()
    do_action("next")
  end, "tts: next segment")
  -- 上/下：音量
  map("<Up>", function()
    do_action("vol_up")
  end, "tts: volume +")
  map("<Down>", function()
    do_action("vol_down")
  end, "tts: volume -")

  map("v", function()
    M.open_voice_float()
  end, "tts: voice float")
  map("L", function()
    do_action("lang")
  end, "tts: toggle UI language")
  map("l", function()
    do_action("lang")
  end, "tts: toggle UI language")

  -- 语速： + / - （及 = / [ ] / Shift+上/下 / 小键盘）
  local function rate_up()
    do_action("rate_up")
    M.render()
  end
  local function rate_down()
    do_action("rate_down")
    M.render()
  end
  map("+", rate_up, "tts: rate+")
  map("=", rate_up, "tts: rate+") -- 未按 Shift 的 + 键位
  map("-", rate_down, "tts: rate-")
  map("_", rate_down, "tts: rate-")
  map("<kPlus>", rate_up, "tts: rate+")
  map("<kMinus>", rate_down, "tts: rate-")
  map("[", rate_down, "tts: rate-")
  map("]", rate_up, "tts: rate+")
  map("<S-Up>", rate_up, "tts: rate+")
  map("<S-Down>", rate_down, "tts: rate-")

  -- 滚轮调节音量
  map("<ScrollWheelUp>", function()
    do_action("vol_up")
  end, "tts: volume +")
  map("<ScrollWheelDown>", function()
    do_action("vol_down")
  end, "tts: volume -")
  map("<C-ScrollWheelUp>", function()
    do_action("vol_up")
  end, "tts: volume +")
  map("<C-ScrollWheelDown>", function()
    do_action("vol_down")
  end, "tts: volume -")

  local function on_click()
    vim.schedule(function()
      if not state.buf or vim.api.nvim_get_current_buf() ~= state.buf then
        return
      end
      local cur = vim.api.nvim_win_get_cursor(0)
      local row, col = cur[1] - 1, cur[2]
      for _, h in ipairs(state.hits or {}) do
        if h.row == row and col >= h.col and col < h.end_col then
          do_action(h.action)
          return
        end
      end
    end)
  end
  vim.keymap.set("n", "<LeftRelease>", on_click, opts)
  vim.keymap.set("n", "<2-LeftMouse>", on_click, opts)
  vim.keymap.set("n", "<CR>", function()
    local cur = vim.api.nvim_win_get_cursor(0)
    local row, col = cur[1] - 1, cur[2]
    for _, h in ipairs(state.hits or {}) do
      if h.row == row and col >= h.col and col < h.end_col then
        do_action(h.action)
        return
      end
    end
  end, opts)
end

---发音人 float 选择
function M.open_voice_float()
  ensure_hl()
  M.close_voice_float()
  engine.ensure()
  engine.list_voices()
  vim.wait(500, function()
    local s = engine.get_state()
    return s.voices and #s.voices > 0
  end, 40)

  local st = engine.get_state()
  local voices = st.voices or {}
  if #voices == 0 then
    vim.notify(T("no_voices"), vim.log.levels.WARN)
    return
  end

  local lines = { T("voice_hint"), "" }
  local cur = st.voice or ""
  local cur_idx = 1
  for i, v in ipairs(voices) do
    local mark = (v.name == cur) and "● " or "○ "
    lines[#lines + 1] = mark .. (v.name or ("#" .. i))
    if v.name == cur then
      cur_idx = i
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].tts_voice_float = true

  local width = 50
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 4)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = T("voice_title"),
    title_pos = "center",
    zindex = 80,
  })
  pcall(function()
    vim.wo[win].winhl = "Normal:TtsVoiceFloat,FloatBorder:TtsVoiceFloat"
    vim.wo[win].cursorline = true
  end)
  state.voice_win = win
  state.voice_buf = buf

  -- 高亮当前
  pcall(vim.api.nvim_buf_set_extmark, buf, NS_VOICE, cur_idx + 1, 0, {
    end_row = cur_idx + 1,
    line_hl_group = "TtsVoiceSel",
  })
  pcall(vim.api.nvim_win_set_cursor, win, { cur_idx + 2, 0 })

  local function pick_line(lnum)
    local i = lnum - 2 -- lines[1]=title, [2]=blank, [3]=voice1
    if i < 1 or i > #voices then
      return
    end
    local name = voices[i].name
    M.close_voice_float()
    engine.set_voice(name)
    -- 记住选择，下次播放仍用同一发音人
    pcall(function()
      require("tts").set_preferred_voice(name)
    end)
    local est = engine.get_state()
    if (est.status == "playing" or est.status == "paused") and #state.segments > 0 then
      engine.speak(state.segments, {
        voice = name,
        volume = est.volume,
        rate = est.rate,
        start = est.index or 0,
      })
    end
    vim.notify(T("voice_saved") .. tostring(name), vim.log.levels.INFO)
    M.render()
  end

  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", function()
    M.close_voice_float()
  end, o)
  vim.keymap.set("n", "<Esc>", function()
    M.close_voice_float()
  end, o)
  vim.keymap.set("n", "<CR>", function()
    local l = vim.api.nvim_win_get_cursor(0)[1]
    pick_line(l)
  end, o)
  vim.keymap.set("n", "<LeftRelease>", function()
    vim.schedule(function()
      if state.voice_buf and vim.api.nvim_get_current_buf() == state.voice_buf then
        pick_line(vim.api.nvim_win_get_cursor(0)[1])
      end
    end)
  end, o)
  vim.keymap.set("n", "<2-LeftMouse>", function()
    pick_line(vim.api.nvim_win_get_cursor(0)[1])
  end, o)
end

function M.set_segments(segments)
  state.segments = segments or {}
end

function M.set_index(i)
  state.index = i or 0
end

function M.render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  ensure_hl()
  local st = engine.get_state()
  local segs = state.segments
  local total = math.max(#segs, st.total or 0)
  local idx = st.index or state.index or 0
  if total > 0 then
    idx = math.max(0, math.min(total - 1, idx))
  end
  state.index = idx

  local w = 60
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    w = math.max(40, vim.api.nvim_win_get_width(state.win) - 2)
  end

  local slabel, shl = status_label(st)
  local vname = st.voice or "?"
  if vim.fn.strdisplaywidth(vname) > 36 then
    vname = vim.fn.strcharpart(vname, 0, 34) .. "…"
  end

  local head = string.format("🔊 TTS  %s", state.source_label)
  local meta = string.format(
    "%s   %d/%d   %s %d   %s %d",
    slabel,
    total > 0 and (idx + 1) or 0,
    total,
    T("volume"),
    st.volume or 0,
    T("rate"),
    st.rate or 0
  )
  local voice_line = T("voice") .. ": " .. vname
  local prog = "[" .. bar(idx, total, math.min(36, w - 4)) .. "]"

  -- 可点按钮行（含中英文切换）
  local buttons = {
    { text = T("btn_prev"), action = "prev", hl = "TtsBtn" },
    { text = T("btn_toggle"), action = "toggle", hl = "TtsBtn" },
    { text = T("btn_next"), action = "next", hl = "TtsBtn" },
    { text = T("btn_vol_up"), action = "vol_up", hl = "TtsBtn" },
    { text = T("btn_vol_down"), action = "vol_down", hl = "TtsBtn" },
    { text = T("btn_rate_up"), action = "rate_up", hl = "TtsBtn" },
    { text = T("btn_rate_down"), action = "rate_down", hl = "TtsBtn" },
    { text = T("btn_voice"), action = "voice", hl = "TtsBtn" },
    { text = T("btn_lang"), action = "lang", hl = "TtsBtn" },
    { text = T("btn_stop"), action = "stop", hl = "TtsBtnDanger" },
  }
  local btn_line = ""
  local btn_hits = {} ---@type TtsHit[]
  for _, b in ipairs(buttons) do
    local c0 = #btn_line
    btn_line = btn_line .. b.text
    btn_hits[#btn_hits + 1] = {
      row = 4, -- 0-based 第 5 行
      col = c0,
      end_col = #btn_line,
      action = b.action,
      hl = b.hl,
    }
  end

  local cur_preview = ""
  if segs[idx + 1] then
    cur_preview = segs[idx + 1]:gsub("\n", " ")
    if vim.fn.strdisplaywidth(cur_preview) > w - 6 then
      cur_preview = vim.fn.strcharpart(cur_preview, 0, w - 8) .. "…"
    end
    cur_preview = "▶ " .. cur_preview
  else
    cur_preview = "▶ " .. T("no_text")
  end

  local lines = {
    head,
    meta,
    voice_line,
    prog,
    btn_line,
    cur_preview,
  }

  pcall(function()
    vim.bo[state.buf].modifiable = true
    vim.bo[state.buf].readonly = false
  end)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_clear_namespace, state.buf, NS_UI, 0, -1)

  local function em(row, hl)
    pcall(vim.api.nvim_buf_set_extmark, state.buf, NS_UI, row, 0, {
      end_col = #(lines[row + 1] or ""),
      hl_group = hl,
    })
  end
  em(0, "TtsTitle")
  em(1, shl)
  em(2, "TtsMeta")
  em(3, "TtsBar")
  em(5, "TtsPlaying") -- 当前句预览：黑字白底

  state.hits = btn_hits
  for _, h in ipairs(btn_hits) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, NS_UI, h.row, h.col, {
      end_col = h.end_col,
      hl_group = h.hl or "TtsBtn",
    })
  end

  pcall(function()
    vim.bo[state.buf].modifiable = false
    vim.bo[state.buf].modified = false
  end)

  -- 同步原文高亮（播放/暂停时；结束或停止后清除）
  if st.status == "playing" or st.status == "paused" then
    M.highlight_source(idx)
  else
    M.clear_source_hl()
  end
end

return M
