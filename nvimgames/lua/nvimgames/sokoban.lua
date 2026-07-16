---@mod nvimgames.sokoban 推箱子（参考 game/sokoban/c_app）
local M = {}

local ns = vim.api.nvim_create_namespace("sokoban")
local state_by_buf = {} ---@type table<integer, table>
local levels_cache = nil ---@type table[]|nil
local hl_ready = false

local default_config = {
  levels_file = nil, -- nil = plugin data/levels.json
  ---进度文件；nil = stdpath('data')/nvimgames/sokoban.json
  state_file = nil,
  ---是否记住上次关卡（无参 :Sokoban 时恢复）
  remember_level = true,
}

local config = vim.deepcopy(default_config)

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function levels_path()
  if config.levels_file and config.levels_file ~= "" then
    return config.levels_file
  end
  return plugin_root() .. "/data/levels.json"
end

local function state_path()
  if config.state_file and config.state_file ~= "" then
    return config.state_file
  end
  return vim.fn.stdpath("data") .. "/nvimgames/sokoban.json"
end

---@return integer|nil
local function load_saved_level()
  if not config.remember_level then
    return nil
  end
  local path = state_path()
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local text = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    return nil
  end
  local n = tonumber(data.level)
  if n and n >= 1 then
    return math.floor(n)
  end
  return nil
end

---@param index integer
local function save_level(index)
  if not config.remember_level then
    return
  end
  index = math.floor(tonumber(index) or 1)
  if index < 1 then
    index = 1
  end
  local path = state_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local ok, encoded = pcall(vim.json.encode, { level = index })
  if not ok or not encoded then
    return
  end
  pcall(vim.fn.writefile, { encoded }, path)
end

