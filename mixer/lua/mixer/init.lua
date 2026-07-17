---@mod mixer Windows winmm MIDI player for Neovim
local player = require("mixer.player")
local i18n = require("mixer.i18n")

local M = {}

local default_config = {
  python = "python",
  volume = 70,
  ui_lang = "auto",
  keys_open = "<leader>mx",
  auto_open = true,
  auto_play = true,
  --- 上下分屏时按内容自动高度；独占整列/唯一窗口时不改高度（对齐 music）
  fit_height = true,
  extensions = { "mid", "midi" },
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}
local auto_aug = nil

---@class MixerHit
---@field action string
---@field row integer 1-based
---@field d0 integer 1-based display col
---@field d1 integer

local state = {
  buf = nil, ---@type integer|nil
  win = nil, ---@type integer|nil
  hits = {}, ---@type MixerHit[]
  preset_index = 1,
  closing = false,
  source_path = nil, ---@type string|nil 当前文件路径（非预设时）
  float_win = nil,
  float_buf = nil,
}

local NS = vim.api.nvim_create_namespace("mixer_ui")
local NS_FLOAT = vim.api.nvim_create_namespace("mixer_preset_float")

local function ensure_hl()
  local function hl(name, spec)
    spec.force = true
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
  hl("MixerNormal", { fg = "#111111", bg = "#ffffff" })
  hl("MixerTitle", { fg = "#111111", bg = "#ffffff", bold = true })
  hl("MixerHeader", { fg = "#666666", bg = "#ffffff", bold = true })
  hl("MixerMeta", { fg = "#555555", bg = "#ffffff" })
  hl("MixerPlay", { fg = "#111111", bg = "#ffffff", bold = true })
  hl("MixerBar", { fg = "#444444", bg = "#ffffff" })
  hl("MixerBarFill", { fg = "#333333", bg = "#ffffff", bold = true })
  hl("MixerBtn", { fg = "#111111", bg = "#e8e8e8", bold = true })
  hl("MixerBtnHot", { fg = "#111111", bg = "#d0d0d0", bold = true })
  hl("MixerFloat", { fg = "#111111", bg = "#ffffff" })
  hl("MixerFloatSel", { fg = "#000000", bg = "#dddddd", bold = true })
end

local function fmt_time(sec)
  sec = math.max(0, math.floor(tonumber(sec) or 0))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function bar(pos, dur, width)
  width = math.max(8, width or 28)
  if not dur or dur <= 0 then
    return string.rep("─", width)
  end
  local filled = math.floor((pos / dur) * width + 0.5)
  filled = math.max(0, math.min(width, filled))
  return string.rep("█", filled) .. string.rep("─", width - filled)
end

local function status_label(st)
  local s = st.status or "idle"
  if s == "playing" then
    return i18n.t("playing"), "MixerPlay"
  end
  if s == "paused" then
    return i18n.t("paused"), "MixerMeta"
  end
  if s == "loading" then
    return i18n.t("loading"), "MixerMeta"
  end
  if s == "stopped" then
    return i18n.t("stopped"), "MixerMeta"
  end
  return i18n.t("idle"), "MixerMeta"
end

local function preset_list()
  local st = player.get_state()
  local list = st.presets or {}
  if #list == 0 then
    return {
      { id = "twinkle", title = "小星星 / Twinkle" },
      { id = "ode", title = "欢乐颂 / Ode to Joy" },
      { id = "scales", title = "乐器巡演 / Scales" },
      { id = "groove", title = "迷你律动 / Groove" },
      { id = "sakura", title = "五声音韵 / Pentatonic" },
    }
  end
  return list
end

local function is_midi_path(path)
  if not path or path == "" then
    return false
  end
  local ext = path:match("%.([%w]+)$")
  if not ext then
    return false
  end
  ext = ext:lower()
  for _, e in ipairs(config.extensions or {}) do
    if e:lower() == ext then
      return true
    end
  end
  return false
