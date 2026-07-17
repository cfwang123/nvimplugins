---@mod videobuf Embedded video player
--- 布局：上方 terminal 只画视频；下方普通 buffer 控制条（对齐 music，可点、不滚动）。
local M = {}

local player = require("videobuf.player")
local lyrics = require("videobuf.lyrics")
local i18n = require("videobuf.i18n")

---@class VideobufConfig
---@field auto_open boolean
---@field auto_play boolean
---@field fps number
---@field fps_min number
---@field fps_max number
---@field fps_step number
---@field volume number
---@field loop boolean
---@field scale "fit"|"fill"
---@field mode "half"|"block"
---@field show_lyrics boolean
---@field hide_empty_lyrics boolean
---@field control_height number
---@field seek_step number
---@field seek_step_large number
---@field python string
---@field filetypes string[]
---@field resize_debounce_ms number
---@field lang "zh"|"en"|"auto"|nil 界面语言，默认 auto 跟随系统

local default_config = {
  auto_open = true,
  auto_play = true,
  fps = 10,
  fps_min = 1,
  fps_max = 30,
  fps_step = 1,
  volume = 30,
  loop = false,
  scale = "fill", -- 拉伸铺满视频窗
  mode = "half", -- solid | half | block（1 / 1/2 / 1/4 色块）
  show_lyrics = true,
  hide_empty_lyrics = false,
  control_height = 6, -- 字幕+状态+进度+主按钮+次按钮+info
  seek_step = 5,
  seek_step_large = 30,
  python = "python",
  filetypes = { "mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "ts", "mpeg", "mpg" },
  resize_debounce_ms = 150,
  lang = "auto", -- "zh" | "en" | "auto"
}

local config = vim.deepcopy(default_config)
local EXT = {}
local ns = vim.api.nvim_create_namespace("videobuf_ui")
local hl_ready = false

---@type integer|nil
local video_buf = nil
---@type integer|nil
local video_win = nil
---@type integer|nil
local ctrl_buf = nil
---@type integer|nil
local ctrl_win = nil
---@type integer|nil
local term_chan = nil
---@type integer
local muted_vol = 30
---@type boolean
local is_muted = false
---@type uv.uv_timer_t|nil
local resize_timer = nil
---@type uv.uv_timer_t|nil
local ui_timer = nil
---@type boolean
local dragging = false
---@type string
local last_info = "" -- decoder / error 显示在控制区
---@type { action: string, row: integer, d0: integer, d1: integer, bar_d0?: integer, bar_w?: integer }[]
local click_hits = {}
---@type integer
local frame_count = 0
---@type boolean
local closing = false
---@type integer|nil
local pair_aug = nil
---@type boolean
local video_click_installed = false

local SIDEBAR_FILETYPES = {
  nerdtree = true,
  NerdTree = true,
  NvimTree = true,
  ["neo-tree"] = true,
  CHADTree = true,
  aerial = true,
  ultratree = true,
  Outline = true,
}

local function rebuild_ext()
  EXT = {}
  for _, e in ipairs(config.filetypes) do
    EXT[e:lower()] = true
  end
end

local function is_video(path)
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

local function ensure_hl()
  if hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  -- 白底 + 黑灰字（简洁，不花哨）
  local bg = "#ffffff"
  vim.api.nvim_set_hl(0, "VideobufNormal", { fg = "#222222", bg = bg })
  vim.api.nvim_set_hl(0, "VideobufMeta", { fg = "#111111", bg = bg, bold = true })
  vim.api.nvim_set_hl(0, "VideobufBtn", { fg = "#111111", bg = "#e8e8e8", bold = true })
  vim.api.nvim_set_hl(0, "VideobufBtnOff", { fg = "#666666", bg = "#f0f0f0" })
  vim.api.nvim_set_hl(0, "VideobufBar", { fg = "#888888", bg = "#f5f5f5" })
  vim.api.nvim_set_hl(0, "VideobufBarFill", { fg = "#111111", bg = "#cccccc", bold = true })
  vim.api.nvim_set_hl(0, "VideobufWarn", { fg = "#555555", bg = bg, italic = true })
  vim.api.nvim_set_hl(0, "VideobufLyric", { fg = "#333333", bg = bg })
  vim.api.nvim_set_hl(0, "VideobufWin", { bg = bg })
  hl_ready = true
end

local function is_sidebar_win(win)
  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local b = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[b].filetype or ""
  if SIDEBAR_FILETYPES[ft] then
    return true
  end
  local name = vim.api.nvim_buf_get_name(b)
  if name:match("NERD_tree_") or name:match("NvimTree_") or name:match("neo%-tree") then
    return true
  end
  return false
end

local function is_usable_content_win(win)
  return win and win ~= 0 and vim.api.nvim_win_is_valid(win) and not is_sidebar_win(win)
end

local function find_content_win(preferred)
  if is_usable_content_win(preferred) then
    return preferred
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if is_usable_content_win(prev) then
    return prev
  end
  local cur = vim.api.nvim_get_current_win()
  if is_usable_content_win(cur) then
    return cur
  end
  local best, best_area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_usable_content_win(win) then
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if area > best_area then
        best_area = area
        best = win
      end
    end
  end
  return best or cur
end

local function lock_view(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(function()
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({
        lnum = 1,
        col = 0,
        topline = 1,
        leftcol = 0,
        curswant = 0,
      })
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    end)
  end)
end

local function map_no_scroll(buf, keep)
  keep = keep or {}
  -- 滚轮留给音量，不在此屏蔽
  local nop_keys = {
    "j",
    "k",
    "<C-d>",
    "<C-u>",
    "<C-f>",
    "<C-b>",
    "<C-e>",
    "<C-y>",
    "gg",
    "G",
    "0",
    "$",
    "w",
    "b",
    "e",
    "zt",
    "zz",
    "zb",
    "M",
    "<CR>",
    "<BS>",
  }
  for _, mode in ipairs({ "n", "t", "x", "v", "s" }) do
    for _, lhs in ipairs(nop_keys) do
      if not keep[lhs] then
        pcall(vim.keymap.set, mode, lhs, "<Nop>", {
          buffer = buf,
          silent = true,
          nowait = true,
          desc = "videobuf: no scroll",
        })
      end
    end
  end
  for _, k in ipairs({ "v", "V", "<C-v>", "gv" }) do
    for _, mode in ipairs({ "n", "x", "v", "s", "t" }) do
      pcall(vim.keymap.set, mode, k, "<Esc>", { buffer = buf, silent = true, nowait = true })
    end
  end
  for _, k in ipairs({ "i", "a", "I", "A", "o", "O", "R", "c", "C" }) do
    pcall(vim.keymap.set, "n", k, "<Nop>", { buffer = buf, silent = true })
  end
end

local function attach_lock(buf, win)
  local aug = vim.api.nvim_create_augroup("VideobufLock_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "TextChangedT" }, {
    group = aug,
    buffer = buf,
    callback = function()
      lock_view(win, buf)
    end,
  })
  vim.api.nvim_create_autocmd("TermEnter", {
    group = aug,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        pcall(vim.cmd, "stopinsert")
        lock_view(win, buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = aug,
    buffer = buf,
    callback = function()
      local mode = vim.fn.mode()
      if mode == "v" or mode == "V" or mode == "\22" then
        vim.schedule(function()
          local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
          pcall(vim.api.nvim_feedkeys, esc, "n", false)
        end)
      end
    end,
  })
end

---Line builder for control buffer
local function new_line()
  local self = {
    parts = {},
    segs = {},
    hits = {},
    bytes = 0,
    disp = 0,
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
    table.insert(self.segs, { hl = hl or "VideobufNormal", b0 = b0, b1 = b1 })
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
  function self:gap(n)
    return self:add(string.rep(" ", n or 1), "VideobufNormal", nil)
  end
  function self:btn(label, action, on)
    return self:add(label, on and "VideobufBtn" or "VideobufBtnOff", action)
  end
  function self:text()
    return table.concat(self.parts)
  end
  return self
end

local function pad_line(text, cols)
  cols = math.max(8, cols)
  local w = vim.fn.strwidth(text)
  if w < cols then
    return text .. string.rep(" ", cols - w)
  end
  while vim.fn.strwidth(text) > cols and #text > 0 do
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
  end
  return text
end

local function control_height()
  -- status + bar + main btns + sub btns + info
  local h = 5
  if config.show_lyrics and (not config.hide_empty_lyrics or lyrics.has()) then
    h = h + 1
  end
  return math.max(5, config.control_height or h)
end

local function video_cell_size()
  local cols, rows = 80, 24
  if video_win and vim.api.nvim_win_is_valid(video_win) then
    cols = math.max(8, vim.api.nvim_win_get_width(video_win))
    rows = math.max(2, vim.api.nvim_win_get_height(video_win))
  end
  return cols, rows
end

---@type string|nil
local pending_video_ansi = nil
local paint_video_scheduled = false

local function paint_video_now(ansi)
  if not term_chan or term_chan <= 0 then
    return
  end
  if not video_buf or not vim.api.nvim_buf_is_valid(video_buf) then
    return
  end
  if not ansi or ansi == "" then
    return
  end
  -- 仅视频区：回原点覆盖（不每次 2J，减少闪烁/开销）
  local payload = "\27[H\27[0m" .. ansi
  pcall(vim.api.nvim_chan_send, term_chan, payload)
end

--- 合并积压帧：只画最新一帧，避免 schedule 排队导致「几秒一帧」
local function paint_video(ansi)
  pending_video_ansi = ansi
  if paint_video_scheduled then
    return
  end
  paint_video_scheduled = true
  vim.schedule(function()
    paint_video_scheduled = false
    local a = pending_video_ansi
    pending_video_ansi = nil
    if a then
      paint_video_now(a)
    end
  end)
end

local function paint_controls()
  if not ctrl_buf or not vim.api.nvim_buf_is_valid(ctrl_buf) then
    return
  end
  ensure_hl()
  local st = player.get_state()
  local cols = 80
  if ctrl_win and vim.api.nvim_win_is_valid(ctrl_win) then
    cols = math.max(20, vim.api.nvim_win_get_width(ctrl_win))
  end

  local lines = {}
  local segs_by_row = {}
  click_hits = {}

  local function commit(line_obj)
    local row = #lines + 1
    local text = pad_line(line_obj:text(), cols)
    table.insert(lines, text)
    segs_by_row[row] = line_obj.segs
    for _, h in ipairs(line_obj.hits) do
      table.insert(click_hits, {
        action = h.action,
        row = row,
        d0 = h.d0,
        d1 = h.d1,
        bar_d0 = h.bar_d0,
        bar_w = h.bar_w,
      })
    end
  end

  -- 字幕
  if config.show_lyrics and (not config.hide_empty_lyrics or lyrics.has()) then
    lyrics.sync(st.position or 0)
    local L = new_line()
    L:add(lyrics.current_text(cols), "VideobufLyric", nil)
    commit(L)
  end

  local t = i18n.t

  -- 状态
  local S = new_line()
  local title = st.title or "videobuf"
  local playing = st.status == "playing"
  local status_txt
  if playing then
    status_txt = t("status_play")
  elseif st.status == "paused" then
    status_txt = t("status_pause")
  else
    status_txt = t("status_stop")
  end
  S:add(" " .. title .. " ", "VideobufMeta", nil)
  S:add(fmt_time(st.position) .. "/" .. fmt_time(st.duration), "VideobufNormal", nil)
  S:gap(2)
  S:add("♪" .. tostring(st.volume or 0) .. "%", "VideobufNormal", nil)
  S:gap(2)
  S:add("fps:" .. tostring(math.floor(st.fps or config.fps)), "VideobufNormal", nil)
  S:gap(2)
  S:add(status_txt, "VideobufMeta", nil)
  S:gap(2)
  S:add(t("frames") .. ":" .. tostring(frame_count), "VideobufNormal", nil)
  commit(S)

  -- 进度条
  local B = new_line()
  B:gap(1)
  local bar_w = math.max(10, cols - 4)
  local ratio = 0
  if st.duration and st.duration > 0 then
    ratio = math.max(0, math.min(1, (st.position or 0) / st.duration))
  end
  local filled = math.floor(bar_w * ratio + 0.5)
  local bar_d0 = B.disp + 1
  B:add("[", "VideobufBar", "seek", { bar_d0 = bar_d0 + 1, bar_w = bar_w })
  if filled > 0 then
    B:add(string.rep("=", math.max(0, filled - 1)) .. "●", "VideobufBarFill", "seek", {
      bar_d0 = bar_d0 + 1,
      bar_w = bar_w,
    })
  end
  B:add(string.rep("-", math.max(0, bar_w - filled)), "VideobufBar", "seek", {
    bar_d0 = bar_d0 + 1,
    bar_w = bar_w,
  })
  B:add("]", "VideobufBar", "seek", { bar_d0 = bar_d0 + 1, bar_w = bar_w })
  -- 整段可点
  for _, h in ipairs(B.hits) do
    h.bar_d0 = bar_d0 + 1
    h.bar_w = bar_w
  end
  commit(B)

  -- 主按钮行：常用 + 语言切换（靠前，避免被窗口裁切）
  local A = new_line()
  A:gap(1)
  A:btn(playing and t("pause") or t("play"), "toggle", true)
  A:gap(1)
  A:btn(t("stop"), "stop", true)
  A:gap(1)
  A:btn(t("replay"), "replay", true)
  A:gap(1)
  A:btn(st.loop and t("loop_on") or t("loop_off"), "loop", st.loop)
  A:gap(1)
  A:btn(is_muted and t("unmute") or t("mute"), "mute", not is_muted)
  A:gap(1)
  A:btn(t("lang"), "lang", true)
  A:gap(1)
  A:btn(t("close"), "close", true)
  commit(A)

  -- 次按钮行：字幕 / fps / 模式
  local A2 = new_line()
  A2:gap(1)
  A2:btn(t("lyrics"), "lyrics", true)
  A2:gap(1)
  A2:btn(t("fps_down"), "fps_down", true)
  A2:btn(t("fps_up"), "fps_up", true)
  A2:gap(1)
  A2:btn(t("mode_solid"), "mode_solid", true)
  A2:btn(t("mode_half"), "mode_half", true)
  A2:btn(t("mode_block"), "mode_block", true)
  commit(A2)

  -- 信息行：解码器 / 错误 / IPC（始终可见）
  local I = new_line()
  local backend = st.backend or "?"
  local info = last_info
  if info == "" then
    info = string.format("decoder:%s  %s", tostring(backend), t("waiting_frame"))
  end
  -- 附带 ipc 计数，便于排障
  local d = player.diag and player.diag() or {}
  info = string.format(
    "%s | ipc L:%s F:%s | %s",
    info,
    tostring(d.lines_in or 0),
    tostring(d.frames_in or 0),
    i18n.get():upper()
  )
  I:add(" " .. info, "VideobufWarn", nil)
  commit(I)

  -- 行未覆盖区域也铺白底
  if ctrl_win and vim.api.nvim_win_is_valid(ctrl_win) then
    pcall(function()
      vim.wo[ctrl_win].winhl =
        "Normal:VideobufWin,NormalNC:VideobufWin,EndOfBuffer:VideobufWin,StatusLine:VideobufNormal,StatusLineNC:VideobufNormal"
    end)
  end

  local bo = vim.bo[ctrl_buf]
  bo.modifiable = true
  bo.readonly = false
  vim.api.nvim_buf_set_lines(ctrl_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(ctrl_buf, ns, 0, -1)
  for row = 1, #lines do
    -- 整行白底
    pcall(vim.api.nvim_buf_add_highlight, ctrl_buf, ns, "VideobufNormal", row - 1, 0, -1)
    local segs = segs_by_row[row]
    if segs then
      for _, seg in ipairs(segs) do
        pcall(vim.api.nvim_buf_add_highlight, ctrl_buf, ns, seg.hl, row - 1, seg.b0, seg.b1)
      end
    end
  end
  bo.modifiable = false
  bo.modified = false
  if ctrl_win and vim.api.nvim_win_is_valid(ctrl_win) then
    lock_view(ctrl_win, ctrl_buf)
  end
end

local function run_action(action, hit, col)
  if action == "toggle" then
    player.toggle()
  elseif action == "stop" then
    player.stop()
  elseif action == "replay" then
    player.seek_abs(0)
    player.play()
  elseif action == "loop" then
    player.set_loop()
  elseif action == "lyrics" then
    lyrics.toggle_panel()
  elseif action == "fps_down" then
    local st = player.get_state()
    local fps = (st.fps or config.fps) - (config.fps_step or 1)
    player.set_fps(math.max(config.fps_min, fps))
  elseif action == "fps_up" then
    local st = player.get_state()
    local fps = (st.fps or config.fps) + (config.fps_step or 1)
    player.set_fps(math.min(config.fps_max, fps))
  elseif action == "mode_solid" then
    player.resize({ mode = "solid" })
    last_info = i18n.t("mode_solid_info")
  elseif action == "mode_half" then
    player.resize({ mode = "half" })
    last_info = i18n.t("mode_half_info")
  elseif action == "mode_block" then
    player.resize({ mode = "block" })
    last_info = i18n.t("mode_block_info")
  elseif action == "mute" then
    local st = player.get_state()
    if is_muted then
      is_muted = false
      player.set_volume(muted_vol)
    else
      muted_vol = st.volume or 30
      is_muted = true
      player.set_volume(0)
    end
  elseif action == "lang" then
    i18n.toggle()
    last_info = i18n.t("lang_switched")
  elseif action == "close" then
    M.close()
    return
  elseif action == "seek" then
    local st = player.get_state()
    if not st.duration or st.duration <= 0 or not hit then
      return
    end
    local bar_d0 = hit.bar_d0 or hit.d0
    local bar_w = hit.bar_w or 1
    local rel = (col or bar_d0) - bar_d0
    if rel < 0 then
      rel = 0
    end
    if rel > bar_w then
      rel = bar_w
    end
    player.seek_abs((rel / math.max(1, bar_w)) * st.duration)
  end
  paint_controls()
end

local function hit_at(row, col)
  for _, h in ipairs(click_hits) do
    if h.row == row and col >= h.d0 and col <= h.d1 then
      return h
    end
  end
  return nil
end

local function mouse_pos(buf)
  local mouse = vim.fn.getmousepos()
  local win = vim.fn.bufwinid(buf)
  if win == -1 or mouse.winid == 0 or mouse.winid ~= win then
    return nil, nil
  end
  local info = vim.fn.getwininfo(win)[1] or {}
  local textoff = info.textoff or 0
  local leftcol = info.leftcol or 0
  local wpos = vim.api.nvim_win_get_position(win)
  local vcol = mouse.screencol - wpos[2] - textoff + leftcol
  if vcol < 1 then
    vcol = mouse.wincol - textoff + leftcol
  end
  if vcol < 1 then
    vcol = mouse.column
  end
  return mouse.line, vcol
end

local function map_volume_wheel(buf)
  local function vol_up()
    is_muted = false
    player.set_volume((player.get_state().volume or 30) + 5)
    paint_controls()
  end
  local function vol_down()
    player.set_volume((player.get_state().volume or 30) - 5)
    paint_controls()
  end
  for _, mode in ipairs({ "n", "t", "v", "x" }) do
    pcall(vim.keymap.set, mode, "<ScrollWheelUp>", vol_up, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "videobuf: vol+",
    })
    pcall(vim.keymap.set, mode, "<ScrollWheelDown>", vol_down, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "videobuf: vol-",
    })
    pcall(vim.keymap.set, mode, "<S-ScrollWheelUp>", vol_up, { buffer = buf, silent = true, nowait = true })
    pcall(vim.keymap.set, mode, "<S-ScrollWheelDown>", vol_down, { buffer = buf, silent = true, nowait = true })
  end
end

--- 点击是否落在视频窗（getmousepos 在按键处理时仍指向点击窗）
local function is_click_on_video()
  if not video_win or not vim.api.nvim_win_is_valid(video_win) then
    return false
  end
  local mp = vim.fn.getmousepos()
  return mp and mp.winid == video_win
end

local function toggle_from_video_click()
  if closing then
    return
  end
  run_action("toggle")
  vim.schedule(function()
    pcall(vim.cmd, "stopinsert")
    if ctrl_win and vim.api.nvim_win_is_valid(ctrl_win) then
      pcall(vim.api.nvim_set_current_win, ctrl_win)
    end
  end)
end

--- 全局鼠标：terminal 本地 map 常失效，用全局兜底
local function install_video_click_global()
  if video_click_installed then
    return
  end
  video_click_installed = true
  local modes = { "n", "i", "v", "x", "s", "t", "c" }
  vim.keymap.set(modes, "<LeftMouse>", function()
    if is_click_on_video() then
      toggle_from_video_click()
      return
    end
    local key = vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true)
    vim.api.nvim_feedkeys(key, "ni", false)
  end, { noremap = true, silent = true, desc = "videobuf: global left click" })
