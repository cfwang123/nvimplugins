---@mod nvimgames.mine Windows-style Minesweeper for Neovim
local M = {}

local i18n = require("nvimgames.i18n")

---@class MineDifficulty
---@field name string
---@field cols number
---@field rows number
---@field mines number

---@class MineConfig
---@field difficulty string
---@field difficulties table<string, MineDifficulty>

local DIFFICULTIES = {
  beginner = { name_key = "mine_diff_beginner", cols = 9, rows = 9, mines = 10 },
  intermediate = { name_key = "mine_diff_intermediate", cols = 16, rows = 16, mines = 40 },
  expert = { name_key = "mine_diff_expert", cols = 30, rows = 16, mines = 99 },
}

local default_config = {
  difficulty = "beginner",
  difficulties = DIFFICULTIES,
}

local config = vim.deepcopy(default_config)
local ns = vim.api.nvim_create_namespace("mine")
local state_by_buf = {} ---@type table<integer, table>
local hl_ready = false

local function get_diff_label(id)
  local d = (config.difficulties and config.difficulties[id]) or DIFFICULTIES[id]
  if d and d.name_key then
    return i18n.t(d.name_key)
  end
  if d and d.name then
    return d.name
  end
  return id
end

-- Classic Windows Minesweeper number colors
local NUM_COLORS = {
  [1] = "0000ff",
  [2] = "008000",
  [3] = "ff0000",
  [4] = "000080",
  [5] = "800000",
  [6] = "008080",
  [7] = "000000",
  [8] = "808080",
}

local function ensure_hl()
  if hl_ready and vim.g.mine_hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  -- panel
  vim.api.nvim_set_hl(0, "MinePanel", { fg = "#000000", bg = "#c0c0c0", bold = true })
  vim.api.nvim_set_hl(0, "MineLed", { fg = "#ff0000", bg = "#000000", bold = true })
  -- 表情：始终黄底（不因 playing 切回灰底）
  vim.api.nvim_set_hl(0, "MineFace", { fg = "#000000", bg = "#ffff00", bold = true })
  vim.api.nvim_set_hl(0, "MineFaceHot", { fg = "#000000", bg = "#ffff00", bold = true })
  -- 未开格：单色底 + 相邻棋盘微差（A/B）
  vim.api.nvim_set_hl(0, "MineCoverA", { fg = "#d4d0c8", bg = "#d4d0c8" })
  vim.api.nvim_set_hl(0, "MineCoverB", { fg = "#c0c0c0", bg = "#c0c0c0" })
  vim.api.nvim_set_hl(0, "MineCover", { fg = "#c0c0c0", bg = "#c0c0c0" }) -- 兼容
  vim.api.nvim_set_hl(0, "MineCoverEdge", { fg = "#c0c0c0", bg = "#c0c0c0", bold = true })
  -- 已开格略深，与未开格区分
  vim.api.nvim_set_hl(0, "MineOpen", { fg = "#808080", bg = "#b0b0b0" })
  vim.api.nvim_set_hl(0, "MineFlagA", { fg = "#ff0000", bg = "#d4d0c8", bold = true })
  vim.api.nvim_set_hl(0, "MineFlagB", { fg = "#ff0000", bg = "#c0c0c0", bold = true })
  vim.api.nvim_set_hl(0, "MineFlag", { fg = "#ff0000", bg = "#c0c0c0", bold = true })
  vim.api.nvim_set_hl(0, "MineMine", { fg = "#000000", bg = "#b0b0b0", bold = true })
  vim.api.nvim_set_hl(0, "MineMineHit", { fg = "#ffffff", bg = "#ff0000", bold = true })
  vim.api.nvim_set_hl(0, "MineWrong", { fg = "#ff0000", bg = "#b0b0b0", bold = true })
  vim.api.nvim_set_hl(0, "MineBorder", { fg = "#808080", bg = "#c0c0c0" })
  vim.api.nvim_set_hl(0, "MineStatus", { fg = "#000000", bg = "#c0c0c0" })
  vim.api.nvim_set_hl(0, "MineBtn", { fg = "#000000", bg = "#a0a0ff", bold = true })
  for n, hex in pairs(NUM_COLORS) do
    vim.api.nvim_set_hl(0, "MineNum" .. n, { fg = "#" .. hex, bg = "#b0b0b0", bold = true })
  end
  hl_ready = true
  vim.g.mine_hl_ready = true
