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
  ---Ctrl-v 单元格块选：进入选中当前整格；hjkl/方向键按格扩展；y 复制为 TSV（去 |）
  map_vblock = true,
  ---开启模式后高亮表头背景与表格线（| / 分隔行）
  highlight = true,
  ---表头行高亮组（背景）
  hl_header = "TableModeHeader",
  ---表格线高亮组（| - : + =）
  hl_border = "TableModeBorder",
  ---高亮刷新防抖（毫秒）
  highlight_ms = 80,
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
---单元格块选：buf → { r1, c1, r2, c2, table_s, table_e }
---r* 为 buffer 行号（数据行），c* 为单元格索引（1-based）；(r1,c1) 锚点，(r2,c2) 自由角
local buf_vblock = {}
---正在 apply 块选（先退可视再进），避免 ModeChanged 清掉状态
local applying_vblock = {}
---块选期间临时 virtualedit：win → 原值
local vblock_ve_save = {}
---高亮刷新 timer
local hl_timers = {}
---extmark 命名空间
local NS_HL = vim.api.nvim_create_namespace("tablemode_hl")
local hl_defined = false

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
  -- 对齐后刷新表头/表格线高亮
  M.refresh_highlights(buf)
  return true
end

---定义默认高亮组（ColorScheme / setup 时重设；可用 hi 覆盖）
local function ensure_highlight_groups()
  -- 表头：淡蓝底；表格线：加粗 + 清晰前景
  vim.api.nvim_set_hl(0, "TableModeHeader", {
    bg = "#6b8fb5",
    ctermbg = 67,
  })
  vim.api.nvim_set_hl(0, "TableModeBorder", {
    bold = true,
    fg = "#89b4fa",
    ctermfg = 111,
  })
  hl_defined = true
end

---@param buf integer
local function clear_highlights(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS_HL, 0, -1)
  end
end

---为单行打表格线高亮（| +，分隔行另含 - = :）
---@param buf integer
---@param row0 integer  0-based
---@param line string
---@param is_sep boolean
---@param hl_border string
local function highlight_borders_on_line(buf, row0, line, is_sep, hl_border)
  if not line or line == "" then
    return
  end
  local i = 1
  local n = #line
  while i <= n do
    local ch = line:sub(i, i)
    local paint = ch == "|" or ch == "+"
    if is_sep and (ch == "-" or ch == "=" or ch == ":" or ch == "+") then
      paint = true
    end
    if paint then
      local j = i
      while j + 1 <= n do
        local c2 = line:sub(j + 1, j + 1)
        local ok2 = c2 == "|" or c2 == "+"
        if is_sep and (c2 == "-" or c2 == "=" or c2 == ":" or c2 == "+") then
          ok2 = true
        end
        if not ok2 then
          break
        end
        j = j + 1
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, NS_HL, row0, i - 1, {
        end_row = row0,
        end_col = j,
        hl_group = hl_border,
        priority = 120,
        strict = false,
      })
      i = j + 1
    else
      i = i + 1
    end
  end
end