end

local function uninstall_video_click_global()
  if not video_click_installed then
    return
  end
  video_click_installed = false
  pcall(vim.keymap.del, { "n", "i", "v", "x", "s", "t", "c" }, "<LeftMouse>")
end

local function map_ctrl_keys(buf)
  local function map(lhs, fn, desc)
    pcall(vim.keymap.set, "n", lhs, fn, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "videobuf: " .. desc,
    })
  end
  map("q", function()
    M.close()
  end, "close")
  map("<Esc>", function()
    M.close()
  end, "close")
  map("<Space>", function()
    run_action("toggle")
  end, "toggle")
  map("x", function()
    run_action("stop")
  end, "stop")
  map("r", function()
    run_action("replay")
  end, "replay")
  map("L", function()
    run_action("loop")
  end, "loop")
  map("m", function()
    run_action("mute")
  end, "mute")
  map("g", function()
    run_action("lyrics")
  end, "lyrics")
  map("h", function()
    player.seek(-(config.seek_step or 5))
    paint_controls()
  end, "seek-")
  map("l", function()
    player.seek(config.seek_step or 5)
    paint_controls()
  end, "seek+")
  map("<Left>", function()
    player.seek(-(config.seek_step or 5))
    paint_controls()
  end, "seek-")
  map("<Right>", function()
    player.seek(config.seek_step or 5)
    paint_controls()
  end, "seek+")
  map("H", function()
    player.seek(-(config.seek_step_large or 30))
    paint_controls()
  end, "seek--")
  map("<S-Left>", function()
    player.seek(-(config.seek_step_large or 30))
    paint_controls()
  end, "seek--")
  map("<S-Right>", function()
    player.seek(config.seek_step_large or 30)
    paint_controls()
  end, "seek++")
  map("+", function()
    is_muted = false
    player.set_volume((player.get_state().volume or 30) + 5)
    paint_controls()
  end, "vol+")
  map("-", function()
    player.set_volume((player.get_state().volume or 30) - 5)
    paint_controls()
  end, "vol-")
  map("<Up>", function()
    is_muted = false
    player.set_volume((player.get_state().volume or 30) + 5)
    paint_controls()
  end, "vol+")
  map("<Down>", function()
    player.set_volume((player.get_state().volume or 30) - 5)
    paint_controls()
  end, "vol-")
  map("[", function()
    run_action("fps_down")
  end, "fps-")
  map("]", function()
    run_action("fps_up")
  end, "fps+")
  map("1", function()
    player.resize({ mode = "solid" })
    last_info = i18n.t("mode_solid_info")
    paint_controls()
  end, "mode-solid")
  map("2", function()
    player.resize({ mode = "half" })
    last_info = i18n.t("mode_half_info")
    paint_controls()
  end, "mode-half")
  map("3", function()
    player.resize({ mode = "block" })
    last_info = i18n.t("mode_block_info")
    paint_controls()
  end, "mode-block")
  map("s", function()
    local st = player.get_state()
    local scale = (st.scale == "fill") and "fit" or "fill"
    player.resize({ scale = scale })
    last_info = scale == "fill" and i18n.t("scale_fill") or i18n.t("scale_fit")
    paint_controls()
  end, "scale")
  map("u", function()
    run_action("lang")
  end, "lang")
  map("<PageUp>", function()
    M.prev()
  end, "prev")
  map("<PageDown>", function()
    M.next()
  end, "next")

  map_no_scroll(buf, {
    h = true,
    l = true,
    H = true,
    L = true,
    ["+"] = true,
    ["-"] = true,
    s = true,
    u = true,
    ["1"] = true,
    ["2"] = true,
    ["3"] = true,
  })
  map_volume_wheel(buf)

  pcall(vim.keymap.set, "n", "<LeftMouse>", function()
    -- 若点在视频窗（焦点却在控制条时），切换播放
    if is_click_on_video() then
      toggle_from_video_click()
      return
    end
    local row, col = mouse_pos(buf)
    if not row then
      return
    end
    local hit = hit_at(row, col)
    if not hit then
      dragging = false
      return
    end
    if hit.action == "seek" then
      dragging = true
      run_action("seek", hit, col)
    else
      dragging = false
      run_action(hit.action, hit, col)
    end
  end, { buffer = buf, silent = true, nowait = true })

  pcall(vim.keymap.set, "n", "<LeftDrag>", function()
    if not dragging then
      return
    end
    local row, col = mouse_pos(buf)
    if not row then
      return
    end
    local hit = hit_at(row, col)
    if hit and hit.action == "seek" then
      run_action("seek", hit, col)
    end
  end, { buffer = buf, silent = true, nowait = true })

  pcall(vim.keymap.set, "n", "<LeftRelease>", function()
    dragging = false
  end, { buffer = buf, silent = true, nowait = true })
