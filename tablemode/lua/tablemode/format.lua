---@mod tablemode.format 表格解析与对齐（纯函数）
local M = {}

---@alias Align "left"|"right"|"center"

---@class TableOpts
---@field corner string  单元格角/竖线，Markdown 多为 "|"
---@field corner_corner string  分隔行交叉角，"+" 或 "|"
---@field fillchar string  普通分隔填充 "-"
---@field header_fillchar string  表头分隔填充，默认同 fillchar；ReST 可用 "="
---@field align_char string  对齐标记 ":"
---@field separator string  列分隔符，默认 "|"

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

---是否为分隔行（---|:---| 等）
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
  -- 允许 | --- | :---: | ---+--- |
  if not s:find("[%-%=%:]", 1) then
    return false
  end
  -- 去掉首尾 |
  if s:sub(1, 1) == "|" then
    s = s:sub(2)
  end
  if s:sub(-1) == "|" then
    s = s:sub(1, -2)
  end
  -- 只允许 - = : | + 空白
  if s:find("[^%s%-%=%:%|+]") then
    return false
  end
  -- 至少有一段横线
  return s:find("%-+") ~= nil or s:find("%=+") ~= nil
end

---是否像表格数据行（含 |）
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
  -- 至少两个 | 或 以 | 开头
  local _, n = s:gsub("|", "")
  if n >= 2 then
    return true
  end
  if s:sub(1, 1) == "|" and n >= 1 then
    return true
  end
  return false
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

---拆分一行单元格（保留空单元格）
---@param line string
---@return string[] cells
---@return boolean is_sep
function M.split_row(line)
  local s = line or ""
  -- 去掉行尾 \r
  s = s:gsub("\r$", "")
  local is_sep = M.is_separator_line(s)
  local raw = trim(s)
  -- 去掉首尾 |
  if raw:sub(1, 1) == "|" then
    raw = raw:sub(2)
  end
  if raw:sub(-1) == "|" then
    raw = raw:sub(1, -2)
  end
  local cells = {}
  -- 按 | 或分隔行的 + 拆分
  if is_sep then
    for part in (raw .. "|"):gmatch("([^|+]*)[+|]") do
      cells[#cells + 1] = trim(part)
    end
  else
    for part in (raw .. "|"):gmatch("([^|]*)|") do
      cells[#cells + 1] = trim(part)
    end
  end
  -- 全空一行（如单独的 |）→ 一个空格
  if #cells == 0 then
    cells = { "" }
  end
  return cells, is_sep
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
  fillchar = (fillchar and fillchar ~= "") and fillchar:sub(1, 1) or "-"
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
  -- 对齐：取第一条分隔行
  local aligns = {}
  for i = 1, max_cols do
    aligns[i] = "left"
  end
  local align_char = opts.align_char or ":"
  for _, r in ipairs(rows) do
    if r.is_sep then
      for i = 1, max_cols do
        aligns[i] = M.parse_align_cell(r.cells[i], align_char)
      end
      break
    end
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

---格式化整表为行列表
---@param parsed ParsedTable
---@param opts? TableOpts
---@return string[]
function M.format_table(parsed, opts)
  opts = opts or {}
  local out = {}
  local saw_data = false
  local first_sep_done = false
  for _, r in ipairs(parsed.rows) do
    local is_header_sep = false
    if r.is_sep then
      if not saw_data and not first_sep_done then
        is_header_sep = true
        first_sep_done = true
      end
    else
      saw_data = true
    end
    out[#out + 1] =
      M.format_row(r.cells, parsed.widths, parsed.aligns, opts, r.is_sep, is_header_sep)
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

---解析一行中每个单元格的 [field_start, content_start, content_end, field_end]
---field: | 后到下一个 | 前；content: 去掉两侧空格后的正文（可为空）
---@param line string
---@return { field_start: integer, content_start: integer, content_end: integer, field_end: integer }[]
local function cell_spans(line)
  local s = line or ""
  local spans = {}
  local i = 1
  while i <= #s and s:sub(i, i):match("%s") do
    i = i + 1
  end
  if s:sub(i, i) == "|" then
    i = i + 1
  end
  local field_start = i
  while i <= #s + 1 do
    local ch = i <= #s and s:sub(i, i) or "|"
    if ch == "|" or i > #s then
      local field_end = i - 1
      local cs = field_start
      while cs <= field_end and s:sub(cs, cs) == " " do
        cs = cs + 1
      end
      local ce = field_end
      while ce >= cs and s:sub(ce, ce) == " " do
        ce = ce - 1
      end
      -- content_end 为最后一个内容字节下标；空内容时 content_start = field 内首写位置
      if cs > ce then
        -- 空单元格：光标落在 field 内第一个可写位置（跳过一个前导空格若有）
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
      if i > #s then
        break
      end
      field_start = i + 1
    end
    i = i + 1
  end
  if #spans == 0 then
    spans[1] = { field_start = 1, content_start = 1, content_end = 0, field_end = 0 }
  end
  return spans
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
  -- 光标正好在 | 上：算右侧格
  if col >= 1 and col <= #s and s:sub(col, col) == "|" then
    idx = math.min(idx + 1, #spans)
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