---扫描 buffer 内所有表格并刷新高亮
---@param buf? integer
function M.refresh_highlights(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  clear_highlights(buf)
  if not buf_enabled[buf] or config.highlight == false then
    return
  end
  ensure_highlight_groups()
  local hl_header = config.hl_header or "TableModeHeader"
  local hl_border = config.hl_border or "TableModeBorder"
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local i = 1
  local n = #lines
  while i <= n do
    if F.is_table_row(lines[i]) then
      local s = i
      while i <= n and F.is_table_row(lines[i]) do
        i = i + 1
      end
      local e = i - 1
      -- 首条分隔行之前的那一行视为表头（GFM）
      local header_lnum = nil
      for r = s, e do
        if F.is_separator_line(lines[r]) then
          if r > s then
            header_lnum = r - 1
          end
          break
        end
      end
      for r = s, e do
        local line = lines[r] or ""
        local row0 = r - 1
        local is_sep = F.is_separator_line(line)
        -- 表头：仅单元格正文有背景（不含两侧空格与 |）
        if header_lnum and r == header_lnum and not is_sep then
          local ncol = F.cell_count(line)
          for c = 1, ncol do
            local sp = F.cell_span(line, c)
            if sp.content_start <= sp.content_end then
              pcall(vim.api.nvim_buf_set_extmark, buf, NS_HL, row0, sp.content_start - 1, {
                end_row = row0,
                end_col = sp.content_end, -- 1-based 闭区间 → nvim 半开 end
                hl_group = hl_header,
                priority = 90,
                strict = false,
              })
            end
          end
        end
        highlight_borders_on_line(buf, row0, line, is_sep, hl_border)
      end
    else
      i = i + 1
    end
  end
end

local function clear_hl_timer(buf)
  local t = hl_timers[buf]
  if t then
    pcall(vim.fn.timer_stop, t)
    hl_timers[buf] = nil
  end
end

---@param buf integer
local function schedule_hl_refresh(buf)
  if not buf_enabled[buf] or config.highlight == false then
    return
  end
  clear_hl_timer(buf)
  local ms = tonumber(config.highlight_ms) or 80
  if ms <= 0 then
    vim.schedule(function()
      if buf_enabled[buf] then
        M.refresh_highlights(buf)
      end
    end)
    return
  end
  hl_timers[buf] = vim.fn.timer_start(ms, function()
    hl_timers[buf] = nil
    vim.schedule(function()
      if buf_enabled[buf] and vim.api.nvim_buf_is_valid(buf) then
        M.refresh_highlights(buf)
      end
    end)
  end)
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
      schedule_hl_refresh(ev.buf)
    end,
  })
  if config.auto_align_on_insert_leave ~= false then
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = AUGROUP_LIVE,
      buffer = buf,
      callback = function(ev)
        clear_live_timer(ev.buf)
        live_align_now(ev.buf)
        schedule_hl_refresh(ev.buf)
      end,
    })
  end
end

local function detach_live_align(buf)
  clear_live_timer(buf)
  clear_hl_timer(buf)
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

---退出可视模式（若在）
local function leave_visual()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    pcall(vim.cmd, "normal! \27")
  end
end

---单元格内容的屏幕列范围（1-based virtcol，含端点）
---@param lnum integer
---@param line string
---@param cell_idx integer
---@return integer vc_left
---@return integer vc_right
local function cell_virt_range(lnum, line, cell_idx)
  local a, b = F.cell_select_range(line, cell_idx)
  a = math.max(1, a or 1)
  b = math.max(a, b or a)
  local vc_a = vim.fn.virtcol({ lnum, a })
  if type(vc_a) ~= "number" or vc_a < 1 then
    vc_a = 1
  end
  local text = line:sub(a, b)
  local w = vim.fn.strdisplaywidth(text)
  if w < 1 then
    w = 1
  end
  return vc_a, vc_a + w - 1
end

