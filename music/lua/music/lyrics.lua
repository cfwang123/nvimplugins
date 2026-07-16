---@mod music.lyrics LRC lyrics panel + current-line helpers (CN/EN co-highlight)
local M = {}

---@class LyricLine
---@field t number start time seconds
---@field text string

---@class LyricsState
---@field audio_path string|nil
---@field lrc_path string|nil
---@field lines LyricLine[]
---@field idx integer first current line 1-based (0 = none)
---@field idx_end integer last current line 1-based
---@field progress number 0–1 within current group
---@field buf integer|nil
---@field win integer|nil

local state = {
  audio_path = nil,
  lrc_path = nil,
  lines = {},
  idx = 0,
  idx_end = 0,
  progress = 0,
  buf = nil,
  win = nil,
}

local ns = vim.api.nvim_create_namespace("music_lyrics")
local hl_ready = false
---Same timestamp tolerance for CN/EN paired lines
local SAME_T = 0.08

local function ensure_hl()
  if hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  vim.api.nvim_set_hl(0, "MusicLyricNormal", { fg = "#6b6b6b", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "MusicLyricCurrent", { fg = "#1a1a1a", bg = "#e8e8e8", bold = true })
  vim.api.nvim_set_hl(0, "MusicLyricSung", { fg = "#c45c12", bg = "#ffffff", bold = true })
  vim.api.nvim_set_hl(0, "MusicLyricRest", { fg = "#8a8a8a", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "MusicLyricMeta", { fg = "#9a9a9a", bg = "#ffffff", italic = true })
  vim.api.nvim_set_hl(0, "MusicLyricEmpty", { fg = "#b0b0b0", bg = "#ffffff" })
  hl_ready = true
end

---Parse [mm:ss.xx] or [mm:ss] → seconds
local function parse_time(tag)
  local m, s, cs = tag:match("^(%d+):(%d+)%.(%d+)$")
  if m then
    local frac = tonumber(cs) or 0
    local len = #cs
    if len == 1 then
      frac = frac / 10
    elseif len == 2 then
      frac = frac / 100
    else
      frac = frac / (10 ^ len)
    end
    return tonumber(m) * 60 + tonumber(s) + frac
  end
  m, s = tag:match("^(%d+):(%d+)$")
  if m then
    return tonumber(m) * 60 + tonumber(s)
  end
  return nil
end

---Find .lrc next to audio file.
---@param audio_path string
---@return string|nil
function M.find_lrc(audio_path)
  if not audio_path or audio_path == "" then
    return nil
  end
  audio_path = vim.fn.fnamemodify(audio_path, ":p")
  local base = vim.fn.fnamemodify(audio_path, ":r")
  local candidates = {
    base .. ".lrc",
    base .. ".LRC",
    base .. ".lrcx",
    audio_path .. ".lrc",
  }
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p) == 1 then
      return p
    end
  end
  return nil
end

---Parse LRC file contents into timed lines (sorted).
---@param path string
---@return LyricLine[], string|nil err
function M.parse_lrc_file(path)
  local raw = vim.fn.readfile(path)
  if not raw then
    return {}, "cannot read " .. path
  end
  ---@type LyricLine[]
  local lines = {}
  for _, line in ipairs(raw) do
    line = line:gsub("\r$", "")
    if line ~= "" and not line:match("^%s*$") then
      local times = {}
      local rest = line
      while true do
        local tag, after = rest:match("^%[([%d%.:]+)%](.*)$")
        if not tag then
          break
        end
        local t = parse_time(tag)
        if t then
          table.insert(times, t)
        end
        rest = after
      end
      local text = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if #times > 0 then
        if text == "" then
          text = " "
        end
        for _, t in ipairs(times) do
          table.insert(lines, { t = t, text = text })
        end
      end
    end
  end
  table.sort(lines, function(a, b)
    if a.t == b.t then
      return a.text < b.text
    end
    return a.t < b.t
  end)
  return lines, nil
end

---@param audio_path string
---@return boolean ok
---@return string|nil msg
function M.load_for_audio(audio_path)
  audio_path = vim.fn.fnamemodify(audio_path or "", ":p")
  state.audio_path = audio_path
  state.idx = 0
  state.idx_end = 0
  state.progress = 0
  local lrc = M.find_lrc(audio_path)
  if not lrc then
    state.lrc_path = nil
    state.lines = {}
    return false, "未找到歌词文件（同目录同名 .lrc）"
  end
  local lines, err = M.parse_lrc_file(lrc)
  if err then
    state.lrc_path = lrc
    state.lines = {}
    return false, err
  end
  state.lrc_path = lrc
  state.lines = lines
  if #lines == 0 then
    return false, "歌词文件为空或无时间轴"
  end
  return true, nil
end

function M.is_open()
  return state.win
    and vim.api.nvim_win_is_valid(state.win)
    and state.buf
    and vim.api.nvim_buf_is_valid(state.buf)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

function M.get_state()
  return state
end

---Last line with t <= pos (1-based), 0 if before first.
local function index_at(pos)
  local lines = state.lines
  if #lines == 0 then
    return 0
  end
  pos = pos or 0
  if pos < lines[1].t then
    return 0
  end
  local lo, hi, ans = 1, #lines, 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if lines[mid].t <= pos then
      ans = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return ans
end

---Expand index to full timestamp group (CN + EN same time).
---@param idx integer
---@return integer i0
---@return integer i1
local function group_range(idx)
  local lines = state.lines
  if idx < 1 or idx > #lines then
    return 0, 0
  end
  local t0 = lines[idx].t
  local i0, i1 = idx, idx
  while i0 > 1 and math.abs(lines[i0 - 1].t - t0) <= SAME_T do
    i0 = i0 - 1
  end
  while i1 < #lines and math.abs(lines[i1 + 1].t - t0) <= SAME_T do
    i1 = i1 + 1
  end
  return i0, i1
end

---Next group start time after i1.
local function group_end_time(i1)
  local lines = state.lines
  if i1 < 1 then
    if #lines > 0 then
      return lines[1].t
    end
    return 0
  end
  if i1 < #lines then
    return lines[i1 + 1].t
  end
  return lines[i1].t + 5
end

---Current lyric group + progress for karaoke (CN/EN all included).
---@param pos number|nil
---@return string[] texts
---@return number progress 0–1
---@return integer i0
---@return integer i1
function M.get_current_display(pos)
  pos = pos or 0
  if #state.lines == 0 then
    return {}, 0, 0, 0
  end
  local idx = index_at(pos)
  if idx < 1 then
    return {}, 0, 0, 0
  end
  local i0, i1 = group_range(idx)
  local t0 = state.lines[i0].t
  local t1 = group_end_time(i1)
  local progress = (pos - t0) / math.max(0.05, t1 - t0)
  progress = math.max(0, math.min(1, progress))
  local texts = {}
  for i = i0, i1 do
    table.insert(texts, state.lines[i].text)
  end
  return texts, progress, i0, i1
end

---Split text by character progress (UTF-8 safe).
---@param text string
---@param progress number
---@return string sung
---@return string rest
function M.split_progress(text, progress)
  text = text or ""
  if text == "" then
    return "", ""
  end
  local n = vim.fn.strchars(text)
  local k = math.floor(n * (progress or 0) + 1e-6)
  k = math.max(0, math.min(n, k))
  return vim.fn.strcharpart(text, 0, k), vim.fn.strcharpart(text, k)
end

local function apply_highlights(i0, i1)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  local n = #state.lines
  if n == 0 then
    pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, "MusicLyricEmpty", 0, 0, -1)
    return
  end
  for i = 1, n do
    local current = i0 > 0 and i >= i0 and i <= i1
    local hl = current and "MusicLyricCurrent" or "MusicLyricNormal"
    pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, hl, i - 1, 0, -1)
  end
  -- karaoke on current lines: sung prefix
  if i0 > 0 and state.progress > 0 then
    for i = i0, i1 do
      local text = state.lines[i].text or ""
      local sung = M.split_progress(text, state.progress)
      if sung ~= "" then
        local byte_end = #sung
        pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, "MusicLyricSung", i - 1, 0, byte_end)
      end
    end
  end