end

local function map_video_keys(buf)
  -- 视频窗也响应主要快捷键
  local function map(lhs, fn)
    for _, mode in ipairs({ "n", "t" }) do
      pcall(vim.keymap.set, mode, lhs, fn, { buffer = buf, silent = true, nowait = true })
    end
  end
  map("q", function()
    M.close()
  end)
  map("<Space>", function()
    run_action("toggle")
  end)
  map("x", function()
    run_action("stop")
  end)
  map_no_scroll(buf, {})
  map_volume_wheel(buf)
  -- buffer 级点击（terminal 下可能无效，全局 map 兜底）
  for _, mode in ipairs({ "n", "t", "i", "v" }) do
    pcall(vim.keymap.set, mode, "<LeftMouse>", function()
      toggle_from_video_click()
    end, { buffer = buf, silent = true, nowait = true, desc = "videobuf: click toggle" })
  end
  install_video_click_global()
end

local function stop_timers()
  if ui_timer then
    pcall(function()
      ui_timer:stop()
      ui_timer:close()
    end)
    ui_timer = nil
  end
  if resize_timer then
    pcall(function()
      resize_timer:stop()
      resize_timer:close()
    end)
    resize_timer = nil
  end
end

local function start_ui_timer()
  stop_timers()
  ui_timer = vim.uv.new_timer()
  if not ui_timer then
    return
  end
  -- 控制条 5fps 足够，别和视频帧抢主线程
  ui_timer:start(200, 200, function()
    vim.schedule(function()
      if not ctrl_buf or not vim.api.nvim_buf_is_valid(ctrl_buf) then
        return
      end
      local st = player.get_state()
      lyrics.sync(st.position or 0)
      -- 播放中少刷新控制条，降低卡顿
      if st.status ~= "playing" or (frame_count % 5 == 0) then
        paint_controls()
      end
    end)
  end)