end

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function led3(n)
  n = math.floor(n)
  if n < -99 then
    n = -99
  end
  if n > 999 then
    n = 999
  end
  if n < 0 then
    return string.format("-%02d", -n)
  end
  return string.format("%03d", n)
end

local function idx(st, x, y)
  return (y - 1) * st.cols + x
end

local function in_board(st, x, y)
  return x >= 1 and x <= st.cols and y >= 1 and y <= st.rows
end

local function neighbors(st, x, y)
  local list = {}
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx, ny = x + dx, y + dy
        if in_board(st, nx, ny) then
          table.insert(list, { nx, ny })
        end
      end
    end
  end
  return list
end

local function stop_timer(st)
  if st.timer then
    pcall(function()
      st.timer:stop()
      st.timer:close()
    end)
    st.timer = nil
  end
end

local function count_flags(st)
  local n = 0
  for i = 1, st.cols * st.rows do
    if st.flagged[i] then
      n = n + 1
    end
  end
  return n
end

local function count_opened(st)
  local n = 0
  for i = 1, st.cols * st.rows do
    if st.opened[i] then
      n = n + 1
    end
  end
  return n
end

local function place_mines(st, safe_x, safe_y)
  local total = st.cols * st.rows
  local forbidden = {}
  forbidden[idx(st, safe_x, safe_y)] = true
  -- first click 3x3 safe (Windows-like comfort)
  for _, n in ipairs(neighbors(st, safe_x, safe_y)) do
    forbidden[idx(st, n[1], n[2])] = true
  end
  local slots = {}
  for i = 1, total do
    if not forbidden[i] then
      table.insert(slots, i)
    end
  end
  -- shuffle
  for i = #slots, 2, -1 do
    local j = math.random(i)
    slots[i], slots[j] = slots[j], slots[i]
  end
  local mines = math.min(st.mines, #slots)
  st.mine = {}
  for i = 1, total do
    st.mine[i] = false
  end
  for i = 1, mines do
    st.mine[slots[i]] = true
  end
  -- adjacency counts
  st.count = {}
  for y = 1, st.rows do
    for x = 1, st.cols do
      local i = idx(st, x, y)
      if st.mine[i] then
        st.count[i] = -1
      else
        local c = 0
        for _, n in ipairs(neighbors(st, x, y)) do
          if st.mine[idx(st, n[1], n[2])] then
            c = c + 1
          end
        end
        st.count[i] = c
      end
    end
  end
  st.mines_placed = true
end

local function flood_open(st, x, y)
  local stack = { { x, y } }
  local seen = {}
  while #stack > 0 do
    local p = table.remove(stack)
    local px, py = p[1], p[2]
    local i = idx(st, px, py)
    if not seen[i] and in_board(st, px, py) and not st.flagged[i] and not st.opened[i] then
      seen[i] = true
      st.opened[i] = true
      if st.count[i] == 0 then
        for _, n in ipairs(neighbors(st, px, py)) do
          table.insert(stack, n)
        end
      end
    end
  end
end

local function check_win(st)
  local need = st.cols * st.rows - st.mines
  if count_opened(st) >= need then
    st.status = "won"
    stop_timer(st)
    -- auto flag remaining mines
    for i = 1, st.cols * st.rows do
      if st.mine[i] then
        st.flagged[i] = true
      end
    end
  end
end

local function reveal_mines(st, hit)
  st.status = "lost"
  st.hit = hit
  stop_timer(st)
  for i = 1, st.cols * st.rows do
    if st.mine[i] then
      st.opened[i] = true
    elseif st.flagged[i] then
      st.wrong[i] = true
    end
  end
end

local function start_timer(st, buf)
  stop_timer(st)
  st.seconds = 0
  st.timer = vim.uv.new_timer()
  if not st.timer then
    return
  end
  st.timer:start(1000, 1000, function()
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        stop_timer(st)
        return
      end
      local s = state_by_buf[buf]
      if not s or s.status ~= "playing" then
        stop_timer(st)
        return
      end
      s.seconds = math.min(999, (s.seconds or 0) + 1)
      M.render(buf)
    end)
  end)
