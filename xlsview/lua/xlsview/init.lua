---@mod xlsview
--- 打开 xlsx 进入表格预览：样式 / 多工作表
local config = require("xlsview.config")
local extract_mod = require("xlsview.extract")
local render_mod = require("xlsview.render")
local highlight = require("xlsview.highlight")

local M = {}

--- Neovim 0.9 只有 vim.loop；0.10+ 为 vim.uv
local uv = vim.uv or vim.loop

---@type table<integer, table>
local states = {}
local auto_installed = false

local function is_xls_path(path)
  return extract_mod.is_supported(path)
end

local function get_state(buf)
  return states[buf]
end

local function win_width(buf)
  local w = vim.fn.bufwinid(buf)
  if w ~= -1 and vim.api.nvim_win_is_valid(w) then
    return math.max(20, vim.api.nvim_win_get_width(w))
  end
  return math.max(20, vim.o.columns - 2)
end

local function apply_winopts(win, cfg)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for k, v in pairs(cfg.winopts or {}) do
    pcall(function()
      vim.wo[win][k] = v
    end)
  end
  -- 宽表横向滚动
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].sidescroll = math.max(1, vim.wo[win].sidescroll or 1)
    vim.wo[win].sidescrolloff = math.max(2, vim.wo[win].sidescrolloff or 0)
  end)
end

local function do_render(st)
  if not st or not st.buf or not vim.api.nvim_buf_is_valid(st.buf) or not st.data then
    return
  end
  local cfg = config.get()
  local width = win_width(st.buf)
  st.width = width
  local keep_r, keep_c = st.cell_r, st.cell_c
  local result = render_mod.render(st.data, {
    width = width,
    cfg = cfg,
    sheet_index = st.sheet_index or 1,
  })
  st.result = result
  render_mod.apply(st.buf, result)
  -- 重绑跳格（防止旧 buffer 映射丢失）
  pcall(function()
    st.maps_version = 0
    attach_maps(st)
  end)
  -- 重绘后恢复格点（若有）
  if keep_r and keep_c and result.nav then
    vim.schedule(function()
      if get_state(st.buf) == st then
        M._goto_cell(st, keep_r, keep_c)
      end
    end)
  end
end