end

function M.is_open()
  return state.buf
    and vim.api.nvim_buf_is_valid(state.buf)
    and state.win
    and vim.api.nvim_win_is_valid(state.win)
end

---True if `win` sits in a vertical stack (horizontal split / :split), not alone in column.
---winlayout: "col" = stacked (top-bottom), "row" = side-by-side (vsplit).
local function win_is_vertically_split(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local function walk(node, parent_col_multi)
    if type(node) ~= "table" then
      return false
    end
    if node[1] == "leaf" then
      return node[2] == win and parent_col_multi
    end
    local kind = node[1] -- "row" | "col"
    local children = node[2] or {}
    local multi = #children > 1
    -- stacked siblings only when parent is "col" with multiple children
    local stacked_here = kind == "col" and multi
    for _, ch in ipairs(children) do
      if walk(ch, stacked_here) then
        return true
      end
    end
    return false
  end
  return walk(vim.fn.winlayout(), false)
end

local UI_LINES = 4 -- title + status + bar + buttons

---仅当窗口处于上下分屏（竖直方向有其它窗）时才自动控制高度。
---独占整列 / 唯一窗口时不改高度（与 music.fit_music_height 一致）。
local function fit_mixer_height(buf, nlines)
  if config.fit_height == false then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  nlines = math.max(3, math.min(nlines or UI_LINES, vim.o.lines - 3))
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf and win_is_vertically_split(win) then
      pcall(vim.api.nvim_win_set_height, win, nlines)
      pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
    end
  end
end

local function close_preset_float()
  if state.float_win and vim.api.nvim_win_is_valid(state.float_win) then
    pcall(vim.api.nvim_win_close, state.float_win, true)
  end
  if state.float_buf and vim.api.nvim_buf_is_valid(state.float_buf) then
    pcall(vim.api.nvim_buf_delete, state.float_buf, { force = true })
  end
  state.float_win, state.float_buf = nil, nil
end

---精简 UI（对齐 music）：标题 / 状态时间音量 / 进度条 / 操作按钮
function M.render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  ensure_hl()
  local st = player.get_state()
  local presets = preset_list()
  if state.preset_index < 1 then
    state.preset_index = 1
  end
  if #presets > 0 and state.preset_index > #presets then
    state.preset_index = #presets
  end
  local cur = presets[state.preset_index] or {}
  local title = st.title
  if not title or title == "" then
    if state.source_path then
      title = vim.fn.fnamemodify(state.source_path, ":t")
    else
      title = cur.title or cur.name or "?"
    end
  end
  local slabel, shl = status_label(st)
  local w = 50
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    w = math.max(36, vim.api.nvim_win_get_width(state.win) - 2)
  end

  local lines = {}
  local hits = {} ---@type MixerHit[]
  ---@type table<integer, {integer,integer,string}[]>
  local segs = {}

  local function push(line, marks)
    lines[#lines + 1] = line
    segs[#lines - 1] = marks or {}
  end

  local function add_hit(action, row0, d0, d1)
    hits[#hits + 1] = { action = action, row = row0 + 1, d0 = d0, d1 = d1 }
  end

  -- 1) 标题
  push(
    string.format("  MIXER  %s", title),
    { { 0, 0, "MixerTitle" } }
  )
  -- 2) 状态 + 时间 + 音量
  push(
    string.format(
      "  %s   %s/%s   %s %d%%",
      slabel,
      fmt_time(st.position),
      fmt_time(st.duration),
      i18n.t("volume"),
      st.volume or config.volume
    ),
    { { 0, 0, shl } }
  )
  -- 3) 进度条
  local bw = math.min(36, math.max(16, w - 6))
  push("  [" .. bar(st.position or 0, st.duration or 0, bw) .. "]", { { 0, 0, "MixerBar" } })

  -- 4) 操作按钮（逗号分隔，可点）—— hit 用**显示列**（strdisplaywidth），点空白不命中
  local playing = st.status == "playing"
  local btns = {
    { text = (playing and i18n.t("pause") or i18n.t("play")) .. "Space", action = "toggle", hot = true },
    { text = i18n.t("stop") .. "x", action = "stop" },
    { text = i18n.t("presets") .. "f", action = "list", hot = true },
    { text = i18n.t("lang") .. "L", action = "lang" },
    { text = i18n.t("close") .. "q", action = "close", hot = true },
  }
  local brow = #lines
  local bline = "  "
  local bmarks = {}
  for i, b in ipairs(btns) do
    if i > 1 then
      local sep = ", "
      local c0 = #bline
      bline = bline .. sep
      bmarks[#bmarks + 1] = { c0, #bline, "MixerMeta" }
    end
    local disp0 = vim.fn.strdisplaywidth(bline) + 1 -- 1-based 显示列
    local c0 = #bline
    bline = bline .. b.text
    local c1 = #bline
    local disp1 = vim.fn.strdisplaywidth(bline) -- inclusive end 显示列
    add_hit(b.action, brow, disp0, disp1)
    bmarks[#bmarks + 1] = {
      c0,
      c1,
      b.hot and "MixerBtnHot" or "MixerBtn",
    }
  end
  push(bline, bmarks)
  -- 末尾空行：点在按钮行下方不会落到按钮行末字上
  push("")

  pcall(function()
    vim.bo[state.buf].modifiable = true
  end)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for row, marks in pairs(segs) do
    for _, m in ipairs(marks) do
      local c0, c1, hl = m[1], m[2], m[3]
      if c1 == 0 then
        c1 = #(lines[row + 1] or "")
      end
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, row, c0, {
        end_col = math.max(c0, c1),
        hl_group = hl,
      })
    end
  end
  pcall(function()
    vim.bo[state.buf].modifiable = false
    vim.bo[state.buf].modified = false
  end)
  state.hits = hits
  -- 上下分屏时才按内容压高度；独占整列不碰
  fit_mixer_height(state.buf, #lines)
end

local function current_preset_id()
  local presets = preset_list()
  local p = presets[state.preset_index]
  return p and (p.id or p.name) or "twinkle"
end

local function load_current(play_after)
  state.source_path = nil
  local id = current_preset_id()
  player.load_preset(id, play_after and true or false)
end

local function load_path(path, play_after)
  state.source_path = path
  player.load_path(path, play_after and true or false)
end

---预设列表 float（f 打开）
function M.open_preset_float()
  close_preset_float()
  ensure_hl()
  player.ensure()
  player.list_presets()
  vim.wait(300, function()
    local s = player.get_state()
    return s.presets and #s.presets > 0
  end, 30)

  local presets = preset_list()
  local lines = { " " .. i18n.t("presets_title") .. " ", "" }
  for i, p in ipairs(presets) do
    local mark = (i == state.preset_index) and "● " or "○ "
    lines[#lines + 1] = mark .. (p.title or p.name or p.id or ("#" .. i))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].mixer_preset_float = true

  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 4)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.7))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. i18n.t("presets") .. " ",
    title_pos = "center",
    zindex = 80,
  })
  pcall(function()
    vim.wo[win].winhl = "Normal:MixerFloat,FloatBorder:MixerFloat"
    vim.wo[win].cursorline = true
    vim.wo[win].number = false
    vim.wo[win].wrap = false
  end)
  state.float_win = win
  state.float_buf = buf

  local sel = math.max(0, state.preset_index - 1)
  pcall(vim.api.nvim_buf_set_extmark, buf, NS_FLOAT, sel + 2, 0, {
    end_row = sel + 2,
    line_hl_group = "MixerFloatSel",
  })
  pcall(vim.api.nvim_win_set_cursor, win, { sel + 3, 0 })

  local function pick_line(lnum)
    local i = lnum - 2
    if i < 1 or i > #presets then
      return
    end
    state.preset_index = i
    close_preset_float()
    load_current(true)
    if M.is_open() then
      M.render()
    end
    vim.notify(i18n.t("loaded") .. tostring(presets[i].title or presets[i].id), vim.log.levels.INFO)
  end

  local o = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_preset_float, o)
  vim.keymap.set("n", "<Esc>", close_preset_float, o)
  vim.keymap.set("n", "<CR>", function()
    pick_line(vim.api.nvim_win_get_cursor(0)[1])
  end, o)
  vim.keymap.set("n", "<LeftRelease>", function()
    vim.schedule(function()
      if state.float_buf and vim.api.nvim_get_current_buf() == state.float_buf then
        pick_line(vim.api.nvim_win_get_cursor(0)[1])
      end
    end)
  end, o)
  -- 禁止选字/滚动
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv", "j", "k", "<ScrollWheelUp>", "<ScrollWheelDown>" }) do
    -- j/k 保留用于列表移动
  end
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv" }) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", o)
  end
  for i = 1, math.min(9, #presets) do
    vim.keymap.set("n", tostring(i), function()
      pick_line(i + 2)
    end, o)
  end
end

local function do_action(action)
  local st = player.get_state()
  if action == "toggle" then
    if st.status == "idle" or st.status == "stopped" or (st.duration or 0) <= 0 then
      if state.source_path then
        load_path(state.source_path, true)
      else
        load_current(true)
      end
    else
      player.toggle()
    end
  elseif action == "stop" then
    player.stop()
  elseif action == "list" then
    M.open_preset_float()
  elseif action == "lang" then
    local next_lang = i18n.toggle()
    i18n.save_prefs()
    vim.notify(next_lang == "en" and i18n.t("lang_to_en") or i18n.t("lang_to_zh"), vim.log.levels.INFO)
  elseif action == "close" then
    M.close()
    return
  elseif action == "vol_up" then
    player.set_volume(math.min(100, (st.volume or 70) + 5))
  elseif action == "vol_down" then
    player.set_volume(math.max(0, (st.volume or 70) - 5))
  end
  if M.is_open() then
    M.render()
  end
end

local function map_no_select_scroll(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  -- 禁止 visual / 选字
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv", "<C-q>", "gh", "gH" }) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", opts)
  end
  pcall(vim.keymap.set, "n", "<LeftDrag>", "<Nop>", opts)
  pcall(vim.keymap.set, "n", "<RightDrag>", "<Nop>", opts)
  pcall(vim.keymap.set, "n", "<S-LeftMouse>", "<Nop>", opts)
  -- 禁止滚动
  local nop_keys = {
    "j",
    "k",
    "h",
    "l",
    "<Down>",
    "<Up>",
    "<Left>",
    "<Right>",
    "<C-d>",
    "<C-u>",
    "<C-f>",
    "<C-b>",
    "<C-e>",
    "<C-y>",
    "<PageUp>",
    "<PageDown>",
    "gg",
    "G",
    "zt",
    "zz",
    "zb",
    "H",
    "M",
    -- 勿 Nop L：用作语言切换
    "<ScrollWheelUp>",
    "<ScrollWheelDown>",
    "<ScrollWheelLeft>",
    "<ScrollWheelRight>",
  }
  for _, lhs in ipairs(nop_keys) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", vim.tbl_extend("force", opts, { desc = "mixer: no scroll" }))
  end
  for _, lhs in ipairs({ "i", "a", "I", "A", "o", "O", "r", "R", "c", "s" }) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", opts)
  end
  -- 误入 visual 立即退出
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
end

local function bind(buf)
  map_no_select_scroll(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", opts, { desc = "mixer: " .. desc }))
  end
  map("q", function()
    do_action("close")
  end, "close")
  map("<Esc>", function()
    do_action("close")
  end, "close")
  map("<Space>", function()
    do_action("toggle")
  end, "play/pause")
  map("x", function()
    do_action("stop")
  end, "stop")
  map("f", function()
    do_action("list")
  end, "presets float")
  map("L", function()
    do_action("lang")
  end, "lang")
  map("+", function()
    do_action("vol_up")
  end, "vol+")
  map("=", function()
    do_action("vol_up")
  end, "vol+")
  map("-", function()
    do_action("vol_down")
  end, "vol-")

  ---用 getmousepos 显示列判定，避免点空白/行尾误触最后一个按钮
  local function on_click()
    if not state.buf or not state.win then
      return
    end
    local mp = vim.fn.getmousepos()
    if mp.winid ~= state.win then
      return
    end
    local row = mp.line -- 1-based buffer line
    -- 窗口内屏幕列（1-based）；无 sign/number 时即缓冲区显示列
    local info = vim.fn.getwininfo(state.win)[1] or {}
    local textoff = info.textoff or 0
    local vcol = (mp.wincol or mp.column or 0) - textoff
    if vcol < 1 then
      vcol = mp.column or 1
    end
    for _, h in ipairs(state.hits or {}) do
      if h.row == row and vcol >= h.d0 and vcol <= h.d1 then
        do_action(h.action)
        return
      end
    end
  end
  vim.keymap.set("n", "<LeftRelease>", on_click, opts)
  vim.keymap.set("n", "<2-LeftMouse>", on_click, opts)
  vim.keymap.set("n", "<LeftMouse>", function()
    -- 按下时也判定一次，并吞掉默认跳光标到行尾的行为干扰
    on_click()
  end, opts)
end

---@param opts? {
---  path?: string,
---  preset?: string,
---  play?: boolean,
---  win?: integer,
---  replace_buf?: integer,
---  close_win?: integer,
---}
function M.open(opts)
  opts = opts or {}
  M.ensure_setup()
  ensure_hl()
  player.ensure()

  local play = opts.play
  if play == nil then
    play = config.auto_play ~= false
  end

  if not M.is_open() then
    local buf = opts.replace_buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      buf = vim.api.nvim_create_buf(false, true)
    end
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "mixer"
    vim.b[buf].mixer_player = true
    pcall(vim.api.nvim_buf_set_name, buf, "mixer://player")

    local win = opts.win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, buf)
    else
      -- 底部分屏：初始高度 = 内容行数（随后 fit 仅在竖直栈中生效）
      local h = math.max(3, math.min(UI_LINES, vim.o.lines - 5))
      vim.cmd("belowright " .. tostring(h) .. "split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end

    pcall(function()
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].wrap = false
      vim.wo[win].cursorline = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldcolumn = "0"
      vim.wo[win].list = false
      vim.wo[win].scrolloff = 0
      vim.wo[win].sidescrolloff = 0
      vim.wo[win].winhl = "Normal:MixerNormal,NormalNC:MixerNormal,EndOfBuffer:MixerNormal"
      -- 高度：仅上下分屏时固定；独占窗口不 set_height
      if win_is_vertically_split(win) then
        local h = math.max(3, math.min(UI_LINES, vim.o.lines - 3))
        pcall(vim.api.nvim_win_set_height, win, h)
        pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
      else
        -- 唯一窗 / 整列独占：允许随屏幕，不锁 winfixheight
        pcall(vim.api.nvim_set_option_value, "winfixheight", false, { win = win })
      end
    end)

    if opts.close_win and vim.api.nvim_win_is_valid(opts.close_win) and opts.close_win ~= win then
      pcall(vim.api.nvim_win_close, opts.close_win, true)
    end

    state.buf = buf
    state.win = win
    bind(buf)
    if not tostring(vim.o.mouse or ""):find("a", 1, true) then
      vim.o.mouse = "a"
    end
  elseif opts.win and vim.api.nvim_win_is_valid(opts.win) then
    state.win = opts.win
    vim.api.nvim_win_set_buf(opts.win, state.buf)
  end

  player.on_status(function()
    if M.is_open() then
      M.render()
    end
  end)

  if opts.path and opts.path ~= "" then
    load_path(vim.fn.fnamemodify(opts.path, ":p"), play)
  elseif opts.preset then
    local presets = preset_list()
    for i, p in ipairs(presets) do
      if p.id == opts.preset or p.name == opts.preset then
        state.preset_index = i
        break
      end
    end
    load_current(play)
  end

  M.render()
  return state.buf
end

function M.close()
  if state.closing then
    return
  end
  state.closing = true
  close_preset_float()
  player.stop()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf, state.win = nil, nil
  state.hits = {}
  state.source_path = nil
  state.closing = false
end

function M.play_preset(name)
  M.open({ preset = name or "twinkle", play = true })
end

function M.play_file(path)
  M.open({ path = path, play = true })
end

local function setup_auto_open()
  if auto_aug then
    pcall(vim.api.nvim_del_augroup_by_id, auto_aug)
    auto_aug = nil
  end
  if config.auto_open == false then
    return
  end
  local pat = {}
  for _, ext in ipairs(config.extensions or { "mid", "midi" }) do
    pat[#pat + 1] = "*." .. ext
    pat[#pat + 1] = "*." .. ext:upper()
  end
  auto_aug = vim.api.nvim_create_augroup("MixerAutoOpen", { clear = true })

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = auto_aug,
    pattern = pat,
    callback = function(ev)
      local path = ev.file
      if path == nil or path == "" then
        path = vim.api.nvim_buf_get_name(ev.buf)
      end
      if not is_midi_path(path) then
        return
      end
      vim.bo[ev.buf].buftype = "nofile"
      vim.bo[ev.buf].bufhidden = "wipe"
      vim.bo[ev.buf].swapfile = false
      vim.bo[ev.buf].binary = false
      vim.b[ev.buf].mixer_placeholder = true
      -- 清空可能读入的二进制垃圾
      pcall(function()
        vim.bo[ev.buf].modifiable = true
        vim.api.nvim_buf_set_lines(ev.buf, 0, -1, false, {})
        vim.bo[ev.buf].modifiable = false
      end)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then
          return
        end
        local win = vim.fn.bufwinid(ev.buf)
        if win == -1 then
          win = vim.api.nvim_get_current_win()
        end
        M.open({
          path = path,
          play = config.auto_play ~= false,
          win = win,
          replace_buf = ev.buf,
        })
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = auto_aug,
    pattern = pat,
    callback = function(ev)
      if vim.b[ev.buf].mixer_player or vim.b[ev.buf].mixer_placeholder then
        return
      end
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if not is_midi_path(path) then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) or vim.b[ev.buf].mixer_player then
          return
        end
        local win = vim.fn.bufwinid(ev.buf)
        if win == -1 then
          win = vim.api.nvim_get_current_win()
        end
        M.open({
          path = path,
          play = config.auto_play ~= false,
          win = win,
          replace_buf = ev.buf,
        })
      end)
    end,
  })
end

local function apply_keys()
  for _, item in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", item)
  end
  keys_applied = {}
  local lhs = config.keys_open
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, function()
      M.open({ play = false })
    end, { silent = true, desc = "mixer: open" })
    keys_applied[#keys_applied + 1] = lhs
  end
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  local remembered = i18n.load_prefs()
  local lang_opt = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang_opt = user.ui_lang
  elseif remembered then
    lang_opt = remembered
  end
  if lang_opt == "zh" or lang_opt == "en" then
    i18n.setup(lang_opt)
  else
    i18n.setup("auto")
  end
  player.setup({
    python = config.python,
    volume = config.volume,
  })
  apply_keys()
  setup_auto_open()
  -- 后台预热 Python/winmm，避免首次打开卡十几秒
  player.warmup()
  setup_done = true
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

return M