end

local function read_frame_data(frame)
  if type(frame.data) == "string" and frame.data ~= "" then
    return frame.data
  end
  if type(frame.b64) == "string" and frame.b64 ~= "" then
    if vim.base64 and vim.base64.decode then
      local ok, raw = pcall(vim.base64.decode, frame.b64)
      if ok and type(raw) == "string" and #raw > 0 then
        return raw:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\r\n")
      end
    end
  end
  if type(frame.file) == "string" and frame.file ~= "" then
    local f = io.open(frame.file, "rb")
    if f then
      local raw = f:read("*a")
      f:close()
      if raw and #raw > 0 then
        return raw:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\r\n")
      end
    end
  end
  return nil
end

local function wire_player_callbacks()
  player.on_frame(function(frame)
    local data = read_frame_data(frame)
    if data then
      frame_count = frame_count + 1
      if frame_count == 1 or frame_count % 15 == 0 then
        last_info = string.format(
          "decoder:%s  frames=%d  pos=%.1fs",
          tostring(player.get_state().backend or "?"),
          frame_count,
          frame.position or 0
        )
      end
      paint_video(data)
    end
  end)
  player.on_status(function()
    local st = player.get_state()
    if st.backend and st.backend ~= "" and st.backend ~= "none" then
      if frame_count == 0 then
        last_info = string.format("decoder:%s  等待画面…", tostring(st.backend))
      end
    end
    if st.status ~= "playing" then
      paint_controls()
    end
  end)
  player.on_ended(function()
    last_info = (last_info ~= "" and last_info or "ended") .. "  [结束]"
    paint_controls()
  end)