---应用单元格矩形块选（真正的 Ctrl-v 覆盖锚点→自由角矩形）
---左右边界取所选各数据行中该列的最小/最大屏幕列，避免短行裁掉长行右侧
---@param buf integer
local function apply_cell_block(buf)
  local vb = buf_vblock[buf]
  if not vb then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local r_top = math.min(vb.r1, vb.r2)
  local r_bot = math.max(vb.r1, vb.r2)
  local c_lo = math.min(vb.c1, vb.c2)
  local c_hi = math.max(vb.c1, vb.c2)

  local vc_left, vc_right = math.huge, 0
  for lnum = r_top, r_bot do
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    if F.is_table_row(line) and not F.is_separator_line(line) then
      local vl, _vr_lo = cell_virt_range(lnum, line, c_lo)
      local _vl_hi, vr = cell_virt_range(lnum, line, c_hi)
      if vl < vc_left then
        vc_left = vl
      end
      if vr > vc_right then
        vc_right = vr
      end
    end
  end
  if vc_left == math.huge or vc_right < 1 then
    return
  end
  if vc_right < vc_left then
    vc_right = vc_left
  end

  ---把光标放到 (lnum, virtcol)，短行靠 virtualedit + curswant
  ---@param lnum integer
  ---@param vc integer
  local function goto_virtcol(lnum, vc)
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    local bcol = vim.fn.virtcol2col(win, lnum, vc)
    if type(bcol) ~= "number" or bcol < 1 then
      -- 超出实字符：落到行尾字节，靠 curswant 伸到虚拟列
      bcol = math.max(1, #line)
    end
    -- setpos 第 5 项为 curswant（期望屏幕列）
    vim.fn.setpos(".", { 0, lnum, bcol, 0, vc })
    -- 再强制一次 | ，在 virtualedit 下尽量贴齐 vc
    pcall(vim.cmd, "normal! " .. tostring(vc) .. "|")
  end

  applying_vblock[buf] = true
  leave_visual()
  -- 块选期间保持 virtualedit=all，短行才能落到虚拟列盖住长行右侧；
  -- 退出可视时再恢复（见 restore_vblock_virtualedit）
  if vblock_ve_save[win] == nil then
    vblock_ve_save[win] = vim.wo[win].virtualedit
  end
  vim.wo[win].virtualedit = "all"
  local ok, err = pcall(function()
    goto_virtcol(r_top, vc_left)
    vim.cmd("normal! \22")
    goto_virtcol(r_bot, vc_right)
  end)
  applying_vblock[buf] = nil
  if not ok then
    vim.notify("tablemode: vblock " .. tostring(err), vim.log.levels.DEBUG)
  end
end

---退出块选后恢复窗口 virtualedit
local function restore_vblock_virtualedit()
  for win, ve in pairs(vblock_ve_save) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(function()
        vim.wo[win].virtualedit = ve
      end)
    end
    vblock_ve_save[win] = nil
  end
end

---Ctrl-v：从当前格开始块选（至少选中一格内容）
function M.vblock_start()
  local buf = vim.api.nvim_get_current_buf()
  if not buf_enabled[buf] then
    pcall(vim.cmd, "normal! \22")
    return
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2] + 1
  local s, e = find_table_range(buf, lnum)
  if not s then
    buf_vblock[buf] = nil
    pcall(vim.cmd, "normal! \22")
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  if F.is_separator_line(line) or not F.is_table_row(line) then
    local nl = next_data_line(buf, lnum, e, 1) or next_data_line(buf, lnum, s, -1)
    if not nl then
      buf_vblock[buf] = nil
      pcall(vim.cmd, "normal! \22")
      return
    end
    lnum = nl
    line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    col = 1
  end
  local cell_idx = F.cursor_cell(line, col)
  local parsed = parse_range(buf, s, e)
  local ncol = parsed and parsed.col_count or F.cell_count(line)
  cell_idx = math.max(1, math.min(ncol, cell_idx))
  buf_vblock[buf] = {
    r1 = lnum,
    c1 = cell_idx,
    r2 = lnum,
    c2 = cell_idx,
    table_s = s,
    table_e = e,
  }
  apply_cell_block(buf)
end

---块选中扩展：一次一行/一列单元格（移动自由角 r2,c2）
---@param dr integer
---@param dc integer
function M.vblock_extend(dr, dc)
  local buf = vim.api.nvim_get_current_buf()
  local vb = buf_vblock[buf]
  if not vb then
    local motion = (dr == 1 and "j") or (dr == -1 and "k") or (dc == 1 and "l") or "h"
    default_motion(motion, vim.v.count1)
    return
  end
  local count = vim.v.count1
  local s, e = vb.table_s, vb.table_e
  -- 表范围可能因编辑变化，尽量刷新
  local ns, ne = find_table_range(buf, vb.r2)
  if ns then
    s, e = ns, ne
    vb.table_s, vb.table_e = s, e
  end
  local parsed = parse_range(buf, s, e)
  local ncol = parsed and parsed.col_count or 1
  for _ = 1, count do
    if dr ~= 0 then
      local step = dr > 0 and 1 or -1
      local last = dr > 0 and e or s
      local nl = next_data_line(buf, vb.r2, last, step)
      if nl then
        vb.r2 = nl
      end
    end
    if dc ~= 0 then
      local line = vim.api.nvim_buf_get_lines(buf, vb.r2 - 1, vb.r2, false)[1] or ""
      local row_cols = math.max(ncol, F.cell_count(line))
      local nc = vb.c2 + dc
      if nc < 1 then
        nc = 1
      elseif nc > row_cols then
        nc = row_cols
      end
      vb.c2 = nc
    end
  end
  apply_cell_block(buf)