end

local function new_game(st, diff_key)
  local d = config.difficulties[diff_key] or config.difficulties.beginner
  st.diff_key = diff_key
  st.cols = d.cols
  st.rows = d.rows
  st.mines = d.mines
  st.diff_name = get_diff_label(diff_key)
  local total = st.cols * st.rows
  st.mine = {}
  st.count = {}
  st.opened = {}
  st.flagged = {}
  st.wrong = {}
  for i = 1, total do
    st.mine[i] = false
    st.count[i] = 0
    st.opened[i] = false
    st.flagged[i] = false
    st.wrong[i] = false
  end
  st.mines_placed = false
  st.status = "ready" -- ready | playing | won | lost
  st.seconds = 0
  st.hit = nil
  st.pressing = false
  stop_timer(st)
end

local function face_char(st)
  if st.status == "won" then
    return "😎"
  end
  if st.status == "lost" then
    return "😵"
  end
  if st.pressing then
    return "😮"
  end
  return "🙂"
end

---Each cell is 2 display columns wide for a chunky Windows look
local CELL_W = 2

---未开格棋盘格：相邻格底色略不同，单格内 fg=bg 纯色
local function cover_parity(x, y)
  return (x + y) % 2 == 0
end

local function cell_glyph(st, x, y)
  local i = idx(st, x, y)
  if st.wrong[i] then
    return "❌", "MineWrong"
  end
  if not st.opened[i] then
    local a = cover_parity(x, y)
    if st.flagged[i] then
      return "🚩", a and "MineFlagA" or "MineFlagB"
    end
    -- 两格空白 + 纯色高亮（不用 ▓，避免格内花纹）
    return "  ", a and "MineCoverA" or "MineCoverB"
  end
  if st.mine[i] then
    if st.hit and st.hit[1] == x and st.hit[2] == y then
      return "💣", "MineMineHit"
    end
    return "💣", "MineMine"
  end
  local c = st.count[i] or 0
  if c == 0 then
    return "·", "MineOpen"
  end
  return tostring(c), "MineNum" .. c
end

local function pad_cell(glyph)
  -- make roughly 2 columns; emoji may be width 2 already
  local w = vim.fn.strwidth(glyph)
  if w >= CELL_W then
    return glyph
  end
  return glyph .. string.rep(" ", CELL_W - w)
end

local function build_header(st)
  local left = " " .. led3(st.mines - count_flags(st)) .. " "
  local face = " " .. face_char(st) .. " "
  local right = " " .. led3(st.seconds) .. " "
  local mid_pad = st.cols * CELL_W + 2 -- borders
  local inner = left .. face .. right
  -- layout: [mines]....[face]....[time]  within board width
  local board_w = st.cols * CELL_W + 2
  local lw = vim.fn.strwidth(left)
  local fw = vim.fn.strwidth(face)
  local rw = vim.fn.strwidth(right)
  local gap = board_w - lw - fw - rw
  if gap < 2 then
    gap = 2
  end
  local g1 = math.floor(gap / 2)
  local g2 = gap - g1
  local line = left .. string.rep(" ", g1) .. face .. string.rep(" ", g2) .. right
  -- hitboxes for face (display cols)
  local face_c0 = lw + g1 + 1
  local face_c1 = face_c0 + fw - 1
  return line, face_c0, face_c1
end

