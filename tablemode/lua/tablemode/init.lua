---@mod tablemode 表格模式（仿 vim-table-mode）
---即时对齐 Markdown/GFM 表格，支持 Tableize、单元格移动与行列操作。
local i18n = require("tablemode.i18n")
local F = require("tablemode.format")

local M = {}

local default_config = {
  ---列分隔 / 行两端角，Markdown 用 "|"
  corner = "|",
  ---分隔行交叉角："|"（GFM）或 "+"
  corner_corner = "|",
  ---分隔填充
  fillchar = "-",
  ---表头分隔填充（ReST 可用 "="）
  header_fillchar = "-",
  ---对齐标记
  align_char = ":",
  ---Tableize 默认分隔符
  delimiter = ",",
  ---Tableize 是否在首行后插入表头分隔行
  tableize_header_sep = true,
  ---开启 table mode 后自动对齐（含输入 | 与编辑单元格）
  auto_align = true,
  ---编辑单元格时是否实时对齐（需 auto_align=true 且已开启模式）
  auto_align_live = true,
  ---实时对齐防抖（毫秒）。0=每次按键立即对齐；中文 IME 建议 50–120
  auto_align_ms = 60,
  ---离开插入模式时再对齐一次（保证最终整齐）
  auto_align_on_insert_leave = true,
  ---markdown / rst 自动套用角样式
  smart_syntax = true,
  ---界面语言
  ui_lang = "auto",
  ---快捷键；false 关闭
  keys_toggle = "<leader>tm",
  keys_realign = "<leader>tr",
  keys_tableize = "<leader>tt",
  keys_tableize_op = "<leader>T",
  keys_delete_row = "<leader>tdd",
  keys_delete_col = "<leader>tdc",
  keys_insert_col_after = "<leader>tic",
  keys_insert_col_before = "<leader>tiC",
  ---单元格移动（始终 buffer 映射，仅在表内生效）
  map_motions = true,
  ---文本对象 i| / a|
  map_text_objects = true,
  ---Tab / Shift-Tab 切换单元格（表内；表外回落默认 Tab 行为）
  map_tab = true,
  ---是否在 normal 也绑定 Tab（会占用 <C-i> 跳转列表，默认关）
  tab_normal = false,
  ---在最后一格再按 Tab 时追加一行空行
  tab_insert_row = true,
  ---normal 模式方向键：表内按单元格移动，边界/表外回落默认
  map_arrows = true,
  ---normal 模式 hjkl：表内按格移动，边界再按可移出表格
  map_hjkl = true,
}

local config = vim.deepcopy(default_config)
local setup_done = false
---@type string[]
local keys_applied = {}

---buffer → enabled
local buf_enabled = {}
---正在写回对齐结果，避免 TextChanged 重入
local aligning = {}
---防抖 timer id
local live_timers = {}

local AUGROUP = "tablemode_nvim"
local AUGROUP_LIVE = "tablemode_nvim_live"

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

local function opts_for_buf(buf)
  local o = {
    corner = config.corner,
    corner_corner = config.corner_corner,
    fillchar = config.fillchar,
    header_fillchar = config.header_fillchar,
    align_char = config.align_char,
  }
  if not config.smart_syntax then
    return o
  end
  local ft = vim.bo[buf].filetype or ""
  if ft == "rst" then
    o.corner = "|"
    o.corner_corner = "+"
    o.header_fillchar = "="
    o.fillchar = "-"
  elseif ft == "markdown" or ft == "markdown.mdx" or ft == "rmd" or ft == "quarto" then
    o.corner = "|"
    o.corner_corner = "|"
    o.header_fillchar = "-"
    o.fillchar = "-"
  end
  return o
end

local function update_status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local on = buf_enabled[buf] == true
  vim.b[buf].tablemode = on
  vim.g.tablemode_status = on and i18n.t("status_on") or i18n.t("status_off")
  -- 兼容 statusline：任意 buffer 开着就显示
  local any = false
  for b, v in pairs(buf_enabled) do
    if v and vim.api.nvim_buf_is_valid(b) then
      any = true
      break
    end
  end
  if any and buf_enabled[buf] then
    vim.g.tablemode_status = i18n.t("status_on")
  elseif not buf_enabled[buf] then
    vim.g.tablemode_status = ""
  end