end

local function scroll_to_current(idx)
  if not M.is_open() or idx < 1 then
    return
  end
  local win = state.win
  local height = vim.api.nvim_win_get_height(win)
  local topline = math.max(1, idx - math.floor(height / 2))
  pcall(function()
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({
        lnum = idx,
        col = 0,
        topline = topline,
        leftcol = 0,
        curswant = 0,
      })
      pcall(vim.api.nvim_win_set_cursor, win, { idx, 0 })
    end)
  end)
end

function M.render_buffer()
  ensure_hl()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local texts = {}
  if #state.lines == 0 then
    if state.lrc_path then
      table.insert(texts, "(歌词无时间轴) " .. vim.fn.fnamemodify(state.lrc_path, ":t"))
    else
      table.insert(texts, "(未找到 .lrc 歌词文件)")
      if state.audio_path then
        table.insert(texts, "期望: " .. vim.fn.fnamemodify(state.audio_path, ":r") .. ".lrc")
      end
    end
  else
    for _, ln in ipairs(state.lines) do
      table.insert(texts, ln.text)
    end
  end
  local bo = vim.bo[state.buf]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, texts)
  bo.modifiable = false
  bo.modified = false
  apply_highlights(state.idx, state.idx_end)
  if state.idx > 0 then
    scroll_to_current(state.idx)
  end