local function render(buf)
  local st = state_by_buf[buf]
  if not st then
    return
  end
  ensure_hl()

  local lines = {}
  local header, face_c0, face_c1 = build_header(st)
  st.face_c0, st.face_c1 = face_c0, face_c1
  table.insert(lines, header)

  local top = "╔" .. string.rep("═", st.cols * CELL_W) .. "╗"
  local bot = "╚" .. string.rep("═", st.cols * CELL_W) .. "╝"
  table.insert(lines, top)

  for y = 1, st.rows do
    local parts = { "║" }
    for x = 1, st.cols do
      local g = cell_glyph(st, x, y)
      table.insert(parts, pad_cell(g))
    end
    table.insert(parts, "║")
    table.insert(lines, table.concat(parts))
  end
  table.insert(lines, bot)

  local dname = get_diff_label(st.diff_key or config.difficulty)
  st.diff_name = dname
  local status
  if st.status == "won" then
    status = i18n.t("mine_won")
  elseif st.status == "lost" then
    status = i18n.t("mine_lost")
  elseif st.status == "ready" then
    status = i18n.tf("mine_ready", dname, st.cols, st.rows, st.mines)
  else
    status = i18n.tf("mine_playing", dname, st.mines - count_flags(st), st.seconds)
  end
  table.insert(lines, "")
  table.insert(lines, status)
  local b1 = i18n.t("mine_diff_beginner")
  local b2 = i18n.t("mine_diff_intermediate")
  local b3 = i18n.t("mine_diff_expert")
  local br = i18n.t("restart")
  local bl = vim.trim(i18n.t("lang_btn"))
  table.insert(lines, i18n.tf("mine_footer", b1, b2, b3, br, bl))

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- header highlights
  local function hl_line(row0, text, specs)
    -- specs: { {start_disp_col 1-based, end, hl}, ... } OR byte ranges
    for _, sp in ipairs(specs) do
      vim.api.nvim_buf_set_extmark(buf, ns, row0, sp[1], {
        end_row = row0,
        end_col = sp[2],
        hl_group = sp[3],
        hl_mode = "replace",
        priority = 200,
      })
    end
  end

  -- LED left/right + face on header by searching substrings
  local h = lines[1]
  local function mark_sub(row0, line, needle, hl)
    local i = line:find(needle, 1, true)
    if i then
      vim.api.nvim_buf_set_extmark(buf, ns, row0, i - 1, {
        end_col = i - 1 + #needle,
        hl_group = hl,
        hl_mode = "replace",
        priority = 210,
      })
      return true
    end
    return false
  end
  mark_sub(0, h, led3(st.mines - count_flags(st)), "MineLed")
  -- 右侧计时：从右侧找，避免与雷数 LED 相同数字时高亮错位
  do
    local sec = led3(st.seconds)
    local last = nil
    local from = 1
    while true do
      local i = h:find(sec, from, true)
      if not i then
        break
      end
      last = i
      from = i + 1
    end
    if last then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, last - 1, {
        end_col = last - 1 + #sec,
        hl_group = "MineLed",
        hl_mode = "replace",
        priority = 210,
      })
    end
  end
  -- 表情始终黄底（含两侧空格）
  local face = face_char(st)
  if not mark_sub(0, h, " " .. face .. " ", "MineFaceHot") then
    mark_sub(0, h, face, "MineFaceHot")
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    end_col = #h,
    hl_group = "MinePanel",
    hl_mode = "combine",
    priority = 100,
  })

  -- borders
  for _, r in ipairs({ 1, st.rows + 2 }) do
    vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
      end_col = #lines[r + 1],
      hl_group = "MineBorder",
      hl_mode = "replace",
      priority = 150,
    })
  end

  -- cells
  for y = 1, st.rows do
    local row0 = y + 1 -- header=0, top border=1, cells start 2
    local line = lines[row0 + 1]
    local byte_col = #"║"
    for x = 1, st.cols do
      local glyph, hl = cell_glyph(st, x, y)
      local cell = pad_cell(glyph)
      local blen = #cell
      vim.api.nvim_buf_set_extmark(buf, ns, row0, byte_col, {
        end_col = byte_col + blen,
        hl_group = hl,
        hl_mode = "replace",
        priority = 200,
      })
      byte_col = byte_col + blen
    end
    -- side borders
    vim.api.nvim_buf_set_extmark(buf, ns, row0, 0, {
      end_col = #"║",
      hl_group = "MineBorder",
      hl_mode = "replace",
      priority = 150,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, row0, #line - #"║", {
      end_col = #line,
      hl_group = "MineBorder",
      hl_mode = "replace",
      priority = 150,
    })
  end

  -- footer
  local foot1 = #lines - 2
  local foot2 = #lines - 1
  vim.api.nvim_buf_set_extmark(buf, ns, foot1, 0, {
    end_col = #lines[foot1 + 1],
    hl_group = "MineStatus",
    hl_mode = "replace",
  })
  local fl = lines[foot2 + 1]
  vim.api.nvim_buf_set_extmark(buf, ns, foot2, 0, {
    end_col = #fl,
    hl_group = "MineStatus",
    hl_mode = "combine",
  })
  local b1 = i18n.t("mine_diff_beginner")
  local b2 = i18n.t("mine_diff_intermediate")
  local b3 = i18n.t("mine_diff_expert")
  local br = i18n.t("restart")
  local bl = vim.trim(i18n.t("lang_btn"))
  for _, label in ipairs({ b1, b2, b3, br, bl }) do
    mark_sub(foot2, fl, label, "MineBtn")
  end

  -- store footer hit regions (display col)
  st.footer_row = foot2 + 1 -- 1-based line number
  st.footer_hits = {}
  local function add_hit(id, label)
    local bi = fl:find(label, 1, true)
    if bi then
      local prefix = fl:sub(1, bi - 1)
      local dstart = vim.fn.strwidth(prefix) + 1
      local dend = dstart + vim.fn.strwidth(label) - 1
      table.insert(st.footer_hits, { id = id, c0 = dstart, c1 = dend })
    end
  end
  add_hit("beginner", b1)
  add_hit("intermediate", b2)
  add_hit("expert", b3)
  add_hit("restart", br)
  add_hit("lang", bl)

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

