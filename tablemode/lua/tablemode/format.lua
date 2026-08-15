---@mod tablemode.format 表格解析与对齐（纯函数）
local M = {}

---@alias Align "left"|"right"|"center"
---@alias TableStyle "gfm"|"unicode"

---@class TableOpts
---@field corner string  单元格角/竖线，Markdown 多为 "|"
---@field corner_corner string  分隔行交叉角，"+" 或 "|"
---@field fillchar string  普通分隔填充 "-"
---@field header_fillchar string  表头分隔填充，默认同 fillchar；ReST 可用 "="
---@field align_char string  对齐标记 ":"
---@field separator string  列分隔符，默认 "|"
---@field table_style? TableStyle  "gfm"（| --- |）或 "unicode"（mdview 框线）

-- mdview 风格 Unicode 框线
local BOX = {
  h = "─",
  v = "│",
  tl = "┌",
  tr = "┐",
  bl = "└",
  br = "┘",
  tm = "┬",
  bm = "┴",
  ml = "├",
  mr = "┤",
  mm = "┼",
}

---@param s string
---@return integer
function M.strwidth(s)
  if s == nil or s == "" then
    return 0
  end
  if vim.fn and vim.fn.strdisplaywidth then
    return vim.fn.strdisplaywidth(s)
  end
  if vim.api and vim.api.nvim_strwidth then
    return vim.api.nvim_strwidth(s)
  end
  return #s
end

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---是否含 Unicode 框线字符
---@param s string
---@return boolean
function M.has_box_chars(s)
  if not s or s == "" then
    return false
  end
  return s:find("[│┌┐└┘├┤┬┴┼─]", 1) ~= nil
    or s:find(BOX.v, 1, true) ~= nil
    or s:find(BOX.h, 1, true) ~= nil
end

---Unicode 顶/中/底框线行（无单元格正文）
---@param line string
---@return boolean
function M.is_box_frame_line(line)
  local s = trim(line or "")
  if s == "" or not M.has_box_chars(s) then
    return false
  end
  -- 仅允许框线、对齐冒号、空白
  local stripped = s
    :gsub(BOX.tl, "")
    :gsub(BOX.tr, "")
    :gsub(BOX.bl, "")
    :gsub(BOX.br, "")
    :gsub(BOX.tm, "")
    :gsub(BOX.bm, "")
    :gsub(BOX.ml, "")
    :gsub(BOX.mr, "")
    :gsub(BOX.mm, "")
    :gsub(BOX.h, "")
    :gsub(":", "")
    :gsub("%s+", "")
  if stripped ~= "" then
    return false
  end
  -- 至少有一段横线
  return s:find(BOX.h, 1, true) ~= nil
end

---是否为分隔行（GFM ---|:---| 或 Unicode 框线）
---@param line string
---@return boolean
function M.is_separator_line(line)
  if type(line) ~= "string" then
    return false
  end
  local s = trim(line)
  if s == "" then
    return false
  end
  if M.is_box_frame_line(s) then
    return true
  end
  -- GFM：允许 | --- | :---: | ---+--- |
  if not s:find("[%-%=%:]", 1) then
    return false
  end
  if s:sub(1, 1) == "|" then
    s = s:sub(2)
  end
  if s:sub(-1) == "|" then
    s = s:sub(1, -2)
  end
  if s:find("[^%s%-%=%:%|+]") then
    return false
  end
  return s:find("%-+") ~= nil or s:find("%=+") ~= nil
end

---是否像表格数据行（GFM | 或 Unicode │ / 框线）
---@param line string
---@return boolean
function M.is_table_row(line)
  if type(line) ~= "string" then
    return false
  end
  local s = trim(line)
  if s == "" then
    return false
  end
  if M.is_separator_line(s) then
    return true
  end
  -- Unicode 数据行
  if s:find(BOX.v, 1, true) then
    local _, n = s:gsub(BOX.v, BOX.v)
    return n >= 2
  end
  -- GFM
  local _, n = s:gsub("|", "")
  if n >= 2 then
    return true
  end
  if s:sub(1, 1) == "|" and n >= 1 then
    return true
  end
  return false
end

---当前行使用的竖线字符（"|" 或 "│"）
---@param line string
---@return string
function M.row_vbar(line)
  local s = line or ""
  if s:find(BOX.v, 1, true) then
    return BOX.v
  end
  return "|"