end

---从可视选区推导表内单元格矩形（无 vblock 状态时）
---@param buf integer
---@return integer|nil r1
---@return integer|nil c1
---@return integer|nil r2
---@return integer|nil c2
local function visual_table_cell_range(buf)
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    return nil
  end
  local p1 = vim.fn.getpos("v")
  local p2 = vim.fn.getpos(".")
  local l1, bcol1 = p1[2], math.max(1, p1[3])
  local l2, bcol2 = p2[2], math.max(1, p2[3])
  if l1 > l2 then
    l1, l2 = l2, l1
    bcol1, bcol2 = bcol2, bcol1
  end
  local s1, e1 = find_table_range(buf, l1)
  local s2 = find_table_range(buf, l2)
  if not s1 or not s2 or s1 ~= s2 then
    return nil
  end
  local line1 = vim.api.nvim_buf_get_lines(buf, l1 - 1, l1, false)[1] or ""
  local line2 = vim.api.nvim_buf_get_lines(buf, l2 - 1, l2, false)[1] or ""
  if not F.is_table_row(line1) and not F.is_table_row(line2) then
    return nil
  end
  local parsed = parse_range(buf, s1, e1)
  local ncol = parsed and parsed.col_count or 1
  local c1, c2
  if mode == "V" then
    c1, c2 = 1, ncol
  else
    c1 = F.cursor_cell(line1, bcol1)
    c2 = F.cursor_cell(line2, bcol2)
  end
  -- 端点落在分隔行时夹到邻近数据行
  if F.is_separator_line(line1) then
    local nl = next_data_line(buf, l1, e1, 1) or next_data_line(buf, l1, s1, -1)
    if nl then
      l1 = nl
    end
  end
  if F.is_separator_line(line2) then
    local nl = next_data_line(buf, l2, s1, -1) or next_data_line(buf, l2, e1, 1)
    if nl then
      l2 = nl
    end
  end
  return l1, c1, l2, c2
end