local function attach_maps(st)
  local buf = st.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- 每次都重绑跳格键，避免旧映射残留
  local opts = { buffer = buf, silent = true, nowait = true, noremap = true }

  pcall(function()
    if not tostring(vim.o.mouse or ""):find("a", 1, true) then
      vim.o.mouse = "a"
    end
  end)

  local function with_st(fn)
    return function()
      local s = get_state(buf)
      if s then
        fn(s)
      end
    end
  end

  vim.keymap.set("n", "q", with_st(function(s)
    M.close(s.buf)
  end), opts)
  vim.keymap.set("n", "<Esc>", with_st(function(s)
    M.close(s.buf)
  end), opts)
  vim.keymap.set("n", "r", with_st(function(s)
    M.refresh(s.buf, true)
  end), opts)

  local function next_sheet(s, delta)
    local n = s.data and s.data.sheet_count or #(s.data and s.data.sheets or {})
    if n < 1 then
      return
    end
    local i = (s.sheet_index or 1) + delta
    if i < 1 then
      i = n
    elseif i > n then
      i = 1
    end
    s.sheet_index = i
    s.cell_r, s.cell_c = 1, 1
    do_render(s)
    M._goto_cell(s, 1, 1)
    -- 换表状态写在标题行即可，避免 echo 触发 hit-enter
  end

  vim.keymap.set("n", "n", with_st(function(s)
    next_sheet(s, 1)
  end), opts)
  vim.keymap.set("n", "]", with_st(function(s)
    next_sheet(s, 1)
  end), opts)
  vim.keymap.set("n", "gt", with_st(function(s)
    next_sheet(s, 1)
  end), opts)
  vim.keymap.set("n", "p", with_st(function(s)
    next_sheet(s, -1)
  end), opts)
  vim.keymap.set("n", "[", with_st(function(s)
    next_sheet(s, -1)
  end), opts)
  vim.keymap.set("n", "gT", with_st(function(s)
    next_sheet(s, -1)
  end), opts)

  for d = 1, 9 do
    vim.keymap.set("n", tostring(d), with_st(function(s)
      local n = s.data and s.data.sheet_count or 0
      if d <= n then
        s.sheet_index = d
        s.cell_r, s.cell_c = 1, 1
        do_render(s)
        M._goto_cell(s, 1, 1)
      end
    end), opts)
  end

  vim.keymap.set("n", "?", function()
    require("xlsview.help").toggle_float()
  end, opts)

  vim.keymap.set("n", "L", function()
    M.toggle_ui_lang()
  end, vim.tbl_extend("force", opts, { desc = "xlsview: toggle UI language" }))

  -- 宽表纯横向滚动（不跳格）
  local function hscroll(cols)
    return function()
      local win = vim.fn.bufwinid(buf)
      if win == -1 then
        return
      end
      pcall(vim.api.nvim_win_call, win, function()
        if cols > 0 then
          vim.cmd("normal! " .. cols .. "zl")
        elseif cols < 0 then
          vim.cmd("normal! " .. (-cols) .. "zh")
        end
      end)
    end
  end
  vim.keymap.set("n", "zl", hscroll(8), vim.tbl_extend("force", opts, { desc = "xlsview: scroll right" }))
  vim.keymap.set("n", "zh", hscroll(-8), vim.tbl_extend("force", opts, { desc = "xlsview: scroll left" }))
  vim.keymap.set("n", "zL", hscroll(24), vim.tbl_extend("force", opts, { desc = "xlsview: scroll right more" }))
  vim.keymap.set("n", "zH", hscroll(-24), vim.tbl_extend("force", opts, { desc = "xlsview: scroll left more" }))

  -- Excel 风格单元格导航
  vim.keymap.set("n", "<Right>", with_st(function(s)
    M._move_cell(s, 0, 1, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell right" }))
  vim.keymap.set("n", "<Left>", with_st(function(s)
    M._move_cell(s, 0, -1, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell left" }))
  vim.keymap.set("n", "<Down>", with_st(function(s)
    M._move_cell(s, 1, 0, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell down" }))
  vim.keymap.set("n", "<Up>", with_st(function(s)
    M._move_cell(s, -1, 0, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell up" }))
  -- Tab / S-Tab / C-i：下一/上一格，行末换行（Excel）
  local function tab_next()
    local s = get_state(buf)
    if s then
      M._move_cell(s, 0, 1, true)
    end
  end
  local function tab_prev()
    local s = get_state(buf)
    if s then
      M._move_cell(s, 0, -1, true)
    end
  end
  vim.keymap.set("n", "<Tab>", tab_next, vim.tbl_extend("force", opts, { desc = "xlsview: next cell" }))
  vim.keymap.set("n", "<C-i>", tab_next, vim.tbl_extend("force", opts, { desc = "xlsview: next cell" }))
  vim.keymap.set("n", "<S-Tab>", tab_prev, vim.tbl_extend("force", opts, { desc = "xlsview: prev cell" }))
  -- 行内首尾单元格
  vim.keymap.set("n", "0", with_st(function(s)
    local r = M._current_cell(s)
    M._goto_cell(s, r or s.cell_r or 1, 1)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: first cell in row" }))
  vim.keymap.set("n", "$", with_st(function(s)
    local nav = s.result and s.result.nav
    if not nav then
      return
    end
    local r = M._current_cell(s)
    M._goto_cell(s, r or s.cell_r or 1, nav.ncols)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: last cell in row" }))
  -- hjkl 也可跳格
  vim.keymap.set("n", "h", with_st(function(s)
    M._move_cell(s, 0, -1, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell left" }))
  vim.keymap.set("n", "l", with_st(function(s)
    M._move_cell(s, 0, 1, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell right" }))
  vim.keymap.set("n", "j", with_st(function(s)
    M._move_cell(s, 1, 0, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell down" }))
  vim.keymap.set("n", "k", with_st(function(s)
    M._move_cell(s, -1, 0, false)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell up" }))

  vim.keymap.set("n", "<CR>", with_st(function(s)
    M._activate(s)
  end), opts)

  local function on_click()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
        local s = get_state(buf)
        if s then
          -- 先尝试点标签；否则同步当前单元格
          M._activate(s)
          local r, c = M._current_cell(s)
          if r and c then
            s.cell_r, s.cell_c = r, c
            M._goto_cell(s, r, c)
          end
        end
      end
    end)
  end
  vim.keymap.set("n", "<LeftRelease>", on_click, opts)
  vim.keymap.set("n", "<2-LeftMouse>", on_click, opts)

  -- Ctrl-v：单元格块选（先选中整格，方向键按格扩展）
  vim.keymap.set("n", "<C-v>", with_st(function(s)
    M._vblock_start(s)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell block select" }))
  vim.keymap.set("n", "<C-q>", with_st(function(s)
    M._vblock_start(s)
  end), vim.tbl_extend("force", opts, { desc = "xlsview: cell block select" }))

  -- 块选中：方向键 / hjkl 一次扩展一行或一列格
  local xopts = vim.tbl_extend("force", opts, { desc = "xlsview: extend cell block" })
  local function xext(dr, dc)
    return function()
      local s = get_state(buf)
      if s and s.vblock then
        M._vblock_extend(s, dr, dc)
      else
        -- 非单元格块选时保持默认
        vim.cmd("normal! " .. (dr == 1 and "j" or dr == -1 and "k" or dc == 1 and "l" or "h"))
      end
    end
  end
  vim.keymap.set("x", "<Right>", xext(0, 1), xopts)
  vim.keymap.set("x", "<Left>", xext(0, -1), xopts)
  vim.keymap.set("x", "<Down>", xext(1, 0), xopts)
  vim.keymap.set("x", "<Up>", xext(-1, 0), xopts)
  vim.keymap.set("x", "l", xext(0, 1), xopts)
  vim.keymap.set("x", "h", xext(0, -1), xopts)
  vim.keymap.set("x", "j", xext(1, 0), xopts)
  vim.keymap.set("x", "k", xext(-1, 0), xopts)
  vim.keymap.set("x", "<Tab>", xext(0, 1), xopts)
  vim.keymap.set("x", "<S-Tab>", xext(0, -1), xopts)

  -- 退出块选时清状态
  vim.keymap.set("x", "<Esc>", function()
    local s = get_state(buf)
    if s then
      s.vblock = nil
    end
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "n", false)
  end, vim.tbl_extend("force", opts, { desc = "xlsview: exit visual" }))

  -- 可视选择复制：按单元格导出文本（忽略 │ 边框），Excel 风格
  vim.keymap.set("x", "y", function()
    local s = get_state(buf)
    if s then
      M._yank_visual(s)
      if s then
        s.vblock = nil
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "xlsview: yank cells" }))
  vim.keymap.set("x", "<C-c>", function()
    local s = get_state(buf)
    if s then
      M._yank_visual(s)
      if s then
        s.vblock = nil
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "xlsview: yank cells" }))
end

---数据行索引：光标所在行或最近数据行
---@param st table
---@param line integer 1-based
---@return integer|nil
local function nearest_data_row(st, line)
  local nav = st.result and st.result.nav
  if not nav or not nav.buf_line then
    return nil
  end
  local best, best_d = nil, math.huge
  for r = 1, nav.nrows do
    local bl = nav.buf_line[r]
    if bl then
      local d = math.abs(bl - line)
      if d < best_d then
        best_d, best = d, r
      end
      if bl == line then
        return r
      end
    end
  end
  return best
end

---从一行文本解析各格起点（竖线右侧 = 格内第一字节，0-based）
---行形如：│ cell1 │ cell2 │ cell3 │
---@param text string
---@return integer[] starts 每格内容起点（0-based byte）
---@return integer[] borders 每条竖线起点（0-based byte）
local function parse_cell_starts(text)
  local starts, borders = {}, {}
  if not text or text == "" then
    return starts, borders
  end
  local border = "│"
  if not text:find(border, 1, true) then
    border = "|"
  end
  if not text:find(border, 1, true) then
    return starts, borders
  end
  local blen = #border
  local pos = 1 -- 1-based search
  while pos <= #text do
    local s = text:find(border, pos, true)
    if not s then
      break
    end
    borders[#borders + 1] = s - 1 -- 0-based
    pos = s + blen
  end
  -- 除最后一条右边框外，每条竖线右侧都是一格起点
  for i = 1, #borders - 1 do
    starts[#starts + 1] = borders[i] + blen
  end
  return starts, borders
end

---当前在第几格：光标 col 落在 [starts[c], starts[c+1])；在竖线上算右侧格
---@param starts integer[]
---@param borders integer[]
---@param col integer 0-based
---@return integer
local function cell_index_from_pos(starts, borders, col)
  if #starts < 1 then
    return 1
  end
  -- 在某条非末竖线上 → 该竖线右侧格
  for i = 1, #borders - 1 do
    local b = borders[i]
    local blen = (starts[i] and (starts[i] - b)) or 1
    if col >= b and col < b + blen then
      return i
    end
  end
  for c = 1, #starts do
    local a = starts[c]
    local nxt = starts[c + 1]
    if nxt then
      if col >= a and col < nxt then
        return c
      end
    else
      if col >= a then
        return c
      end
    end
  end
  if col < starts[1] then
    return 1
  end
  return #starts
end

---光标放到 line 上 0-based 字节列，并保证横向可见
local function set_cursor_byte(win, line, col)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  col = math.max(0, math.min(col or 0, #text))
  while col > 0 do
    local ch = text:byte(col + 1)
    if ch and ch >= 0x80 and ch < 0xC0 then
      col = col - 1
    else
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { line, col })
  pcall(vim.api.nvim_win_call, win, function()
    local view = vim.fn.winsaveview()
    local left = view.leftcol or 0
    local w = vim.api.nvim_win_get_width(0)
    local screen_col = vim.fn.strdisplaywidth(text:sub(1, col))
    if screen_col < left then
      view.leftcol = math.max(0, screen_col - 2)
      vim.fn.winrestview(view)
    elseif screen_col >= left + w - 2 then
      view.leftcol = math.max(0, screen_col - w + 8)
      vim.fn.winrestview(view)
    end
  end)
end

---取某数据行的格起点列表
---@param st table
---@param r integer
---@return integer[]|nil starts
---@return integer|nil bline
local function row_cell_starts(st, r)
  local nav = st.result and st.result.nav
  if not nav or not nav.buf_line or not nav.buf_line[r] then
    return nil, nil
  end
  local bline = nav.buf_line[r]
  local text = vim.api.nvim_buf_get_lines(st.buf, bline - 1, bline, false)[1] or ""
  local starts = parse_cell_starts(text)
  -- 若行上解析失败，退回 nav.col0
  if #starts == 0 and nav.col0 then
    for c = 1, nav.ncols or 0 do
      if nav.col0[c] then
        starts[#starts + 1] = nav.col0[c]
      end
    end
  end
  return starts, bline
end

---从光标解析当前数据格 (1-based row/col)
---@param st table
---@return integer|nil r
---@return integer|nil c
function M._current_cell(st)
  local nav = st.result and st.result.nav
  if not nav or not nav.nrows or nav.nrows < 1 then
    return nil, nil
  end
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 then
    return st.cell_r, st.cell_c
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local line, col = cur[1], cur[2]
  local r = nearest_data_row(st, line)
  if not r then
    return st.cell_r, st.cell_c
  end
  local starts, bline = row_cell_starts(st, r)
  if not starts or #starts == 0 then
    return r, st.cell_c or 1
  end
  local text = vim.api.nvim_buf_get_lines(st.buf, (bline or line) - 1, (bline or line), false)[1] or ""
  local _, borders = parse_cell_starts(text)
  local c = cell_index_from_pos(starts, borders, col)
  return r, c
end

---把光标放到数据格 (r,c) 内部（该格左竖线右侧第一字节）
---@param st table
---@param r integer
---@param c integer
function M._goto_cell(st, r, c)
  local nav = st.result and st.result.nav
  if not nav or not nav.nrows or nav.nrows < 1 then
    return
  end
  r = math.max(1, math.min(nav.nrows, r or 1))
  local starts, bline = row_cell_starts(st, r)
  if not starts or not bline or #starts < 1 then
    return
  end
  c = math.max(1, math.min(#starts, c or 1))
  st.cell_r, st.cell_c = r, c
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 or not vim.api.nvim_win_is_valid(win) then
    return
  end
  set_cursor_byte(win, bline, starts[c])
end

---单元格内容字节范围 [start0, end0]（0-based inclusive，不含两侧 │）
---@param st table
---@param r integer
---@param c integer
---@return integer|nil bline
---@return integer|nil start0
---@return integer|nil end0
local function cell_byte_range(st, r, c)
  local starts, bline = row_cell_starts(st, r)
  if not starts or not bline or #starts < 1 then
    return nil
  end
  c = math.max(1, math.min(#starts, c))
  local text = vim.api.nvim_buf_get_lines(st.buf, bline - 1, bline, false)[1] or ""
  local _, borders = parse_cell_starts(text)
  local s0 = starts[c]
  local e0
  if borders[c + 1] then
    -- 右竖线前一字节
    e0 = borders[c + 1] - 1
  else
    e0 = math.max(s0, #text - 1)
  end
  if e0 < s0 then
    e0 = s0
  end
  return bline, s0, e0
end

---应用单元格矩形块选（真正的 Ctrl-v 选区覆盖整格）
---@param st table
function M._apply_cell_block(st)
  local b = st.vblock
  local nav = st.result and st.result.nav
  if not b or not nav then
    return
  end
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local r1 = math.min(b.r1, b.r2)
  local r2 = math.max(b.r1, b.r2)
  local c1 = math.min(b.c1, b.c2)
  local c2 = math.max(b.c1, b.c2)
  r1 = math.max(1, math.min(nav.nrows, r1))
  r2 = math.max(1, math.min(nav.nrows, r2))
  local l1, s0 = cell_byte_range(st, r1, c1)
  local l2, _, e0 = cell_byte_range(st, r2, c2)
  if not l1 or not l2 or not s0 or not e0 then
    return
  end
  -- 先退出当前可视，再重新拉块选
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    pcall(vim.cmd, "normal! \27")
  end
  pcall(vim.api.nvim_win_set_cursor, win, { l1, s0 })
  -- 进入块选并拉到对角
  pcall(vim.cmd, "normal! \22")
  pcall(vim.api.nvim_win_set_cursor, win, { l2, e0 })
  -- 保证可视
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zz")
  end)
end

---Ctrl-v：从当前格开始块选（选中整格）
---@param st table
function M._vblock_start(st)
  local nav = st.result and st.result.nav
  if not nav or not nav.nrows or nav.nrows < 1 then
    -- 回退原生 Ctrl-v
    pcall(vim.cmd, "normal! \22")
    return
  end
  local r, c = M._current_cell(st)
  r = r or st.cell_r or 1
  c = c or st.cell_c or 1
  r = math.max(1, math.min(nav.nrows, r))
  c = math.max(1, math.min(nav.ncols or 1, c))
  st.vblock = { r1 = r, c1 = c, r2 = r, c2 = c }
  st.cell_r, st.cell_c = r, c
  M._apply_cell_block(st)
end

---块选中扩展：一次一行/一列单元格（移动自由角 r2,c2）
---@param st table
---@param dr integer
---@param dc integer
function M._vblock_extend(st, dr, dc)
  local nav = st.result and st.result.nav
  if not st.vblock or not nav then
    return
  end
  local b = st.vblock
  local nr = b.r2 + (dr or 0)
  local nc = b.c2 + (dc or 0)
  nr = math.max(1, math.min(nav.nrows, nr))
  nc = math.max(1, math.min(nav.ncols or 1, nc))
  if nr == b.r2 and nc == b.c2 then
    return
  end
  b.r2, b.c2 = nr, nc
  st.cell_r, st.cell_c = nr, nc
  M._apply_cell_block(st)
end

---取 sheet 数据格纯文本（完整值，非截断显示）
---@param st table
---@param r integer 1-based data row
---@param c integer 1-based col
---@return string
local function sheet_cell_text(st, r, c)
  local si = st.sheet_index or 1
  local sheet = st.data and st.data.sheets and st.data.sheets[si]
  if not sheet or not sheet.rows then
    return ""
  end
  local row = sheet.rows[r]
  if not row then
    return ""
  end
  local cell = row[c]
  local t
  if type(cell) == "table" then
    t = cell.text or ""
  else
    t = tostring(cell or "")
  end
  t = t:gsub("\r\n", "\n"):gsub("\r", "\n")
  -- 单元格内换行：复制时收成空格（与常见表格粘贴一致）
  t = t:gsub("\n+", " ")
  return vim.trim(t)
end

---字节列 → 该数据行上的列索引（竖线忽略，落在 │ 上算右侧格）
---@param st table
---@param data_r integer
---@param col0 integer 0-based byte
---@return integer
local function col_at_byte(st, data_r, col0)
  local starts, bline = row_cell_starts(st, data_r)
  if not starts or #starts < 1 then
    return 1
  end
  local text = ""
  if bline then
    text = vim.api.nvim_buf_get_lines(st.buf, bline - 1, bline, false)[1] or ""
  end
  local _, borders = parse_cell_starts(text)
  return cell_index_from_pos(starts, borders, col0)
end

---可视选区 → 数据行/列矩形 [r1,c1]–[r2,c2]（1-based inclusive）
---@param st table
---@return integer|nil r1
---@return integer|nil c1
---@return integer|nil r2
---@return integer|nil c2
---@return string mode
local function visual_cell_range(st)
  local nav = st.result and st.result.nav
  if not nav then
    return nil
  end
  local mode = vim.fn.mode()
  -- getpos: col 为 1-based byte
  local p1 = vim.fn.getpos("v")
  local p2 = vim.fn.getpos(".")
  local l1, bcol1 = p1[2], math.max(0, p1[3] - 1)
  local l2, bcol2 = p2[2], math.max(0, p2[3] - 1)
  if l1 > l2 or (l1 == l2 and bcol1 > bcol2) then
    l1, l2 = l2, l1
    bcol1, bcol2 = bcol2, bcol1
  end

  -- 收集选区内的数据行（跳过表头分隔线等非数据行）
  local rows = {}
  for line = l1, l2 do
    local r = nearest_data_row(st, line)
    if r and nav.buf_line[r] == line then
      rows[#rows + 1] = r
    end
  end
  if #rows == 0 then
    -- 选区落在分隔线上：取最近数据行
    local r1 = nearest_data_row(st, l1)
    local r2 = nearest_data_row(st, l2)
    if r1 then
      rows[1] = r1
    end
    if r2 and r2 ~= r1 then
      rows[#rows + 1] = r2
    end
  end
  if #rows == 0 then
    return nil
  end
  table.sort(rows)
  -- 去重
  local uniq = {}
  local seen = {}
  for _, r in ipairs(rows) do
    if not seen[r] then
      seen[r] = true
      uniq[#uniq + 1] = r
    end
  end
  rows = uniq
  local rmin, rmax = rows[1], rows[#rows]

  local cmin, cmax
  if mode == "\22" then
    -- 块选：用屏幕列对齐矩形，再映射到单元格（边上的 │ 归入邻格，等于忽略边框）
    local win = vim.fn.bufwinid(st.buf)
    local vc1 = vim.fn.virtcol({ l1, bcol1 + 1 })
    local vc2 = vim.fn.virtcol({ l2, bcol2 + 1 })
    if vc1 > vc2 then
      vc1, vc2 = vc2, vc1
    end
    cmin, cmax = nav.ncols or 1, 1
    for _, r in ipairs(rows) do
      local bline = nav.buf_line[r]
      if bline and win ~= -1 then
        local bc1 = vim.fn.virtcol2col(win, bline, vc1)
        local bc2 = vim.fn.virtcol2col(win, bline, vc2)
        if type(bc1) == "number" and bc1 > 0 then
          local ca = col_at_byte(st, r, bc1 - 1)
          cmin = math.min(cmin, ca)
          cmax = math.max(cmax, ca)
        end
        if type(bc2) == "number" and bc2 > 0 then
          local cb = col_at_byte(st, r, bc2 - 1)
          cmin = math.min(cmin, cb)
          cmax = math.max(cmax, cb)
        end
      else
        local ca = col_at_byte(st, r, bcol1)
        local cb = col_at_byte(st, r, bcol2)
        cmin = math.min(cmin, ca, cb)
        cmax = math.max(cmax, ca, cb)
      end
    end
  elseif mode == "V" then
    -- 行选：整行所有列
    cmin, cmax = 1, nav.ncols or 1
  else
    -- 字符选
    local ca = col_at_byte(st, rmin, bcol1)
    local cb = col_at_byte(st, rmax, bcol2)
    cmin = math.min(ca, cb)
    cmax = math.max(ca, cb)
  end
  cmin = math.max(1, cmin)
  cmax = math.min(nav.ncols or cmax, cmax)
  return rmin, cmin, rmax, cmax, mode
end

---按单元格拼出 Excel 风格文本（Tab 分隔，空单元格保留列）
---@param st table
---@param r1 integer
---@param c1 integer
---@param r2 integer
---@param c2 integer
---@return string
local function format_cells_tsv(st, r1, c1, r2, c2)
  local lines = {}
  local widths = {}
  for c = c1, c2 do
    widths[c] = 0
  end
  local grid = {}
  for r = r1, r2 do
    local rowt = {}
    for c = c1, c2 do
      local t = sheet_cell_text(st, r, c)
      rowt[c] = t
      widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(t))
    end
    grid[#grid + 1] = rowt
  end
  -- 空列宽至少 1，便于对齐空单元格
  for c = c1, c2 do
    if widths[c] < 1 then
      widths[c] = 1
    end
  end
  for _, rowt in ipairs(grid) do
    local parts = {}
    for c = c1, c2 do
      local t = rowt[c] or ""
      local pad = widths[c] - vim.fn.strdisplaywidth(t)
      if pad < 0 then
        pad = 0
      end
      -- 与示例一致：列间用空格对齐（末列不补也可；统一右补空格）
      parts[#parts + 1] = t .. string.rep(" ", pad)
    end
    -- 列之间再留 4 空格，观感接近 Excel 文本粘贴
    local line = table.concat(parts, "    ")
    -- 去掉行尾多余空格
    line = line:gsub("%s+$", "")
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

---可视模式 y：复制选中单元格文本（忽略边框 │）
---@param st table
function M._yank_visual(st)
  local r1, c1, r2, c2 = visual_cell_range(st)
  if not r1 then
    -- 回退默认 yank
    vim.cmd("normal! y")
    return
  end
  local text = format_cells_tsv(st, r1, c1, r2, c2)
  if text == "" then
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "n", false)
    return
  end
  -- 行尾换行，便于多行粘贴
  if not text:match("\n$") then
    text = text .. "\n"
  end
  vim.fn.setreg('"', text, "l")
  pcall(vim.fn.setreg, "+", text, "l")
  pcall(vim.fn.setreg, "*", text, "l")
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "n", false)
  -- 不 notify，避免 hit-enter；用 echo 短提示且 silent
  pcall(vim.api.nvim_echo, {
    { string.format("xlsview: yank %dx%d cells", r2 - r1 + 1, c2 - c1 + 1), "ModeMsg" },
  }, false, {})
end

---移动单元格（严格按「格起点」跳，不按字符走）
--- 右：下一格起点（下一个 │ 右侧）
--- 左：上一格起点（左边第 2 个 │ 右侧）
--- 上/下：同行索引，邻行同列起点
---@param st table
---@param dr integer
---@param dc integer
---@param wrap boolean
function M._move_cell(st, dr, dc, wrap)
  local nav = st.result and st.result.nav
  if not nav or not nav.nrows or nav.nrows < 1 then
    return
  end
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local line, col = cur[1], cur[2]
  local r = nearest_data_row(st, line) or st.cell_r or 1
  local starts, bline = row_cell_starts(st, r)
  if not starts or not bline or #starts < 1 then
    return
  end
  local text = vim.api.nvim_buf_get_lines(st.buf, bline - 1, bline, false)[1] or ""
  local _, borders = parse_cell_starts(text)
  local c = cell_index_from_pos(starts, borders, col)

  -- 不在数据行：先落到当前格起点再算
  if line ~= bline then
    M._goto_cell(st, r, c)
    return M._move_cell(st, dr, dc, wrap)
  end

  local ncols = #starts
  local nrows = nav.nrows
  local nr, nc = r, c

  if dr ~= 0 and dc == 0 then
    nr = r + dr
    if wrap then
      if nr > nrows then
        nr = 1
      elseif nr < 1 then
        nr = nrows
      end
    else
      if nr < 1 or nr > nrows then
        return
      end
    end
    M._goto_cell(st, nr, c)
    return
  end

  if dc ~= 0 then
    nc = c + dc
    if wrap then
      if nc > ncols then
        nc = 1
        nr = r + 1
        if nr > nrows then
          nr = 1
        end
      elseif nc < 1 then
        nc = ncols
        nr = r - 1
        if nr < 1 then
          nr = nrows
        end
      end
    else
      if nc < 1 or nc > ncols then
        return
      end
    end
    M._goto_cell(st, nr, nc)
  end
end

local function attach_autocmds(st)
  if st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
  end
  local buf = st.buf
  local aug = vim.api.nvim_create_augroup("XlsView_" .. buf, { clear = true })
  st.au_group = aug
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = aug,
    buffer = buf,
    callback = function()
      if st.resize_timer then
        pcall(function()
          st.resize_timer:stop()
          st.resize_timer:close()
        end)
      end
      states[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) or vim.fn.bufwinid(buf) == -1 then
        return
      end
      local nw = win_width(buf)
      if st.width and math.abs(nw - st.width) < 2 then
        return
      end
      if st.resize_timer then
        pcall(function()
          st.resize_timer:stop()
        end)
      end
      local timer = uv.new_timer()
      st.resize_timer = timer
      if timer then
        timer:start(120, 0, function()
          vim.schedule(function()
            local s = get_state(buf)
            if s and s.data then
              do_render(s)
            end
          end)
        end)
      end
    end,
  })
end

local function prep_buf(buf)
  pcall(function()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    vim.bo[buf].filetype = "xlsview"
  end)
  vim.b[buf].xlsview_preview = true
end

function M._activate(st)
  if not st or not st.result then
    return
  end
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local row, col = cur[1], cur[2]
  for _, h in ipairs(st.result.hits or {}) do
    if h.kind == "sheet" and h.line == row then
      if h.col == nil or (col >= (h.col or 0) and col < (h.end_col or math.huge)) then
        st.sheet_index = h.sheet
        do_render(st)
        return
      end
    end
  end
end

function M.open(path, opts)
  opts = opts or {}
  config.ensure_setup()
  highlight.setup(config.get().highlights)
  highlight.ensure()

  path = path and path ~= "" and path or vim.fn.expand("%:p")
  path = vim.fn.fnamemodify(path, ":p")
  local i18n = require("xlsview.i18n")
  if not is_xls_path(path) then
    vim.notify(i18n.t("not_xlsx") .. tostring(path), vim.log.levels.WARN)
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify(i18n.t("not_found") .. path, vim.log.levels.ERROR)
    return
  end

  local win = opts.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  for b, st in pairs(states) do
    if st.path == path and vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_win_set_buf(win, b)
      apply_winopts(win, config.get())
      st.win = win
      if opts.force then
        M.refresh(b, true)
      end
      return b
    end
  end

  -- 不在这里 vim.notify「正在提取」：会与后续 echo 叠成 hit-enter（按 ENTER 才能继续）
  local data, err = extract_mod.extract(path, opts.force)
  if not data then
    vim.notify(i18n.t("err") .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_create_buf(true, false)
  prep_buf(buf)
  pcall(vim.api.nvim_buf_set_name, buf, path .. " [xlsview]")

  local st = {
    buf = buf,
    win = win,
    path = path,
    data = data,
    sheet_index = 1,
    result = nil,
    width = nil,
    maps_version = 0,
  }
  states[buf] = st

  vim.api.nvim_win_set_buf(win, buf)
  apply_winopts(win, config.get())
  st.cell_r, st.cell_c = 1, 1
  do_render(st)
  attach_maps(st)
  attach_autocmds(st)
  -- 打开后落在首个数据格
  vim.schedule(function()
    if get_state(buf) == st then
      M._goto_cell(st, 1, 1)
    end
  end)
  -- 清掉可能残留的 hit-enter 提示（不额外 echo 成功信息，界面已展示表格）
  pcall(vim.cmd, "redraw!")
  return buf
end

function M.close(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = states[buf]
  require("xlsview.help").close()
  if st and st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
  end
  states[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].xlsview_preview then
    local wins = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        wins[#wins + 1] = w
      end
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    for _, w in ipairs(wins) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(function()
          vim.api.nvim_win_call(w, function()
            vim.cmd("enew")
          end)
        end)
      end
    end
  end
end

function M.refresh(buf, force)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = states[buf]
  if not st then
    return
  end
  local i18n = require("xlsview.i18n")
  local data, err = extract_mod.extract(st.path, force)
  if not data then
    vim.notify(i18n.t("err") .. tostring(err), vim.log.levels.ERROR)
    return
  end
  st.data = data
  local n = data.sheet_count or 1
  st.sheet_index = math.min(st.sheet_index or 1, n)
  do_render(st)
  pcall(vim.cmd, "redraw!")
end

---切换中/英文并重绘所有预览
function M.toggle_ui_lang()
  local i18n = require("xlsview.i18n")
  local next_lang = i18n.toggle()
  i18n.save_prefs()
  if next_lang == "en" then
    vim.notify(i18n.t("lang_to_en"), vim.log.levels.INFO)
  else
    vim.notify(i18n.t("lang_to_zh"), vim.log.levels.INFO)
  end
  local help = require("xlsview.help")
  local help_was = help.is_open and help.is_open()
  if help_was then
    help.close()
  end
  for b, st in pairs(states) do
    if st and vim.api.nvim_buf_is_valid(b) then
      pcall(do_render, st)
    end
  end
  if help_was then
    help.toggle_float()
  end
end

function M.setup(user)
  config.setup(user)
  highlight.setup(config.get().highlights)
  M._install_auto()
  return config.get()
end

function M.ensure_setup()
  config.ensure_setup()
  highlight.ensure()
  pcall(function()
    require("xlsview.zipfix").install()
  end)
  M._install_auto()
end

function M._install_auto()
  if auto_installed then
    return
  end
  auto_installed = true
  local aug = vim.api.nvim_create_augroup("XlsViewAuto", { clear = true })
  local pats = { "*.xlsx", "*.XLSX", "*.xlsm", "*.XLSM", "*.xltx", "*.XLTX", "*.xltm", "*.XLTM" }

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = pats,
    nested = true,
    desc = "xlsview: open workbook without zip#Browse",
    callback = function(args)
      local cfg = config.get()
      local path = vim.fn.fnamemodify(args.file ~= "" and args.file or args.match, ":p")
      pcall(vim.api.nvim_buf_set_lines, args.buf, 0, -1, false, {
        cfg.auto_open == false and "xlsview: auto_open=false · :XlsView" or "xlsview: loading…",
        path,
      })
      pcall(function()
        vim.bo[args.buf].buftype = "nofile"
        vim.bo[args.buf].swapfile = false
        vim.bo[args.buf].modifiable = false
        vim.b[args.buf].xlsview_skip = true
      end)
      if cfg.auto_open == false then
        return
      end
      vim.schedule(function()
        local win = vim.fn.bufwinid(args.buf)
        if win == -1 then
          win = vim.api.nvim_get_current_win()
        end
        local opened = M.open(path, { win = win })
        if opened and vim.api.nvim_buf_is_valid(args.buf) and args.buf ~= opened then
          pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = aug,
    pattern = pats,
    callback = function(args)
      local cfg = config.get()
      if cfg.auto_open == false then
        return
      end
      local buf = args.buf
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.b[buf].xlsview_preview or vim.b[buf].xlsview_skip then
        return
      end
      local path = vim.api.nvim_buf_get_name(buf)
      if not is_xls_path(path) then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].xlsview_preview then
          return
        end
        local win = vim.fn.bufwinid(buf)
        if win == -1 then
          win = vim.api.nvim_get_current_win()
        end
        local opened = M.open(path, { win = win })
        if opened and vim.api.nvim_buf_is_valid(buf) and buf ~= opened then
          vim.b[buf].xlsview_skip = true
          pcall(function()
            local still = false
            for _, w in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_get_buf(w) == buf then
                still = true
                break
              end
            end
            if not still then
              pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
          end)
        end
      end)
    end,
  })
end

return M