end

local function list_siblings(path)
  path = vim.fn.fnamemodify(path, ":p")
  local dir = vim.fn.fnamemodify(path, ":h")
  local files = vim.fn.glob(dir .. "/*", false, true)
  local vids = {}
  for _, f in ipairs(files) do
    if vim.fn.isdirectory(f) == 0 and is_video(f) then
      table.insert(vids, vim.fn.fnamemodify(f, ":p"))
    end
  end
  table.sort(vids, function(a, b)
    return vim.fn.fnamemodify(a, ":t"):lower() < vim.fn.fnamemodify(b, ":t"):lower()
  end)
  local idx = 1
  local norm = path:gsub("\\", "/"):lower()
  for i, f in ipairs(vids) do
    if f:gsub("\\", "/"):lower() == norm then
      idx = i
      break
    end
  end
  if #vids == 0 then
    vids = { path }
    idx = 1
  end
  return vids, idx
end

local function pause_music_if_any()
  pcall(function()
    local ok, mplayer = pcall(require, "music.player")
    if ok and mplayer and mplayer.pause then
      mplayer.pause()
    end
  end)
end

local function destroy_ui()
  stop_timers()
  uninstall_video_click_global()
  if pair_aug then
    pcall(vim.api.nvim_del_augroup_by_id, pair_aug)
    pair_aug = nil
  end
  term_chan = nil
  local vb, cb = video_buf, ctrl_buf
  local vw, cw = video_win, ctrl_win
  video_buf, video_win, ctrl_buf, ctrl_win = nil, nil, nil, nil
  frame_count = 0
  -- 先关窗再删 buf，避免 WinClosed 重入
  if cw and vim.api.nvim_win_is_valid(cw) then
    pcall(vim.api.nvim_win_close, cw, true)
  end
  if vw and vim.api.nvim_win_is_valid(vw) then
    -- 若还在且不是最后一个窗
    local wins = vim.api.nvim_tabpage_list_wins(0)
    if #wins > 1 then
      pcall(vim.api.nvim_win_close, vw, true)
    end
  end
  if vb and vim.api.nvim_buf_is_valid(vb) then
    pcall(vim.api.nvim_buf_delete, vb, { force = true })
  end
  if cb and vim.api.nvim_buf_is_valid(cb) then
    pcall(vim.api.nvim_buf_delete, cb, { force = true })
  end