end

function M.box_chars()
  return BOX
end

---解析分隔格对齐
---@param cell string
---@param align_char string
---@return Align
function M.parse_align_cell(cell, align_char)
  align_char = align_char or ":"
  local t = trim(cell or "")
  if t == "" then
    return "left"
  end
  local left = t:sub(1, 1) == align_char
  local right = t:sub(-1) == align_char
  if left and right then
    return "center"
  end
  if right then
    return "right"
  end
  return "left"
end

---按竖线/交叉角拆分（支持 | 与 Unicode │ ┼ ┬ ┴ 等）
---@param raw string  已去掉首尾框的内容
---@param is_sep boolean
---@return string[]
local function split_cells_raw(raw, is_sep)
  local cells = {}
  if raw == "" then
    return { "" }
  end
  if is_sep and M.has_box_chars(raw) then
    -- Unicode 分隔：按 ┼ ┬ ┴ 拆；无交叉角时整段为一格
    local parts = {}
    local buf = {}
    local i = 1
    while i <= #raw do
      local ch3 = raw:sub(i, i + 2)
      if ch3 == BOX.mm or ch3 == BOX.tm or ch3 == BOX.bm then
        parts[#parts + 1] = table.concat(buf)
        buf = {}
        i = i + 3
      else
        buf[#buf + 1] = raw:sub(i, i)
        i = i + 1
      end
    end
    parts[#parts + 1] = table.concat(buf)
    for _, p in ipairs(parts) do
      cells[#cells + 1] = trim(p)
    end
  elseif is_sep then
    for part in (raw .. "|"):gmatch("([^|+]*)[+|]") do
      cells[#cells + 1] = trim(part)
    end
  elseif raw:find(BOX.v, 1, true) then
    -- 用 plain find 按 │ 拆
    local start = 1
    while true do
      local a, b = raw:find(BOX.v, start, true)
      if not a then
        cells[#cells + 1] = trim(raw:sub(start))
        break
      end
      cells[#cells + 1] = trim(raw:sub(start, a - 1))
      start = b + 1
    end
    -- 去掉因首尾 │ 产生的空端（与 GFM 一致：│ a │ b │ → a, b）
    if #cells >= 2 and cells[1] == "" then
      table.remove(cells, 1)
    end
    if #cells >= 1 and cells[#cells] == "" then
      cells[#cells] = nil
    end
  else
    for part in (raw .. "|"):gmatch("([^|]*)|") do
      cells[#cells + 1] = trim(part)
    end
  end
  if #cells == 0 then
    cells = { "" }
  end
  return cells
end

---拆分一行单元格（保留空单元格）
---@param line string
---@return string[] cells
---@return boolean is_sep
function M.split_row(line)
  local s = (line or ""):gsub("\r$", "")
  local is_sep = M.is_separator_line(s)
  local raw = trim(s)
  -- 去掉首尾竖线 / 框角
  local function strip_ends(str)
    local t = str
    local changed = true
    while changed do
      changed = false
      for _, ch in ipairs({
        "|",
        BOX.v,
        BOX.tl,
        BOX.tr,
        BOX.bl,
        BOX.br,
        BOX.ml,
        BOX.mr,
        BOX.tm,
        BOX.bm,
      }) do
        if t:sub(1, #ch) == ch then
          t = t:sub(#ch + 1)
          changed = true
        end
        if t:sub(-#ch) == ch then
          t = t:sub(1, #t - #ch)
          changed = true
        end
      end
    end
    return t
  end
  raw = strip_ends(raw)
  return split_cells_raw(raw, is_sep), is_sep
end

---@param text string
---@param width integer
---@param align Align
---@return string
function M.pad_cell(text, width, align)
  text = text or ""
  local w = M.strwidth(text)
  local pad = width - w
  if pad < 0 then
    pad = 0
  end
  if align == "right" then
    return string.rep(" ", pad) .. text
  end
  if align == "center" then
    local left = math.floor(pad / 2)
    local right = pad - left
    return string.rep(" ", left) .. text .. string.rep(" ", right)
  end
  return text .. string.rep(" ", pad)
end

---生成分隔单元格
---@param width integer
---@param align Align
---@param fillchar string
---@param align_char string
---@return string
function M.make_sep_cell(width, align, fillchar, align_char)
  -- 支持多字节填充（如 ─）；只取第一个“字符”而非第一个字节
  if not fillchar or fillchar == "" then
    fillchar = "-"
  else
    local ok, first = pcall(vim.fn.strcharpart, fillchar, 0, 1)
    if ok and first and first ~= "" then
      fillchar = first
    else
      fillchar = fillchar:sub(1, 1)
    end
  end
  align_char = align_char or ":"
  width = math.max(width, 3)
  if align == "center" then
    return align_char .. string.rep(fillchar, width - 2) .. align_char
  end
  if align == "right" then
    return string.rep(fillchar, width - 1) .. align_char
  end
  if align == "left" then
    -- Markdown 惯例：:--- 或 ---
    return string.rep(fillchar, width)
  end
  return string.rep(fillchar, width)
end

---@param cells string[]
---@param widths integer[]
---@param aligns Align[]
---@param opts TableOpts
---@param is_sep boolean
---@param is_header_sep boolean|nil
---@return string
function M.format_row(cells, widths, aligns, opts, is_sep, is_header_sep)
  opts = opts or {}
  local style = opts.table_style or "gfm"
  if style == "unicode" then
    -- unicode 整表由 format_table 处理；单行数据/中线兜底
    local fill = BOX.h
    local align_char = opts.align_char or ":"
    local parts = {}
    local ncol = #widths
    for i = 1, ncol do
      local w = widths[i] or 3
      local al = aligns[i] or "left"
      if is_sep then
        -- 中线格宽 = 内容宽 + 两侧空格
        parts[i] = M.make_sep_cell(w + 2, al, fill, align_char)
      else
        parts[i] = M.pad_cell(cells[i] or "", w, al)
      end
    end
    if is_sep then
      return BOX.ml .. table.concat(parts, BOX.mm) .. BOX.mr
    end
    return BOX.v .. " " .. table.concat(parts, " " .. BOX.v .. " ") .. " " .. BOX.v
  end

  local corner = opts.corner or "|"
  local corner_corner = opts.corner_corner or corner
  local fill = is_header_sep and (opts.header_fillchar or opts.fillchar or "-") or (opts.fillchar or "-")
  local align_char = opts.align_char or ":"
  local parts = {}
  local ncol = #widths
  for i = 1, ncol do
    local w = widths[i] or 3
    local al = aligns[i] or "left"
    if is_sep then
      parts[i] = M.make_sep_cell(w, al, fill, align_char)
    else
      parts[i] = M.pad_cell(cells[i] or "", w, al)
    end
  end
  -- 分隔交叉角用 + 时：|---+---+---|（紧凑）
  if is_sep and corner_corner ~= corner then
    return corner .. table.concat(parts, corner_corner) .. corner
  end
  -- GFM 惯例：| cell | cell |（竖线两侧空格）
  return corner .. " " .. table.concat(parts, " " .. corner .. " ") .. " " .. corner
end

---Unicode 顶/底边框行
---@param widths integer[]
---@param left string
---@param mid string
---@param right string
---@return string
function M.format_box_border(widths, left, mid, right)
  local parts = {}
  for i = 1, #widths do
    -- 与 " " .. pad(w) .. " " 同宽
    parts[i] = string.rep(BOX.h, (widths[i] or 3) + 2)
  end
  return left .. table.concat(parts, mid) .. right
end

---@class ParsedTable
---@field start_line integer  1-based
---@field end_line integer
---@field rows { cells: string[], is_sep: boolean }[]
---@field aligns Align[]
---@field widths integer[]
---@field col_count integer

---从行列表解析整张表
---@param lines string[]
---@param opts? TableOpts
---@return ParsedTable|nil
function M.parse_lines(lines, opts)
  opts = opts or {}
  if not lines or #lines == 0 then
    return nil
  end
  local rows = {}
  local max_cols = 0
  for _, line in ipairs(lines) do
    if not M.is_table_row(line) then
      return nil
    end
    local cells, is_sep = M.split_row(line)
    rows[#rows + 1] = { cells = cells, is_sep = is_sep }
    if #cells > max_cols then
      max_cols = #cells
    end
  end
  if max_cols == 0 then
    return nil
  end
  -- 统一列数
  for _, r in ipairs(rows) do
    while #r.cells < max_cols do
      r.cells[#r.cells + 1] = ""
    end
  end
  -- 对齐：优先取「首条数据行之后」的分隔行（Unicode 中线）；否则第一条分隔行
  local aligns = {}
  for i = 1, max_cols do
    aligns[i] = "left"
  end
  local align_char = opts.align_char or ":"
  local first_sep_aligns = nil
  local mid_aligns = nil
  local seen_data = false
  for _, r in ipairs(rows) do
    if r.is_sep then
      local a = {}
      for i = 1, max_cols do
        a[i] = M.parse_align_cell(r.cells[i], align_char)
      end
      if not first_sep_aligns then
        first_sep_aligns = a
      end
      if seen_data and not mid_aligns then
        mid_aligns = a
      end
    else
      seen_data = true
    end
  end
  local use = mid_aligns or first_sep_aligns
  if use then
    aligns = use
  end
  -- 列宽：非分隔行内容 + 分隔至少 3
  local widths = {}
  for i = 1, max_cols do
    widths[i] = 3
  end
  for _, r in ipairs(rows) do
    if not r.is_sep then
      for i = 1, max_cols do
        local w = M.strwidth(r.cells[i] or "")
        if w > widths[i] then
          widths[i] = w
        end
      end
    end
  end
  return {
    start_line = 1,
    end_line = #lines,
    rows = rows,
    aligns = aligns,
    widths = widths,
    col_count = max_cols,
  }
end

---从 parsed.rows 提取数据行，并判断是否曾有分隔/中线
---@param rows { cells: string[], is_sep: boolean }[]
---@return { cells: string[], is_sep: boolean }[] data
---@return boolean had_sep
local function extract_data_rows(rows)
  local data = {}
  local had_sep = false
  for _, r in ipairs(rows) do
    if r.is_sep then
      had_sep = true
    else
      data[#data + 1] = r
    end
  end
  return data, had_sep
end

---格式化整表为行列表
---@param parsed ParsedTable
---@param opts? TableOpts
---@return string[]
function M.format_table(parsed, opts)
  opts = opts or {}
  local style = opts.table_style or "gfm"
  local data, had_sep = extract_data_rows(parsed.rows)
  local widths = parsed.widths
  local aligns = parsed.aligns

  if style == "unicode" then
    local uopts = vim.tbl_extend("force", {}, opts, { table_style = "unicode" })
    local out = {}
    out[#out + 1] = M.format_box_border(widths, BOX.tl, BOX.tm, BOX.tr)
    if #data == 0 then
      out[#out + 1] = M.format_box_border(widths, BOX.bl, BOX.bm, BOX.br)
      return out
    end
    out[#out + 1] = M.format_row(data[1].cells, widths, aligns, uopts, false, false)
    if had_sep or #data > 1 then
      out[#out + 1] = M.format_row({}, widths, aligns, uopts, true, true)
    end
    for i = 2, #data do
      out[#out + 1] = M.format_row(data[i].cells, widths, aligns, uopts, false, false)
    end
    out[#out + 1] = M.format_box_border(widths, BOX.bl, BOX.bm, BOX.br)
    return out
  end

  -- GFM：始终用数据行 + 可选表头分隔重建（兼容从 Unicode 还原）
  local gopts = vim.tbl_extend("force", {}, opts, { table_style = "gfm" })
  -- 去掉 unicode 专用
  gopts.table_style = nil
  local out = {}
  if #data == 0 then
    return out
  end
  out[#out + 1] = M.format_row(data[1].cells, widths, aligns, gopts, false, false)
  if had_sep or #data > 1 then
    out[#out + 1] = M.format_row({}, widths, aligns, gopts, true, true)
  end
  for i = 2, #data do
    out[#out + 1] = M.format_row(data[i].cells, widths, aligns, gopts, false, false)
  end
  return out
end

---根据当前行生成分隔行
---@param parsed ParsedTable
---@param opts? TableOpts
---@param as_header boolean|nil
---@return string
function M.make_separator_line(parsed, opts, as_header)
  opts = opts or {}
  local dummy = {}
  for i = 1, parsed.col_count do
    dummy[i] = ""
  end
  return M.format_row(dummy, parsed.widths, parsed.aligns, opts, true, as_header ~= false)
end

---CSV/分隔文本 → 单元格矩阵
---@param lines string[]
---@param delimiter string  单字符或 pattern；默认 ","
---@return string[][]
function M.split_delimited(lines, delimiter)
  delimiter = delimiter or ","
  local rows = {}
  for _, line in ipairs(lines) do
    local s = line:gsub("\r$", "")
    local cells = {}
    if delimiter == "\t" or delimiter == "\\t" then
      for part in (s .. "\t"):gmatch("([^\t]*)\t") do
        cells[#cells + 1] = trim(part)
      end
    elseif #delimiter == 1 then
      local d = delimiter
      -- 简单 CSV：不处理引号内逗号（够用）
      local pat = "([^" .. d:gsub("%W", "%%%0") .. "]*)" .. d:gsub("%W", "%%%0")
      for part in (s .. d):gmatch(pat) do
        cells[#cells + 1] = trim(part)
      end
    else
      -- 多字符：用 vim.split
      cells = vim.split(s, delimiter, { plain = true })
      for i, c in ipairs(cells) do
        cells[i] = trim(c)
      end
    end
    if #cells == 0 then
      cells = { "" }
    end
    rows[#rows + 1] = cells
  end
  return rows
end

---矩阵 → 表格行（首行后自动加分隔行）
---@param matrix string[][]
---@param opts? TableOpts
---@param with_header_sep boolean|nil  默认 true
---@return string[]
function M.matrix_to_table_lines(matrix, opts, with_header_sep)
  opts = opts or {}
  if with_header_sep == nil then
    with_header_sep = true
  end
  local rows = {}
  for i, cells in ipairs(matrix) do
    rows[#rows + 1] = { cells = vim.deepcopy(cells), is_sep = false }
    if with_header_sep and i == 1 then
      local sep_cells = {}
      for j = 1, #cells do
        sep_cells[j] = "---"
      end
      rows[#rows + 1] = { cells = sep_cells, is_sep = true }
    end
  end
  local max_cols = 0
  for _, r in ipairs(rows) do
    if #r.cells > max_cols then
      max_cols = #r.cells
    end
  end
  for _, r in ipairs(rows) do
    while #r.cells < max_cols do
      r.cells[#r.cells + 1] = ""
    end
  end
  local aligns = {}
  for i = 1, max_cols do
    aligns[i] = "left"
  end
  local widths = {}
  for i = 1, max_cols do
    widths[i] = 3
  end
  for _, r in ipairs(rows) do
    if not r.is_sep then
      for i = 1, max_cols do
        local w = M.strwidth(r.cells[i] or "")
        if w > widths[i] then
          widths[i] = w
        end
      end
    end
  end
  local parsed = {
    start_line = 1,
    end_line = #rows,
    rows = rows,
    aligns = aligns,
    widths = widths,
    col_count = max_cols,
  }
  return M.format_table(parsed, opts)
end

---行内竖线字节位置列表（| 或 │）
---@param s string
---@return integer[] byte_starts  每个竖线起始字节（1-based）
---@return integer vlen  竖线字节长度
local function vbar_positions(s)
  local pos = {}
  local vlen = 1
  if s:find(BOX.v, 1, true) then
    vlen = #BOX.v
    local start = 1
    while true do
      local a = s:find(BOX.v, start, true)
      if not a then
        break
      end
      pos[#pos + 1] = a
      start = a + vlen
    end
  else
    for i = 1, #s do
      if s:sub(i, i) == "|" then
        pos[#pos + 1] = i
      end
    end
  end
  return pos, vlen
end

---解析一行中每个单元格的 [field_start, content_start, content_end, field_end]
---field: 竖线后到下一个竖线前；content: 去掉两侧空格后的正文（可为空）
---@param line string
---@return { field_start: integer, content_start: integer, content_end: integer, field_end: integer }[]
local function cell_spans(line)
  local s = line or ""
  local spans = {}
  local bars, vlen = vbar_positions(s)
  if #bars < 2 then
    -- 回退：无成对竖线
    spans[1] = { field_start = 1, content_start = 1, content_end = 0, field_end = 0 }
    return spans
  end
  for b = 1, #bars - 1 do
    local field_start = bars[b] + vlen
    local field_end = bars[b + 1] - 1
    local cs = field_start
    while cs <= field_end and s:sub(cs, cs) == " " do
      cs = cs + 1
    end
    local ce = field_end
    while ce >= cs and s:sub(ce, ce) == " " do
      ce = ce - 1
    end
    if cs > ce then
      local write = field_start
      if write <= field_end and s:sub(write, write) == " " then
        write = write + 1
      end
      if write > field_end + 1 then
        write = field_end + 1
      end
      spans[#spans + 1] = {
        field_start = field_start,
        content_start = write,
        content_end = write - 1,
        field_end = field_end,
      }
    else
      spans[#spans + 1] = {
        field_start = field_start,
        content_start = cs,
        content_end = ce,
        field_end = field_end,
      }
    end
  end
  if #spans == 0 then
    spans[1] = { field_start = 1, content_start = 1, content_end = 0, field_end = 0 }
  end
  return spans
end

---导出：某格的 field/content 字节范围（1-based）
---@param line string
---@param cell_idx integer
---@return { field_start: integer, content_start: integer, content_end: integer, field_end: integer }
function M.cell_span(line, cell_idx)
  local spans = cell_spans(line)
  if not spans or #spans == 0 then
    return { field_start = 1, content_start = 1, content_end = 0, field_end = 0 }
  end
  cell_idx = math.max(1, math.min(#spans, cell_idx or 1))
  return spans[cell_idx]
end

---一行单元格数量
---@param line string
---@return integer
function M.cell_count(line)
  return #cell_spans(line)
end

---块选用：单元格可高亮的 [start, end] 字节列（1-based，含端点）
---有内容时用 content；空格时用 field 内 padding，保证至少 1 列
---@param line string
---@param cell_idx integer
---@return integer start_col
---@return integer end_col
function M.cell_select_range(line, cell_idx)
  local sp = M.cell_span(line, cell_idx)
  if sp.content_start <= sp.content_end then
    return sp.content_start, sp.content_end
  end
  -- 空内容：尽量覆盖 field 内空白
  local a = sp.field_start
  local b = sp.field_end
  if a > b then
    a = math.max(1, sp.content_start > 0 and sp.content_start or 1)
    b = a
  end
  return a, b
end

---光标列 → 单元格索引（1-based）与格内偏移
---@param line string
---@param col integer  1-based byte 列（vim 的 col()）；插入模式常为光标后一字节
---@return integer cell_idx
---@return integer offset_in_cell  从单元格内容起点起的字节偏移（光标在内容后）
function M.cursor_cell(line, col)
  col = math.max(1, col or 1)
  local s = line or ""
  if col > #s + 1 then
    col = #s + 1
  end
  local spans = cell_spans(s)
  local idx = 1
  for c, sp in ipairs(spans) do
    -- 落在该 field（含两侧 padding）内
    if col >= sp.field_start and col <= sp.field_end + 1 then
      idx = c
      break
    end
    if col >= sp.field_start then
      idx = c
    end
  end
  -- 光标正好在竖线（| / │）上：算右侧格
  if col >= 1 and col <= #s then
    local on_bar = s:sub(col, col) == "|"
      or s:sub(col, col + #BOX.v - 1) == BOX.v
    if on_bar then
      idx = math.min(idx + 1, #spans)
    end
  end
  local sp = spans[idx] or spans[1]
  local offset
  if col <= sp.content_start then
    offset = 0
  elseif col > sp.content_end then
    -- 在内容之后的 padding 里：视为内容末尾
    offset = math.max(0, sp.content_end - sp.content_start + 1)
  else
    offset = col - sp.content_start
  end
  return idx, offset
end

---根据 cell_idx + offset 还原列位置
---@param line string
---@param cell_idx integer
---@param offset integer
---@return integer col 1-based
function M.cell_to_col(line, cell_idx, offset)
  local s = line or ""
  local spans = cell_spans(s)
  local sp = spans[cell_idx] or spans[#spans] or spans[1]
  if not sp then
    return 1
  end
  offset = offset or 0
  local content_len = math.max(0, sp.content_end - sp.content_start + 1)
  if offset < 0 then
    offset = 0
  end
  if offset > content_len then
    offset = content_len
  end
  -- 空单元格
  if content_len == 0 then
    return sp.content_start
  end
  return sp.content_start + offset
end

return M