end

---在 buffer 中找光标所在表的起止行（1-based，含）
---@param buf integer
---@param lnum integer
---@return integer|nil start_line
---@return integer|nil end_line
local function find_table_range(buf, lnum)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if lnum < 1 or lnum > line_count then
    return nil, nil
  end
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if not F.is_table_row(line) then
    return nil, nil
  end
  local s = lnum
  while s > 1 do
    local prev = vim.api.nvim_buf_get_lines(buf, s - 2, s - 1, false)[1] or ""
    if not F.is_table_row(prev) then
      break
    end
    s = s - 1
  end
  local e = lnum
  while e < line_count do
    local nextl = vim.api.nvim_buf_get_lines(buf, e, e + 1, false)[1] or ""
    if not F.is_table_row(nextl) then
      break
    end
    e = e + 1
  end
  return s, e
end

---@param buf integer
---@param start_line integer
---@param end_line integer
---@return ParsedTable|nil
local function parse_range(buf, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local parsed = F.parse_lines(lines, opts_for_buf(buf))
  if not parsed then
    return nil
  end
  parsed.start_line = start_line
  parsed.end_line = end_line
  return parsed
end

---对齐并写回，尽量保持光标在同一单元格
---@param buf integer
---@param start_line integer
---@param end_line integer
---@param cur_lnum? integer
---@param cur_col? integer  1-based
---@param opts? { undojoin?: boolean, force?: boolean }
---@return boolean
local function realign_range(buf, start_line, end_line, cur_lnum, cur_col, opts)
  opts = opts or {}
  if aligning[buf] then
    return false
  end
  local parsed = parse_range(buf, start_line, end_line)
  if not parsed then
    return false
  end
  local o = opts_for_buf(buf)
  local new_lines = F.format_table(parsed, o)
  local old_lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  if not opts.force and #old_lines == #new_lines then
    local same = true
    for i = 1, #new_lines do
      if old_lines[i] ~= new_lines[i] then
        same = false
        break
      end
    end
    if same then
      return true
    end
  end

  local rel_row, cell_idx, offset
  if cur_lnum and cur_lnum >= start_line and cur_lnum <= end_line then
    rel_row = cur_lnum - start_line + 1
    local old = old_lines[rel_row] or ""
    cell_idx, offset = F.cursor_cell(old, cur_col or 1)
  end

  aligning[buf] = true
  -- 与刚输入的字符并入同一 undo 块，避免每敲一次多一层撤销
  if opts.undojoin ~= false then
    pcall(vim.cmd, "silent! undojoin")
  end
  vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line, false, new_lines)
  aligning[buf] = false

  if rel_row and new_lines[rel_row] then
    local col = F.cell_to_col(new_lines[rel_row], cell_idx or 1, offset or 0)
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { start_line + rel_row - 1, math.max(0, col - 1) })
    end
  end
  return true
end

local function clear_live_timer(buf)
  local t = live_timers[buf]
  if t then
    pcall(vim.fn.timer_stop, t)
    live_timers[buf] = nil
  end
end

---实时对齐当前光标所在表（静默）
---@param buf? integer
local function live_align_now(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not buf_enabled[buf] or not config.auto_align or config.auto_align_live == false then
    return
  end
  if aligning[buf] or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  -- 补全弹窗打开时不对齐，避免打乱补全
  if vim.fn.pumvisible() == 1 then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  -- 只在 insert / normal / replace 下处理
  if not (mode:match("^[iR]") or mode == "n") then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if not F.is_table_row(line) then
    return
  end
  local s, e = find_table_range(buf, lnum)
  if not s then
    return
  end
  realign_range(buf, s, e, lnum, col, { undojoin = true })
end

---@param buf integer
local function schedule_live_align(buf)
  if not buf_enabled[buf] or not config.auto_align or config.auto_align_live == false then
    return
  end
  if aligning[buf] then
    return
  end
  clear_live_timer(buf)
  local ms = tonumber(config.auto_align_ms) or 60
  if ms <= 0 then
    vim.schedule(function()
      live_align_now(buf)
    end)
    return
  end
  live_timers[buf] = vim.fn.timer_start(ms, function()
    live_timers[buf] = nil
    vim.schedule(function()
      live_align_now(buf)
    end)
  end)
end

local function attach_live_align(buf)
  vim.api.nvim_clear_autocmds({ group = AUGROUP_LIVE, buffer = buf })
  if not buf_enabled[buf] then
    return
  end
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group = AUGROUP_LIVE,
    buffer = buf,
    callback = function(ev)
      schedule_live_align(ev.buf)
    end,
  })
  if config.auto_align_on_insert_leave ~= false then
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = AUGROUP_LIVE,
      buffer = buf,
      callback = function(ev)
        clear_live_timer(ev.buf)
        live_align_now(ev.buf)
      end,
    })
  end