end

--- 绑定双窗：关任意一个 → 停播并关另一个
local function attach_pair_lifecycle()
  if pair_aug then
    pcall(vim.api.nvim_del_augroup_by_id, pair_aug)
  end
  pair_aug = vim.api.nvim_create_augroup("VideobufPair", { clear = true })
  local function on_gone()
    if closing then
      return
    end
    vim.schedule(function()
      if not closing then
        M.close()
      end
    end)
  end
  for _, buf in ipairs({ video_buf, ctrl_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = pair_aug,
        buffer = buf,
        callback = on_gone,
      })
    end
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = pair_aug,
    callback = function(ev)
      if closing then
        return
      end
      local w = tonumber(ev.match)
      if not w then
        return
      end
      if w == video_win or w == ctrl_win then
        on_gone()
      end
    end,
  })
end

local function attach_resize()
  local aug = vim.api.nvim_create_augroup("VideobufResize", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = aug,
    callback = function()
      if not video_buf or not vim.api.nvim_buf_is_valid(video_buf) then
        return
      end
      if resize_timer then
        pcall(function()
          resize_timer:stop()
          resize_timer:close()
        end)
        resize_timer = nil
      end
      local t = vim.uv.new_timer()
      if not t then
        return
      end
      resize_timer = t
      t:start(config.resize_debounce_ms or 150, 0, function()
        vim.schedule(function()
          if resize_timer then
            pcall(function()
              resize_timer:stop()
              resize_timer:close()
            end)
            resize_timer = nil
          end
          if not video_win or not vim.api.nvim_win_is_valid(video_win) then
            return
          end
          -- 保持控制窗高度
          if ctrl_win and vim.api.nvim_win_is_valid(ctrl_win) then
            pcall(vim.api.nvim_win_set_height, ctrl_win, control_height())
          end
          local cols, rows = video_cell_size()
          player.resize({ cols = cols, rows = rows })
          paint_controls()
        end)
      end)
    end,
  })
end

