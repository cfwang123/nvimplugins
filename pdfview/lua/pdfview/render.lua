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

  -- 懒渲染 / 超预算：只留可点标签，不生成色块
  local budget = ctx.image_budget
  local allow = ctx.allow_images ~= false
  if imgcfg.mode == "placeholder" or not allow or (budget ~= nil and budget <= 0) then
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
    if budget ~= nil then
      ctx.image_budget = budget - 1
    end
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

---@param width number
---@param cfg table
---@return table
local function new_ctx(width, cfg, allow_images, image_budget)
  return {
    lines = {},
    extmarks = {},
    hits = {},
    width = width,
    cfg = cfg,
    allow_images = allow_images ~= false,
    image_budget = image_budget,
  }
end

---@param ctx table
---@param pno number
---@param page_count number
---@param multi_page boolean
local function append_page_sep(ctx, pno, page_count, multi_page)
  local cfg = ctx.cfg or {}
  if cfg.page_sep == false or not multi_page then
    return
  end
  local width = ctx.width
  local sep = string.format(require("pdfview.i18n").t("page_sep"), pno, page_count or pno)
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

---完整渲染一页内容（相对行号，从 0 起）
---@param page table
---@param opts {width:number, cfg:table, multi_page?:boolean, page_count?:number, allow_images?:boolean, image_budget?:number}
---@return table segment {lines, extmarks, hits, full, page}
function M.render_page_full(page, opts)
  opts = opts or {}
  local cfg = opts.cfg or {}
  local width = math.max(20, opts.width or 80)
  local pno = page.page or 1
  local page_count = opts.page_count or pno
  local multi_page = opts.multi_page
  if multi_page == nil then
    multi_page = page_count > 1
  end
  local budget = opts.image_budget
  if budget == nil then
    budget = (cfg.image and cfg.image.max_images) or 30
  end
  local ctx = new_ctx(width, cfg, opts.allow_images ~= false, budget)
  append_page_sep(ctx, pno, page_count, multi_page)
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
  if #ctx.lines == 0 then
    ctx.lines[1] = ""
  end
  return {
    lines = ctx.lines,
    extmarks = ctx.extmarks,
    hits = ctx.hits,
    full = true,
    page = pno,
    image_budget_left = ctx.image_budget,
  }
end