M.render = render

local function open_cell(st, buf, x, y)
  if st.status == "won" or st.status == "lost" then
    return
  end
  local i = idx(st, x, y)
  if st.flagged[i] or st.opened[i] then
    return
  end
  if not st.mines_placed then
    place_mines(st, x, y)
    st.status = "playing"
    start_timer(st, buf)
  end
  if st.mine[i] then
    reveal_mines(st, { x, y })
    render(buf)
    return
  end
  flood_open(st, x, y)
  check_win(st)
  render(buf)
end

local function toggle_flag(st, buf, x, y)
  if st.status == "won" or st.status == "lost" then
    return
  end
  local i = idx(st, x, y)
  if st.opened[i] then
    return
  end
  if not st.mines_placed then
    -- allow flagging before first open; still place on first open
  end
  st.flagged[i] = not st.flagged[i]
  if st.status == "ready" then
    st.status = "playing"
    start_timer(st, buf)
  end
  render(buf)
end

---Chord: open neighbors if flags match count
local function chord(st, buf, x, y)
  if st.status ~= "playing" and st.status ~= "ready" then
    return
  end
  local i = idx(st, x, y)
  if not st.opened[i] then
    return
  end
  local need = st.count[i] or 0
  if need <= 0 then
    return
  end
  local flags = 0
  for _, n in ipairs(neighbors(st, x, y)) do
    if st.flagged[idx(st, n[1], n[2])] then
      flags = flags + 1
    end
  end
  if flags ~= need then
    return
  end
  for _, n in ipairs(neighbors(st, x, y)) do
    local ni = idx(st, n[1], n[2])
    if not st.flagged[ni] and not st.opened[ni] then
      if not st.mines_placed then
        place_mines(st, n[1], n[2])
        st.status = "playing"
        start_timer(st, buf)
      end
      if st.mine[ni] then
        reveal_mines(st, { n[1], n[2] })
        render(buf)
        return
      end
      flood_open(st, n[1], n[2])
    end
  end
  check_win(st)
  render(buf)
end

local function restart(st, buf, diff_key)
  new_game(st, diff_key or st.diff_key or config.difficulty)
  render(buf)
end

---Map mouse to board cell
local function mouse_to_cell(st, mouse, win)
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
  local row = mouse.line
  -- rows: 1 header, 2 top border, 3..2+rows cells, then bot border
  local cell_row0 = 3 -- 1-based first cell line
  if row < cell_row0 or row >= cell_row0 + st.rows then
    return nil
  end
  local y = row - cell_row0 + 1
  -- skip left border col (width 1 for ║)
  local inner = vcol - 1
  if inner < 1 then
    return nil
  end
  local x = math.floor((inner - 1) / CELL_W) + 1
  if not in_board(st, x, y) then
    return nil
  end
  return x, y