end

local function detach_live_align(buf)
  clear_live_timer(buf)
  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP_LIVE, buffer = buf })
end

function M.realign()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local s, e = find_table_range(buf, lnum)
  if not s then
    notify(i18n.t("not_in_table"), vim.log.levels.WARN)
    return false
  end
  local ok = realign_range(buf, s, e, lnum, col)
  if ok then
    notify(i18n.t("realigned"))
  end
  return ok
end

---静默对齐（插入 | / 实时编辑用）
local function realign_silent()
  local buf = vim.api.nvim_get_current_buf()
  clear_live_timer(buf)
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local s, e = find_table_range(buf, lnum)
  if not s then
    return
  end
  realign_range(buf, s, e, lnum, col, { undojoin = true })
end

---当前行是否“空表格行”（仅 | 与空白，用于生成分隔线）
local function is_pipe_only_line(line)
  local s = vim.trim(line or "")
  if s == "" then
    return false
  end
  return s:match("^|[%s|]*$") ~= nil or s:match("^|%s*|$") ~= nil or s == "||" or s == "|"
end

---在当前行插入分隔线（基于上一行表格宽度）
local function expand_separator_if_needed()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if not is_pipe_only_line(line) then
    return false
  end
  -- 需要上一行是表
  if lnum <= 1 then
    return false
  end
  local prev = vim.api.nvim_buf_get_lines(buf, lnum - 2, lnum - 1, false)[1] or ""
  if not F.is_table_row(prev) or F.is_separator_line(prev) then
    -- 也可能整表已有，用整表宽度
    local s, e = find_table_range(buf, lnum - 1)
    if not s then
      return false
    end
    local parsed = parse_range(buf, s, e)
    if not parsed then
      return false
    end
    local sep = F.make_separator_line(parsed, opts_for_buf(buf), true)
    vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { sep })
    local win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_cursor, win, { lnum, #sep })
    return true
  end
  local s, e = find_table_range(buf, lnum - 1)
  if not s then
    -- 仅上一行
    local parsed = F.parse_lines({ prev }, opts_for_buf(buf))
    if not parsed then
      return false
    end
    local sep = F.make_separator_line(parsed, opts_for_buf(buf), true)
    vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { sep })
    return true
  end
  local parsed = parse_range(buf, s, math.max(e, lnum - 1))
  if not parsed then
    return false
  end
  local sep = F.make_separator_line(parsed, opts_for_buf(buf), true)
  vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { sep })
  local win = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_win_set_cursor, win, { lnum, #sep })
  return true
end

---插入模式下按 | 后的处理
function M.on_pipe_insert()
  local buf = vim.api.nvim_get_current_buf()
  if not buf_enabled[buf] then
    -- 未开启模式时不应挂此映射；兜底插入字面量
    vim.api.nvim_feedkeys("|", "n", false)
    return
  end
  -- 先插入 |
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  local new_line = before .. "|" .. after
  aligning[buf] = true
  pcall(vim.cmd, "silent! undojoin")
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { new_line })
  aligning[buf] = false
  vim.api.nvim_win_set_cursor(0, { row, col + 1 })

  if not config.auto_align then
    return
  end
  -- 尝试扩展分隔行
  if expand_separator_if_needed() then
    return
  end
  -- 对齐当前表
  realign_silent()
end

