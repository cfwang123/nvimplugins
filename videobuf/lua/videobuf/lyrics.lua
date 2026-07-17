---@mod videobuf.lyrics Subtitle line (LRC / SRT), aligned with music.lyrics
local M = {}

---@class VbLyricLine
---@field t number
---@field text string

local state = {
  path = nil,
  sub_path = nil,
  lines = {},
  idx = 0,
  idx_end = 0,
  progress = 0,
  panel_buf = nil,
  panel_win = nil,
}

local SAME_T = 0.08
local ns = vim.api.nvim_create_namespace("videobuf_lyrics")
local hl_ready = false

local function ensure_hl()
  if hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  vim.api.nvim_set_hl(0, "VideobufLyricSung", { fg = "#ffb86c", bold = true })
  vim.api.nvim_set_hl(0, "VideobufLyricRest", { fg = "#888888" })
  vim.api.nvim_set_hl(0, "VideobufLyricEmpty", { fg = "#666666", italic = true })
  vim.api.nvim_set_hl(0, "VideobufLyricCurrent", { fg = "#f8f8f2", bold = true })
  hl_ready = true
end

local function parse_lrc_time(tag)
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

local function parse_srt_time(s)
  -- 00:00:01,000 or 00:00:01.000
  local h, m, sec, ms = s:match("(%d+):(%d+):(%d+)[,.](%d+)")
  if not h then
    return nil
  end
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec) + (tonumber(ms) or 0) / 1000
end

function M.find_sub(video_path)
  if not video_path or video_path == "" then
    return nil
  end
  video_path = vim.fn.fnamemodify(video_path, ":p")
  local base = vim.fn.fnamemodify(video_path, ":r")
  local candidates = {
    base .. ".lrc",
    base .. ".LRC",
    base .. ".srt",
    base .. ".SRT",
    base .. ".lrcx",
  }
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p) == 1 then
      return p
    end
  end
  return nil
end

function M.parse_lrc_file(path)
  local raw = vim.fn.readfile(path)
  if not raw then
    return {}, "cannot read"
  end
  local lines = {}
  for _, line in ipairs(raw) do
    line = line:gsub("\r$", "")
    if line ~= "" then
      local times = {}
      local rest = line
      while true do
        local tag, after = rest:match("^%[([%d%.:]+)%](.*)$")
        if not tag then
          break
        end
        local t = parse_lrc_time(tag)
        if t then
          table.insert(times, t)
        end
        rest = after
      end
      rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if #times > 0 and rest ~= "" then
        for _, t in ipairs(times) do
          table.insert(lines, { t = t, text = rest })
        end
      end
    end
  end
  table.sort(lines, function(a, b)
    return a.t < b.t
  end)
  return lines, nil
end

function M.parse_srt_file(path)
  local raw = vim.fn.readfile(path)
  if not raw then
    return {}, "cannot read"
  end
  local lines = {}
  local i = 1
  while i <= #raw do
    local line = raw[i]:gsub("\r$", "")
    if line:match("^%d+$") then
      i = i + 1
      if i > #raw then
        break
      end
      local tl = raw[i]:gsub("\r$", "")
      local a, b = tl:match("(%d+:%d+:%d+[,.]%d+)%s*%-%-%>%s*(%d+:%d+:%d+[,.]%d+)")
      i = i + 1
      local texts = {}
      while i <= #raw do
        local t = raw[i]:gsub("\r$", "")
        if t == "" then
          break
        end
        -- strip simple html tags
        t = t:gsub("<[^>]+>", "")
        table.insert(texts, t)
        i = i + 1
      end
      local t0 = a and parse_srt_time(a)
      if t0 and #texts > 0 then
        table.insert(lines, { t = t0, text = table.concat(texts, " ") })
      end
    end
    i = i + 1
  end
  table.sort(lines, function(a, b)
    return a.t < b.t
  end)
  return lines, nil
end

function M.load(video_path)
  state.path = video_path
  state.lines = {}
  state.idx = 0
  state.idx_end = 0
  state.progress = 0
  state.sub_path = M.find_sub(video_path)
  if not state.sub_path then
    return false
  end
  local ext = state.sub_path:match("%.([%w]+)$")
  ext = ext and ext:lower() or ""
  local lines
  if ext == "srt" then
    lines = M.parse_srt_file(state.sub_path)
  else
    lines = M.parse_lrc_file(state.sub_path)
  end
  state.lines = lines or {}
  return #state.lines > 0
end

function M.clear()
  state.path = nil
  state.sub_path = nil
  state.lines = {}
  state.idx = 0
  state.idx_end = 0
  state.progress = 0
end