end

local function mouse_header_face(st, mouse, win)
  if mouse.line ~= 1 then
    return false
  end
  local info = vim.fn.getwininfo(win)[1] or {}
  local textoff = info.textoff or 0
  local wpos = vim.api.nvim_win_get_position(win)
  local vcol = mouse.screencol - wpos[2] - textoff
  if vcol < 1 then
    vcol = mouse.column
  end
  return st.face_c0 and vcol >= st.face_c0 and vcol <= st.face_c1
end

local function mouse_footer(st, mouse, win)
  if not st.footer_row or mouse.line ~= st.footer_row then
    return nil
  end
  local info = vim.fn.getwininfo(win)[1] or {}
  local textoff = info.textoff or 0
  local wpos = vim.api.nvim_win_get_position(win)
  local vcol = mouse.screencol - wpos[2] - textoff
  if vcol < 1 then
    vcol = mouse.column
  end
  for _, h in ipairs(st.footer_hits or {}) do
    if vcol >= h.c0 and vcol <= h.c1 then
      return h.id
    end
  end
  return nil
end

local function apply_win_opts(win)
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].list = false
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].statuscolumn = ""
    vim.wo[win].colorcolumn = ""
  end)
  if vim.o.mouse == "" then
    vim.o.mouse = "a"
  end
end

---隐藏光标（guicursor 为全局选项，进出 buffer 时恢复）
local function hide_cursor(buf)
  vim.api.nvim_set_hl(0, "MineNoCursor", { blend = 100, nocombine = true })
  local prev = nil
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      prev = vim.o.guicursor
      vim.o.guicursor = "a:MineNoCursor"
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave", "BufWipeout" }, {
    buffer = buf,
    callback = function()
      if prev ~= nil then
        vim.o.guicursor = prev
        prev = nil
      end
    end,
  })
  prev = vim.o.guicursor
  vim.o.guicursor = "a:MineNoCursor"
end

---禁止在扫雷 buffer 里选中字符（键盘 Visual / 鼠标拖选）
local function disable_selection(buf)
  local block = { "n", "v", "x", "s", "o" }
  local nops = {
    "v",
    "V",
    "<C-v>",
    "gv",
    "gh",
    "gH",
    "g<C-h>",
    "<Select>",
    "<S-Left>",
    "<S-Right>",
    "<S-Up>",
    "<S-Down>",
    "<S-Home>",
    "<S-End>",
    "<S-PageUp>",
    "<S-PageDown>",
  }
  for _, lhs in ipairs(nops) do
    pcall(vim.keymap.set, block, lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "mine: no select",
    })
  end
  -- 拖选相关鼠标键：在 Visual 里也吞掉默认选区行为（具体游戏逻辑在 n 等模式另绑）
  for _, lhs in ipairs({
    "<LeftDrag>",
    "<RightDrag>",
    "<LeftRelease>",
    "<RightRelease>",
    "<2-LeftMouse>",
    "<3-LeftMouse>",
    "<4-LeftMouse>",
    "<C-LeftMouse>",
    "<A-LeftMouse>",
    "<S-LeftMouse>",
    "<S-RightMouse>",
    "<S-LeftDrag>",
    "<S-RightDrag>",
  }) do
    pcall(vim.keymap.set, { "v", "x", "s" }, lhs, function()
      pcall(vim.cmd, "normal! \27")
      return ""
    end, { buffer = buf, silent = true, nowait = true, expr = false })
  end

  -- 一旦进入可视/选择模式立即退回 Normal
  vim.api.nvim_create_autocmd("ModeChanged", {
    buffer = buf,
    desc = "mine: forbid visual selection",
    callback = function()
      local m = vim.fn.mode()
      if m:match("[vV\x16sS\x13]") then
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == buf then
            pcall(vim.cmd, "normal! \27")
          end
        end)
      end
    end,
  })
end