function M.open(path, opts)
  M.ensure_setup()
  opts = opts or {}
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("videobuf: 文件不存在: " .. path, vim.log.levels.ERROR)
    return nil
  end

  pause_music_if_any()
  player.shutdown()
  destroy_ui()

  local host = find_content_win(opts.win)
  -- 在 host 里：视频全占，再拆底栏
  video_buf = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, video_buf, "videobuf-video://" .. path)
  vim.api.nvim_win_set_buf(host, video_buf)
  video_win = host

  pcall(function()
    vim.bo[video_buf].bufhidden = "wipe"
    vim.bo[video_buf].swapfile = false
    vim.bo[video_buf].filetype = "videobuf"
    vim.bo[video_buf].scrollback = 1
    vim.wo[video_win].number = false
    vim.wo[video_win].relativenumber = false
    vim.wo[video_win].signcolumn = "no"
    vim.wo[video_win].foldcolumn = "0"
    vim.wo[video_win].list = false
    vim.wo[video_win].cursorline = false
    vim.wo[video_win].wrap = false
    vim.wo[video_win].scrolloff = 0
  end)
  vim.b[video_buf].videobuf_player = true

  -- 底部分屏控制区
  vim.api.nvim_set_current_win(video_win)
  vim.cmd("belowright " .. control_height() .. "split")
  ctrl_win = vim.api.nvim_get_current_win()
  ctrl_buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, ctrl_buf, "videobuf-ctrl://" .. vim.fn.fnamemodify(path, ":t"))
  vim.api.nvim_win_set_buf(ctrl_win, ctrl_buf)
  pcall(function()
    vim.bo[ctrl_buf].buftype = "nofile"
    vim.bo[ctrl_buf].bufhidden = "wipe"
    vim.bo[ctrl_buf].swapfile = false
    vim.bo[ctrl_buf].modifiable = false
    vim.bo[ctrl_buf].filetype = "videobuf_ctrl"
    vim.wo[ctrl_win].number = false
    vim.wo[ctrl_win].relativenumber = false
    vim.wo[ctrl_win].signcolumn = "no"
    vim.wo[ctrl_win].foldcolumn = "0"
    vim.wo[ctrl_win].list = false
    vim.wo[ctrl_win].cursorline = false
    vim.wo[ctrl_win].wrap = false
    vim.wo[ctrl_win].winfix = control_height()
    vim.wo[ctrl_win].winhl = "Normal:VideobufWin,NormalNC:VideobufWin,EndOfBuffer:VideobufWin,StatusLine:VideobufNormal,StatusLineNC:VideobufNormal"
    vim.wo[ctrl_win].statusline = " videobuf "
  end)
  vim.b[ctrl_buf].videobuf_ctrl = true

  -- 打开 terminal（在视频窗）
  local chan
  local ok_t, err_t = pcall(function()
    vim.api.nvim_win_call(video_win, function()
      chan = vim.api.nvim_open_term(video_buf, { on_input = function() end })
    end)
  end)
  if not ok_t or not chan or chan <= 0 then
    last_info = "open_term 失败: " .. tostring(err_t or chan)
    paint_controls()
    vim.notify("videobuf: " .. last_info, vim.log.levels.ERROR)
    return nil
  end
  term_chan = chan

  map_video_keys(video_buf)
  map_ctrl_keys(ctrl_buf)
  attach_lock(video_buf, video_win)
  attach_lock(ctrl_buf, ctrl_win)
  attach_resize()
  attach_pair_lifecycle()
  wire_player_callbacks()

  if vim.o.mouse == "" or not tostring(vim.o.mouse):find("a", 1, true) then
    vim.o.mouse = "a"
  end
  -- 保证终端 buffer 不吞掉点击（尽量保持 normal）
  if video_buf and vim.api.nvim_buf_is_valid(video_buf) then
    pcall(function()
      vim.keymap.set("t", "<Esc>", "<C-\\><C-n>", { buffer = video_buf, silent = true })
    end)
    vim.api.nvim_create_autocmd({ "TermEnter", "BufEnter", "WinEnter" }, {
      buffer = video_buf,
      callback = function()
        vim.schedule(function()
          pcall(vim.cmd, "stopinsert")
        end)
      end,
    })
  end

  frame_count = 0
  last_info = "启动解码…"
  lyrics.load(path)
  paint_controls()

  -- 占位画面（证明 terminal 可画）
  local cols, rows = video_cell_size()
  local placeholder = {}
  for y = 1, rows do
    local line = {}
    for x = 1, cols do
      local g = 40 + ((x + y) % 40)
      line[#line + 1] = string.format("\27[48;2;%d;%d;%dm ", g, g, g + 20)
    end
    line[#line + 1] = "\27[0m"
    placeholder[#placeholder + 1] = table.concat(line)
  end
  paint_video(table.concat(placeholder, "\r\n"))

  player.setup({
    python = config.python,
    volume = config.volume,
    loop = config.loop,
    fps = config.fps,
  })

  local do_play = opts.auto_play
  if do_play == nil then
    do_play = config.auto_play
  end

  local ok, err = player.open({
    path = path,
    fps = config.fps,
    cols = cols,
    rows = rows,
    scale = config.scale,
    mode = config.mode,
    volume = config.volume,
    start = 0,
    loop = config.loop,
    auto_play = do_play, -- daemon 在 open 就绪后立即 play，无需 defer
  })
  if not ok then
    last_info = "open 失败: " .. tostring(err)
    paint_controls()
    vim.notify("videobuf: " .. last_info, vim.log.levels.ERROR)
  else
    last_info = do_play and "已 open（自动播放）…" or "已 open，等待播放…"
    paint_controls()
  end

  start_ui_timer()

  -- 2s / 5s 诊断：仍无帧则显示 IPC 状态
  vim.defer_fn(function()
    if not ctrl_buf or not vim.api.nvim_buf_is_valid(ctrl_buf) then
      return
    end
    if frame_count > 0 then
      return
    end
    local d = player.diag and player.diag() or {}
    last_info = string.format(
      "仍无帧 job=%s L=%s F=%s be=%s py=%s ev=%s err=%s",
      tostring(d.job_id),
      tostring(d.lines_in),
      tostring(d.frames_in),
      tostring(d.backend),
      tostring(d.python or "?"),
      tostring(d.event_path or "?"):sub(-40),
      tostring(d.last_error or d.last_stderr or "-")
    )
    paint_controls()
    player.poll()
  end, 2000)

  vim.defer_fn(function()
    if not ctrl_buf or not vim.api.nvim_buf_is_valid(ctrl_buf) then
      return
    end
    if frame_count > 0 then
      return
    end
    local d = player.diag and player.diag() or {}
    last_info = string.format(
      "超时无帧! job=%s lines_in=%s 请检查 python/av。stderr=%s",
      tostring(d.job_id),
      tostring(d.lines_in),
      tostring(d.last_stderr or d.last_error or "-")
    )
    paint_controls()
  end, 5000)

  -- 焦点放在控制条，方便点按钮
  if ctrl_win and vim.api.nvim_win_is_valid(ctrl_win) then
    vim.api.nvim_set_current_win(ctrl_win)
  end
  pcall(vim.cmd, "stopinsert")

  -- 兜底：若 daemon 未 auto_play（旧进程），1.5s 后再发一次 play
  if do_play then
    vim.defer_fn(function()
      if not video_buf or not vim.api.nvim_buf_is_valid(video_buf) then
        return
      end
      local st = player.get_state()
      if st.status ~= "playing" then
        player.play()
        paint_controls()
      end
    end, 1500)
  end

  return video_buf
end

function M.toggle()
  player.toggle()
  paint_controls()
end

function M.stop()
  player.stop()
  paint_controls()
end

function M.close()
  if closing then
    return
  end
  closing = true
  -- 停解码 / 音频 / 守护进程
  pcall(function()
    player.shutdown()
  end)
  pcall(function()
    lyrics.clear()
  end)
  pcall(destroy_ui)
  closing = false
end

function M.set_fps(n)
  if n == nil then
    local st = player.get_state()
    vim.notify("videobuf fps: " .. tostring(st.fps), vim.log.levels.INFO)
    return st.fps
  end
  n = tonumber(n)
  if not n then
    return
  end
  player.set_fps(math.max(config.fps_min, math.min(config.fps_max, n)))
  paint_controls()
  return n
end

function M.next()
  local st = player.get_state()
  local path = st.path
  if not path then
    return
  end
  local list, idx = list_siblings(path)
  if idx >= #list then
    vim.notify("videobuf: 已是最后一个", vim.log.levels.INFO)
    return
  end
  M.open(list[idx + 1])
end

function M.prev()
  local st = player.get_state()
  local path = st.path
  if not path then
    return
  end
  local list, idx = list_siblings(path)
  if idx <= 1 then
    vim.notify("videobuf: 已是第一个", vim.log.levels.INFO)
    return
  end
  M.open(list[idx - 1])
end

local function setup_auto_open()
  local pat = {}
  for _, ext in ipairs(config.filetypes) do
    table.insert(pat, "*." .. ext)
    table.insert(pat, "*." .. ext:upper())
  end
  local aug = vim.api.nvim_create_augroup("VideobufAutoOpen", { clear = true })
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
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then
          return
        end
        local target = find_content_win(vim.fn.bufwinid(ev.buf))
        M.open(path, { win = target })
      end)
    end,
  })