---Update current index by playback position
function M.sync(pos)
  pos = pos or 0
  local lines = state.lines
  if #lines == 0 then
    state.idx = 0
    state.idx_end = 0
    state.progress = 0
    return
  end
  local idx = 0
  for i, ln in ipairs(lines) do
    if ln.t <= pos + 0.001 then
      idx = i
    else
      break
    end
  end
  if idx == 0 then
    state.idx = 0
    state.idx_end = 0
    state.progress = 0
    return
  end
  local t0 = lines[idx].t
  local idx_end = idx
  while idx_end < #lines and math.abs(lines[idx_end + 1].t - t0) <= SAME_T do
    idx_end = idx_end + 1
  end
  local t1 = (idx_end < #lines) and lines[idx_end + 1].t or (t0 + 5)
  local dur = math.max(0.05, t1 - t0)
  state.idx = idx
  state.idx_end = idx_end
  state.progress = math.max(0, math.min(1, (pos - t0) / dur))
end

---One-line display text for control bar
function M.current_text(cols)
  cols = cols or 80
  local empty_label = " （无字幕）"
  pcall(function()
    empty_label = require("videobuf.i18n").t("no_subtitle")
  end)
  if #state.lines == 0 then
    return empty_label
  end
  if state.idx < 1 then
    return " ..."
  end
  local parts = {}
  for i = state.idx, state.idx_end do
    table.insert(parts, state.lines[i].text)
  end
  local text = " " .. table.concat(parts, "  |  ")
  if vim.fn.strwidth(text) > cols then
    while vim.fn.strwidth(text) > cols - 1 and #text > 1 do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
    text = text .. "…"
  end
  return text
end

---ANSI line: sung (bright) + rest (dim) approx by progress
function M.current_ansi(cols)
  cols = math.max(8, cols or 80)
  if #state.lines == 0 then
    local s = " （无字幕）"
    local pad = cols - vim.fn.strwidth(s)
    if pad > 0 then
      s = s .. string.rep(" ", pad)
    end
    return "\27[0m\27[38;2;136;136;136m" .. s .. "\27[0m"
  end
  if state.idx < 1 then
    local s = " ..."
    local pad = cols - vim.fn.strwidth(s)
    if pad > 0 then
      s = s .. string.rep(" ", pad)
    end
    return "\27[0m\27[38;2;136;136;136m" .. s .. "\27[0m"
  end
  local parts = {}
  for i = state.idx, state.idx_end do
    table.insert(parts, state.lines[i].text)
  end
  local full = table.concat(parts, "  |  ")
  local n = vim.fn.strchars(full)
  local cut = math.floor(n * (state.progress or 0) + 0.5)
  if cut < 0 then
    cut = 0
  elseif cut > n then
    cut = n
  end
  local sung = vim.fn.strcharpart(full, 0, cut)
  local rest = vim.fn.strcharpart(full, cut, n - cut)
  local text = " " .. sung .. rest
  local w = vim.fn.strwidth(text)
  if w > cols then
    text = vim.fn.strcharpart(text, 0, cols)
    -- rebuild cut roughly
    sung = text
    rest = ""
  else
    text = text .. string.rep(" ", cols - w)
  end
  -- re-split for color after pad is awkward; color by char progress on unpadded
  local base = " " .. vim.fn.strcharpart(full, 0, cut)
  local tail = vim.fn.strcharpart(full, cut, n - cut)
  local line = base .. tail
  local lw = vim.fn.strwidth(line)
  if lw < cols then
    line = line .. string.rep(" ", cols - lw)
  end
  return "\27[0m\27[38;2;255;184;108m"
    .. base
    .. "\27[38;2;136;136;136m"
    .. tail
    .. string.rep(" ", math.max(0, cols - lw))
    .. "\27[0m"
end

function M.has()
  return #state.lines > 0
end

function M.get_state()
  return state
end

function M.toggle_panel()
  ensure_hl()
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    pcall(vim.api.nvim_win_close, state.panel_win, true)
    state.panel_win = nil
    return
  end
  if #state.lines == 0 then
    vim.notify("videobuf: 无字幕文件", vim.log.levels.INFO)
    return
  end
  local buf = state.panel_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    state.panel_buf = buf
  end
  local texts = {}
  for _, ln in ipairs(state.lines) do
    local m = math.floor(ln.t / 60)
    local s = ln.t - m * 60
    table.insert(texts, string.format("[%02d:%04.1f] %s", m, s, ln.text))
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "videobuf_lyrics"
  vim.cmd("aboveleft 12split")
  state.panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.panel_win, buf)
  if state.idx >= 1 then
    pcall(vim.api.nvim_win_set_cursor, state.panel_win, { state.idx, 0 })
  end
  vim.keymap.set("n", "q", function()
    if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
      pcall(vim.api.nvim_win_close, state.panel_win, true)
    end
    state.panel_win = nil
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "g", function()
    M.toggle_panel()
  end, { buffer = buf, silent = true })
end

return M