function M.open(opts)
  opts = opts or {}
  ensure_hl()
  math.randomseed(os.time() % 100000 + (vim.uv.hrtime() % 100000))

  local diff = opts.difficulty or config.difficulty or "beginner"
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, "mine://game")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "mine"
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(win, buf)
  apply_win_opts(win)
  disable_selection(buf)
  hide_cursor(buf)

  local st = {
    sel_x = 1,
    sel_y = 1,
  }
  state_by_buf[buf] = st
  new_game(st, diff)

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      local s = state_by_buf[buf]
      if s then
        fn(s)
      end
    end, { buffer = buf, silent = true, nowait = true, desc = "mine: " .. (desc or "") })
  end

  map("q", function(s)
    stop_timer(s)
    pcall(vim.cmd, "bdelete!")
  end, "quit")
  map("r", function(s)
    restart(s, buf)
  end, "restart")
  map("1", function(s)
    restart(s, buf, "beginner")
  end, "beginner")
  map("2", function(s)
    restart(s, buf, "intermediate")
  end, "intermediate")
  map("3", function(s)
    restart(s, buf, "expert")
  end, "expert")
  map("u", function(s)
    i18n.toggle()
    s.diff_name = get_diff_label(s.diff_key or config.difficulty)
    render(buf)
  end, "lang")
  map("U", function(s)
    i18n.toggle()
    s.diff_name = get_diff_label(s.diff_key or config.difficulty)
    render(buf)
  end, "lang")
  map("?", function()
    vim.notify(i18n.t("mine_help"), vim.log.levels.INFO)
  end, "help")
  map("h", function(s)
    s.sel_x = clamp((s.sel_x or 1) - 1, 1, s.cols)
  end, "left")
  map("l", function(s)
    s.sel_x = clamp((s.sel_x or 1) + 1, 1, s.cols)
  end, "right")
  map("k", function(s)
    s.sel_y = clamp((s.sel_y or 1) - 1, 1, s.rows)
  end, "up")
  map("j", function(s)
    s.sel_y = clamp((s.sel_y or 1) + 1, 1, s.rows)
  end, "down")
  map("<Left>", function(s)
    s.sel_x = clamp((s.sel_x or 1) - 1, 1, s.cols)
  end, "left")
  map("<Right>", function(s)
    s.sel_x = clamp((s.sel_x or 1) + 1, 1, s.cols)
  end, "right")
  map("<Up>", function(s)
    s.sel_y = clamp((s.sel_y or 1) - 1, 1, s.rows)
  end, "up")
  map("<Down>", function(s)
    s.sel_y = clamp((s.sel_y or 1) + 1, 1, s.rows)
  end, "down")
  map("<Space>", function(s)
    open_cell(s, buf, s.sel_x or 1, s.sel_y or 1)
  end, "open")
  map("m", function(s)
    toggle_flag(s, buf, s.sel_x or 1, s.sel_y or 1)
  end, "flag")
  map("c", function(s)
    chord(s, buf, s.sel_x or 1, s.sel_y or 1)
  end, "chord")

  local modes = { "n", "v", "x", "s" }

  -- Windows 扫雷：左右键同时按下 = 弦开（chord）
  -- 状态：btn_left / btn_right / chorded / pending_open{x,y}
  local function btn_state(st)
    st.btn = st.btn or { left = false, right = false, chorded = false, px = nil, py = nil }
    return st.btn
  end

  local function current_cell(st)
    local mouse = vim.fn.getmousepos()
    local w = vim.fn.bufwinid(buf)
    if mouse.winid ~= w then
      return nil, nil, mouse, w
    end
    local x, y = mouse_to_cell(st, mouse, w)
    return x, y, mouse, w
  end

  local function do_chord_at(st, x, y)
    if not x then
      return
    end
    st.sel_x, st.sel_y = x, y
    local b = btn_state(st)
    b.chorded = true
    b.px, b.py = nil, nil -- 不再单独开格/插旗
    st.pressing = false
    chord(st, buf, x, y)
  end

  local function force_normal()
    local m = vim.fn.mode()
    if m:match("[vV\x16sS\x13]") then
      pcall(vim.cmd, "normal! \27")
    end
  end

  vim.keymap.set(modes, "<LeftMouse>", function()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    force_normal()
    local x, y, mouse, w = current_cell(st)
    if not w or mouse.winid ~= w then
      return ""
    end
    -- UI 按钮仍立即响应
    if mouse_header_face(st, mouse, w) then
      restart(st, buf)
      return ""
    end
    local fid = mouse_footer(st, mouse, w)
    if fid == "beginner" or fid == "intermediate" or fid == "expert" then
      restart(st, buf, fid)
      return ""
    end
    if fid == "restart" then
      restart(st, buf)
      return ""
    end
    if fid == "lang" then
      i18n.toggle()
      st.diff_name = get_diff_label(st.diff_key or config.difficulty)
      render(buf)
      return ""
    end

    local b = btn_state(st)
    b.left = true
    if x then
      st.sel_x, st.sel_y = x, y
      -- 右键已按下 → 左右同时 → 弦开
      if b.right then
        do_chord_at(st, x, y)
        return ""
      end
      -- 单独左键：记录，等松开再开格（以便中途按下右键改弦开）
      b.chorded = false
      b.px, b.py = x, y
      st.pressing = true
      render(buf)
    end
    return ""
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set(modes, "<LeftRelease>", function()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    local b = btn_state(st)
    local px, py = b.px, b.py
    local was_chorded = b.chorded
    b.left = false
    st.pressing = false
    -- 仅左键完整点击且未弦开 → 开格
    if not was_chorded and not b.right and px and py then
      b.px, b.py = nil, nil
      open_cell(st, buf, px, py)
    else
      b.px, b.py = nil, nil
      if not b.right then
        b.chorded = false
      end
      render(buf)
    end
    return ""
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set(modes, "<RightMouse>", function()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    force_normal()
    local x, y = current_cell(st)
    local b = btn_state(st)
    b.right = true
    if x then
      st.sel_x, st.sel_y = x, y
      -- 左键已按下 → 弦开
      if b.left then
        do_chord_at(st, x, y)
        return ""
      end
      -- 单独右键：立即插旗（Windows 行为）
      b.chorded = false
      toggle_flag(st, buf, x, y)
    end
    return ""
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set(modes, "<RightRelease>", function()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    local b = btn_state(st)
    b.right = false
    if not b.left then
      b.chorded = false
      b.px, b.py = nil, nil
    end
    return ""
  end, { buffer = buf, silent = true, nowait = true })

  -- 中键仍可弦开
  vim.keymap.set(modes, "<MiddleMouse>", function()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    local x, y = current_cell(st)
    if x then
      st.sel_x, st.sel_y = x, y
      chord(st, buf, x, y)
    end
    return ""
  end, { buffer = buf, silent = true, nowait = true })

  -- 拖动时若已是双键，随鼠标位置更新弦开目标（Windows 会跟踪格子）
  vim.keymap.set(modes, "<LeftDrag>", function()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    local b = btn_state(st)
    local x, y = current_cell(st)
    if x and b.left and b.right and not b.chorded then
      do_chord_at(st, x, y)
    elseif x and b.left and not b.right and not b.chorded then
      b.px, b.py = x, y
      st.sel_x, st.sel_y = x, y
    end
    return ""
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set(modes, "<RightDrag>", function()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    local b = btn_state(st)
    local x, y = current_cell(st)
    if x and b.left and b.right and not b.chorded then
      do_chord_at(st, x, y)
    end
    return ""
  end, { buffer = buf, silent = true, nowait = true })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local s = state_by_buf[buf]
      if s then
        stop_timer(s)
      end
      state_by_buf[buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("MineHl_" .. buf, { clear = true }),
    callback = function()
      hl_ready = false
      vim.g.mine_hl_ready = false
      ensure_hl()
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end,
  })

  render(buf)
  return buf
end

---@param user? MineConfig
function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  if user and user.difficulties then
    config.difficulties = vim.tbl_deep_extend("force", DIFFICULTIES, user.difficulties)
  end
  hl_ready = false
end

---解析难度参数（英文 / 中文别名）
---@param arg? string
---@return string
function M.resolve_difficulty(arg)
  if not arg or arg == "" then
    return config.difficulty
  end
  if arg == "beginner" or arg == "intermediate" or arg == "expert" then
    return arg
  end
  local map = { ["初级"] = "beginner", ["中级"] = "intermediate", ["高级"] = "expert" }
  return map[arg] or config.difficulty
end

function M.config()
  return config
end

return M
