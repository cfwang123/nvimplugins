---@mod xlsview.render
local highlight = require("xlsview.highlight")

local M = {}
local NS = vim.api.nvim_create_namespace("xlsview_render")

local function str_width(s)
  return vim.fn.strdisplaywidth(s or "")
end

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
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    if str_width(out .. ch) > width - 1 then
      break
    end
    out = out .. ch
  end
  return out .. "…"
end

local function sum_w(t)
  local n = 0
  for _, v in ipairs(t) do
    n = n + v
  end
  return n
end

local function table_borders(style)
  if style == "ascii" then
    return { tl = "+", tr = "+", bl = "+", br = "+", h = "-", v = "|", t = "+", b = "+", l = "+", r = "+", c = "+" }
  elseif style == "minimal" then
    return { tl = " ", tr = " ", bl = " ", br = " ", h = " ", v = " ", t = " ", b = " ", l = " ", r = " ", c = " " }
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

---@param sheet table
---@param width number
---@param cfg table
---@return string[] lines, table[] extmarks, table hits
local function render_sheet(sheet, width, cfg)
  local lines = {}
  local extmarks = {}
  local hits = {}

  if sheet.error then
    lines[1] = "error: " .. tostring(sheet.error)
    return lines, extmarks, hits
  end

  local rows = sheet.rows or {}
  if #rows == 0 then
    lines[1] = "(empty sheet)"
    return lines, extmarks, hits
  end

  local ncol = 0
  for _, row in ipairs(rows) do
    ncol = math.max(ncol, #row)
  end
  if ncol == 0 then
    lines[1] = "(empty sheet)"
    return lines, extmarks, hits
  end

  local style = cfg.table_style or "unicode"
  local B = table_borders(style)
  local border_w = (style == "minimal") and 0 or (ncol + 1)
  local rn_w = 0
  if cfg.show_row_numbers then
    local max_rn = (sheet.min_row or 1) + #rows - 1
    rn_w = math.max(3, #tostring(max_rn)) + 1
  end
  local avail = math.max(ncol, width - border_w - rn_w)

  -- 内容需求宽
  local need = {}
  for c = 1, ncol do
    need[c] = 1
    for r = 1, #rows do
      local cell = rows[r][c]
      local t = type(cell) == "table" and (cell.text or "") or tostring(cell or "")
      need[c] = math.max(need[c], str_width(t) + 2)
    end
  end

  local col_w = {}
  local total = 0
  for c = 1, ncol do
    col_w[c] = need[c]
    total = total + need[c]
  end
  if total > avail then
    local scale = avail / total
    for c = 1, ncol do
      col_w[c] = math.max(1, math.floor(need[c] * scale))
    end
  end
  -- 钳制
  local guard = 0
  while sum_w(col_w) > avail and guard < 10000 do
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
  -- 余量均分
  local extra = avail - sum_w(col_w)
  local i = 1
  while extra > 0 do
    col_w[i] = col_w[i] + 1
    extra = extra - 1
    i = i % ncol + 1
  end

  local function format_cell(cell, cw, is_header)
    local text, bold, italic, color, bg, align
    if type(cell) == "table" then
      text = cell.text or ""
      bold = cell.bold
      italic = cell.italic
      color = cell.color
      bg = cell.bg
      align = cell.align or "left"
    else
      text = tostring(cell or "")
      align = "left"
    end
    if is_header then
      bold = true
    end
    text = text:gsub("[\r\n]+", " ")
    local inner = math.max(0, cw - 2)
    local body = truncate_display(text, inner)
    local pad = inner - str_width(body)
    if pad < 0 then
      pad = 0
    end
    local left, right = 1, 1 -- 边距空格算在 cw 内
    if align == "right" then
      body = string.rep(" ", pad) .. body
    elseif align == "center" then
      local l = math.floor(pad / 2)
      body = string.rep(" ", l) .. body .. string.rep(" ", pad - l)
    else
      body = body .. string.rep(" ", pad)
    end
    local out = " " .. body
    local dw = str_width(out)
    if dw < cw then
      out = out .. string.rep(" ", cw - dw)
    elseif dw > cw then
      out = truncate_display(out, cw)
      dw = str_width(out)
      if dw < cw then
        out = out .. string.rep(" ", cw - dw)
      end
    end
    local hl = highlight.truecolor(color or "#000000", bold, italic, bg)
    return out, hl
  end

  local function border_line(left, mid, right)
    local parts = {}
    if rn_w > 0 then
      parts[#parts + 1] = string.rep(" ", rn_w)
    end
    parts[#parts + 1] = left
    for c = 1, ncol do
      parts[#parts + 1] = string.rep(B.h, col_w[c])
      parts[#parts + 1] = (c < ncol) and mid or right
    end
    return table.concat(parts)
  end

  local function emit(line, hl)
    local row = #lines
    lines[#lines + 1] = line
    if hl then
      extmarks[#extmarks + 1] = { row = row, col = 0, end_col = #line, hl = hl }
    end
  end

  if style ~= "minimal" then
    emit(border_line(B.tl, B.t, B.tr), "XlsViewBorder")
  end

  local header_row = cfg.header_row ~= false
  for ri, row in ipairs(rows) do
    local pieces = {}
    local row0 = #lines
    local byte = 0
    if rn_w > 0 then
      local rn = tostring((sheet.min_row or 1) + ri - 1)
      local pad = rn_w - 1 - str_width(rn)
      if pad < 0 then
        pad = 0
      end
      local s = string.rep(" ", pad) .. rn .. " "
      pieces[#pieces + 1] = s
      extmarks[#extmarks + 1] = {
        row = row0,
        col = 0,
        end_col = #s,
        hl = "XlsViewRowNr",
      }
      byte = #s
    end
    pieces[#pieces + 1] = B.v
    byte = byte + #B.v
    local is_hdr = header_row and ri == 1
    for c = 1, ncol do
      local cell = row[c]
      local text, hl = format_cell(cell, col_w[c], is_hdr)
      local c0 = byte
      pieces[#pieces + 1] = text
      byte = byte + #text
      extmarks[#extmarks + 1] = {
        row = row0,
        col = c0,
        end_col = byte,
        hl = is_hdr and "XlsViewHeader" or hl,
      }
      -- header 仍叠真彩（有 fill/color 时）
      if is_hdr and type(cell) == "table" and (cell.bg or (cell.color and cell.color ~= "#000000")) then
        extmarks[#extmarks + 1] = {
          row = row0,
          col = c0,
          end_col = byte,
          hl = hl,
        }
      end
      pieces[#pieces + 1] = B.v
      byte = byte + #B.v
    end
    lines[#lines + 1] = table.concat(pieces)
    extmarks[#extmarks + 1] = {
      row = row0,
      col = 0,
      end_col = #lines[#lines],
      hl = "XlsViewBorder",
    }
    if is_hdr and style ~= "minimal" then
      emit(border_line(B.l, B.c, B.r), "XlsViewBorder")
    end
  end

  if style ~= "minimal" then
    emit(border_line(B.bl, B.b, B.br), "XlsViewBorder")
  end

  return lines, extmarks, hits
end

---@param data table
---@param opts { width: number, cfg: table, sheet_index: number }
function M.render(data, opts)
  highlight.ensure()
  opts = opts or {}
  local cfg = opts.cfg or {}
  local width = math.max(20, opts.width or 80)
  local sheets = data.sheets or {}
  local si = math.max(1, math.min(#sheets, opts.sheet_index or 1))

  local lines = {}
  local extmarks = {}
  local hits = {}

  local title = (data.meta and data.meta.title) or ""
  if title == "" then
    title = vim.fn.fnamemodify(data.path or "book.xlsx", ":t")
  end
  local h1 = "📊 " .. title
  lines[#lines + 1] = h1
  extmarks[#extmarks + 1] = { row = 0, col = 0, end_col = #h1, hl = "XlsViewTitle" }

  local i18n = require("xlsview.i18n")
  local meta = string.format(
    i18n.t("meta"),
    data.sheet_count or #sheets,
    data.max_rows or 0,
    data.max_cols or 0,
    math.max(1, #sheets)
  )
  lines[#lines + 1] = meta
  extmarks[#extmarks + 1] = { row = 1, col = 0, end_col = #meta, hl = "XlsViewMeta" }
  lines[#lines + 1] = ""

  -- sheet tabs
  local tab_parts = {}
  local tab_marks = {}
  local col = 0
  for i, sh in ipairs(sheets) do
    local name = sh.name or ("Sheet" .. i)
    local label = (i == si) and ("[" .. name .. "]") or (" " .. name .. " ")
    if i > 1 then
      tab_parts[#tab_parts + 1] = " "
      col = col + 1
    end
    local c0 = col
    tab_parts[#tab_parts + 1] = label
    col = col + #label
    tab_marks[#tab_marks + 1] = {
      col = c0,
      end_col = col,
      hl = (i == si) and "XlsViewSheetActive" or "XlsViewSheetInactive",
      sheet = i,
    }
    hits[#hits + 1] = {
      kind = "sheet",
      line = #lines + 1,
      col = c0,
      end_col = col,
      sheet = i,
    }
  end
  local tab_line = table.concat(tab_parts)
  local tab_row = #lines
  lines[#lines + 1] = tab_line
  for _, m in ipairs(tab_marks) do
    extmarks[#extmarks + 1] = {
      row = tab_row,
      col = m.col,
      end_col = m.end_col,
      hl = m.hl,
    }
  end
  lines[#lines + 1] = ""

  local sheet = sheets[si] or { rows = {} }
  local info = string.format(
    "── %s  (%d×%d) ",
    sheet.name or ("#" .. si),
    sheet.nrows or 0,
    sheet.ncols or 0
  )
  local pad = width - str_width(info)
  if pad > 0 then
    info = info .. string.rep("─", pad)
  end
  local ir = #lines
  lines[#lines + 1] = info
  extmarks[#extmarks + 1] = { row = ir, col = 0, end_col = #info, hl = "XlsViewSheet" }
  lines[#lines + 1] = ""

  local body, bem, bhits = render_sheet(sheet, width, cfg)
  local base = #lines
  for _, ln in ipairs(body) do
    lines[#lines + 1] = ln
  end
  for _, m in ipairs(bem) do
    extmarks[#extmarks + 1] = {
      row = base + m.row,
      col = m.col,
      end_col = m.end_col,
      hl = m.hl,
    }
  end
  for _, h in ipairs(bhits) do
    hits[#hits + 1] = h
  end

  local hint = require("xlsview.i18n").t("hint")
  lines[#lines + 1] = ""
  local hr = #lines
  lines[#lines + 1] = hint
  extmarks[#extmarks + 1] = { row = hr, col = 0, end_col = #hint, hl = "XlsViewHint" }

  return {
    lines = lines,
    extmarks = extmarks,
    hits = hits,
    sheet_index = si,
    ns = NS,
  }
end

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
