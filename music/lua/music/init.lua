---@mod music Buffer-based audio player (colorful clickable UI)
local M = {}

local player = require("music.player")

---@class MusicConfig
---@field backend "python"|"auto"
---@field volume number
---@field loop boolean
---@field auto_next boolean
---@field auto_play boolean
---@field auto_open boolean
---@field extensions string[]
---@field poll_ms number
---@field bar_width number|nil
---@field viz_height number
---@field viz boolean
---@field python string Python 可执行文件（默认 python）

local default_config = {
  backend = "python",
  volume = 70,
  loop = false,
  auto_next = true,
  auto_play = true,
  auto_open = true,
  extensions = {
    "mp3",
    "flac",
    "wav",
    "ogg",
    "oga",
    "m4a",
    "aac",
    "opus",
    "wma",
    "aiff",
    "ape",
    "wv",
  },
  poll_ms = 200,
  bar_width = nil,
  viz_height = 8,
  viz = true,
  python = "python",
}

local config = vim.deepcopy(default_config)
local EXT = {}

---@class MusicHit
---@field action string
---@field row integer 1-based
---@field d0 integer 1-based display col start
---@field d1 integer 1-based display col end inclusive
---@field bar_d0 integer|nil for seek: bar display start
---@field bar_w integer|nil

---@class MusicSeg
---@field text string
---@field hl string
---@field b0 integer 0-based byte start
---@field b1 integer 0-based byte end exclusive

---@class MusicBufState
---@field path string
---@field siblings string[]
---@field index integer
---@field hits MusicHit[]
---@field segs table<integer, MusicSeg[]> 0-based row -> segs
---@field dragging boolean
---@field drag_action string|nil
---@field phase number

---@type table<integer, MusicBufState>
local state_by_buf = {}
---@type integer|nil
local active_buf = nil
---@type uv.uv_timer_t|nil
local poll_timer = nil
local ns = vim.api.nvim_create_namespace("music")
local hl_ready = false

local function rebuild_ext()
  EXT = {}
  for _, e in ipairs(config.extensions) do
    EXT[e:lower()] = true
  end
end

local function is_audio(path)
  if not path or path == "" then
    return false
  end
  local ext = path:match("%.([%w]+)$")
  return ext and EXT[ext:lower()] == true
end

local function fmt_time(sec)
  if sec == nil or sec < 0 or sec ~= sec then
    return "--:--"
  end
  sec = math.floor(sec + 0.5)
  local m = math.floor(sec / 60)
  local s = sec % 60
  if m >= 60 then
    local h = math.floor(m / 60)
    m = m % 60
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

local function list_siblings(path)
  path = vim.fn.fnamemodify(path, ":p")
  local dir = vim.fn.fnamemodify(path, ":h")
  local files = vim.fn.glob(dir .. "/*", false, true)
  local audio = {}
  for _, f in ipairs(files) do
    if vim.fn.isdirectory(f) == 0 and is_audio(f) then
      table.insert(audio, vim.fn.fnamemodify(f, ":p"))
    end
  end
  table.sort(audio, function(a, b)
    return vim.fn.fnamemodify(a, ":t"):lower() < vim.fn.fnamemodify(b, ":t"):lower()
  end)
  local idx = 1
  local norm = path:gsub("\\", "/"):lower()
  for i, f in ipairs(audio) do
    if f:gsub("\\", "/"):lower() == norm then
      idx = i
      break
    end
  end
  if #audio == 0 then
    audio = { path }
    idx = 1
  end
  return audio, idx
end