local function set_insert_pipe_map(buf, enable)
  if enable then
    vim.keymap.set("i", "|", function()
      M.on_pipe_insert()
    end, { buffer = buf, silent = true, desc = "tablemode: pipe + align" })
  else
    pcall(vim.keymap.del, "i", "|", { buffer = buf })
  end
end

---下一/上一数据行（跳过分隔行）
---@param buf integer
---@param from integer
---@param last integer
---@param step integer  1 或 -1
---@return integer|nil
local function next_data_line(buf, from, last, step)
  local l = from + step
  while (step > 0 and l <= last) or (step < 0 and l >= last) do
    local L = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
    if F.is_table_row(L) and not F.is_separator_line(L) then
      return l
    end
    l = l + step
  end
  return nil
end

---在表末追加空数据行，返回新行号
---@param buf integer
---@param s integer
---@param e integer
---@return integer|nil lnum
local function append_empty_row(buf, s, e)
  local parsed = parse_range(buf, s, e)
  if not parsed then
    return nil
  end
  local cells = {}
  for i = 1, parsed.col_count do
    cells[i] = ""
  end
  parsed.rows[#parsed.rows + 1] = { cells = cells, is_sep = false }
  -- 列宽至少保持
  local new_lines = F.format_table(parsed, opts_for_buf(buf))
  aligning[buf] = true
  pcall(vim.cmd, "silent! undojoin")
  vim.api.nvim_buf_set_lines(buf, s - 1, e, false, new_lines)
  aligning[buf] = false
  return s + #new_lines - 1
end

---单元格导航
---@param dir "left"|"right"|"up"|"down"
---@param opts? { insert_row?: boolean, nowrap?: boolean }
---  nowrap: 左右不跨行（hjkl/方向键用，便于从首末列移出表格）
---@return boolean moved  是否实际移动（或插入了新行）
---@return boolean in_table  原先是否在表内
function M.move_cell(dir, opts)
  opts = opts or {}
  local nowrap = opts.nowrap == true
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local old_lnum, old_col0 = pos[1], pos[2]
  local s, e = find_table_range(buf, lnum)
  if not s then
    return false, false
  end
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if not F.is_table_row(line) then
    return false, false
  end
  local cell_idx = F.cursor_cell(line, col)
  local parsed = parse_range(buf, s, e)
  if not parsed then
    return false, false
  end
  local ncol = parsed.col_count
  local on_sep = F.is_separator_line(line)
  local new_lnum, new_cell = lnum, cell_idx
  local did_insert = false

  if dir == "right" then
    if on_sep then
      if not nowrap then
        local nl = next_data_line(buf, lnum, e, 1)
        if nl then
          new_lnum, new_cell = nl, 1
        elseif opts.insert_row and config.tab_insert_row ~= false then
          local nl2 = append_empty_row(buf, s, e)
          if nl2 then
            new_lnum, new_cell, did_insert = nl2, 1, true
          end
        end
      end
    elseif cell_idx < ncol then
      new_cell = cell_idx + 1
    elseif not nowrap then
      local nl = next_data_line(buf, lnum, e, 1)
      if nl then
        new_lnum, new_cell = nl, 1
      elseif opts.insert_row and config.tab_insert_row ~= false then
        local nl2 = append_empty_row(buf, s, e)
        if nl2 then
          new_lnum, new_cell, did_insert = nl2, 1, true
        end
      end
    end
  elseif dir == "left" then
    if on_sep then
      if not nowrap then
        local pl = next_data_line(buf, lnum, s, -1)
        if pl then
          new_lnum, new_cell = pl, ncol
        end
      end
    elseif cell_idx > 1 then
      new_cell = cell_idx - 1
    elseif not nowrap then
      local pl = next_data_line(buf, lnum, s, -1)
      if pl then
        new_lnum, new_cell = pl, ncol
      end
    end
  elseif dir == "down" then
    local nl = next_data_line(buf, lnum, e, 1)
    if nl then
      new_lnum = nl
    end
  elseif dir == "up" then
    local pl = next_data_line(buf, lnum, s, -1)
    if pl then
      new_lnum = pl
    end
  end

  -- 边界：没有下一格 → 让 hjkl/方向键回落默认，可移出表格
  if not did_insert and new_lnum == lnum and new_cell == cell_idx then
    return false, true
  end

  line = vim.api.nvim_buf_get_lines(buf, new_lnum - 1, new_lnum, false)[1] or ""
  local new_col = F.cell_to_col(line, new_cell, 0)
  vim.api.nvim_win_set_cursor(0, { new_lnum, math.max(0, new_col - 1) })
  local cur = vim.api.nvim_win_get_cursor(0)
  if cur[1] == old_lnum and cur[2] == old_col0 and not did_insert then
    return false, true
  end
  return true, true
end

---默认 h/j/k/l 运动（不 remap，用于移出表格）
---@param motion string
---@param count? integer
local function default_motion(motion, count)
  count = count or 1
  if count < 1 then
    return
  end
  pcall(vim.cmd, "normal! " .. tostring(count) .. motion)
end

---表内按格移动；到边界或表外则用默认运动（可移出表格）
---左右不跨行，这样在首/末列再按 h/l 即可离开表格
---@param dir "left"|"right"|"up"|"down"
---@param motion string  h/j/k/l
function M.move_or_exit(dir, motion)
  local count = vim.v.count1
  for i = 1, count do
    local moved = M.move_cell(dir, { nowrap = true })
    if not moved then
      default_motion(motion, count - i + 1)
      return
    end
  end
end

---Tab / Shift-Tab：换单元格；不在表内返回 false 以便回落默认键
---@param delta integer  1=下一格，-1=上一格
---@return boolean handled  在表内则吞掉按键（即使已在边界）
function M.tab_cell(delta)
  local buf = vim.api.nvim_get_current_buf()
  if not buf_enabled[buf] then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum = pos[1]
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if not F.is_table_row(line) then
    return false
  end
  if config.auto_align ~= false then
    clear_live_timer(buf)
    local s, e = find_table_range(buf, lnum)
    if s then
      local col = pos[2] + 1
      realign_range(buf, s, e, lnum, col, { undojoin = true })
    end
  end
  if delta >= 0 then
    M.move_cell("right", { insert_row = true })
  else
    M.move_cell("left", { insert_row = false })
  end
  return true
end
---文本对象：选中单元格
---@param around boolean a| 含右侧 |
function M.select_cell(around)
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if not F.is_table_row(line) or F.is_separator_line(line) then
    return
  end
  local cell_idx = F.cursor_cell(line, col)
  -- 找单元格 byte 范围
  local i = 1
  while i <= #line and line:sub(i, i):match("%s") do
    i = i + 1
  end
  if line:sub(i, i) == "|" then
    i = i + 1
  end
  local starts, ends = {}, {}
  local c = 1
  starts[1] = i
  while i <= #line do
    if line:sub(i, i) == "|" then
      ends[c] = i - 1
      c = c + 1
      starts[c] = i + 1
    end
    i = i + 1
  end
  ends[c] = #line
  local a = starts[cell_idx] or 1
  local b = ends[cell_idx] or a
  -- 内层去掉两侧空格
  while a <= b and line:sub(a, a) == " " do
    a = a + 1
  end
  while b >= a and line:sub(b, b) == " " do
    b = b - 1
  end
  if around then
    -- 含右侧 |
    local right_bar = ends[cell_idx] and (ends[cell_idx] + 1) or b
    if right_bar <= #line and line:sub(right_bar, right_bar) == "|" then
      b = right_bar
    end
    -- 恢复左侧从 | 后开始（含前导空格）
    a = starts[cell_idx] or a
  end
  if a > b then
    b = a
  end
  vim.api.nvim_win_set_cursor(0, { lnum, a - 1 })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(0, { lnum, b - 1 })
end

function M.delete_row(count)
  count = count or vim.v.count1
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local s, e = find_table_range(buf, lnum)
  if not s then
    notify(i18n.t("not_in_table"), vim.log.levels.WARN)
    return
  end
  local del_s = lnum
  local del_e = math.min(e, lnum + count - 1)
  vim.api.nvim_buf_set_lines(buf, del_s - 1, del_e, false, {})
  -- 对齐剩余
  local new_line_count = vim.api.nvim_buf_line_count(buf)
  local check = math.min(del_s, new_line_count)
  local ns, ne = find_table_range(buf, check)
  if ns then
    realign_range(buf, ns, ne, check, 1)
  end
  notify(i18n.t("deleted_row", del_e - del_s + 1))
end

function M.delete_col(count)
  count = count or vim.v.count1
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local s, e = find_table_range(buf, lnum)
  if not s then
    notify(i18n.t("not_in_table"), vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local cell_idx = F.cursor_cell(line, col)
  local parsed = parse_range(buf, s, e)
  if not parsed then
    return
  end
  local from = cell_idx
  local to = math.min(parsed.col_count, cell_idx + count - 1)
  if from > parsed.col_count then
    return
  end
  for _, r in ipairs(parsed.rows) do
    for _ = from, to do
      if #r.cells >= from then
        table.remove(r.cells, from)
      end
    end
  end
  -- 重建 widths / aligns
  local new_cols = parsed.col_count - (to - from + 1)
  if new_cols < 1 then
    -- 删光：删整表
    vim.api.nvim_buf_set_lines(buf, s - 1, e, false, {})
    notify(i18n.t("deleted_col", to - from + 1))
    return
  end
  local aligns = {}
  local widths = {}
  for i = 1, new_cols do
    local old_i = i < from and i or (i + (to - from + 1))
    aligns[i] = parsed.aligns[old_i] or "left"
    widths[i] = 3
  end
  for _, r in ipairs(parsed.rows) do
    if not r.is_sep then
      for i = 1, new_cols do
        local w = F.strwidth(r.cells[i] or "")
        if w > widths[i] then
          widths[i] = w
        end
      end
    end
  end
  parsed.aligns = aligns
  parsed.widths = widths
  parsed.col_count = new_cols
  local new_lines = F.format_table(parsed, opts_for_buf(buf))
  vim.api.nvim_buf_set_lines(buf, s - 1, e, false, new_lines)
  notify(i18n.t("deleted_col", to - from + 1))
end

---@param before boolean
function M.insert_col(before, count)
  count = count or vim.v.count1
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local s, e = find_table_range(buf, lnum)
  if not s then
    notify(i18n.t("not_in_table"), vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local cell_idx = F.cursor_cell(line, col)
  local insert_at = before and cell_idx or (cell_idx + 1)
  local parsed = parse_range(buf, s, e)
  if not parsed then
    return
  end
  for _ = 1, count do
    for _, r in ipairs(parsed.rows) do
      if r.is_sep then
        table.insert(r.cells, insert_at, "---")
      else
        table.insert(r.cells, insert_at, "")
      end
    end
    table.insert(parsed.aligns, insert_at, "left")
  end
  parsed.col_count = parsed.col_count + count
  local widths = {}
  for i = 1, parsed.col_count do
    widths[i] = 3
  end
  for _, r in ipairs(parsed.rows) do
    if not r.is_sep then
      for i = 1, parsed.col_count do
        local w = F.strwidth(r.cells[i] or "")
        if w > widths[i] then
          widths[i] = w
        end
      end
    end
  end
  parsed.widths = widths
  local new_lines = F.format_table(parsed, opts_for_buf(buf))
  vim.api.nvim_buf_set_lines(buf, s - 1, e, false, new_lines)
  -- 光标移到新列
  local new_line = new_lines[lnum - s + 1] or new_lines[1]
  if new_line then
    local ncol = F.cell_to_col(new_line, insert_at, 0)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(0, ncol - 1) })
  end
  notify(i18n.t("inserted_col", count))
end

---@param line1 integer
---@param line2 integer
---@param delimiter? string
function M.tableize(line1, line2, delimiter)
  local buf = vim.api.nvim_get_current_buf()
  line1 = line1 or vim.fn.line(".")
  line2 = line2 or line1
  if line2 < line1 then
    line1, line2 = line2, line1
  end
  local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
  if #lines == 0 then
    notify(i18n.t("empty_selection"), vim.log.levels.WARN)
    return
  end
  -- 若已是表格，则只对齐
  local all_table = true
  for _, L in ipairs(lines) do
    if not F.is_table_row(L) then
      all_table = false
      break
    end
  end
  if all_table then
    realign_range(buf, line1, line2, line1, 1)
    notify(i18n.t("realigned"))
    return
  end
  delimiter = delimiter or config.delimiter or ","
  if delimiter == "" then
    delimiter = ","
  end
  local matrix = F.split_delimited(lines, delimiter)
  local out = F.matrix_to_table_lines(matrix, opts_for_buf(buf), config.tableize_header_sep ~= false)
  vim.api.nvim_buf_set_lines(buf, line1 - 1, line2, false, out)
  notify(i18n.t("tableized", #out))
end

function M.tableize_prompt(line1, line2)
  vim.ui.input({ prompt = i18n.t("delimiter_prompt") }, function(input)
    if input == nil then
      return
    end
    local d = vim.trim(input)
    if d == "" then
      d = config.delimiter or ","
    end
    if d == "\\t" then
      d = "\t"
    end
    M.tableize(line1, line2, d)
  end)
end

local function feed_default_key(lhs)
  local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  vim.api.nvim_feedkeys(keys, "n", false)
end

local function clear_buf_maps(buf)
  pcall(vim.keymap.del, "i", "|", { buffer = buf })
  for _, lhs in ipairs({
    "]|",
    "[|",
    "}|",
    "{|",
    "<Tab>",
    "<S-Tab>",
    "<Left>",
    "<Right>",
    "<Up>",
    "<Down>",
    "h",
    "j",
    "k",
    "l",
  }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    pcall(vim.keymap.del, "x", lhs, { buffer = buf })
    pcall(vim.keymap.del, "i", lhs, { buffer = buf })
  end
  pcall(vim.keymap.del, "x", "i|", { buffer = buf })
  pcall(vim.keymap.del, "x", "a|", { buffer = buf })
  pcall(vim.keymap.del, "o", "i|", { buffer = buf })
  pcall(vim.keymap.del, "o", "a|", { buffer = buf })
end

local function apply_buf_maps(buf)
  clear_buf_maps(buf)
  if not buf_enabled[buf] then
    return
  end
  set_insert_pipe_map(buf, true)

  if config.map_motions ~= false then
    local function map_move(lhs, dir, motion)
      vim.keymap.set({ "n", "x" }, lhs, function()
        -- 专用键：边界也尽量换格；无法移动时回落默认
        M.move_or_exit(dir, motion)
      end, { buffer = buf, silent = true, desc = "tablemode: cell " .. dir })
    end
    map_move("]|", "right", "l")
    map_move("[|", "left", "h")
    map_move("}|", "down", "j")
    map_move("{|", "up", "k")
  end

  -- normal 方向键：表内按格，边界可移出
  if config.map_arrows ~= false then
    local arrows = {
      { "<Left>", "left", "h" },
      { "<Right>", "right", "l" },
      { "<Up>", "up", "k" },
      { "<Down>", "down", "j" },
    }
    for _, item in ipairs(arrows) do
      local lhs, dir, motion = item[1], item[2], item[3]
      vim.keymap.set("n", lhs, function()
        M.move_or_exit(dir, motion)
      end, { buffer = buf, silent = true, desc = "tablemode: cell " .. dir })
    end
  end

  -- normal hjkl：表内按格，边界再按用默认运动移出表格
  if config.map_hjkl ~= false then
    local hjkl = {
      { "h", "left" },
      { "l", "right" },
      { "k", "up" },
      { "j", "down" },
    }
    for _, item in ipairs(hjkl) do
      local lhs, dir = item[1], item[2]
      vim.keymap.set("n", lhs, function()
        M.move_or_exit(dir, lhs)
      end, { buffer = buf, silent = true, desc = "tablemode: cell " .. dir })
    end
  end

  if config.map_tab ~= false then
    -- 不可用 expr 映射：expr 上下文禁止 nvim_buf_set_lines（E565）
    vim.keymap.set("i", "<Tab>", function()
      if not M.tab_cell(1) then
        feed_default_key("<Tab>")
      end
    end, { buffer = buf, silent = true, desc = "tablemode: next cell" })
    vim.keymap.set("i", "<S-Tab>", function()
      if not M.tab_cell(-1) then
        feed_default_key("<S-Tab>")
      end
    end, { buffer = buf, silent = true, desc = "tablemode: prev cell" })
    if config.tab_normal ~= false then
      vim.keymap.set("n", "<Tab>", function()
        if not M.tab_cell(1) then
          feed_default_key("<Tab>")
        end
      end, { buffer = buf, silent = true, desc = "tablemode: next cell" })
      vim.keymap.set("n", "<S-Tab>", function()
        if not M.tab_cell(-1) then
          feed_default_key("<S-Tab>")
        end
      end, { buffer = buf, silent = true, desc = "tablemode: prev cell" })
    end
  end

  if config.map_text_objects ~= false then
    vim.keymap.set({ "x", "o" }, "i|", function()
      M.select_cell(false)
    end, { buffer = buf, silent = true, desc = "tablemode: inner cell" })
    vim.keymap.set({ "x", "o" }, "a|", function()
      M.select_cell(true)
    end, { buffer = buf, silent = true, desc = "tablemode: around cell" })
  end
end

function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  buf_enabled[buf] = true
  apply_buf_maps(buf)
  attach_live_align(buf)
  update_status(buf)
  notify(i18n.t("enabled"))
end

function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  buf_enabled[buf] = false
  detach_live_align(buf)
  clear_buf_maps(buf)
  update_status(buf)
  notify(i18n.t("disabled"))
end

function M.toggle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if buf_enabled[buf] then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

function M.is_enabled(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return buf_enabled[buf] == true
end

local function apply_global_keys()
  for _, lhs in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", lhs)
    pcall(vim.keymap.del, "x", lhs)
  end
  keys_applied = {}

  local function add(lhs, fn, mode, desc)
    if not lhs or lhs == false or lhs == "" then
      return
    end
    mode = mode or "n"
    vim.keymap.set(mode, lhs, fn, { silent = true, desc = desc })
    keys_applied[#keys_applied + 1] = lhs
  end

  add(config.keys_toggle, function()
    M.toggle()
  end, "n", "tablemode: toggle")

  add(config.keys_realign, function()
    M.realign()
  end, "n", "tablemode: realign")

  add(config.keys_tableize, function()
    local v = vim.fn.mode():match("[vV\22]")
    if v then
      local l1 = vim.fn.line("v")
      local l2 = vim.fn.line(".")
      M.tableize(l1, l2)
    else
      M.tableize(vim.fn.line("."), vim.fn.line("."))
    end
  end, { "n", "x" }, "tablemode: tableize")

  add(config.keys_tableize_op, function()
    local mode = vim.fn.mode()
    local l1, l2
    if mode:match("[vV\22]") then
      l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    else
      local c = vim.v.count1
      l1 = vim.fn.line(".")
      l2 = math.min(vim.api.nvim_buf_line_count(0), l1 + c - 1)
    end
    M.tableize_prompt(l1, l2)
  end, { "n", "x" }, "tablemode: tableize with delimiter")

  add(config.keys_delete_row, function()
    M.delete_row(vim.v.count1)
  end, "n", "tablemode: delete row")

  add(config.keys_delete_col, function()
    M.delete_col(vim.v.count1)
  end, "n", "tablemode: delete column")

  add(config.keys_insert_col_after, function()
    M.insert_col(false, vim.v.count1)
  end, "n", "tablemode: insert column after")

  add(config.keys_insert_col_before, function()
    M.insert_col(true, vim.v.count1)
  end, "n", "tablemode: insert column before")
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  local lang = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang = user.ui_lang
  end
  if lang == "zh" or lang == "en" then
    i18n.setup(lang)
  else
    i18n.setup("auto")
  end
  apply_global_keys()

  -- buffer 清理 + 实时对齐 augroup
  local aug = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_augroup(AUGROUP_LIVE, { clear = true })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = aug,
    callback = function(ev)
      detach_live_align(ev.buf)
      buf_enabled[ev.buf] = nil
      aligning[ev.buf] = nil
    end,
  })

  -- 已开启的 buffer 按新配置重挂 live autocmd
  for b, on in pairs(buf_enabled) do
    if on and vim.api.nvim_buf_is_valid(b) then
      attach_live_align(b)
    end
  end

  setup_done = true
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

function M.get_config()
  return config
end

---供测试 / 脚本
M._format = F

return M