end

---Update follow highlight from playback position (seconds).
---Always refreshes karaoke progress so sung prefix updates continuously.
---@param pos number|nil
function M.follow(pos)
  if not M.is_open() then
    return
  end
  if #state.lines == 0 then
    return
  end
  local texts, progress, i0, i1 = M.get_current_display(pos or 0)
  local changed = i0 ~= state.idx or i1 ~= state.idx_end
  -- 约 10f/s 时每帧都可能只前进很少，阈值放宽以便句内橙色进度流畅
  local prog_changed = math.abs((state.progress or 0) - progress) > 0.001
  state.idx = i0
  state.idx_end = i1
  state.progress = progress
  if changed or prog_changed then
    apply_highlights(i0, i1)
  end
  if changed and i0 > 0 then
    scroll_to_current(i0)
  end
  return texts, progress
end

---@param music_win integer|nil
---@param height? integer
---@return integer|nil win
function M.open_panel(music_win, height)
  ensure_hl()
  height = math.max(5, math.min(height or 12, vim.o.lines - 6))

  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = vim.api.nvim_create_buf(false, true)
    local bo = vim.bo[state.buf]
    bo.buftype = "nofile"
    bo.bufhidden = "hide"
    bo.buflisted = false
    bo.swapfile = false
    bo.modifiable = false
    bo.filetype = "music_lyrics"
    pcall(vim.api.nvim_buf_set_name, state.buf, "music://lyrics")
    vim.b[state.buf].music_lyrics = true
    vim.keymap.set("n", "q", function()
      M.close_panel()
    end, { buffer = state.buf, silent = true, desc = "music: close lyrics" })
    vim.keymap.set("n", "g", function()
      M.close_panel()
    end, { buffer = state.buf, silent = true, desc = "music: close lyrics" })
  end

  if M.is_open() then
    M.render_buffer()
    return state.win
  end

  if music_win and vim.api.nvim_win_is_valid(music_win) then
    pcall(vim.api.nvim_set_current_win, music_win)
  end
  vim.cmd("aboveleft " .. tostring(height) .. "split")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  local wo = vim.wo[state.win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = true
  wo.cursorline = false
  wo.list = false
  -- Neovim 0.12+: winfixheight is boolean (fix height on/off), not the height value
  pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = state.win })
  pcall(vim.api.nvim_win_set_height, state.win, height)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function()
      if state.win and not vim.api.nvim_win_is_valid(state.win) then
        state.win = nil
      end
    end,
  })

  M.render_buffer()
  return state.win
end

function M.close_panel()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local tab_wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(state.win))
    if #tab_wins <= 1 then
      local empty = vim.api.nvim_create_buf(true, true)
      pcall(vim.api.nvim_win_set_buf, state.win, empty)
    else
      pcall(vim.api.nvim_win_close, state.win, true)
    end
  end
  state.win = nil
end

---@param music_win integer|nil
---@param audio_path string|nil
---@return boolean open
function M.toggle(music_win, audio_path)
  if M.is_open() then
    M.close_panel()
    return false
  end
  if audio_path and audio_path ~= "" then
    local ok, msg = M.load_for_audio(audio_path)
    if not ok then
      vim.notify("music: " .. tostring(msg), vim.log.levels.WARN)
    end
  end
  M.open_panel(music_win, 12)
  return true
end

---@param audio_path string
---@param pos number|nil
function M.on_track(audio_path, pos)
  if not audio_path or audio_path == "" then
    return
  end
  local same = state.audio_path
    and vim.fn.fnamemodify(state.audio_path, ":p") == vim.fn.fnamemodify(audio_path, ":p")
  if not same then
    M.load_for_audio(audio_path)
    state.idx = 0
    state.idx_end = 0
    state.progress = 0
    if M.is_open() then
      M.render_buffer()
    end
  end
  M.follow(pos or 0)
end

function M.reset()
  M.close_panel()
  state.audio_path = nil
  state.lrc_path = nil
  state.lines = {}
  state.idx = 0
  state.idx_end = 0
  state.progress = 0
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
end

return M