---尚未提取的页：分隔线 + 提示 + 等高占位行（让滚动条近似按页比例）
---@param pno number
---@param opts {width:number, cfg:table, multi_page?:boolean, page_count?:number, pending?:boolean, stub_lines?:number}
---@return table segment
function M.render_page_stub(pno, opts)
  opts = opts or {}
  local cfg = opts.cfg or {}
  local width = math.max(20, opts.width or 80)
  local page_count = opts.page_count or pno
  local multi_page = opts.multi_page
  if multi_page == nil then
    multi_page = page_count > 1
  end
  local ctx = new_ctx(width, cfg, false, 0)
  append_page_sep(ctx, pno, page_count, multi_page)
  local hint = opts.pending and "  … loading" or "  …"
  local row = #ctx.lines
  ctx.lines[#ctx.lines + 1] = hint
  ctx.extmarks[#ctx.extmarks + 1] = {
    row = row,
    col = 0,
    end_col = #hint,
    hl = "PdfViewMeta",
  }
  -- 等高占位：滚动约 50% ≈ 中间页（未提取区按固定行高估算）
  local pad = tonumber(opts.stub_lines) or tonumber(cfg.stub_page_lines) or 36
  pad = math.max(2, math.min(120, pad))
  -- 已有 sep(2) + hint(1)，再补到 pad 行
  while #ctx.lines < pad do
    ctx.lines[#ctx.lines + 1] = ""
  end
  return {
    lines = ctx.lines,
    extmarks = ctx.extmarks,
    hits = {},
    full = false,
    page = pno,
    pending = opts.pending == true,
  }
end

---文档头（标题 + 元信息）
---@param data table
---@param opts {width:number, cfg:table}
---@return table segment
function M.render_header(data, opts)
  opts = opts or {}
  local cfg = opts.cfg or {}
  local width = math.max(20, opts.width or 80)
  local ctx = new_ctx(width, cfg, false, 0)

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
    meta_line = string.format(i18n.t("meta_pdf"), data.page_count or #(data.pages or {}))
  end
  ctx.lines[#ctx.lines + 1] = meta_line
  ctx.extmarks[#ctx.extmarks + 1] = {
    row = 1,
    col = 0,
    end_col = #meta_line,
    hl = "PdfViewMeta",
  }
  ctx.lines[#ctx.lines + 1] = ""
  return {
    lines = ctx.lines,
    extmarks = ctx.extmarks,
    hits = {},
    full = true,
    page = 0,
  }
end

---把 segment 拼到 result 上，并修正绝对行号
---@param result table
---@param seg table
---@param pno number|nil 写入 page_map / page_ranges
local function append_segment(result, seg, pno)
  local base = #result.lines -- 0-based next row
  local start_line = base + 1 -- 1-based
  for _, ln in ipairs(seg.lines or {}) do
    result.lines[#result.lines + 1] = ln
  end
  for _, m in ipairs(seg.extmarks or {}) do
    result.extmarks[#result.extmarks + 1] = {
      row = base + (m.row or 0),
      col = m.col,
      end_col = m.end_col,
      hl = m.hl,
    }
  end
  for _, h in ipairs(seg.hits or {}) do
    local nh = vim.tbl_extend("force", {}, h)
    local rel_a = (h.line or 1) - 1 -- hits 在 page ctx 里是 1-based 相对
    local rel_b = (h.line_end or h.line or 1) - 1
    -- render_image 写的 line 是 ctx 内 1-based（= row+1）
    nh.line = start_line + rel_a
    nh.line_end = start_line + rel_b
    result.hits[#result.hits + 1] = nh
  end
  local end_line = #result.lines
  if pno and pno > 0 then
    result.page_map[pno] = start_line
    result.page_ranges[pno] = {
      start = start_line,
      finish = end_line,
      full = seg.full == true,
    }
  end
end

---按页缓存组装整份预览
---@param data table
---@param opts {width:number, cfg:table, full_pages?:table<number,boolean>|nil, page_cache?:table}
---@return table result
function M.assemble(data, opts)
  highlight.ensure()
  opts = opts or {}
  local cfg = opts.cfg or {}
  local width = math.max(20, opts.width or 80)
  local pages = data.pages or {}
  local page_count = data.page_count or #pages
  local multi_page = page_count > 1
  local full_pages = opts.full_pages -- set of page numbers to fully render; nil = all
  local page_cache = opts.page_cache or {}
  local image_budget = (cfg.image and cfg.image.max_images) or 30

  local result = {
    lines = {},
    extmarks = {},
    hits = {},
    page_map = {},
    page_ranges = {}, ---@type table<number, {start:number, finish:number, full:boolean}>
    ns = NS,
    header_lines = 0,
    page_count = page_count,
    width = width,
  }

  local header = M.render_header(data, { width = width, cfg = cfg })
  append_segment(result, header, nil)
  result.header_lines = #header.lines

  -- 建立 page 号 → page 数据
  local by_no = {}
  for _, page in ipairs(pages) do
    local pno = page.page or 1
    by_no[pno] = page
  end
  -- 若 page 字段缺失，按顺序 1..n
  if #pages > 0 and not by_no[1] and pages[1] then
    by_no = {}
    for i, page in ipairs(pages) do
      by_no[i] = page
      page.page = page.page or i
    end
    page_count = math.max(page_count, #pages)
    result.page_count = page_count
  end

  local order = {}
  for pno, _ in pairs(by_no) do
    order[#order + 1] = pno
  end
  table.sort(order)
  if #order == 0 then
    for i = 1, page_count do
      order[i] = i
    end
  end

  local stub_lines = tonumber(cfg.stub_page_lines) or 36
  local stub_opts = {
    width = width,
    cfg = cfg,
    multi_page = multi_page,
    page_count = page_count,
    stub_lines = stub_lines,
  }

  -- 策略：
  --  · 已提取页 → 始终完整显示（滚走再滚回不丢内容）
  --  · 未提取页 → 等高占位（滚动条比例接近真实页序）
  --  · full_pages 仅作「优先渲染/图片预算」提示，不再把已提取页打回 stub
  for _, pno in ipairs(order) do
    local page = by_no[pno]
    local pending = page and page._pending == true
    local prefer = (full_pages == nil) or (full_pages[pno] == true)
    local seg
    if pending or not page then
      local so = vim.tbl_extend("force", {}, stub_opts, { pending = pending == true })
      seg = M.render_page_stub(pno, so)
      page_cache[pno] = nil
    else
      seg = page_cache[pno]
      if not seg or not seg.full then
        -- 视口外已提取页也完整渲染；无图预算时仍画文字
        local allow_img = prefer and (image_budget == nil or image_budget > 0)
        seg = M.render_page_full(page, {
          width = width,
          cfg = cfg,
          multi_page = multi_page,
          page_count = page_count,
          allow_images = allow_img,
          image_budget = allow_img and image_budget or 0,
        })
        if allow_img and seg.image_budget_left ~= nil then
          image_budget = math.max(0, seg.image_budget_left)
        end
        page_cache[pno] = seg
      end
    end
    append_segment(result, seg, pno)
  end

  if #result.lines == 0 then
    result.lines[1] = "(empty PDF)"
  end
  result.page_cache = page_cache
  return result
end

---@param data table extract JSON
---@param opts {width:number, cfg:table, full_pages?:table<number,boolean>, page_cache?:table}
---@return table result
function M.render(data, opts)
  return M.assemble(data, opts or {})
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

---根据预览行号反查页码
---@param result table
---@param line number 1-based
---@return number|nil page
function M.page_at_line(result, line)
  if not result or not result.page_ranges then
    return nil
  end
  line = tonumber(line) or 1
  local best, best_start = nil, -1
  for pno, r in pairs(result.page_ranges) do
    if r.start and r.finish and line >= r.start and line <= r.finish then
      return pno
    end
    if r.start and r.start <= line and r.start > best_start then
      best_start = r.start
      best = pno
    end
  end
  return best
end

return M