local function ensure_hl()
  if hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  -- 彩色图块（深色主题友好）
  vim.api.nvim_set_hl(0, "SokobanWall", { fg = "#585b70", bg = "#45475a", bold = true })
  vim.api.nvim_set_hl(0, "SokobanFloor", { fg = "#6c7086", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "SokobanGoal", { fg = "#f9e2af", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "SokobanBox", { fg = "#1e1e2e", bg = "#fab387", bold = true })
  vim.api.nvim_set_hl(0, "SokobanBoxGoal", { fg = "#1e1e2e", bg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "SokobanPlayer", { fg = "#1e1e2e", bg = "#89b4fa", bold = true })
  vim.api.nvim_set_hl(0, "SokobanPlayerGoal", { fg = "#1e1e2e", bg = "#cba6f7", bold = true })
  vim.api.nvim_set_hl(0, "SokobanOutside", { fg = "#11111b", bg = "#11111b" })
  vim.api.nvim_set_hl(0, "SokobanStatus", { fg = "#cdd6f4", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "SokobanTitle", { fg = "#89b4fa", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "SokobanWin", { fg = "#1e1e2e", bg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "SokobanBtn", { fg = "#1e1e2e", bg = "#89b4fa", bold = true })
  hl_ready = true
end

local function load_levels()
  if levels_cache then
    return levels_cache
  end
  local path = levels_path()
  if vim.fn.filereadable(path) == 0 then
    vim.notify("sokoban: 找不到关卡文件 " .. path, vim.log.levels.ERROR)
    levels_cache = {}
    return levels_cache
  end
  local text = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    vim.notify("sokoban: 关卡 JSON 解析失败", vim.log.levels.ERROR)
    levels_cache = {}
    return levels_cache
  end
  levels_cache = data
  return levels_cache
end

local function is_box_at(st, x, y)
  for _, b in ipairs(st.boxes) do
    if b.x == x and b.y == y then
      return true
    end
  end
  return false
end

local function move_box(st, fx, fy, tx, ty)
  for _, b in ipairs(st.boxes) do
    if b.x == fx and b.y == fy then
      b.x, b.y = tx, ty
      return
    end
  end
end

local function cell_base(st, x, y)
  if x < 0 or y < 0 or x >= st.w or y >= st.h then
    return "#"
  end
  return st.cells[y * st.w + x + 1] -- 1-based lua array
end

local function is_goal(st, x, y)
  return cell_base(st, x, y) == "."
end

---显示字符（与 c_app game_cell_at 一致）
local function cell_at(st, x, y)
  if x < 0 or y < 0 or x >= st.w or y >= st.h then
    return "#"
  end
  local base = cell_base(st, x, y)
  if st.player.x == x and st.player.y == y then
    return base == "." and "+" or "@"
  end
  if is_box_at(st, x, y) then
    return base == "." and "*" or "$"
  end
  return base
end

local function check_win(st)
  if #st.boxes == 0 then
    st.won = true
    return true
  end
  for _, b in ipairs(st.boxes) do
    if not is_goal(st, b.x, b.y) then
      st.won = false
      return false
    end
  end
  st.won = true
  return true
end

local function hist_push(st, player_before, had_box, box_from, box_to)
  table.insert(st.hist, {
    player = { x = player_before.x, y = player_before.y },
    had_box = had_box and true or false,
    box_from = box_from and { x = box_from.x, y = box_from.y } or nil,
    box_to = box_to and { x = box_to.x, y = box_to.y } or nil,
  })
end

local function try_move(st, dx, dy)
  if st.won then
    return false
  end
  local nx, ny = st.player.x + dx, st.player.y + dy
  if nx < 0 or ny < 0 or nx >= st.w or ny >= st.h then
    return false
  end
  if cell_base(st, nx, ny) == "#" then
    return false
  end

  local player_before = { x = st.player.x, y = st.player.y }

  if is_box_at(st, nx, ny) then
    local bx, by = nx + dx, ny + dy
    if bx < 0 or by < 0 or bx >= st.w or by >= st.h then
      return false
    end
    if cell_base(st, bx, by) == "#" then
      return false
    end
    if is_box_at(st, bx, by) then
      return false
    end
    move_box(st, nx, ny, bx, by)
    st.player.x, st.player.y = nx, ny
    st.moves = st.moves + 1
    hist_push(st, player_before, true, { x = nx, y = ny }, { x = bx, y = by })
    check_win(st)
    return true
  end

  -- 纯移动不计步数（与 c_app 一致）
  st.player.x, st.player.y = nx, ny
  hist_push(st, player_before, false, nil, nil)
  return true
end

---撤销：跳过纯移动，回到上一次推箱前（与 c_app 一致）
local function undo(st)
  if st.won then
    return
  end
  if #st.hist == 0 then
    return
  end
  local popped_box = false
  while #st.hist > 0 and not popped_box do
    local h = table.remove(st.hist)
    if h.had_box then
      move_box(st, h.box_to.x, h.box_to.y, h.box_from.x, h.box_from.y)
      st.player.x, st.player.y = h.player.x, h.player.y
      st.moves = math.max(0, st.moves - 1)
      popped_box = true
    else
      st.player.x, st.player.y = h.player.x, h.player.y
    end
  end
  st.won = false
end

local function load_level(st, levels, index)
  if index < 1 or index > #levels then
    return false
  end
  local lvl = levels[index]
  local puzzle = lvl.puzzle or {}
  local h = #puzzle
  local w = 0
  for _, row in ipairs(puzzle) do
    local len = vim.fn.strchars(row)
    if len > w then
      w = len
    end
  end
  if w < 1 then
    w = 1
  end
  if h < 1 then
    h = 1
  end

  local cells = {}
  for i = 1, w * h do
    cells[i] = "-"
  end
  local boxes, goals = {}, {}
  local player = { x = 0, y = 0 }

  for y = 0, h - 1 do
    local row = puzzle[y + 1] or ""
    local len = vim.fn.strchars(row)
    for x = 0, w - 1 do
      local ch = x < len and vim.fn.strcharpart(row, x, 1) or "-"
      local base = "-"
      if ch == "#" then
        base = "#"
      elseif ch == "." then
        base = "."
        table.insert(goals, { x = x, y = y })
      elseif ch == "-" or ch == " " then
        base = "-"
      elseif ch == "$" then
        base = "-"
        table.insert(boxes, { x = x, y = y })
      elseif ch == "*" then
        base = "."
        table.insert(boxes, { x = x, y = y })
        table.insert(goals, { x = x, y = y })
      elseif ch == "@" then
        base = "-"
        player.x, player.y = x, y
      elseif ch == "+" then
        base = "."
        player.x, player.y = x, y
        table.insert(goals, { x = x, y = y })
      else
        base = "-"
      end
      cells[y * w + x + 1] = base
    end
  end

  st.w, st.h = w, h
  st.cells = cells
  st.boxes = boxes
  st.goals = goals
  st.player = player
  st.moves = 0
  st.won = false
  st.level_index = index
  st.level_name = lvl.name or tostring(index)
  st.hist = {}
  return true
end

---视觉：每格两列宽，彩色图块
local CELL_W = 2

-- 汉字图块（配合 highlight 上色，宽约 2 列）
local GLYPH = {
  ["#"] = { "墙", "SokobanWall" },
  ["-"] = { "  ", "SokobanFloor" },
  ["."] = { "◎", "SokobanGoal" },
  ["$"] = { "箱", "SokobanBox" },
  ["*"] = { "箱", "SokobanBoxGoal" },
  ["@"] = { "人", "SokobanPlayer" },
  ["+"] = { "人", "SokobanPlayerGoal" },
}

local function pad2(s)
  local w = vim.fn.strwidth(s)
  if w >= CELL_W then
    return s
  end
  return s .. string.rep(" ", CELL_W - w)
end

local function glyph_of(ch)
  local g = GLYPH[ch] or GLYPH["-"]
  return pad2(g[1]), g[2]
end

local function render(buf)
  local st = state_by_buf[buf]
  if not st then
    return
  end
  ensure_hl()

  local title = string.format(
    " 推箱子  关卡 %d/%d  %s  步数:%d  %s",
    st.level_index,
    st.level_count,
    st.level_name,
    st.moves,
    st.won and "★ 过关！" or ""
  )
  local help = " hjkl/方向键移动  z撤销  r重开  n/p下/上关  g跳关  q退出 "

  local lines = { title, "" }
  local row_marks = {} -- {row0, byte_start, byte_end, hl}

  -- title
  table.insert(row_marks, { 0, 0, #title, st.won and "SokobanWin" or "SokobanTitle" })

  for y = 0, st.h - 1 do
    local parts = {}
    local byte_col = 0
    local line_marks = {}
    for x = 0, st.w - 1 do
      local ch = cell_at(st, x, y)
      local text, hl = glyph_of(ch)
      table.insert(parts, text)
      local blen = #text
      table.insert(line_marks, { byte_col, byte_col + blen, hl })
      byte_col = byte_col + blen
    end
    local line = table.concat(parts)
    table.insert(lines, line)
    local row0 = #lines - 1
    for _, m in ipairs(line_marks) do
      table.insert(row_marks, { row0, m[1], m[2], m[3] })
    end
  end

  table.insert(lines, "")
  table.insert(lines, help)
  table.insert(row_marks, { #lines - 1, 0, #help, "SokobanStatus" })

  if st.won then
    local tip = " ★ 过关！按 Space 进入下一关，或 r 重玩本关 "
    table.insert(lines, tip)
    table.insert(row_marks, { #lines - 1, 0, #tip, "SokobanWin" })
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, m in ipairs(row_marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], {
      end_row = m[1],
      end_col = m[3],
      hl_group = m[4],
      hl_mode = "replace",
      priority = 200,
      strict = false,
    })
  end

  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function disable_selection(buf)
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv", "gh", "gH" }) do
    pcall(vim.keymap.set, { "n", "v", "x", "s" }, lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
    })
  end
  vim.api.nvim_create_autocmd("ModeChanged", {
    buffer = buf,
    callback = function()
      local m = vim.fn.mode()
      if m:match("[vV\x16sS]") then
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == buf then
            pcall(vim.cmd, "normal! \27")
          end
        end)
      end
    end,
  })
end

local function apply_win(win)
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].list = false
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].statuscolumn = ""
  end)
end

---隐藏光标（guicursor 为全局选项，进出 buffer 时恢复）
local function hide_cursor(buf)
  vim.api.nvim_set_hl(0, "SokobanNoCursor", { blend = 100, nocombine = true })
  local prev = nil
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      prev = vim.o.guicursor
      vim.o.guicursor = "a:SokobanNoCursor"
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
  -- 当前已在该 buffer 内时立即生效
  prev = vim.o.guicursor
  vim.o.guicursor = "a:SokobanNoCursor"
end

local function goto_level(st, buf, index)
  local levels = load_levels()
  if not load_level(st, levels, index) then
    vim.notify("sokoban: 无效关卡 " .. tostring(index), vim.log.levels.WARN)
    return
  end
  st.level_count = #levels
  save_level(st.level_index)
  render(buf)
end

function M.open(opts)
  opts = opts or {}
  ensure_hl()
  local levels = load_levels()
  if #levels == 0 then
    return
  end

  -- 显式指定关卡 > 上次进度 > 第 1 关
  local index = opts.level
  if index == nil then
    index = load_saved_level() or 1
  elseif type(index) == "string" then
    index = tonumber(index) or load_saved_level() or 1
  end
  index = math.max(1, math.min(#levels, index))
  save_level(index)

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, "sokoban://game")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sokoban"
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(win, buf)
  apply_win(win)
  disable_selection(buf)
  hide_cursor(buf)

  local st = {
    level_count = #levels,
  }
  state_by_buf[buf] = st
  load_level(st, levels, index)

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      local s = state_by_buf[buf]
      if s then
        fn(s)
        if vim.api.nvim_buf_is_valid(buf) then
          render(buf)
        end
      end
    end, { buffer = buf, silent = true, nowait = true, desc = "sokoban: " .. (desc or "") })
  end

  local function move(dx, dy)
    return function(s)
      if s.won then
        return
      end
      try_move(s, dx, dy)
    end
  end

  local function next_level(s)
    if s.level_index < s.level_count then
      goto_level(s, buf, s.level_index + 1)
    else
      vim.notify("sokoban: 已是最后一关，恭喜通关！", vim.log.levels.INFO)
    end
  end

  map("h", move(-1, 0), "left")
  map("l", move(1, 0), "right")
  map("k", move(0, -1), "up")
  map("j", move(0, 1), "down")
  map("<Left>", move(-1, 0), "left")
  map("<Right>", move(1, 0), "right")
  map("<Up>", move(0, -1), "up")
  map("<Down>", move(0, 1), "down")
  map("z", function(s)
    undo(s)
  end, "undo")
  map("r", function(s)
    goto_level(s, buf, s.level_index)
  end, "reset")
  map("n", next_level, "next")
  map("p", function(s)
    if s.level_index > 1 then
      goto_level(s, buf, s.level_index - 1)
    else
      vim.notify("sokoban: 已是第一关", vim.log.levels.INFO)
    end
  end, "prev")
  map("g", function(s)
    local input = vim.fn.input(string.format("跳转到关卡 (1-%d): ", s.level_count))
    local n = tonumber(input)
    if n then
      goto_level(s, buf, n)
    end
  end, "goto")
  -- 过关后 Space 进入下一关
  map("<Space>", function(s)
    if s.won then
      next_level(s)
    end
  end, "next when won")
  map("q", function(s)
    if s and s.level_index then
      save_level(s.level_index)
    end
    state_by_buf[buf] = nil
    pcall(vim.cmd, "bdelete!")
  end, "quit")
  map("?", function()
    vim.notify(
      "推箱子\nhjkl 移动  z 撤销  r 重开  n/p 下/上关  g 跳关\n过关后 Space 下一关  q 退出\n箱=箱子  ◎=目标  人=玩家  墙=墙",
      vim.log.levels.INFO
    )
  end, "help")

  -- 过关后自动提示下一关：在 move 后 check；n 已绑定

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local s = state_by_buf[buf]
      if s and s.level_index then
        save_level(s.level_index)
      end
      state_by_buf[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("SokobanHl_" .. buf, { clear = true }),
    callback = function()
      hl_ready = false
      ensure_hl()
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end,
  })

  render(buf)
  return buf
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  levels_cache = nil
  hl_ready = false
end

function M.config()
  return config
end

return M