end

local function register_commands()
  vim.api.nvim_create_user_command("Videobuf", function(opts)
    local path = opts.args
    if path == nil or path == "" then
      path = vim.fn.expand("%:p")
    end
    if path == nil or path == "" then
      vim.notify("videobuf: 请指定视频路径", vim.log.levels.ERROR)
      return
    end
    M.open(path)
  end, { nargs = "?", complete = "file", desc = "打开内嵌视频播放器" })

  vim.api.nvim_create_user_command("VideobufToggle", function()
    M.toggle()
  end, { desc = "播放/暂停" })
  vim.api.nvim_create_user_command("VideobufStop", function()
    M.stop()
  end, { desc = "停止" })
  vim.api.nvim_create_user_command("VideobufNext", function()
    M.next()
  end, { desc = "下一个" })
  vim.api.nvim_create_user_command("VideobufPrev", function()
    M.prev()
  end, { desc = "上一个" })
  vim.api.nvim_create_user_command("VideobufClose", function()
    M.close()
  end, { desc = "关闭" })
  vim.api.nvim_create_user_command("VideobufFps", function(opts)
    local arg = vim.trim(opts.args or "")
    if arg == "" then
      M.set_fps(nil)
      return
    end
    M.set_fps(tonumber(arg))
  end, { nargs = "?", desc = "设置 FPS" })
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  rebuild_ext()
  hl_ready = false -- 允许重设配色
  vim.g.videobuf_setup_done = true
  -- 界面语言：auto 跟系统，或显式 zh/en
  if config.lang == "zh" or config.lang == "en" then
    i18n.setup(config.lang)
  else
    i18n.setup(nil) -- detect
  end
  player.setup({
    python = config.python,
    volume = config.volume,
    loop = config.loop,
    fps = config.fps,
  })
  register_commands()
  if config.auto_open then
    setup_auto_open()
  else
    vim.api.nvim_create_augroup("VideobufAutoOpen", { clear = true })
  end
end

function M.ensure_setup()
  if not vim.g.videobuf_setup_done then
    M.setup()
  end
end

function M.config()
  return config
end

---供 player warn 推送到控制区
function M.set_info(msg)
  last_info = tostring(msg or "")
  paint_controls()
end

return M