local function win_width(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return vim.api.nvim_win_get_width(win)
    end
  end
  return vim.o.columns
end

local function ensure_hl()
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  -- Catppuccin-ish player palette
  vim.api.nvim_set_hl(0, "MusicNormal", { fg = "#cdd6f4", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "MusicHeader", { fg = "#cba6f7", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "MusicTitle", { fg = "#89b4fa", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "MusicPath", { fg = "#6c7086", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "MusicMeta", { fg = "#a6adc8", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "MusicTime", { fg = "#f9e2af", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "MusicStatusPlay", { fg = "#a6e3a1", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "MusicStatusPause", { fg = "#f9e2af", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "MusicStatusStop", { fg = "#f38ba8", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "MusicBarFill", { fg = "#89b4fa", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "MusicBarEmpty", { fg = "#45475a", bg = "#313244" })
  vim.api.nvim_set_hl(0, "MusicBarThumb", { fg = "#cba6f7", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "MusicBarBracket", { fg = "#74c7ec", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "MusicBtn", { fg = "#1e1e2e", bg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "MusicBtnPlay", { fg = "#1e1e2e", bg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "MusicBtnPause", { fg = "#1e1e2e", bg = "#f9e2af", bold = true })
  vim.api.nvim_set_hl(0, "MusicBtnWarn", { fg = "#1e1e2e", bg = "#fab387", bold = true })
  vim.api.nvim_set_hl(0, "MusicBtnDanger", { fg = "#1e1e2e", bg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "MusicBtnMute", { fg = "#1e1e2e", bg = "#9399b2", bold = true })
  vim.api.nvim_set_hl(0, "MusicBtnLoopOn", { fg = "#1e1e2e", bg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "MusicBtnLoopOff", { fg = "#cdd6f4", bg = "#45475a", bold = true })
  vim.api.nvim_set_hl(0, "MusicHint", { fg = "#585b70", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "MusicSep", { fg = "#313244", bg = "#1e1e2e" })
  -- spectrum bands
  local viz_colors = {
    "#f38ba8",
    "#fab387",
    "#f9e2af",
    "#a6e3a1",
    "#94e2d5",
    "#89b4fa",
    "#b4befe",
    "#cba6f7",
  }
  for i, hex in ipairs(viz_colors) do
    vim.api.nvim_set_hl(0, "MusicViz" .. i, { fg = hex, bg = "#1e1e2e" })
  end
  hl_ready = true
end

---Line builder: tracks display cols (1-based) and byte ranges for highlights.
local function new_line()
  local self = {
    parts = {}, ---@type string[]
    segs = {}, ---@type MusicSeg[]
    hits = {}, ---@type {action:string,d0:integer,d1:integer,bar_d0?:integer,bar_w?:integer}[]
    bytes = 0,
    disp = 0, -- last used display col (0 = none yet; next char at disp+1)
  }

  function self:add(text, hl, action, extra)
    if not text or text == "" then
      return self
    end
    local w = vim.fn.strwidth(text)
    local b0 = self.bytes
    local b1 = b0 + #text
    local d0 = self.disp + 1
    local d1 = self.disp + w
    table.insert(self.parts, text)
    table.insert(self.segs, { text = text, hl = hl or "MusicNormal", b0 = b0, b1 = b1 })
    if action then
      local hit = { action = action, d0 = d0, d1 = d1 }
      if extra then
        for k, v in pairs(extra) do
          hit[k] = v
        end
      end
      table.insert(self.hits, hit)
    end
    self.bytes = b1
    self.disp = d1
    return self
  end

  function self:gap(n, hl)
    return self:add(string.rep(" ", n or 1), hl or "MusicNormal", nil)
  end

  function self:btn(label, hl, action)
    -- pad label for button look: [ label ]
    return self:add(" " .. label .. " ", hl or "MusicBtn", action)
  end

  function self:text()
    return table.concat(self.parts)
  end

  return self
end

---Return fill / thumb / empty cell counts that always sum to `width`.
local function progress_segments(pos, dur, width)
  width = math.max(8, width)
  local filled = 0
  if dur and dur > 0 then
    pos = math.max(0, math.min(dur, pos or 0))
    filled = math.floor(pos / dur * width + 0.5)
    filled = math.max(0, math.min(width, filled))
  end
  if filled <= 0 then
    return 0, true, width - 1
  end
  if filled >= width then
    return width - 1, true, 0
  end
  return filled, true, width - filled - 1
end

local function viz_data(st, playing, pos, width, height)
  height = math.max(3, height)
  width = math.max(16, width)
  local t = st.phase or 0
  local n_bars = math.floor(width / 2)
  n_bars = math.max(8, math.min(40, n_bars))
  local energy = playing and 1.0 or 0.18
  if pos then
    energy = energy * (0.75 + 0.25 * math.sin(pos * 1.7))
  end
  local heights = {}
  for i = 1, n_bars do
    local u = i / n_bars
    local h = 0.35
      + 0.35 * math.sin(t * 2.1 + u * 9.0)
      + 0.20 * math.sin(t * 3.7 + u * 17.0)
      + 0.15 * math.sin(t * 5.3 + u * 4.0 + (pos or 0) * 0.4)
    h = math.max(0.08, math.min(1.0, h * energy))
    if not playing then
      h = h * 0.35 + 0.06
    end
    heights[i] = h
  end
  local gap = 1
  local used = n_bars + gap * (n_bars - 1)
  local pad = math.max(0, math.floor((width - used) / 2))
  return heights, n_bars, gap, pad
end

local function status_label(status)
  if status == "playing" then
    return "▶ 播放中", "MusicStatusPlay"
  elseif status == "paused" then
    return "⏸ 已暂停", "MusicStatusPause"
  elseif status == "stopped" then
    return "⏹ 已停止", "MusicStatusStop"
  end
  return "○ 就绪", "MusicMeta"
end

local function track_status(st, pst)
  local status = pst.status or "idle"
  local pos = pst.position or 0
  if pst.path and vim.fn.fnamemodify(pst.path, ":p") ~= vim.fn.fnamemodify(st.path, ":p") then
    status = "idle"
    pos = 0
  end
  return status, pos, pst.duration
end

---@return string[] lines
---@return table<integer, MusicSeg[]> segs_by_row 0-based
---@return MusicHit[] hits
local function build_ui(buf, st)
  ensure_hl()
  local pst = player.get_state()
  local w = win_width(buf)
  local content_w = math.max(28, w - 4)
  local bar_w = config.bar_width or math.min(content_w - 4, math.max(24, w - 10))

  local title = vim.fn.fnamemodify(st.path, ":t")
  local dir = vim.fn.fnamemodify(st.path, ":h")
  local backend = pst.backend or player.backend_name() or "?"
  local status, pos, dur = track_status(st, pst)
  local playing = status == "playing"
  local slabel, shl = status_label(status)

  local lines = {}
  local segs_by_row = {}
  local all_hits = {}

  local function push(line_obj)
    local row1 = #lines + 1
    table.insert(lines, line_obj:text())
    segs_by_row[row1 - 1] = line_obj.segs
    for _, h in ipairs(line_obj.hits) do
      table.insert(all_hits, {
        action = h.action,
        row = row1,
        d0 = h.d0,
        d1 = h.d1,
        bar_d0 = h.bar_d0,
        bar_w = h.bar_w,
      })
    end
  end

  -- header
  do
    local L = new_line()
    L:gap(2):add("♫  MUSIC", "MusicHeader"):gap(2):add("· buffer player", "MusicPath")
    push(L)
  end
  push(new_line():gap(2):add(string.rep("━", math.min(content_w, 42)), "MusicSep"))

  -- title / path
  push(new_line():gap(2):add("♪  " .. title, "MusicTitle"))
  push(new_line():gap(2):add(dir, "MusicPath"))
  push(new_line())

  -- status meta
  do
    local L = new_line()
    L:gap(2)
      :add(slabel, shl)
      :gap(3)
      :add(string.format("音量 %d%%", pst.volume or config.volume), "MusicMeta")
      :gap(3)
      :add("后端 " .. tostring(backend), "MusicMeta")
      :gap(3)
      :add(string.format("%d / %d", st.index, #st.siblings), "MusicMeta")
    push(L)
  end
  push(new_line())

  -- time
  do
    local L = new_line()
    L:gap(2)
      :add(fmt_time(pos), "MusicTime")
      :add("  /  ", "MusicMeta")
      :add(fmt_time(dur), "MusicTime")
    push(L)
  end

  -- progress bar (clickable)
  do
    local L = new_line()
    L:gap(2):add("▕", "MusicBarBracket")
    local fill_n, has_thumb, empty_n = progress_segments(pos, dur, bar_w)
    local bar_d0 = L.disp + 1
    if fill_n > 0 then
      L:add(string.rep("█", fill_n), "MusicBarFill", "seek", { bar_d0 = bar_d0, bar_w = bar_w })
    end
    if has_thumb then
      L:add("●", "MusicBarThumb", "seek", { bar_d0 = bar_d0, bar_w = bar_w })
    end
    if empty_n > 0 then
      L:add(string.rep("─", empty_n), "MusicBarEmpty", "seek", { bar_d0 = bar_d0, bar_w = bar_w })
    end
    -- also whole bar as one seek region is covered by segments
    L:add("▏", "MusicBarBracket")
    push(L)
  end
  push(new_line())

  -- visualization
  if config.viz then
    if playing then
      st.phase = (st.phase or 0) + 0.18
    end
    local heights, n_bars, gap, pad = viz_data(st, playing, pos, content_w, config.viz_height)
    local blocks = { " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
    for row = 1, config.viz_height do
      local L = new_line()
      L:gap(2)
      if pad > 0 then
        L:gap(pad)
      end
      local threshold = (config.viz_height - row + 0.5) / config.viz_height
      for i = 1, n_bars do
        local h = heights[i]
        local ch = " "
        if h >= threshold then
          if h >= threshold + 0.45 / config.viz_height then
            ch = "█"
          else
            local frac = (h - (config.viz_height - row) / config.viz_height) * config.viz_height
            local bi = math.min(#blocks, math.max(2, math.floor(frac * (#blocks - 1)) + 1))
            ch = blocks[bi] or "▄"
          end
        elseif row == config.viz_height then
          ch = "▁"
        end
        local hl = "MusicViz" .. (((i - 1) % 8) + 1)
        L:add(ch, hl)
        if i < n_bars and gap > 0 then
          L:gap(gap)
        end
      end
      push(L)
    end
    push(new_line())
  end

  push(new_line():gap(2):add(string.rep("─", math.min(content_w, 48)), "MusicSep"))

  -- primary controls
  do
    local L = new_line()
    L:gap(2)
    L:btn("⏮ 上一首", "MusicBtn", "prev")
    L:gap(1)
    if playing then
      L:btn("⏸ 暂停", "MusicBtnPause", "toggle")
    else
      L:btn("▶ 播放", "MusicBtnPlay", "toggle")
    end
    L:gap(1)
    L:btn("⏭ 下一首", "MusicBtn", "next")
    L:gap(1)
    L:btn("⏹ 停止", "MusicBtnDanger", "stop")
    push(L)
  end
  push(new_line())

  -- secondary controls
  do
    local L = new_line()
    L:gap(2)
    L:btn("⏪ -5s", "MusicBtnWarn", "seek_back")
    L:gap(1)
    L:btn("⏩ +5s", "MusicBtnWarn", "seek_fwd")
    L:gap(1)
    L:btn("🔉 -", "MusicBtnMute", "vol_down")
    L:gap(1)
    L:btn("🔊 +", "MusicBtnMute", "vol_up")
    L:gap(1)
    if pst.loop then
      L:btn("🔁 循环·开", "MusicBtnLoopOn", "loop")
    else
      L:btn("🔁 循环·关", "MusicBtnLoopOff", "loop")
    end
    L:gap(1)
    L:btn("↻ 重播", "MusicBtn", "restart")
    L:gap(1)
    L:btn("✕ 关闭", "MusicBtnDanger", "close")
    push(L)
  end
  push(new_line())
  push(new_line():gap(2):add("提示: 点击按钮 · 拖动进度条跳转 · Space 播放/暂停", "MusicHint"))

  st.hits = all_hits
  st.segs = segs_by_row
  return lines, segs_by_row, all_hits
end

local function render(buf)
  local st = state_by_buf[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  player.poll()
  local lines, segs_by_row = build_ui(buf, st)
  local bo = vim.bo[buf]
  bo.readonly = false
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  bo.modifiable = false
  bo.modified = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row0, segs in pairs(segs_by_row) do
    for _, seg in ipairs(segs) do
      if seg.hl and seg.b1 > seg.b0 then
        pcall(vim.api.nvim_buf_add_highlight, buf, ns, seg.hl, row0, seg.b0, seg.b1)
      end
    end
  end

  -- window colors
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.wo[win].winhl = "Normal:MusicNormal,EndOfBuffer:MusicNormal,SignColumn:MusicNormal"
    end
  end
end

local function stop_poll()
  if poll_timer then
    pcall(function()
      poll_timer:stop()
      poll_timer:close()
    end)
    poll_timer = nil
  end
end

local function start_poll()
  stop_poll()
  if config.poll_ms <= 0 then
    return
  end
  poll_timer = vim.uv.new_timer()
  if not poll_timer then
    return
  end
  poll_timer:start(
    config.poll_ms,
    config.poll_ms,
    vim.schedule_wrap(function()
      if not active_buf or not vim.api.nvim_buf_is_valid(active_buf) then
        stop_poll()
        return
      end
      render(active_buf)
    end)
  )
end

local function hit_at(st, row, col)
  -- row 1-based, col 1-based display
  if not st.hits then
    return nil
  end
  for _, h in ipairs(st.hits) do
    if h.row == row and col >= h.d0 and col <= h.d1 then
      return h
    end
  end
  return nil
end

local function do_toggle(buf, st)
  local pst = player.get_state()
  if pst.status == "idle" or pst.status == "stopped" or not pst.path then
    player.play(st.path, pst.position or 0)
  else
    player.toggle()
  end
  render(buf)
end

local play_path_in_buf ---@type fun(buf: integer, path: string, opts?: table)

local function goto_sibling(buf, delta)
  local st = state_by_buf[buf]
  if not st or #st.siblings == 0 then
    return
  end
  local idx = st.index + delta
  if idx < 1 then
    idx = #st.siblings
  elseif idx > #st.siblings then
    idx = 1
  end
  play_path_in_buf(buf, st.siblings[idx], { auto_play = true })
end

local function seek_from_hit(buf, st, hit, col)
  local pst = player.get_state()
  local dur = pst.duration
  if not dur or dur <= 0 then
    vim.notify("music: 未知时长，无法跳转", vim.log.levels.WARN)
    return
  end
  local bar_d0 = hit.bar_d0 or hit.d0
  local bar_w = hit.bar_w or math.max(1, hit.d1 - hit.d0 + 1)
  local rel = col - bar_d0
  if rel < 0 then
    rel = 0
  end
  if rel >= bar_w then
    rel = bar_w - 1
  end
  local ratio = bar_w <= 1 and 0 or (rel / (bar_w - 1))
  player.seek_abs(ratio * dur)
  render(buf)
end

local function run_action(buf, st, action, hit, col)
  if action == "toggle" then
    do_toggle(buf, st)
  elseif action == "prev" then
    goto_sibling(buf, -1)
  elseif action == "next" then
    goto_sibling(buf, 1)
  elseif action == "stop" then
    player.stop()
    render(buf)
  elseif action == "seek_back" then
    player.seek(-5)
    render(buf)
  elseif action == "seek_fwd" then
    player.seek(5)
    render(buf)
  elseif action == "vol_up" then
    player.volume_up(5)
    render(buf)
  elseif action == "vol_down" then
    player.volume_down(5)
    render(buf)
  elseif action == "loop" then
    local on = player.set_loop()
    vim.notify("music: 单曲循环 " .. (on and "开" or "关"), vim.log.levels.INFO)
    render(buf)
  elseif action == "restart" then
    player.play(st.path, 0)
    render(buf)
  elseif action == "close" then
    M.close(buf)
  elseif action == "seek" then
    seek_from_hit(buf, st, hit, col)
  end
end

local function mouse_handle(buf, mode)
  local st = state_by_buf[buf]
  if not st then
    return
  end
  local pos = vim.fn.getmousepos()
  if pos.winid == 0 or vim.api.nvim_win_get_buf(pos.winid) ~= buf then
    return
  end
  local row = pos.line
  local col = pos.column -- 1-based
  local hit = hit_at(st, row, col)
  if not hit then
    if mode == "release" then
      st.dragging = false
      st.drag_action = nil
    end
    return
  end

  if mode == "down" then
    if hit.action == "seek" then
      st.dragging = true
      st.drag_action = "seek"
      seek_from_hit(buf, st, hit, col)
    else
      st.dragging = false
      st.drag_action = nil
      run_action(buf, st, hit.action, hit, col)
    end
  elseif mode == "drag" then
    if st.dragging and (st.drag_action == "seek" or hit.action == "seek") then
      local h = hit.action == "seek" and hit or hit_at(st, row, col)
      -- prefer any seek hit on this row
      if not h or h.action ~= "seek" then
        for _, x in ipairs(st.hits or {}) do
          if x.row == row and x.action == "seek" then
            h = x
            break
          end
        end
      end
      if h and h.action == "seek" then
        seek_from_hit(buf, st, h, col)
      end
    end
  elseif mode == "release" then
    if st.dragging and st.drag_action == "seek" then
      for _, x in ipairs(st.hits or {}) do
        if x.row == row and x.action == "seek" then
          seek_from_hit(buf, st, x, col)
          break
        end
      end
    end
    st.dragging = false
    st.drag_action = nil
  end
end

play_path_in_buf = function(buf, path, opts)
  opts = opts or {}
  path = vim.fn.fnamemodify(path, ":p")
  local siblings, index = list_siblings(path)
  local st = state_by_buf[buf]
  if not st then
    st = {
      path = path,
      siblings = siblings,
      index = index,
      hits = {},
      segs = {},
      dragging = false,
      drag_action = nil,
      phase = 0,
    }
    state_by_buf[buf] = st
  else
    st.path = path
    st.siblings = siblings
    st.index = index
  end

  pcall(vim.api.nvim_buf_set_name, buf, path)
  vim.b[buf].music_player = true
  active_buf = buf
  ensure_hl()
  render(buf)
  start_poll()

  if opts.auto_play ~= false and config.auto_play then
    local ok, err = player.play(path, 0)
    if not ok then
      vim.notify("music: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  render(buf)
end

---True if buffer is shown in any window.
local function is_buf_displayed(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

---Any music player buffer currently visible?
local function any_music_displayed()
  for buf, _ in pairs(state_by_buf) do
    if is_buf_displayed(buf) then
      return true
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].music_player and is_buf_displayed(buf) then
      return true
    end
  end
  return false
end

---When player buffer is not shown in any window, stop audio.
local function silence_if_hidden()
  if any_music_displayed() then
    return
  end
  local st = player.get_state()
  if player.is_active() or (st.job_id and st.job_id > 0) then
    player.stop()
  end
  stop_poll()
end

local function on_ended()
  local buf = active_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- buffer 已不在窗口里：不要自动下一首（避免后台又开进程）
  if not is_buf_displayed(buf) then
    return
  end
  local st = state_by_buf[buf]
  if not st then
    return
  end
  local pst = player.get_state()
  if pst.loop then
    player.play(st.path, 0)
    render(buf)
    return
  end
  if config.auto_next and #st.siblings > 1 then
    goto_sibling(buf, 1)
  else
    render(buf)
  end
end

local function bind(buf)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  local function with_st(fn)
    return function()
      local st = state_by_buf[buf]
      if st then
        fn(st)
      end
    end
  end

  map("q", function()
    M.close(buf)
  end, "music: close")
  map("<Esc>", function()
    M.close(buf)
  end, "music: close")
  map("<Space>", with_st(function(st)
    do_toggle(buf, st)
  end), "music: toggle")
  map("p", with_st(function(st)
    do_toggle(buf, st)
  end), "music: toggle")
  map("n", function()
    goto_sibling(buf, 1)
  end, "music: next")
  map("N", function()
    goto_sibling(buf, -1)
  end, "music: prev")
  map(">", function()
    goto_sibling(buf, 1)
  end, "music: next")
  map("<", function()
    goto_sibling(buf, -1)
  end, "music: prev")
  map("l", function()
    player.seek(5)
    render(buf)
  end, "music: +5s")
  map("h", function()
    player.seek(-5)
    render(buf)
  end, "music: -5s")
  map("<Right>", function()
    player.seek(5)
    render(buf)
  end, "music: +5s")
  map("<Left>", function()
    player.seek(-5)
    render(buf)
  end, "music: -5s")
  map("+", function()
    player.volume_up(5)
    render(buf)
  end, "music: vol+")
  map("=", function()
    player.volume_up(5)
    render(buf)
  end, "music: vol+")
  map("-", function()
    player.volume_down(5)
    render(buf)
  end, "music: vol-")
  map("r", with_st(function(st)
    player.play(st.path, 0)
    render(buf)
  end), "music: restart")
  map("L", function()
    local on = player.set_loop()
    vim.notify("music: 单曲循环 " .. (on and "开" or "关"), vim.log.levels.INFO)
    render(buf)
  end, "music: loop")

  map("<LeftMouse>", function()
    mouse_handle(buf, "down")
  end, "music: click")
  map("<LeftDrag>", function()
    mouse_handle(buf, "drag")
  end, "music: drag")
  map("<LeftRelease>", function()
    mouse_handle(buf, "release")
  end, "music: release")
end

local function apply_buf_opts(buf)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false
  bo.modifiable = false
  bo.readonly = false
  bo.filetype = "music"
  bo.textwidth = 0
  vim.b[buf].music_player = true

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local wo = vim.wo[win]
      wo.number = false
      wo.relativenumber = false
      wo.signcolumn = "no"
      wo.cursorline = false
      wo.wrap = false
      wo.list = false
      wo.foldenable = false
      wo.winhl = "Normal:MusicNormal,EndOfBuffer:MusicNormal,SignColumn:MusicNormal"
      if vim.o.mouse == "" then
        vim.o.mouse = "a"
      end
    end
  end
end

---@param path string
---@param opts? { win?: integer, replace_buf?: integer, auto_play?: boolean }
---@return integer|nil buf
function M.open(path, opts)
  M.ensure_setup()
  opts = opts or {}
  path = vim.fn.expand(path or "")
  path = vim.fn.fnamemodify(path, ":p")
  if path == "" or vim.fn.filereadable(path) ~= 1 then
    vim.notify("music: 文件不存在: " .. tostring(path), vim.log.levels.ERROR)
    return nil
  end
  if not is_audio(path) then
    vim.notify("music: 不是支持的音频: " .. path, vim.log.levels.WARN)
  end

  local win = opts.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  local buf = opts.replace_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(true, true)
  end

  vim.api.nvim_win_set_buf(win, buf)
  ensure_hl()
  apply_buf_opts(buf)
  bind(buf)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      state_by_buf[buf] = nil
      if active_buf == buf then
        active_buf = nil
        stop_poll()
        player.stop()
      end
      -- no music buffer left visible → ensure silence
      vim.schedule(silence_if_hidden)
    end,
  })

  -- leave window / hide buffer → stop sound while not displayed
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufHidden" }, {
    buffer = buf,
    callback = function()
      vim.schedule(silence_if_hidden)
    end,
  })

  vim.api.nvim_create_autocmd({ "VimResized", "ColorScheme" }, {
    buffer = buf,
    callback = function()
      hl_ready = false
      ensure_hl()
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end,
  })

  play_path_in_buf(buf, path, { auto_play = opts.auto_play })
  return buf
end

function M.close(buf)
  buf = buf or active_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    player.stop()
    return
  end
  player.stop()
  state_by_buf[buf] = nil
  if active_buf == buf then
    active_buf = nil
    stop_poll()
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

function M.toggle()
  M.ensure_setup()
  if active_buf and state_by_buf[active_buf] then
    do_toggle(active_buf, state_by_buf[active_buf])
  else
    player.toggle()
  end
end

function M.next()
  if active_buf and state_by_buf[active_buf] then
    goto_sibling(active_buf, 1)
  end
end

function M.prev()
  if active_buf and state_by_buf[active_buf] then
    goto_sibling(active_buf, -1)
  end
end

function M.stop()
  player.stop()
  if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
    render(active_buf)
  end
end

local function setup_auto_open()
  local pat = {}
  for _, ext in ipairs(config.extensions) do
    table.insert(pat, "*." .. ext)
    table.insert(pat, "*." .. ext:upper())
  end

  local aug = vim.api.nvim_create_augroup("MusicAutoOpen", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = pat,
    callback = function(ev)
      local path = ev.file
      if path == nil or path == "" then
        path = vim.api.nvim_buf_get_name(ev.buf)
      end
      vim.bo[ev.buf].buftype = "nofile"
      vim.bo[ev.buf].bufhidden = "wipe"
      vim.bo[ev.buf].swapfile = false
      vim.b[ev.buf].music_placeholder = true
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then
          return
        end
        M.open(path, { replace_buf = ev.buf, win = vim.api.nvim_get_current_win() })
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = aug,
    pattern = pat,
    callback = function(ev)
      if vim.b[ev.buf].music_player or vim.b[ev.buf].music_placeholder then
        return
      end
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if not is_audio(path) then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) or vim.b[ev.buf].music_player then
          return
        end
        M.open(path, { replace_buf = ev.buf, win = vim.api.nvim_get_current_win() })
      end)
    end,
  })
end

---@param user? MusicConfig
function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  rebuild_ext()
  player.setup({
    backend = config.backend,
    volume = config.volume,
    loop = config.loop,
    python = config.python,
  })
  player.on_ended(on_ended)
  player.on_status(function()
    if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
      render(active_buf)
    end
  end)

  vim.api.nvim_create_user_command("Music", function(opts)
    local path = opts.args
    if path == nil or path == "" then
      path = vim.fn.expand("%:p")
    end
    if path == nil or path == "" then
      vim.notify("music: 请指定音频文件", vim.log.levels.ERROR)
      return
    end
    M.open(path)
  end, {
    nargs = "?",
    complete = "file",
    desc = "在 buffer 中打开音频播放器",
  })

  if config.auto_open then
    setup_auto_open()
  else
    vim.api.nvim_create_augroup("MusicAutoOpen", { clear = true })
  end

  -- window closed / tab closed → recheck visibility
  vim.api.nvim_create_autocmd({ "WinClosed", "TabClosed", "BufWinLeave" }, {
    group = vim.api.nvim_create_augroup("MusicVisibility", { clear = true }),
    callback = function()
      vim.schedule(silence_if_hidden)
    end,
  })

  -- leave Neovim: quit python daemon
  local leave_aug = vim.api.nvim_create_augroup("MusicLeave", { clear = true })
  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimLeave" }, {
    group = leave_aug,
    callback = function()
      stop_poll()
      player.shutdown()
    end,
  })

  ensure_hl()
  vim.g.music_setup_done = true
end

function M.ensure_setup()
  if not vim.g.music_setup_done then
    M.setup()
  end
end

function M.config()
  return config
end

return M
