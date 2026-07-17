---@mod pdfview.render
--- 提取结果 → 预览行 + extmarks + hits
local highlight = require("pdfview.highlight")
local image_mod = require("pdfview.image")

local M = {}

local NS = vim.api.nvim_create_namespace("pdfview_render")

local function str_width(s)
  return vim.fn.strdisplaywidth(s or "")
end

local function pad_align(s, width, align)
  s = s or ""
  local w = str_width(s)
  if w > width then
    while str_width(s) > width - 1 and #s > 0 do
      s = s:sub(1, -2)
    end
    s = s .. "…"
    w = str_width(s)
  end
  local pad = width - w
  if pad < 0 then
    pad = 0
  end
  if align == "right" then
    return string.rep(" ", pad) .. s
  elseif align == "center" then
    local l = math.floor(pad / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", pad - l)
  end
  return s .. string.rep(" ", pad)
end

local function wrap_text(text, width)
  if not text or text == "" then
    return { "" }
  end
  if width <= 0 or str_width(text) <= width then
    return { text }
  end
  local lines = {}
  local cur = ""
  -- 按 UTF-8 字符切
  local chars = vim.fn.split(text, "\\zs")
  for _, ch in ipairs(chars) do
    if str_width(cur .. ch) > width then
      if cur ~= "" then
        lines[#lines + 1] = cur
      end
      cur = ch
      if str_width(cur) > width then
        lines[#lines + 1] = cur
        cur = ""
      end
    else
      cur = cur .. ch
    end
  end
  if cur ~= "" then
    lines[#lines + 1] = cur
  end
  return #lines > 0 and lines or { "" }
end

---合并 spans 为 text + style ranges（字节偏移）
---@return string text, table[] ranges
local function flatten_spans(spans)
  local parts = {}
  local ranges = {}
  local col = 0
  for _, sp in ipairs(spans or {}) do
    local t = sp.text or ""
    if t == "" then
      goto continue
    end
    local start = col
    parts[#parts + 1] = t
    local blen = #t
    col = col + blen
    local bold = sp.bold == true
    local italic = sp.italic == true
    local color = sp.color or "#000000"
    local hl
    if sp.mono then
      hl = "PdfViewMono"
    else
      hl = highlight.truecolor(color, bold, italic)
    end
    ranges[#ranges + 1] = { col = start, end_col = col, hl = hl, bold = bold, italic = italic }
    -- 大字号当标题再叠 bold 组（可选）
    local size = tonumber(sp.size) or 0
    if size >= 16 and not bold then
      ranges[#ranges + 1] = { col = start, end_col = col, hl = "PdfViewBold" }
    end
    ::continue::
  end
  return table.concat(parts), ranges
end

---把带样式的长文本按显示宽折行，并映射 ranges
---@return string[] lines, table[] marks {row,col,end_col,hl}
local function wrap_styled(text, ranges, width)
  if width <= 0 or str_width(text) <= width then
    local marks = {}
    for _, r in ipairs(ranges or {}) do
      marks[#marks + 1] = {
        row = 0,
        col = r.col,
        end_col = r.end_col,
        hl = r.hl,
      }
    end
    return { text }, marks
  end

  -- 按显示宽度切成多行，记录每行对应的字节区间
  local lines = {}
  local line_byte_ranges = {} -- {b0, b1}  exclusive end
  local i = 1
  local n = #text
  while i <= n do
    local cur = ""
    local b0 = i - 1
    while i <= n do
      local c = text:byte(i)
      local ulen = 1
      if c >= 0xF0 then
        ulen = 4
      elseif c >= 0xE0 then
        ulen = 3
      elseif c >= 0xC0 then
        ulen = 2
      end
      local ch = text:sub(i, i + ulen - 1)
      if str_width(cur .. ch) > width then
        break
      end
      cur = cur .. ch
      i = i + ulen
    end
    if cur == "" and i <= n then
      -- 单字符超宽
      local c = text:byte(i)
      local ulen = 1
      if c >= 0xF0 then
        ulen = 4
      elseif c >= 0xE0 then
        ulen = 3
      elseif c >= 0xC0 then
        ulen = 2
      end
      cur = text:sub(i, i + ulen - 1)
      i = i + ulen
    end
    lines[#lines + 1] = cur
    line_byte_ranges[#line_byte_ranges + 1] = { b0, b0 + #cur }
  end

  local marks = {}
  for _, r in ipairs(ranges or {}) do
    for li, br in ipairs(line_byte_ranges) do
      local a = math.max(r.col, br[1])
      local b = math.min(r.end_col, br[2])
      if b > a then
        marks[#marks + 1] = {
          row = li - 1,
          col = a - br[1],
          end_col = b - br[1],
          hl = r.hl,
        }
      end
    end
  end
  return lines, marks
end

local function table_borders(style)
  if style == "ascii" then
    return {
      tl = "+",
      tr = "+",
      bl = "+",
      br = "+",
      h = "-",
      v = "|",
      t = "+",
      b = "+",
      l = "+",
      r = "+",
      c = "+",
    }
  elseif style == "minimal" then
    return {
      tl = " ",
      tr = " ",
      bl = " ",
      br = " ",
      h = " ",
      v = " ",
      t = " ",
      b = " ",
      l = " ",
      r = " ",
      c = " ",
    }
  end
  return {
    tl = "┌",
    tr = "┐",
    bl = "└",
    br = "┘",
    h = "─",
    v = "│",
    t = "┬",
    b = "┴",
    l = "├",
    r = "┤",
    c = "┼",
  }
end

---按显示宽度截断（UTF-8 安全），必要时末尾 …
---@param s string
---@param width number
---@return string
local function truncate_display(s, width)
  s = s or ""
  width = math.max(0, width or 0)
  if width <= 0 then
    return ""
  end
  if str_width(s) <= width then
    return s
  end
  if width == 1 then
    return "…"
  end
  local out = ""
  local chars = vim.fn.split(s, "\\zs")
  for _, ch in ipairs(chars) do
    if str_width(out .. ch) > width - 1 then
      break
    end
    out = out .. ch
  end
  return out .. "…"
end

---列宽之和
local function sum_widths(col_w)
  local t = 0
  for _, w in ipairs(col_w) do
    t = t + w
  end
  return t
end

---把列宽总和钳到 avail（优先缩最宽列，最低 min_w）
---@param col_w number[]
---@param avail number
---@param min_w number
local function clamp_col_widths(col_w, avail, min_w)
  min_w = math.max(1, min_w or 1)
  avail = math.max(#col_w * min_w, avail)
  -- 超出则缩
  local guard = 0
  while sum_widths(col_w) > avail and guard < 10000 do
    guard = guard + 1
    local best = 1
    for c = 2, #col_w do
      if col_w[c] > col_w[best] then
        best = c
      end
    end
    if col_w[best] <= min_w then
      -- 全部已到底：允许再压到 1
      if min_w > 1 then
        min_w = 1
      else
        break
      end
    else
      col_w[best] = col_w[best] - 1
    end
  end
  -- 不足则把余量均分（可选：表格铺满；不超过 avail）
  local used = sum_widths(col_w)
  local extra = avail - used
  local i = 1
  while extra > 0 do
    col_w[i] = col_w[i] + 1
    extra = extra - 1
    i = i % #col_w + 1
  end
end

---@param ctx table
---@param rows string[][]
---@param has_header boolean
local function render_table(ctx, rows, has_header)
  if not rows or #rows == 0 then
    return
  end
  local ncol = 0
  for _, row in ipairs(rows) do
    ncol = math.max(ncol, #row)
  end
  if ncol == 0 then
    return
  end
  -- 规范化列数
  for _, row in ipairs(rows) do
    while #row < ncol do
      row[#row + 1] = ""
    end
  end

  local width = math.max(ncol + 2, ctx.width or 40)
  local style = (ctx.cfg.table_style) or "unicode"
  local B = table_borders(style)
  -- 行结构：│ cell │ cell │ … │  → 竖线 ncol+1 条，各占 1 显示宽
  local border_w = (style == "minimal") and 0 or (ncol + 1)
  -- 单元格内容可用宽（不含竖线）
  local avail = math.max(ncol, width - border_w)

  local need = {}
  for c = 1, ncol do
    need[c] = 1
    for r = 1, #rows do
      -- 左右各留 1 空格的内边距（内容+2），但至少 1
      need[c] = math.max(need[c], str_width(rows[r][c] or "") + 2)
    end
  end

  local col_w = {}
  local total = 0
  for c = 1, ncol do
    col_w[c] = need[c]
    total = total + need[c]
  end

  if total > avail then
    -- 按比例缩小，再钳制
    local scale = avail / total
    for c = 1, ncol do
      col_w[c] = math.max(1, math.floor(need[c] * scale))
    end
  end
  -- 无论放大还是缩小，最终保证 sum(col_w) + border_w <= width
  clamp_col_widths(col_w, avail, 1)

  -- 二次校验：整行显示宽
  local function row_display_w()
    return sum_widths(col_w) + border_w
  end
  local guard = 0
  while row_display_w() > width and guard < 1000 do
    guard = guard + 1
    local best = 1
    for c = 2, ncol do
      if col_w[c] > col_w[best] then
        best = c
      end
    end
    if col_w[best] <= 1 then
      break
    end
    col_w[best] = col_w[best] - 1
  end

  local function border_line(left, mid, right)
    local parts = { left }
    for c = 1, ncol do
      parts[#parts + 1] = string.rep(B.h, col_w[c])
      parts[#parts + 1] = (c < ncol) and mid or right
    end
    return table.concat(parts)
  end

  local function emit(line, hl)
    local row = #ctx.lines
    ctx.lines[#ctx.lines + 1] = line
    ctx.extmarks[#ctx.extmarks + 1] = {
      row = row,
      col = 0,
      end_col = #line,
      hl = hl or "PdfViewTableBorder",
    }
  end

  ---单元格：左右各 1 空格内边距（列宽足够时），超出则截断
  ---@param raw string
  ---@param cw number
  ---@return string
  local function format_cell(raw, cw)
    raw = (raw or ""):gsub("[\r\n]+", " ")
    if cw <= 0 then
      return ""
    end
    if cw == 1 then
      return truncate_display(raw, 1)
    end
    if cw == 2 then
      return truncate_display(raw, 2)
    end
    local inner = cw - 2
    local body = truncate_display(raw, inner)
    local cell = " " .. body
    -- 右垫到 cw
    local pad = cw - str_width(cell)
    if pad > 0 then
      cell = cell .. string.rep(" ", pad)
    elseif pad < 0 then
      cell = truncate_display(cell, cw)
      pad = cw - str_width(cell)
      if pad > 0 then
        cell = cell .. string.rep(" ", pad)
      end
    end
    return cell
  end

  if style ~= "minimal" then
    emit(border_line(B.tl, B.t, B.tr))
  end

  for ri, row in ipairs(rows) do
    local pieces = { B.v }
    local line_start = #ctx.lines
    local cell_ranges = {}
    local byte = #B.v
    for c = 1, ncol do
      local cell = format_cell(row[c], col_w[c])
      -- 强制显示宽 == col_w[c]
      local dw = str_width(cell)
      if dw < col_w[c] then
        cell = cell .. string.rep(" ", col_w[c] - dw)
      elseif dw > col_w[c] then
        cell = truncate_display(cell, col_w[c])
        dw = str_width(cell)
        if dw < col_w[c] then
          cell = cell .. string.rep(" ", col_w[c] - dw)
        end
      end
      local c0 = byte
      pieces[#pieces + 1] = cell
      byte = byte + #cell
      local c1 = byte
      if has_header and ri == 1 then
        cell_ranges[#cell_ranges + 1] = { col = c0, end_col = c1, hl = "PdfViewTableHeader" }
      end
      pieces[#pieces + 1] = B.v
      byte = byte + #B.v
    end
    local line = table.concat(pieces)
    ctx.lines[#ctx.lines + 1] = line
    ctx.extmarks[#ctx.extmarks + 1] = {
      row = line_start,
      col = 0,
      end_col = #line,
      hl = "PdfViewTableBorder",
    }
    for _, r in ipairs(cell_ranges) do
      ctx.extmarks[#ctx.extmarks + 1] = {
        row = line_start,
        col = r.col,
        end_col = r.end_col,
        hl = r.hl,
      }
    end
    if has_header and ri == 1 and style ~= "minimal" then
      emit(border_line(B.l, B.c, B.r))
    end
  end

  if style ~= "minimal" then
    emit(border_line(B.bl, B.b, B.br))
  end
end

---@param ctx table
---@param block table
local function render_text(ctx, block)
  local width = ctx.width
  for _, line in ipairs(block.lines or {}) do
    local text, ranges = flatten_spans(line.spans or {})
    text = text:gsub("[\r\n]", " ")
    if text:match("^%s*$") then
      ctx.lines[#ctx.lines + 1] = ""
    else
      local wrapped, marks = wrap_styled(text, ranges, width)
      local base = #ctx.lines
      for i, wl in ipairs(wrapped) do
        ctx.lines[#ctx.lines + 1] = wl
      end
      for _, m in ipairs(marks) do
        ctx.extmarks[#ctx.extmarks + 1] = {
          row = base + m.row,
          col = m.col,
          end_col = m.end_col,
          hl = m.hl,
        }
      end
    end
  end
  -- 段后空行
  if #(block.lines or {}) > 0 then
    ctx.lines[#ctx.lines + 1] = ""
  end
end

---@param ctx table
---@param block table
local function render_image(ctx, block)
  local path = block.path
  if not path or path == "" then
    return
  end
  local cfg = ctx.cfg
  local imgcfg = cfg.image or {}
  if imgcfg.mode == "off" then
    return
  end
  local width = ctx.width
  local full_w = imgcfg.max_width or width
  full_w = math.min(width, math.max(8, full_w))
  local max_h = imgcfg.max_height or 0

  local label = "🖼  image"
  local label_row = #ctx.lines
  ctx.lines[#ctx.lines + 1] = label
  ctx.extmarks[#ctx.extmarks + 1] = {
    row = label_row,
    col = 0,
    end_col = #label,
    hl = "PdfViewImage",
  }

  -- 1-based 行号：标签行也可点
  local hit_start = label_row + 1

  if imgcfg.mode == "placeholder" then
    ctx.hits[#ctx.hits + 1] = {
      kind = "image",
      line = hit_start,
      line_end = hit_start,
      col = 0,
      end_col = #label,
      path = path,
    }
    ctx.lines[#ctx.lines + 1] = ""
    return
  end

  local thumb = image_mod.render_thumb(path, full_w, max_h, cfg)
  if thumb and thumb.lines then
    local base = #ctx.lines
    for _, ln in ipairs(thumb.lines) do
      ctx.lines[#ctx.lines + 1] = ln
    end
    for _, m in ipairs(thumb.marks or {}) do
      ctx.extmarks[#ctx.extmarks + 1] = {
        row = base + m.row,
        col = m.col,
        end_col = m.end_col,
        hl = m.hl,
      }
    end
    local end_line = #ctx.lines -- 1-based last thumb line
    -- 标签 + 色块整块可点；高清叠层从色块首行起（跳过标题）
    local thumb_start = base + 1
    ctx.hits[#ctx.hits + 1] = {
      kind = "image",
      line = hit_start,
      line_end = end_line,
      col = 0,
      end_col = #(thumb.lines[1] or ""),
      path = path,
      dcols = full_w,
    }
    ctx.hits[#ctx.hits + 1] = {
      kind = "image_hd",
      line = thumb_start,
      line_end = end_line,
      col = 0,
      end_col = #(thumb.lines[1] or ""),
      path = path,
      dcols = full_w,
    }
  else
    ctx.hits[#ctx.hits + 1] = {
      kind = "image",
      line = hit_start,
      line_end = hit_start,
      path = path,
    }
  end
  ctx.lines[#ctx.lines + 1] = ""
end

---@param data table extract JSON
---@param opts {width:number, cfg:table}
---@return table result
function M.render(data, opts)
  highlight.ensure()
  opts = opts or {}
  local cfg = opts.cfg or {}
  local width = math.max(20, opts.width or 80)

  local ctx = {
    lines = {},
    extmarks = {},
    hits = {},
    page_map = {}, ---@type table<number, number> page -> preview line (1-based)
    width = width,
    cfg = cfg,
  }

  local meta = data.meta or {}
  local title = meta.title
  if not title or title == "" then
    title = vim.fn.fnamemodify(data.path or "document.pdf", ":t")
  end
  local header = string.format("📄 %s", title)
  ctx.lines[#ctx.lines + 1] = header
  ctx.extmarks[#ctx.extmarks + 1] = {
    row = 0,
    col = 0,
    end_col = #header,
    hl = "PdfViewTitle",
  }
  local kind = data.kind or "pdf"
  local i18n = require("pdfview.i18n")
  local meta_line
  if kind == "docx" or kind == "doc" then
    meta_line = i18n.t("meta_word")
  else
    meta_line = string.format(
      i18n.t("meta_pdf"),
      data.page_count or #(data.pages or {})
    )
  end
  ctx.lines[#ctx.lines + 1] = meta_line
  ctx.extmarks[#ctx.extmarks + 1] = {
    row = 1,
    col = 0,
    end_col = #meta_line,
    hl = "PdfViewMeta",
  }
  ctx.lines[#ctx.lines + 1] = ""

  local multi_page = (data.page_count or #(data.pages or {})) > 1
  for _, page in ipairs(data.pages or {}) do
    local pno = page.page or 1
    ctx.page_map[pno] = #ctx.lines + 1
    -- Word 单节不画 Page 分隔；PDF 多页画分隔
    if cfg.page_sep ~= false and multi_page then
      local sep = string.format(require("pdfview.i18n").t("page_sep"), pno, data.page_count or pno)
      local pad = width - str_width(sep)
      if pad > 0 then
        sep = sep .. string.rep("─", pad)
      end
      local row = #ctx.lines
      ctx.lines[#ctx.lines + 1] = sep
      ctx.extmarks[#ctx.extmarks + 1] = {
        row = row,
        col = 0,
        end_col = #sep,
        hl = "PdfViewPageSep",
      }
      ctx.lines[#ctx.lines + 1] = ""
    end

    for _, block in ipairs(page.blocks or {}) do
      if block.type == "text" then
        render_text(ctx, block)
      elseif block.type == "table" then
        render_table(ctx, block.rows or {}, block.header ~= false)
        ctx.lines[#ctx.lines + 1] = ""
      elseif block.type == "image" then
        render_image(ctx, block)
      end
    end
  end

  if #ctx.lines == 0 then
    ctx.lines[1] = "(empty PDF)"
  end

  return {
    lines = ctx.lines,
    extmarks = ctx.extmarks,
    hits = ctx.hits,
    page_map = ctx.page_map,
    ns = NS,
  }
end

---@param buf integer
---@param result table
function M.apply(buf, result)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  highlight.ensure()
  pcall(function()
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
  end)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines or {})
  pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  for _, m in ipairs(result.extmarks or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, m.row, m.col, {
      end_col = m.end_col,
      hl_group = m.hl,
    })
  end
  pcall(function()
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
  end)
end

return M