---矩形单元格 → Tab 分隔文本（Excel 风格，去掉 |）
---@param buf integer
---@param r1 integer
---@param c1 integer
---@param r2 integer
---@param c2 integer
---@return string
---@return integer nrows
---@return integer ncols
local function format_cells_tsv(buf, r1, c1, r2, c2)
  local top, bot = math.min(r1, r2), math.max(r1, r2)
  local clo, chi = math.min(c1, c2), math.max(c1, c2)
  local out = {}
  for lnum = top, bot do
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    if F.is_table_row(line) and not F.is_separator_line(line) then
      local cells = F.split_row(line)
      local parts = {}
      for c = clo, chi do
        local t = cells[c] or ""
        -- 格内换行收成空格，便于粘贴
        t = t:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n+", " ")
        parts[#parts + 1] = t
      end
      out[#out + 1] = table.concat(parts, "\t")
    end
  end
  local text = table.concat(out, "\n")
  return text, #out, chi - clo + 1
end

---可视模式 y：复制选中单元格为 TSV（去 |）；非表内回落默认 yank
function M.yank_visual()
  local buf = vim.api.nvim_get_current_buf()
  local r1, c1, r2, c2
  local vb = buf_vblock[buf]
  if vb then
    r1, c1, r2, c2 = vb.r1, vb.c1, vb.r2, vb.c2
  else
    r1, c1, r2, c2 = visual_table_cell_range(buf)
  end
  if not r1 then
    pcall(vim.cmd, "normal! y")
    return
  end
  local text, nrows, ncols = format_cells_tsv(buf, r1, c1, r2, c2)
  if text == "" then
    leave_visual()
    buf_vblock[buf] = nil
    return
  end
  if not text:match("\n$") then
    text = text .. "\n"
  end
  vim.fn.setreg('"', text, "l")
  pcall(vim.fn.setreg, "+", text, "l")
  pcall(vim.fn.setreg, "*", text, "l")
  leave_visual()
  buf_vblock[buf] = nil
  restore_vblock_virtualedit()
  pcall(vim.api.nvim_echo, {
    { i18n.t("yanked_cells", nrows, ncols), "ModeMsg" },
  }, false, {})
end

function M.clear_vblock(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  buf_vblock[buf] = nil
  restore_vblock_virtualedit()
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
    "<C-v>",
    "<C-q>",
    "y",
    "<C-c>",
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

  -- Ctrl-v 单元格块选 + 可视扩展 + TSV 复制
  if config.map_vblock ~= false then
    vim.keymap.set("n", "<C-v>", function()
      M.vblock_start()
    end, { buffer = buf, silent = true, desc = "tablemode: cell block select" })
    -- Windows 终端里 Ctrl-v 常被占用，Ctrl-q 作备用
    vim.keymap.set("n", "<C-q>", function()
      M.vblock_start()
    end, { buffer = buf, silent = true, desc = "tablemode: cell block select" })

    local xopts = { buffer = buf, silent = true, desc = "tablemode: extend cell block" }
    local function xext(dr, dc)
      return function()
        if buf_vblock[buf] then
          M.vblock_extend(dr, dc)
        else
          local motion = (dr == 1 and "j") or (dr == -1 and "k") or (dc == 1 and "l") or "h"
          default_motion(motion, vim.v.count1)
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

    vim.keymap.set("x", "y", function()
      M.yank_visual()
    end, { buffer = buf, silent = true, desc = "tablemode: yank cells as TSV" })
    vim.keymap.set("x", "<C-c>", function()
      M.yank_visual()
    end, { buffer = buf, silent = true, desc = "tablemode: yank cells as TSV" })
  end
end

function M.enable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  buf_enabled[buf] = true
  apply_buf_maps(buf)
  attach_live_align(buf)
  update_status(buf)
  M.refresh_highlights(buf)
  notify(i18n.t("enabled"))
end

function M.disable(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  buf_enabled[buf] = false
  buf_vblock[buf] = nil
  detach_live_align(buf)
  clear_buf_maps(buf)
  clear_highlights(buf)
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
      clear_highlights(ev.buf)
      buf_enabled[ev.buf] = nil
      aligning[ev.buf] = nil
      buf_vblock[ev.buf] = nil
      hl_timers[ev.buf] = nil
    end,
  })
  -- 进入 normal 时清块选状态并恢复 virtualedit（apply 重绘期间跳过）
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = aug,
    pattern = "*:n",
    callback = function(ev)
      local b = ev.buf
      if b and not applying_vblock[b] then
        if buf_vblock[b] then
          buf_vblock[b] = nil
        end
        restore_vblock_virtualedit()
      end
    end,
  })
  -- colorscheme 切换后重设默认高亮并刷新已开启 buffer
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = aug,
    callback = function()
      hl_defined = false
      ensure_highlight_groups()
      for b, on in pairs(buf_enabled) do
        if on and vim.api.nvim_buf_is_valid(b) then
          M.refresh_highlights(b)
        end
      end
    end,
  })

  -- 已开启的 buffer 按新配置重挂 live autocmd + 高亮
  for b, on in pairs(buf_enabled) do
    if on and vim.api.nvim_buf_is_valid(b) then
      attach_live_align(b)
      M.refresh_highlights(b)
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
