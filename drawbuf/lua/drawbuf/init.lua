---@mod drawbuf 1/2 & 1/4 block drawing canvas in Neovim
local M = {}

---@class DrawbufConfig
---@field width number
---@field height number
---@field default_char string
---@field brush_chars string[]
---@field colors string[] hex without #
---@field canvas_bg string default empty cell background
---@field statusline boolean

-- 100% 全方格 + 1/2 + 1/4 Unicode 色块
local BLOCK_CHARS = {
  "█", -- 100% 全方格
  "▀", -- 上半 1/2
  "▄", -- 下半 1/2
  "▌", -- 左半 1/2
  "▐", -- 右半 1/2
  "▘", -- 左上 1/4
  "▝", -- 右上 1/4
  "▖", -- 左下 1/4
  "▗", -- 右下 1/4
  "▚", -- 对角
  "▞", -- 对角
  "▙", -- 3/4
  "▛", -- 3/4
  "▜", -- 3/4
  "▟", -- 3/4
}

local BLOCK_LABELS = {
  ["█"] = "100% 全方格",
  ["▀"] = "上半 1/2",
  ["▄"] = "下半 1/2",
  ["▌"] = "左半 1/2",
  ["▐"] = "右半 1/2",
  ["▘"] = "左上 1/4",
  ["▝"] = "右上 1/4",
  ["▖"] = "左下 1/4",
  ["▗"] = "右下 1/4",
  ["▚"] = "对角",
  ["▞"] = "对角",
  ["▙"] = "3/4",
  ["▛"] = "3/4",
  ["▜"] = "3/4",
  ["▟"] = "3/4",
}

local default_config = {
  width = 80,
  height = 24,
  default_char = " ",
  brush_chars = BLOCK_CHARS,
  -- 1 白 … 11 黑；默认画笔用黑（见 open 时 fg）
  colors = {
    "ffffff",
    "ff5555",
    "50fa7b",
    "f1fa8c",
    "bd93f9",
    "ff79c6",
    "8be9fd",
    "ffb86c",
    "aaaaaa",
    "44475a",
    "000000",
  },
  -- 默认：白底纸 + 黑线
  canvas_bg = "ffffff",
  statusline = true,
}

local config = vim.deepcopy(default_config)
local ns = vim.api.nvim_create_namespace("drawbuf")
local state_by_buf = {} ---@type table<integer, table>
local hl_cache = {} ---@type table<string, boolean>

local TOOL_PENCIL = "pencil"
local TOOL_ERASER = "eraser"
local TOOL_LINE = "line"
local TOOL_RECT = "rect"
local TOOL_ELLIPSE = "ellipse"
local TOOL_FILL = "fill"

local TOOL_LABELS = {
  [TOOL_PENCIL] = "铅笔",
  [TOOL_ERASER] = "橡皮",
  [TOOL_LINE] = "直线",
  [TOOL_RECT] = "矩形",
  [TOOL_ELLIPSE] = "椭圆",
  [TOOL_FILL] = "填充",
}

local TOOL_ORDER = {
  TOOL_PENCIL,
  TOOL_ERASER,
  TOOL_LINE,
  TOOL_RECT,
  TOOL_ELLIPSE,
  TOOL_FILL,
}

local function is_shape_tool(tool)
  return tool == TOOL_LINE or tool == TOOL_RECT or tool == TOOL_ELLIPSE
end

---Default pen color: prefer pure black in palette, else last entry.
local function default_ink_fg()
  for i, hex in ipairs(config.colors) do
    if tostring(hex):lower():gsub("^#", "") == "000000" then
      return i
    end
  end
  local n = #config.colors
  return n > 0 and n or 1
end

local function ensure_hl()
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  vim.api.nvim_set_hl(0, "DrawbufCursor", {
    fg = "#000000",
    bg = "#f1fa8c",
    bold = true,
  })
  vim.api.nvim_set_hl(0, "DrawbufStatus", {
    fg = "#cdd6f4",
    bg = "#313244",
    bold = true,
  })
  vim.api.nvim_set_hl(0, "DrawbufStatusBtn", {
    fg = "#1e1e2e",
    bg = "#89b4fa",
    bold = true,
  })
  vim.api.nvim_set_hl(0, "DrawbufStatusBtnHot", {
    fg = "#1e1e2e",
    bg = "#a6e3a1",
    bold = true,
  })
  vim.api.nvim_set_hl(0, "DrawbufEmpty", {
    fg = "#" .. config.canvas_bg,
    bg = "#" .. config.canvas_bg,
  })
  -- shape drag preview (distinct from final paint)
  vim.api.nvim_set_hl(0, "DrawbufPreview", {
    fg = "#11111b",
    bg = "#f9e2af",
    bold = true,
  })
end

---fg/bg palette indices (0 = canvas default / empty)
local function cell_hl(fg, bg)
  fg = fg or 0
  bg = bg or 0
  local key = fg .. "_" .. bg
  local name = "DrawbufF" .. fg .. "B" .. bg
  if not hl_cache[key] then
    local fg_hex = (fg > 0 and config.colors[fg]) or config.canvas_bg
    local bg_hex = (bg > 0 and config.colors[bg]) or config.canvas_bg
    vim.api.nvim_set_hl(0, name, { fg = "#" .. fg_hex, bg = "#" .. bg_hex })
    hl_cache[key] = true
  end
  return name
end

local function color_swatch_hl(idx, kind)
  -- kind: "fg" or "bg" preview on status
  local name = "DrawbufSwatch" .. kind .. idx
  local key = "sw_" .. kind .. idx
  if not hl_cache[key] then
    local hex = (idx > 0 and config.colors[idx]) or config.canvas_bg
    if kind == "fg" then
      vim.api.nvim_set_hl(0, name, { fg = "#" .. hex, bg = "#" .. config.canvas_bg })
    else
      vim.api.nvim_set_hl(0, name, { fg = "#" .. hex, bg = "#" .. hex })
    end
    hl_cache[key] = true
  end
  return name
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

local function is_block_char(ch)
  if not ch or ch == "" or ch == " " then
    return ch == " "
  end
  for _, b in ipairs(config.brush_chars) do
    if b == ch then
      return true
    end
  end
  return false
end

local function normalize_glyph(ch)
  if not ch or ch == "" or ch == " " then
    return " "
  end
  ch = vim.fn.strcharpart(ch, 0, 1)
  if is_block_char(ch) then
    return ch
  end
  -- unknown → full block
  return "█"
end

local function cell_show_char(st, x, y)
  local cell = st.grid[y][x]
  local ch = cell.ch
  if ch == "" or ch == nil then
    ch = " "
  end
  if x == st.cx and y == st.cy and (ch == " " or (cell.fg or 0) == 0) then
    return "·"
  end
  return normalize_glyph(ch)
end

local function empty_cell()
  return { ch = " ", fg = 0, bg = 0 }
end

local function empty_grid(w, h)
  local grid = {}
  for y = 1, h do
    grid[y] = {}
    for x = 1, w do
      grid[y][x] = empty_cell()
    end
  end
  return grid
end

local function clone_grid(grid)
  local h = #grid
  local w = h > 0 and #grid[1] or 0
  local out = {}
  for y = 1, h do
    out[y] = {}
    for x = 1, w do
      local c = grid[y][x]
      out[y][x] = { ch = c.ch, fg = c.fg or c.c or 0, bg = c.bg or 0 }
    end
  end
  return out
end

local function push_undo(st)
  st.undo = st.undo or {}
  table.insert(st.undo, clone_grid(st.grid))
  if #st.undo > 50 then
    table.remove(st.undo, 1)
  end
  st.redo = {}
end

local function mark_row_dirty(st, y)
  if not st.dirty_rows then
    st.dirty_rows = {}
  end
  if y >= 1 and y <= st.height then
    st.dirty_rows[y] = true
  end
end

local function mark_cell_dirty(st, x, y)
  mark_row_dirty(st, y)
end

local function mark_all_dirty(st)
  st.dirty_rows = {}
  for y = 1, st.height do
    st.dirty_rows[y] = true
  end
  st.status_dirty = true
  st.need_full = true
end

local function set_cell(st, x, y, ch, fg, bg)
  if y < 1 or y > st.height or x < 1 or x > st.width then
    return
  end
  local prev = st.grid[y][x]
  local nch, nfg, nbg = ch, fg or 0, bg or 0
  if prev and prev.ch == nch and (prev.fg or 0) == nfg and (prev.bg or 0) == nbg then
    return
  end
  st.grid[y][x] = {
    ch = nch,
    fg = nfg,
    bg = nbg,
  }
  st.dirty = true
  mark_cell_dirty(st, x, y)
end

local function paint_cell(st, x, y)
  if st.tool == TOOL_ERASER then
    set_cell(st, x, y, " ", 0, 0)
  else
    set_cell(st, x, y, normalize_glyph(st.brush), st.fg, st.bg)
  end
end

---Invoke paint_fn(x,y) for each point on a Bresenham line
local function each_line_point(x0, y0, x1, y1, paint_fn)
  local dx = math.abs(x1 - x0)
  local dy = -math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  local x, y = x0, y0
  while true do
    paint_fn(x, y)
    if x == x1 and y == y1 then
      break
    end
    local e2 = 2 * err
    if e2 >= dy then
      err = err + dy
      x = x + sx
    end
    if e2 <= dx then
      err = err + dx
      y = y + sy
    end
  end
end

local function each_rect_point(x0, y0, x1, y1, paint_fn)
  local xa, xb = math.min(x0, x1), math.max(x0, x1)
  local ya, yb = math.min(y0, y1), math.max(y0, y1)
  for x = xa, xb do
    paint_fn(x, ya)
    paint_fn(x, yb)
  end
  for y = ya, yb do
    paint_fn(xa, y)
    paint_fn(xb, y)
  end
end

---Ellipse outline from bounding box corners (x0,y0)-(x1,y1)
local function each_ellipse_point(x0, y0, x1, y1, paint_fn)
  local xa, xb = math.min(x0, x1), math.max(x0, x1)
  local ya, yb = math.min(y0, y1), math.max(y0, y1)
  local cx = (xa + xb) / 2
  local cy = (ya + yb) / 2
  local rx = (xb - xa) / 2
  local ry = (yb - ya) / 2
  if rx < 0.5 then
    rx = 0.5
  end
  if ry < 0.5 then
    ry = 0.5
  end
  local seen = {}
  local function plot(px, py)
    px = math.floor(px + 0.5)
    py = math.floor(py + 0.5)
    local k = py * 100000 + px
    if not seen[k] then
      seen[k] = true
      paint_fn(px, py)
    end
  end
  local steps = math.max(64, math.floor((rx + ry) * 6))
  local prevx, prevy
  for i = 0, steps do
    local t = (i / steps) * 2 * math.pi
    local x = cx + rx * math.cos(t)
    local y = cy + ry * math.sin(t)
    local ix, iy = math.floor(x + 0.5), math.floor(y + 0.5)
    if prevx then
      each_line_point(prevx, prevy, ix, iy, plot)
    else
      plot(ix, iy)
    end
    prevx, prevy = ix, iy
  end
end

local function each_shape_point(tool, x0, y0, x1, y1, paint_fn)
  if tool == TOOL_LINE then
    each_line_point(x0, y0, x1, y1, paint_fn)
  elseif tool == TOOL_RECT then
    each_rect_point(x0, y0, x1, y1, paint_fn)
  elseif tool == TOOL_ELLIPSE then
    each_ellipse_point(x0, y0, x1, y1, paint_fn)
  end
end

local function apply_shape(st, tool, x0, y0, x1, y1)
  each_shape_point(tool, x0, y0, x1, y1, function(x, y)
    paint_cell(st, x, y)
  end)
end

local function cancel_shape_drag(st)
  if st.shape_drag and st.preview_map then
    for k, _ in pairs(st.preview_map) do
      local y = math.floor(k / (st.width + 1))
      mark_row_dirty(st, y)
    end
  end
  st.shape_drag = nil
  st.preview_map = {}
end

local function commit_shape_drag(st)
  local s = st.shape_drag
  if not s then
    return false
  end
  push_undo(st)
  apply_shape(st, s.tool or st.tool, s.x0, s.y0, s.x1, s.y1)
  st.shape_drag = nil
  st.preview_map = {}
  return true
end

local function start_shape_drag(st, x, y, tool)
  st.shape_drag = {
    tool = tool or st.tool,
    x0 = x,
    y0 = y,
    x1 = x,
    y1 = y,
  }
  st.drawing = false
  st.mouse_dragging = false
  mark_row_dirty(st, y)
end

local function flood_fill(st, x, y)
  if y < 1 or y > st.height or x < 1 or x > st.width then
    return
  end
  local target = st.grid[y][x]
  local tch, tfg, tbg = target.ch, target.fg or 0, target.bg or 0
  local nch, nfg, nbg = st.brush, st.fg, st.bg
  if st.tool == TOOL_ERASER then
    nch, nfg, nbg = " ", 0, 0
  else
    nch = normalize_glyph(nch)
  end
  if tch == nch and tfg == nfg and tbg == nbg then
    return
  end
  local stack = { { x, y } }
  local seen = {}
  local function key(a, b)
    return b * (st.width + 1) + a
  end
  while #stack > 0 do
    local p = table.remove(stack)
    local px, py = p[1], p[2]
    if px >= 1 and px <= st.width and py >= 1 and py <= st.height then
      local k = key(px, py)
      if not seen[k] then
        seen[k] = true
        local cell = st.grid[py][px]
        if cell.ch == tch and (cell.fg or 0) == tfg and (cell.bg or 0) == tbg then
          set_cell(st, px, py, nch, nfg, nbg)
          table.insert(stack, { px + 1, py })
          table.insert(stack, { px - 1, py })
          table.insert(stack, { px, py + 1 })
          table.insert(stack, { px, py - 1 })
        end
      end
    end
  end
end

---Build status line + click hitboxes (display-column based, 1-based inclusive).
local function build_status(st)
  local parts = {}
  local hits = {}
  local col = 1 -- display column

  local function add_text(s, hl, hit_id)
    local w = vim.fn.strwidth(s)
    local start_c = col
    local end_c = col + w - 1
    table.insert(parts, { text = s, hl = hl or "DrawbufStatus", hit = hit_id })
    if hit_id then
      table.insert(hits, { id = hit_id, c0 = start_c, c1 = end_c })
    end
    col = end_c + 1
  end

  local function add_gap(n)
    add_text(string.rep(" ", n or 1), "DrawbufStatus", nil)
  end

  local tool_name = TOOL_LABELS[st.tool] or st.tool
  add_text("[" .. tool_name .. " ▾]", "DrawbufStatusBtnHot", "tool")
  add_gap(1)
  add_text("[字符:" .. normalize_glyph(st.brush) .. " ▾]", "DrawbufStatusBtn", "brush")
  add_gap(1)
  add_text("[前景:", "DrawbufStatus", nil)
  add_text("██", nil, "fg") -- hl applied specially
  add_text(" ▾]", "DrawbufStatus", "fg")
  add_gap(1)
  add_text("[背景:", "DrawbufStatus", nil)
  add_text("██", nil, "bg")
  add_text(" ▾]", "DrawbufStatus", "bg")
  add_gap(2)
  add_text(string.format("%d×%d", st.width, st.height), "DrawbufStatus", nil)
  add_gap(1)
  add_text(string.format("(%d,%d)", st.cx, st.cy), "DrawbufStatus", nil)
  add_gap(2)
  add_text("[演示 ▾]", "DrawbufStatusBtnHot", "demo")
  add_gap(1)
  add_text("[保存]", "DrawbufStatusBtn", "save")
  add_gap(1)
  add_text("[退出]", "DrawbufStatusBtn", "quit")
  add_gap(1)
  add_text("[撤销]", "DrawbufStatusBtn", "undo")
  add_gap(1)
  add_text("[?]", "DrawbufStatusBtn", "help")

  local text_parts = {}
  for _, p in ipairs(parts) do
    table.insert(text_parts, p.text)
  end
  return table.concat(text_parts), parts, hits, col - 1
end

local function status_row_index(st)
  -- 0-based: canvas height rows, blank, status
  return st.height + 1
end

---Build current shape-preview map (or empty)
local function build_preview_map(st)
  local preview = {}
  if not st.shape_drag then
    return preview
  end
  local s = st.shape_drag
  local brush = normalize_glyph(st.brush)
  local pfg, pbg = st.fg or 0, st.bg or 0
  each_shape_point(s.tool or st.tool, s.x0, s.y0, s.x1, s.y1, function(x, y)
    if x >= 1 and x <= st.width and y >= 1 and y <= st.height then
      preview[y * (st.width + 1) + x] = { ch = brush, fg = pfg, bg = pbg }
    end
  end)
  return preview
end

local function cell_visual(st, x, y, preview)
  local pkey = y * (st.width + 1) + x
  if preview[pkey] then
    local pv = preview[pkey]
    return pv.ch, cell_hl(pv.fg or 0, pv.bg or 0), true
  end
  local show = cell_show_char(st, x, y)
  local cell = st.grid[y][x]
  if x == st.cx and y == st.cy then
    return show, "DrawbufCursor", false
  end
  local fg, bg = cell.fg or 0, cell.bg or 0
  if (show == " " or show == "·") and fg == 0 and bg == 0 then
    return show, "DrawbufEmpty", false
  end
  return show, cell_hl(fg, bg), false
end

---Redraw one canvas row (text + highlights). O(width).
local function redraw_row(buf, st, y, preview)
  if y < 1 or y > st.height then
    return
  end
  preview = preview or st.preview_map or {}
  local parts = {}
  local marks = {} -- {byte_start, byte_end, hl}
  local byte_col = 0
  for x = 1, st.width do
    local show, hl = cell_visual(st, x, y, preview)
    local blen = #show
    table.insert(parts, show)
    table.insert(marks, { byte_col, byte_col + blen, hl })
    byte_col = byte_col + blen
  end
  local line = table.concat(parts)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, y - 1, y, false, { line })
  -- clear only this row's extmarks
  vim.api.nvim_buf_clear_namespace(buf, ns, y - 1, y)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, y - 1, m[1], {
      end_row = y - 1,
      end_col = m[2],
      hl_group = m[3],
      hl_mode = "replace",
      priority = 200,
      strict = false,
    })
  end
end

local function redraw_status(buf, st)
  if not config.statusline then
    st.status_hits = {}
    return
  end
  local status_str, status_parts, hits = build_status(st)
  st.status_hits = hits
  st.status_parts = status_parts
  local srow = status_row_index(st) -- 0-based status row
  -- ensure blank + status exist
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.bo[buf].modifiable = true
  if line_count < st.height + 2 then
    local pad = {}
    for _ = line_count + 1, st.height + 2 do
      table.insert(pad, "")
    end
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, pad)
  end
  vim.api.nvim_buf_set_lines(buf, st.height, st.height + 2, false, { "", status_str })
  vim.api.nvim_buf_clear_namespace(buf, ns, srow, srow + 1)
  local byte_col = 0
  for _, p in ipairs(status_parts) do
    local blen = #p.text
    local hl = p.hl or "DrawbufStatus"
    if p.hit == "fg" and p.text == "██" then
      hl = color_swatch_hl(st.fg, "fg")
    elseif p.hit == "bg" and p.text == "██" then
      hl = color_swatch_hl(st.bg, "bg")
    end
    vim.api.nvim_buf_set_extmark(buf, ns, srow, byte_col, {
      end_row = srow,
      end_col = byte_col + blen,
      hl_group = hl,
      hl_mode = "replace",
      priority = 210,
      strict = false,
    })
    byte_col = byte_col + blen
  end
end

local function place_cursor(buf, st)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end
  local byte_col = 0
  local preview = st.preview_map or {}
  for x = 1, st.cx - 1 do
    local show = cell_visual(st, x, st.cy, preview)
    byte_col = byte_col + #show
  end
  pcall(vim.api.nvim_win_set_cursor, win, { st.cy, byte_col })
end

---Full redraw (open / load demo / resize)
local function paint_buffer_full(buf)
  local st = state_by_buf[buf]
  if not st then
    return
  end
  ensure_hl()
  st.preview_map = build_preview_map(st)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local lines = {}
  for y = 1, st.height do
    local parts = {}
    for x = 1, st.width do
      local show = cell_visual(st, x, y, st.preview_map)
      table.insert(parts, show)
    end
    table.insert(lines, table.concat(parts))
  end
  if config.statusline then
    table.insert(lines, "")
    local s, parts, hits = build_status(st)
    st.status_parts, st.status_hits = parts, hits
    table.insert(lines, s)
  else
    st.status_hits = {}
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for y = 1, st.height do
    local byte_col = 0
    for x = 1, st.width do
      local show, hl = cell_visual(st, x, y, st.preview_map)
      local blen = #show
      vim.api.nvim_buf_set_extmark(buf, ns, y - 1, byte_col, {
        end_row = y - 1,
        end_col = byte_col + blen,
        hl_group = hl,
        hl_mode = "replace",
        priority = 200,
        strict = false,
      })
      byte_col = byte_col + blen
    end
  end

  -- status highlights (lines already set)
  if config.statusline and st.status_parts then
    local srow = status_row_index(st)
    local byte_col = 0
    for _, p in ipairs(st.status_parts) do
      local blen = #p.text
      local hl = p.hl or "DrawbufStatus"
      if p.hit == "fg" and p.text == "██" then
        hl = color_swatch_hl(st.fg, "fg")
      elseif p.hit == "bg" and p.text == "██" then
        hl = color_swatch_hl(st.bg, "bg")
      end
      vim.api.nvim_buf_set_extmark(buf, ns, srow, byte_col, {
        end_row = srow,
        end_col = byte_col + blen,
        hl_group = hl,
        hl_mode = "replace",
        priority = 210,
        strict = false,
      })
      byte_col = byte_col + blen
    end
  end

  place_cursor(buf, st)
  st.dirty_rows = {}
  st.need_full = false
  st.rendered = true
  st.status_dirty = false
  st._prev_cx, st._prev_cy = st.cx, st.cy
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = st.dirty == true
end

---Incremental: only dirty rows + optional status
local function paint_buffer_dirty(buf)
  local st = state_by_buf[buf]
  if not st or not st.rendered then
    paint_buffer_full(buf)
    return
  end
  ensure_hl()

  -- cursor moved → dirty old/new rows
  if st._prev_cx and (st._prev_cx ~= st.cx or st._prev_cy ~= st.cy) then
    mark_row_dirty(st, st._prev_cy)
    mark_row_dirty(st, st.cy)
  end

  -- shape preview: dirty rows from old and new preview maps
  local new_preview = build_preview_map(st)
  local rows = st.dirty_rows or {}
  local function mark_preview_rows(pmap)
    for k, _ in pairs(pmap) do
      local y = math.floor(k / (st.width + 1))
      rows[y] = true
    end
  end
  if st.preview_map then
    mark_preview_rows(st.preview_map)
  end
  mark_preview_rows(new_preview)
  st.preview_map = new_preview
  st.dirty_rows = rows

  if st.need_full or not next(st.dirty_rows) and not st.status_dirty then
    if st.need_full then
      paint_buffer_full(buf)
      return
    end
  end

  vim.bo[buf].modifiable = true
  for y, _ in pairs(st.dirty_rows) do
    redraw_row(buf, st, y, st.preview_map)
  end
  st.dirty_rows = {}

  if st.status_dirty then
    redraw_status(buf, st)
    st.status_dirty = false
  end

  place_cursor(buf, st)
  st._prev_cx, st._prev_cy = st.cx, st.cy
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = st.dirty == true
end

local function paint_buffer(buf, full)
  if full then
    paint_buffer_full(buf)
  else
    paint_buffer_dirty(buf)
  end
end

local function move(st, dx, dy)
  st.cx = clamp(st.cx + dx, 1, st.width)
  st.cy = clamp(st.cy + dy, 1, st.height)
  -- keyboard shape: moving updates endpoint + live preview
  if st.shape_drag and not st.shape_drag.from_mouse then
    st.shape_drag.x1 = st.cx
    st.shape_drag.y1 = st.cy
  elseif st.drawing and not st.shape_drag then
    paint_cell(st, st.cx, st.cy)
  end
end

local function do_paint_here(st)
  -- shape tools: Space 开始/确认（键盘）；鼠标用按下-拖动-松开
  if is_shape_tool(st.tool) then
    if not st.shape_drag then
      start_shape_drag(st, st.cx, st.cy, st.tool)
      st.shape_drag.from_mouse = false
      vim.notify("drawbuf: 拖动/移动到终点，Space/松开确认，Esc 取消", vim.log.levels.INFO)
    else
      commit_shape_drag(st)
    end
    return
  end
  if st.tool == TOOL_FILL then
    push_undo(st)
    flood_fill(st, st.cx, st.cy)
    return
  end
  push_undo(st)
  paint_cell(st, st.cx, st.cy)
end

local function undo(st)
  if not st.undo or #st.undo == 0 then
    return
  end
  st.redo = st.redo or {}
  table.insert(st.redo, clone_grid(st.grid))
  st.grid = table.remove(st.undo)
  st.dirty = true
  mark_all_dirty(st)
end

local function redo(st)
  if not st.redo or #st.redo == 0 then
    return
  end
  st.undo = st.undo or {}
  table.insert(st.undo, clone_grid(st.grid))
  st.grid = table.remove(st.redo)
  st.dirty = true
  mark_all_dirty(st)
end

local function set_tool(st, tool)
  st.tool = tool
  st.anchor = nil
  st.drawing = false
  cancel_shape_drag(st)
  st.status_dirty = true
end

local function grid_to_text(st, with_meta)
  local lines = {}
  if with_meta then
    table.insert(lines, string.format("DRAWBUF %d %d", st.width, st.height))
  end
  for y = 1, st.height do
    local parts = {}
    for x = 1, st.width do
      table.insert(parts, st.grid[y][x].ch)
    end
    table.insert(lines, table.concat(parts))
  end
  if with_meta then
    local function write_layer(name, field)
      table.insert(lines, name)
      for y = 1, st.height do
        local parts = {}
        for x = 1, st.width do
          local c = st.grid[y][x][field] or 0
          if c < 10 then
            table.insert(parts, tostring(c))
          else
            table.insert(parts, string.char(string.byte("a") + c - 10))
          end
        end
        table.insert(lines, table.concat(parts))
      end
    end
    write_layer("COLORS", "fg") -- backward name = fg
    write_layer("BGCOLORS", "bg")
  end
  return lines
end

local function parse_color_digit(ch)
  if ch:match("%d") then
    return tonumber(ch)
  end
  if ch:match("[a-z]") then
    return string.byte(ch) - string.byte("a") + 10
  end
  return 0
end

local function parse_draw_file(lines)
  if #lines == 0 then
    return nil, "empty file"
  end
  local w, h
  local start = 1
  if lines[1]:match("^DRAWBUF%s+%d+%s+%d+") then
    w = tonumber(lines[1]:match("^DRAWBUF%s+(%d+)"))
    h = tonumber(lines[1]:match("^DRAWBUF%s+%d+%s+(%d+)"))
    start = 2
  else
    h = #lines
    w = vim.fn.strchars(lines[1] or "")
  end
  local grid = empty_grid(w, h)
  local y = 1
  local i = start
  while i <= #lines and y <= h do
    local line = lines[i]
    if line == "COLORS" or line == "BGCOLORS" then
      break
    end
    local len = vim.fn.strchars(line)
    for x = 1, math.min(w, len) do
      local ch = vim.fn.strcharpart(line, x - 1, 1)
      grid[y][x] = {
        ch = normalize_glyph(ch),
        fg = ch == " " and 0 or default_ink_fg(),
        bg = 0,
      }
    end
    y = y + 1
    i = i + 1
  end
  local function read_layer(field)
    if lines[i] ~= "COLORS" and lines[i] ~= "BGCOLORS" then
      return
    end
    -- COLORS means fg; BGCOLORS means bg
    if lines[i] == "COLORS" then
      field = "fg"
    elseif lines[i] == "BGCOLORS" then
      field = "bg"
    end
    i = i + 1
    y = 1
    while i <= #lines and y <= h do
      if lines[i] == "COLORS" or lines[i] == "BGCOLORS" then
        break
      end
      local line = lines[i]
      for x = 1, math.min(w, #line) do
        if grid[y] and grid[y][x] then
          grid[y][x][field] = parse_color_digit(line:sub(x, x))
        end
      end
      y = y + 1
      i = i + 1
    end
  end
  read_layer("fg")
  read_layer("bg")
  return { width = w, height = h, grid = grid }
end

local function save(st, path)
  path = path or st.path
  if not path or path == "" then
    path = vim.fn.input("保存为: ", "drawing.draw", "file")
    if path == nil or path == "" then
      return
    end
  end
  path = vim.fn.fnamemodify(path, ":p")
  local ok, err = pcall(vim.fn.writefile, grid_to_text(st, true), path)
  if not ok then
    vim.notify("drawbuf: 保存失败: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  st.path = path
  st.dirty = false
  vim.notify("drawbuf: 已保存 " .. path, vim.log.levels.INFO)
end

local function export_plain(st, path)
  path = path or vim.fn.input("导出文本: ", "drawing.txt", "file")
  if path == nil or path == "" then
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  local ok, err = pcall(vim.fn.writefile, grid_to_text(st, false), path)
  if not ok then
    vim.notify("drawbuf: 导出失败: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("drawbuf: 已导出 " .. path, vim.log.levels.INFO)
end

local function clear_canvas(st)
  push_undo(st)
  st.grid = empty_grid(st.width, st.height)
  st.dirty = true
  mark_all_dirty(st)
end

local function ncolors()
  return #config.colors
end

local function color_at(i)
  local n = ncolors()
  if n < 1 then
    return 1
  end
  return ((i - 1) % n) + 1
end

---Paint a cell only if inside canvas (helpers for demos)
local function put(st, x, y, ch, fg, bg)
  if x >= 1 and x <= st.width and y >= 1 and y <= st.height then
    set_cell(st, x, y, ch or "█", fg or 1, bg or 0)
  end
end

local function fill_rect(st, x0, y0, x1, y1, ch, fg, bg)
  for y = y0, y1 do
    for x = x0, x1 do
      put(st, x, y, ch, fg, bg)
    end
  end
end

---Map normalized coords [0,1]x[0,1] → canvas cell
local function to_xy(st, u, v)
  local x = math.floor(u * (st.width - 1) + 1.5)
  local y = math.floor(v * (st.height - 1) + 1.5)
  return clamp(x, 1, st.width), clamp(y, 1, st.height)
end

local function fill_bg(st, fg, bg, ch)
  fill_rect(st, 1, 1, st.width, st.height, ch or "█", fg or 7, bg or 0)
end

local function fill_circle(st, cx, cy, rx, ry, ch, fg, bg)
  rx = math.max(0.6, rx)
  ry = math.max(0.6, ry)
  for y = math.floor(cy - ry - 1), math.ceil(cy + ry + 1) do
    for x = math.floor(cx - rx - 1), math.ceil(cx + rx + 1) do
      local dx = (x - cx) / rx
      local dy = (y - cy) / ry
      if dx * dx + dy * dy <= 1.05 then
        put(st, x, y, ch or "█", fg, bg)
      end
    end
  end
end

local function stroke_circle(st, cx, cy, rx, ry, ch, fg, bg)
  rx = math.max(0.6, rx)
  ry = math.max(0.6, ry)
  local steps = math.max(48, math.floor((rx + ry) * 5))
  local prevx, prevy
  for i = 0, steps do
    local t = (i / steps) * 2 * math.pi
    local x = math.floor(cx + rx * math.cos(t) + 0.5)
    local y = math.floor(cy + ry * math.sin(t) + 0.5)
    if prevx then
      each_line_point(prevx, prevy, x, y, function(px, py)
        put(st, px, py, ch or "█", fg, bg)
      end)
    else
      put(st, x, y, ch or "█", fg, bg)
    end
    prevx, prevy = x, y
  end
end

---Built-in colorful demos (scale with canvas)
local DEMO_PATTERNS = {
  {
    id = "smiley",
    name = "笑脸",
    desc = "经典黄色笑脸",
    build = function(st)
      local w, h = st.width, st.height
      fill_bg(st, 7, 0, "█") -- cyan sky-ish empty via dark
      fill_rect(st, 1, 1, w, h, "█", 10, 0)
      local cx, cy = (w + 1) / 2, (h + 1) / 2
      local rx, ry = w * 0.34, h * 0.40
      fill_circle(st, cx, cy, rx, ry, "█", 4, 8) -- yellow face, orange undertone
      stroke_circle(st, cx, cy, rx + 0.4, ry + 0.4, "█", 8, 0)
      -- eyes
      local ey = cy - ry * 0.22
      local ex = rx * 0.38
      fill_circle(st, cx - ex, ey, rx * 0.12, ry * 0.14, "█", 11, 4)
      fill_circle(st, cx + ex, ey, rx * 0.12, ry * 0.14, "█", 11, 4)
      fill_circle(st, cx - ex + 0.4, ey - 0.3, rx * 0.04, ry * 0.05, "█", 1, 11)
      fill_circle(st, cx + ex + 0.4, ey - 0.3, rx * 0.04, ry * 0.05, "█", 1, 11)
      -- blush
      fill_circle(st, cx - ex * 1.15, cy + ry * 0.05, rx * 0.12, ry * 0.06, "█", 6, 4)
      fill_circle(st, cx + ex * 1.15, cy + ry * 0.05, rx * 0.12, ry * 0.06, "█", 6, 4)
      -- smile
      local my = cy + ry * 0.18
      for x = math.floor(cx - rx * 0.42), math.floor(cx + rx * 0.42) do
        local t = (x - cx) / (rx * 0.42)
        local yy = math.floor(my + t * t * ry * 0.28 + 0.5)
        put(st, x, yy, "▄", 11, 4)
        put(st, x, yy + 1, "▀", 2, 4)
      end
    end,
  },
  {
    id = "rainbow_cat",
    name = "彩虹猫",
    desc = "Nyan 风彩虹猫",
    build = function(st)
      local w, h = st.width, st.height
      -- space bg with stars
      fill_rect(st, 1, 1, w, h, "█", 11, 0)
      for i = 1, math.floor(w * h / 18) do
        local sx = ((i * 37) % w) + 1
        local sy = ((i * 53) % h) + 1
        put(st, sx, sy, "▀", 1, 11)
      end
      -- rainbow trail (left half)
      local trail_x1 = 1
      local trail_x2 = math.floor(w * 0.48)
      local band_h = math.max(1, math.floor(h * 0.55 / 6))
      local by0 = math.floor(h * 0.22)
      local rainbow = { 2, 8, 4, 3, 7, 5 } -- r o y g c p
      for bi, col in ipairs(rainbow) do
        local y0 = by0 + (bi - 1) * band_h
        local y1 = y0 + band_h - 1
        for y = y0, y1 do
          for x = trail_x1, trail_x2 do
            local wave = math.floor(math.sin(x * 0.45 + bi) * 1.2)
            put(st, x, y + wave, "█", col, 0)
          end
        end
      end
      -- cat body (pop-tart)
      local bx0 = math.floor(w * 0.42)
      local bx1 = math.floor(w * 0.78)
      local by1 = by0
      local by2 = by0 + band_h * 6 - 1
      fill_rect(st, bx0, by1, bx1, by2, "█", 6, 0) -- pink frosting
      -- frosting dots
      for i = 1, 12 do
        local dx = bx0 + 1 + (i * 7) % math.max(1, bx1 - bx0 - 2)
        local dy = by1 + 1 + (i * 5) % math.max(1, by2 - by1 - 2)
        put(st, dx, dy, "▀", 1, 6)
        put(st, dx + 1, dy + 1, "▄", 5, 6)
      end
      -- crust border
      for x = bx0, bx1 do
        put(st, x, by1, "▀", 8, 6)
        put(st, x, by2, "▄", 8, 6)
      end
      for y = by1, by2 do
        put(st, bx0, y, "▌", 8, 6)
        put(st, bx1, y, "▐", 8, 6)
      end
      -- head
      local hx0, hx1 = math.floor(w * 0.70), math.floor(w * 0.92)
      local hy0, hy1 = math.floor(h * 0.28), math.floor(h * 0.62)
      fill_rect(st, hx0, hy0, hx1, hy1, "█", 9, 0)
      -- ears
      for t = 0, math.floor((hx1 - hx0) * 0.35) do
        put(st, hx0 + 1 + t, hy0 - t, "█", 9, 0)
        put(st, hx1 - 1 - t, hy0 - t, "█", 9, 0)
        put(st, hx0 + 1 + t, hy0 - t + 1, "▀", 6, 9)
        put(st, hx1 - 1 - t, hy0 - t + 1, "▀", 6, 9)
      end
      -- face
      local fcx = (hx0 + hx1) / 2
      put(st, math.floor(fcx - 2), math.floor(hy0 + (hy1 - hy0) * 0.4), "█", 11, 9)
      put(st, math.floor(fcx + 2), math.floor(hy0 + (hy1 - hy0) * 0.4), "█", 11, 9)
      for x = math.floor(fcx - 2), math.floor(fcx + 2) do
        put(st, x, math.floor(hy0 + (hy1 - hy0) * 0.65), "▄", 6, 9)
      end
      -- legs
      for _, lx in ipairs({ bx0 + 2, bx0 + 5, bx1 - 5, bx1 - 2 }) do
        for y = by2, math.min(h, by2 + math.floor(h * 0.12)) do
          put(st, lx, y, "█", 9, 0)
        end
      end
      -- tail
      for i = 0, math.floor(w * 0.08) do
        put(st, bx0 - i, by0 + band_h * 2 + (i % 3) - 1, "█", 9, 0)
      end
    end,
  },
  {
    id = "dog",
    name = "狗",
    desc = "卡通小狗",
    build = function(st)
      local w, h = st.width, st.height
      fill_rect(st, 1, 1, w, h, "█", 3, 0) -- grass-ish green field soft
      for y = 1, h do
        for x = 1, w do
          put(st, x, y, "█", 7, 0)
        end
      end
      -- ground
      fill_rect(st, 1, math.floor(h * 0.72), w, h, "█", 3, 0)
      for x = 1, w do
        put(st, x, math.floor(h * 0.72), "▀", 3, 7)
      end
      local cx = w * 0.5
      local body_y = h * 0.52
      -- body
      fill_circle(st, cx, body_y, w * 0.22, h * 0.16, "█", 8, 0)
      -- head
      fill_circle(st, cx + w * 0.18, body_y - h * 0.08, w * 0.14, h * 0.14, "█", 8, 0)
      -- snout
      fill_circle(st, cx + w * 0.28, body_y - h * 0.02, w * 0.08, h * 0.07, "█", 9, 8)
      put(st, math.floor(cx + w * 0.32), math.floor(body_y - h * 0.02), "█", 11, 9)
      -- ears
      fill_circle(st, cx + w * 0.10, body_y - h * 0.18, w * 0.06, h * 0.10, "█", 8, 0)
      fill_circle(st, cx + w * 0.22, body_y - h * 0.20, w * 0.05, h * 0.09, "█", 2, 8)
      -- eyes
      put(st, math.floor(cx + w * 0.20), math.floor(body_y - h * 0.12), "█", 11, 8)
      put(st, math.floor(cx + w * 0.26), math.floor(body_y - h * 0.12), "█", 11, 8)
      put(st, math.floor(cx + w * 0.20), math.floor(body_y - h * 0.13), "▀", 1, 11)
      -- legs
      for _, ox in ipairs({ -0.12, -0.04, 0.06, 0.14 }) do
        local lx = math.floor(cx + w * ox)
        fill_rect(st, lx - 1, math.floor(body_y + h * 0.08), lx + 1, math.floor(h * 0.78), "█", 8, 0)
        put(st, lx, math.floor(h * 0.78), "▄", 11, 8)
      end
      -- tail
      for i = 0, math.floor(w * 0.1) do
        put(st, math.floor(cx - w * 0.22 - i * 0.3), math.floor(body_y - i * 0.35), "█", 8, 0)
      end
      -- spots
      fill_circle(st, cx - w * 0.05, body_y, w * 0.05, h * 0.04, "█", 9, 8)
      fill_circle(st, cx + w * 0.05, body_y + h * 0.04, w * 0.04, h * 0.03, "█", 2, 8)
      -- bone
      fill_rect(st, math.floor(w * 0.12), math.floor(h * 0.85), math.floor(w * 0.28), math.floor(h * 0.88), "█", 1, 0)
      fill_circle(st, w * 0.12, h * 0.86, 1.2, 1.2, "█", 1, 0)
      fill_circle(st, w * 0.28, h * 0.86, 1.2, 1.2, "█", 1, 0)
    end,
  },
  {
    id = "cloud",
    name = "云",
    desc = "蓝天白云 + 小鸟",
    build = function(st)
      local w, h = st.width, st.height
      -- sky gradient
      for y = 1, h do
        local t = (y - 1) / math.max(1, h - 1)
        local fg = t < 0.5 and 7 or (t < 0.75 and 5 or 6)
        for x = 1, w do
          put(st, x, y, "█", fg, 0)
        end
      end
      local function cloud_blob(cx, cy, rx, ry)
        fill_circle(st, cx, cy, rx, ry, "█", 1, 7)
        fill_circle(st, cx - rx * 0.55, cy + ry * 0.15, rx * 0.55, ry * 0.7, "█", 1, 7)
        fill_circle(st, cx + rx * 0.55, cy + ry * 0.1, rx * 0.6, ry * 0.75, "█", 1, 7)
        fill_circle(st, cx, cy + ry * 0.35, rx * 0.75, ry * 0.55, "█", 1, 7)
        -- soft shadow
        fill_circle(st, cx + rx * 0.1, cy + ry * 0.45, rx * 0.5, ry * 0.25, "▀", 9, 1)
      end
      cloud_blob(w * 0.28, h * 0.32, w * 0.14, h * 0.12)
      cloud_blob(w * 0.62, h * 0.28, w * 0.18, h * 0.14)
      cloud_blob(w * 0.78, h * 0.48, w * 0.12, h * 0.10)
      -- sun
      fill_circle(st, w * 0.12, h * 0.18, w * 0.07, h * 0.09, "█", 4, 8)
      -- birds
      local function bird(bx, by, col)
        put(st, math.floor(bx), math.floor(by), "▀", col, 7)
        put(st, math.floor(bx - 1), math.floor(by), "▖", col, 7)
        put(st, math.floor(bx + 1), math.floor(by), "▗", col, 7)
      end
      bird(w * 0.45, h * 0.55, 11)
      bird(w * 0.52, h * 0.60, 10)
      bird(w * 0.40, h * 0.62, 11)
    end,
  },
  {
    id = "building",
    name = "楼",
    desc = "彩色城市楼群夜景",
    build = function(st)
      local w, h = st.width, st.height
      -- night sky
      for y = 1, h do
        local t = (y - 1) / math.max(1, h - 1)
        local fg = t < 0.35 and 11 or (t < 0.55 and 5 or 10)
        for x = 1, w do
          put(st, x, y, "█", fg, 0)
        end
      end
      -- stars
      for i = 1, math.floor(w / 2) do
        put(st, ((i * 17) % w) + 1, ((i * 13) % math.max(1, math.floor(h * 0.4))) + 1, "▀", 4, 11)
      end
      -- moon
      fill_circle(st, w * 0.85, h * 0.15, w * 0.06, h * 0.08, "█", 1, 5)
      fill_circle(st, w * 0.87, h * 0.14, w * 0.045, h * 0.06, "█", 5, 0)
      -- buildings: list of {u0, u1, height_frac, body_color, window_a, window_b}
      local buildings = {
        { 0.02, 0.14, 0.55, 10, 4, 7 },
        { 0.13, 0.28, 0.75, 9, 4, 6 },
        { 0.26, 0.40, 0.48, 11, 3, 4 },
        { 0.38, 0.55, 0.85, 10, 4, 8 },
        { 0.52, 0.66, 0.60, 9, 7, 1 },
        { 0.64, 0.78, 0.70, 11, 2, 4 },
        { 0.76, 0.92, 0.50, 10, 6, 5 },
        { 0.88, 0.99, 0.65, 9, 4, 7 },
      }
      local ground = math.floor(h * 0.92)
      for _, b in ipairs(buildings) do
        local x0 = math.floor(b[1] * (w - 1)) + 1
        local x1 = math.floor(b[2] * (w - 1)) + 1
        local top = math.floor(ground - b[3] * h * 0.75)
        top = clamp(top, 2, ground - 2)
        fill_rect(st, x0, top, x1, ground, "█", b[4], 0)
        -- roof
        for x = x0, x1 do
          put(st, x, top, "▀", color_at(b[5] + x), b[4])
        end
        -- antenna on tall ones
        if b[3] > 0.7 then
          local mx = math.floor((x0 + x1) / 2)
          for y = top - math.floor(h * 0.08), top - 1 do
            put(st, mx, y, "█", 2, 0)
          end
          put(st, mx, top - math.floor(h * 0.08), "▀", 2, 0)
        end
        -- windows grid
        local wy = top + 2
        while wy < ground - 1 do
          for x = x0 + 1, x1 - 1, 2 do
            local lit = ((x + wy * 3) % 5) ~= 0
            if lit then
              local wc = ((x + wy) % 2 == 0) and b[5] or b[6]
              put(st, x, wy, "█", wc, b[4])
              if wy + 1 < ground then
                put(st, x, wy + 1, "▄", wc, b[4])
              end
            else
              put(st, x, wy, "█", 11, b[4])
            end
          end
          wy = wy + 3
        end
      end
      -- street
      fill_rect(st, 1, ground, w, h, "█", 11, 0)
      for x = 1, w, 3 do
        put(st, x, ground + 1, "▀", 4, 11)
      end
      -- car lights
      for i = 1, 5 do
        local cx = math.floor(w * (0.1 + i * 0.15))
        put(st, cx, ground, "█", 4, 11)
        put(st, cx + 1, ground, "█", 2, 11)
      end
    end,
  },
  {
    id = "rainbow",
    name = "彩虹",
    desc = "拱形彩虹 + 草地",
    build = function(st)
      local w, h = st.width, st.height
      for y = 1, h do
        local t = (y - 1) / math.max(1, h - 1)
        local fg = t < 0.65 and 7 or 3
        for x = 1, w do
          put(st, x, y, "█", fg, 0)
        end
      end
      local cx, cy = w * 0.5, h * 0.85
      local cols = { 2, 8, 4, 3, 7, 5, 6 }
      for bi, col in ipairs(cols) do
        local r = h * (0.55 + bi * 0.045)
        local ry = r * 0.55
        local steps = math.max(40, math.floor(r * 4))
        for i = 0, steps do
          local t = math.pi + (i / steps) * math.pi -- upper semicircle
          local x = math.floor(cx + r * 0.9 * math.cos(t) + 0.5)
          local y = math.floor(cy + ry * math.sin(t) + 0.5)
          put(st, x, y, "█", col, 0)
          put(st, x, y + 1, "▄", col, 7)
        end
      end
      -- ground flowers
      for x = 1, w, 2 do
        put(st, x, h, "▀", 3, 0)
        if x % 4 == 1 then
          put(st, x, h - 1, "▀", color_at(x), 3)
        end
      end
    end,
  },
}

local function load_demo(st, demo)
  if not demo or not demo.build then
    return
  end
  push_undo(st)
  st.grid = empty_grid(st.width, st.height)
  demo.build(st)
  st.dirty = true
  st.anchor = nil
  st.drawing = false
  mark_all_dirty(st)
end

---opts.full = true 强制全量；默认增量
local function refresh(buf, opts)
  opts = opts or {}
  local st = state_by_buf[buf]
  if not st then
    return
  end
  if opts.full or opts.status then
    if opts.status then
      st.status_dirty = true
    end
    if opts.full then
      st.need_full = true
    end
  end
  if opts.full or st.need_full or not st.rendered then
    paint_buffer_full(buf)
  else
    paint_buffer_dirty(buf)
  end
end

---Close floating picker if open
local function close_float(st)
  if st.float_win and vim.api.nvim_win_is_valid(st.float_win) then
    pcall(vim.api.nvim_win_close, st.float_win, true)
  end
  if st.float_buf and vim.api.nvim_buf_is_valid(st.float_buf) then
    pcall(vim.api.nvim_buf_delete, st.float_buf, { force = true })
  end
  st.float_win = nil
  st.float_buf = nil
  st.float_on_select = nil
  st.float_n = nil
end

---Find byte range [start, end) of needle inside line (0-based start).
local function find_bytes(line, needle)
  local idx = line:find(needle, 1, true)
  if not idx then
    return nil, nil
  end
  return idx - 1, idx - 1 + #needle
end

---Centered float menu.
---opts.lines: display strings (no leading space)
---opts.swatches: { { row=0-based item index, needle="████", hl="Group" }, ... }
---opts.on_select(idx 1-based)
local function open_float_menu(st, canvas_buf, opts)
  close_float(st)
  local title = opts.title or "选择"
  local items = opts.lines or {}
  local swatches = opts.swatches or {}
  local n = #items
  if n == 0 then
    return
  end

  local width = opts.width or 36
  for _, ln in ipairs(items) do
    width = math.max(width, vim.fn.strwidth(ln) + 4)
  end
  width = math.min(width, math.max(24, vim.o.columns - 4))
  local height = math.min(n + 2, math.max(6, vim.o.lines - 4))

  local fbuf = vim.api.nvim_create_buf(false, true)
  local body = { " " .. title, string.rep("─", width) }
  for _, ln in ipairs(items) do
    table.insert(body, " " .. ln)
  end

  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, body)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden = "wipe"
  vim.bo[fbuf].filetype = "drawbuf_menu"

  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    zindex = 200,
  })

  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"

  local float_ns = vim.api.nvim_create_namespace("drawbuf_float")
  -- header
  vim.api.nvim_buf_set_extmark(fbuf, float_ns, 0, 0, {
    end_row = 0,
    end_col = #body[1],
    hl_group = "Title",
    hl_mode = "combine",
  })

  -- color swatches on item rows (buffer row = item_row + 2)
  for _, s in ipairs(swatches) do
    local brow = (s.row or 0) + 2
    local line = body[brow + 1] or ""
    local b0, b1 = find_bytes(line, s.needle or "████")
    if b0 and b1 and s.hl then
      pcall(vim.api.nvim_buf_set_extmark, fbuf, float_ns, brow, b0, {
        end_row = brow,
        end_col = b1,
        hl_group = s.hl,
        hl_mode = "replace",
        priority = 400,
      })
    end
  end

  st.float_win = win
  st.float_buf = fbuf
  st.float_n = n
  st.float_on_select = opts.on_select

  local closing = false

  local function cur_index()
    if not vim.api.nvim_win_is_valid(win) then
      return 1
    end
    local l = vim.api.nvim_win_get_cursor(win)[1]
    return clamp(l - 2, 1, n)
  end

  local function move_cursor(delta)
    local idx = clamp(cur_index() + delta, 1, n)
    vim.api.nvim_win_set_cursor(win, { idx + 2, 0 })
  end

  local function focus_canvas()
    if vim.api.nvim_buf_is_valid(canvas_buf) then
      local w = vim.fn.bufwinid(canvas_buf)
      if w ~= -1 then
        pcall(vim.api.nvim_set_current_win, w)
      end
    end
  end

  local function confirm()
    if closing then
      return
    end
    closing = true
    local idx = cur_index()
    local cb = st.float_on_select
    close_float(st)
    if cb then
      cb(idx)
    end
    if vim.api.nvim_buf_is_valid(canvas_buf) then
      st.status_dirty = true
      refresh(canvas_buf)
    end
    focus_canvas()
  end

  local function cancel()
    if closing then
      return
    end
    closing = true
    close_float(st)
    focus_canvas()
  end

  -- 焦点离开弹窗（点击外部常见路径）→ 关闭
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = fbuf,
    callback = function()
      vim.schedule(function()
        if closing then
          return
        end
        if st.float_win and vim.api.nvim_win_is_valid(st.float_win) then
          if vim.api.nvim_get_current_win() ~= st.float_win then
            cancel()
          end
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = vim.api.nvim_create_augroup("DrawbufFloatOut_" .. fbuf, { clear = true }),
    callback = function()
      if closing then
        return
      end
      if not (st.float_win and vim.api.nvim_win_is_valid(st.float_win)) then
        return
      end
      if vim.api.nvim_get_current_win() ~= st.float_win then
        cancel()
      end
    end,
  })

  local function map_f(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = fbuf, silent = true, nowait = true })
  end

  map_f("j", function()
    move_cursor(1)
  end)
  map_f("k", function()
    move_cursor(-1)
  end)
  map_f("<Down>", function()
    move_cursor(1)
  end)
  map_f("<Up>", function()
    move_cursor(-1)
  end)
  map_f("<CR>", confirm)
  map_f("<Space>", confirm)
  map_f("q", cancel)
  map_f("<Esc>", cancel)
  map_f("<LeftMouse>", function()
    local m = vim.fn.getmousepos()
    if m.winid == win then
      if m.line >= 3 then
        local idx = clamp(m.line - 2, 1, n)
        vim.api.nvim_win_set_cursor(win, { idx + 2, 0 })
        confirm()
      end
    else
      cancel()
    end
  end)

  for i = 1, math.min(9, n) do
    map_f(tostring(i % 10), function()
      vim.api.nvim_win_set_cursor(win, { i + 2, 0 })
      confirm()
    end)
  end

  local start = opts.start_index or 1
  start = clamp(start, 1, n)
  vim.api.nvim_win_set_cursor(win, { start + 2, 0 })
end

local function menu_tool(st, buf)
  local lines = {}
  local start = 1
  for i, t in ipairs(TOOL_ORDER) do
    local mark = (st.tool == t) and "●" or " "
    table.insert(lines, string.format("%s %s", mark, TOOL_LABELS[t]))
    if st.tool == t then
      start = i
    end
  end
  open_float_menu(st, buf, {
    title = "选择工具",
    lines = lines,
    width = 22,
    start_index = start,
    on_select = function(idx)
      if TOOL_ORDER[idx] then
        set_tool(st, TOOL_ORDER[idx])
      end
    end,
  })
end

local function menu_brush(st, buf)
  local lines = {}
  local swatches = {}
  local fg = st.fg > 0 and st.fg or 1
  local bg = st.bg
  local start = 1
  for i, ch in ipairs(config.brush_chars) do
    local mark = (st.brush == ch) and "●" or " "
    local sw = string.rep(ch, 4)
    local label = BLOCK_LABELS[ch] or ""
    table.insert(lines, string.format("%s %s  %s", mark, sw, label))
    table.insert(swatches, {
      row = i - 1,
      needle = sw,
      hl = cell_hl(fg, bg),
    })
    if st.brush == ch then
      start = i
    end
  end
  open_float_menu(st, buf, {
    title = "选择字符（100% / 1/2 / 1/4）",
    lines = lines,
    width = 30,
    swatches = swatches,
    start_index = start,
    on_select = function(idx)
      if config.brush_chars[idx] then
        st.brush = config.brush_chars[idx]
      end
    end,
  })
end

local function menu_demo(st, buf)
  local lines = {}
  local swatches = {}
  for i, d in ipairs(DEMO_PATTERNS) do
    -- mini rainbow strip as visual cue
    local strip = "████"
    table.insert(lines, string.format("%d  %s  %s  %s", i, strip, d.name, d.desc or ""))
    local hex = config.colors[color_at(i * 2)] or "ffffff"
    local hl = "DrawbufDemo" .. i
    if not hl_cache["demo_" .. i] then
      vim.api.nvim_set_hl(0, hl, { fg = "#" .. hex, bg = "#" .. hex })
      hl_cache["demo_" .. i] = true
    end
    table.insert(swatches, { row = i - 1, needle = strip, hl = hl })
  end
  open_float_menu(st, buf, {
    title = "加载演示图案（彩色）",
    lines = lines,
    width = 48,
    swatches = swatches,
    on_select = function(idx)
      local d = DEMO_PATTERNS[idx]
      if d then
        load_demo(st, d)
        vim.notify("drawbuf: 已加载「" .. d.name .. "」", vim.log.levels.INFO)
      end
    end,
  })
end

local function menu_color(st, buf, field, title)
  local lines = {}
  local swatches = {}
  local start = 1

  -- item 1: none (color 0)
  do
    local mark = (st[field] == 0) and "●" or " "
    local sw = "████"
    table.insert(lines, string.format("%s %s  0  无（画布底色）", mark, sw))
    -- empty-looking: dark swatch
    local hl = "DrawbufPickNone"
    if not hl_cache.pick_none then
      vim.api.nvim_set_hl(0, hl, {
        fg = "#" .. config.canvas_bg,
        bg = "#" .. config.canvas_bg,
      })
      hl_cache.pick_none = true
    end
    table.insert(swatches, { row = 0, needle = sw, hl = hl })
    if st[field] == 0 then
      start = 1
    end
  end

  for i, hex in ipairs(config.colors) do
    local mark = (st[field] == i) and "●" or " "
    local sw = "████"
    table.insert(lines, string.format("%s %s  %d  #%s", mark, sw, i, hex))
    local hl_name = "DrawbufPick" .. i
    if not hl_cache["pick_" .. i] then
      -- fg=bg=color → solid visible block
      vim.api.nvim_set_hl(0, hl_name, { fg = "#" .. hex, bg = "#" .. hex })
      hl_cache["pick_" .. i] = true
    end
    table.insert(swatches, { row = i, needle = sw, hl = hl_name })
    if st[field] == i then
      start = i + 1
    end
  end

  open_float_menu(st, buf, {
    title = title,
    lines = lines,
    width = 34,
    swatches = swatches,
    start_index = start,
    on_select = function(idx)
      -- idx 1 → color 0, idx 2 → color 1, ...
      st[field] = idx - 1
    end,
  })
end

local function show_help()
  vim.notify(
    table.concat({
      "drawbuf 操作说明:",
      "  铅笔：鼠标拖拽绘制；右键擦除；p 连续绘制",
      "  直线/矩形/椭圆：按下起点→拖动预览→松开确认；Esc 取消",
      "  底部状态栏：工具 / 字符 / 前景 / 背景 / 演示",
      "  色块：100% █ + 1/2 + 1/4；选色 float 真彩色",
      "  hjkl 移动  u 撤销  s 保存  q 退出",
    }, "\n"),
    vim.log.levels.INFO
  )
end

local function hit_status(st, display_col)
  if not st.status_hits then
    return nil
  end
  for _, h in ipairs(st.status_hits) do
    if display_col >= h.c0 and display_col <= h.c1 then
      return h.id
    end
  end
  return nil
end

local function on_status_click(st, buf, display_col)
  local id = hit_status(st, display_col)
  if not id then
    return false
  end
  if id == "tool" then
    menu_tool(st, buf)
  elseif id == "brush" then
    menu_brush(st, buf)
  elseif id == "fg" then
    menu_color(st, buf, "fg", "选择前景色")
  elseif id == "bg" then
    menu_color(st, buf, "bg", "选择背景色")
  elseif id == "demo" then
    menu_demo(st, buf)
  elseif id == "save" then
    save(st)
    refresh(buf)
  elseif id == "quit" then
    if st.dirty then
      local ans = vim.fn.confirm("画布未保存，关闭？", "&是\n&否", 2)
      if ans ~= 1 then
        return true
      end
    end
    pcall(vim.cmd, "bdelete!")
  elseif id == "undo" then
    undo(st)
    refresh(buf)
  elseif id == "help" then
    show_help()
  end
  return true
end

local function bind(buf)
  local function with_st(fn)
    return function()
      local st = state_by_buf[buf]
      if not st then
        return
      end
      fn(st)
      if vim.api.nvim_buf_is_valid(buf) then
        refresh(buf)
      end
    end
  end

  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, with_st(fn), {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "drawbuf: " .. desc,
    })
  end

  map("h", function(st)
    move(st, -1, 0)
  end, "left")
  map("l", function(st)
    move(st, 1, 0)
  end, "right")
  map("j", function(st)
    move(st, 0, 1)
  end, "down")
  map("k", function(st)
    move(st, 0, -1)
  end, "up")
  map("<Left>", function(st)
    move(st, -1, 0)
  end, "left")
  map("<Right>", function(st)
    move(st, 1, 0)
  end, "right")
  map("<Down>", function(st)
    move(st, 0, 1)
  end, "down")
  map("<Up>", function(st)
    move(st, 0, -1)
  end, "up")

  map("<Space>", do_paint_here, "paint")
  map("<CR>", do_paint_here, "paint")
  map("p", function(st)
    st.drawing = not st.drawing
    if st.drawing then
      push_undo(st)
      paint_cell(st, st.cx, st.cy)
      vim.notify("drawbuf: 连续绘制 开", vim.log.levels.INFO)
    else
      vim.notify("drawbuf: 连续绘制 关", vim.log.levels.INFO)
    end
  end, "toggle draw")

  map("x", function(st)
    push_undo(st)
    set_cell(st, st.cx, st.cy, " ", 0, 0)
  end, "erase")
  map("d", function(st)
    set_tool(st, TOOL_ERASER)
  end, "eraser")
  map("a", function(st)
    set_tool(st, TOOL_PENCIL)
  end, "pencil")
  map("L", function(st)
    set_tool(st, TOOL_LINE)
  end, "line")
  map("R", function(st)
    set_tool(st, TOOL_RECT)
  end, "rect")
  map("O", function(st)
    set_tool(st, TOOL_ELLIPSE)
  end, "ellipse")
  map("f", function(st)
    set_tool(st, TOOL_FILL)
  end, "fill")
  map("<Esc>", function(st)
    if st.shape_drag then
      cancel_shape_drag(st)
      vim.notify("drawbuf: 已取消图形绘制", vim.log.levels.INFO)
    end
  end, "cancel shape")

  map("]", function(st)
    local list = config.brush_chars
    local idx = 1
    for i, ch in ipairs(list) do
      if ch == st.brush then
        idx = i
        break
      end
    end
    st.brush = list[(idx % #list) + 1]
    st.status_dirty = true
  end, "next brush")
  map("[", function(st)
    local list = config.brush_chars
    local idx = 1
    for i, ch in ipairs(list) do
      if ch == st.brush then
        idx = i
        break
      end
    end
    st.brush = list[((idx - 2) % #list) + 1]
    st.status_dirty = true
  end, "prev brush")
  map(".", function(st)
    st.fg = (st.fg % #config.colors) + 1
    st.status_dirty = true
  end, "next fg")
  map(",", function(st)
    st.fg = ((st.fg - 2) % #config.colors) + 1
    st.status_dirty = true
  end, "prev fg")
  map(">", function(st)
    st.bg = (st.bg % #config.colors) + 1
    st.status_dirty = true
  end, "next bg")
  map("<", function(st)
    st.bg = ((st.bg - 2) % #config.colors) + 1
    st.status_dirty = true
  end, "prev bg")

  map("u", undo, "undo")
  map("<C-r>", redo, "redo")
  map("s", function(st)
    save(st)
  end, "save")
  map("S", function(st)
    st.path = nil
    save(st)
  end, "save as")
  map("e", function(st)
    export_plain(st)
  end, "export")
  map("C", clear_canvas, "clear")
  map("q", function()
    local st = state_by_buf[buf]
    if st and st.dirty then
      local ans = vim.fn.confirm("画布未保存，关闭？", "&是\n&否", 2)
      if ans ~= 1 then
        return
      end
    end
    pcall(vim.cmd, "bdelete!")
  end, "quit")
  map("?", function()
    show_help()
  end, "help")

  ---Mouse → canvas or status (display column)
  local function mouse_pos()
    local st = state_by_buf[buf]
    if not st then
      return nil
    end
    local mouse = vim.fn.getmousepos()
    local win = vim.fn.bufwinid(buf)
    if win == -1 or mouse.winid ~= win then
      return nil
    end
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
    return {
      row = mouse.line,
      vcol = vcol,
      st = st,
    }
  end

  ---Map display column on a canvas row → cell x by walking glyph widths
  local function vcol_to_cell_x(st, row, vcol)
    if vcol < 1 then
      return 1
    end
    local acc = 0
    for x = 1, st.width do
      local g = cell_show_char(st, x, row)
      local w = math.max(1, vim.fn.strwidth(g))
      if vcol <= acc + w then
        return x
      end
      acc = acc + w
    end
    return st.width
  end

  local function stroke_to(st, x1, y1, erasing)
    local x0, y0 = st.mouse_last_x, st.mouse_last_y
    if not x0 then
      x0, y0 = x1, y1
    end
    local dx = math.abs(x1 - x0)
    local dy = -math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    local x, y = x0, y0
    while true do
      if erasing then
        set_cell(st, x, y, " ", 0, 0)
      else
        paint_cell(st, x, y)
      end
      if x == x1 and y == y1 then
        break
      end
      local e2 = 2 * err
      if e2 >= dy then
        err = err + dy
        x = x + sx
      end
      if e2 <= dx then
        err = err + dx
        y = y + sy
      end
    end
    st.mouse_last_x, st.mouse_last_y = x1, y1
    st.cx, st.cy = x1, y1
  end

  local function end_mouse_stroke()
    local st = state_by_buf[buf]
    if not st then
      return
    end
    -- shape: mouse up commits
    if st.shape_drag and st.shape_drag.from_mouse then
      commit_shape_drag(st)
      st.mouse_dragging = false
      st.mouse_erasing = false
      st.mouse_last_x, st.mouse_last_y = nil, nil
      refresh(buf)
      return
    end
    st.mouse_dragging = false
    st.mouse_erasing = false
    st.mouse_last_x, st.mouse_last_y = nil, nil
  end

  local mouse_modes = { "n", "v", "x", "s" }

  local function on_left_down()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    if vim.fn.mode():match("[vVsS\x16]") then
      vim.cmd("normal! \27")
    end
    local mp = mouse_pos()
    if not mp then
      return ""
    end

    -- status bar click
    if config.statusline and mp.row == status_row_index(st) + 1 then
      st.mouse_dragging = false
      if st.shape_drag and st.shape_drag.from_mouse then
        cancel_shape_drag(st)
      end
      on_status_click(st, buf, mp.vcol)
      return ""
    end

    if mp.row < 1 or mp.row > st.height then
      return ""
    end

    local x = vcol_to_cell_x(st, mp.row, mp.vcol)
    local y = mp.row
    st.cx, st.cy = x, y

    if st.tool == TOOL_FILL then
      st.mouse_dragging = false
      push_undo(st)
      flood_fill(st, x, y)
      refresh(buf)
      return ""
    end

    -- 直线 / 矩形 / 椭圆：按下为起点，拖动预览，松开确认
    if is_shape_tool(st.tool) then
      start_shape_drag(st, x, y, st.tool)
      st.shape_drag.from_mouse = true
      st.mouse_dragging = true -- track drag
      refresh(buf)
      return ""
    end

    push_undo(st)
    st.mouse_dragging = true
    st.mouse_erasing = (st.tool == TOOL_ERASER)
    st.mouse_last_x, st.mouse_last_y = x, y
    if st.mouse_erasing then
      set_cell(st, x, y, " ", 0, 0)
    else
      paint_cell(st, x, y)
    end
    refresh(buf)
    return ""
  end

  local function on_left_drag()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    if vim.fn.mode():match("[vVsS\x16]") then
      vim.cmd("normal! \27")
    end
    local mp = mouse_pos()
    if not mp or mp.row < 1 or mp.row > st.height then
      return ""
    end
    local x = vcol_to_cell_x(st, mp.row, mp.vcol)
    local y = mp.row
    st.cx, st.cy = x, y

    -- shape preview while dragging
    if st.shape_drag and st.shape_drag.from_mouse then
      if x == st.shape_drag.x1 and y == st.shape_drag.y1 then
        return ""
      end
      st.shape_drag.x1 = x
      st.shape_drag.y1 = y
      refresh(buf)
      return ""
    end

    if not st.mouse_dragging then
      if is_shape_tool(st.tool) then
        start_shape_drag(st, x, y, st.tool)
        st.shape_drag.from_mouse = true
        st.mouse_dragging = true
        refresh(buf)
        return ""
      end
      push_undo(st)
      st.mouse_dragging = true
      st.mouse_erasing = (st.tool == TOOL_ERASER)
      st.mouse_last_x, st.mouse_last_y = x, y
      paint_cell(st, x, y)
      refresh(buf)
      return ""
    end
    if x == st.mouse_last_x and y == st.mouse_last_y then
      return ""
    end
    stroke_to(st, x, y, st.mouse_erasing)
    refresh(buf)
    return ""
  end

  local function on_right_down()
    local st = state_by_buf[buf]
    if not st then
      return ""
    end
    if vim.fn.mode():match("[vVsS\x16]") then
      vim.cmd("normal! \27")
    end
    local mp = mouse_pos()
    if not mp or mp.row < 1 or mp.row > st.height then
      return ""
    end
    local x = vcol_to_cell_x(st, mp.row, mp.vcol)
    local y = mp.row
    push_undo(st)
    st.mouse_dragging = true
    st.mouse_erasing = true
    st.mouse_last_x, st.mouse_last_y = x, y
    set_cell(st, x, y, " ", 0, 0)
    st.cx, st.cy = x, y
    refresh(buf)
    return ""
  end

  local function on_right_drag()
    local st = state_by_buf[buf]
    if not st or not st.mouse_dragging then
      return ""
    end
    local mp = mouse_pos()
    if not mp or mp.row < 1 or mp.row > st.height then
      return ""
    end
    local x = vcol_to_cell_x(st, mp.row, mp.vcol)
    local y = mp.row
    if x == st.mouse_last_x and y == st.mouse_last_y then
      return ""
    end
    stroke_to(st, x, y, true)
    refresh(buf)
    return ""
  end

  local function map_mouse(lhs, fn, desc)
    vim.keymap.set(mouse_modes, lhs, fn, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "drawbuf: " .. desc,
    })
  end

  map_mouse("<LeftMouse>", on_left_down, "mouse down")
  map_mouse("<LeftDrag>", on_left_drag, "mouse drag")
  map_mouse("<LeftRelease>", function()
    end_mouse_stroke()
    return ""
  end, "mouse up")
  map_mouse("<RightMouse>", on_right_down, "erase down")
  map_mouse("<RightDrag>", on_right_drag, "erase drag")
  map_mouse("<RightRelease>", function()
    end_mouse_stroke()
    return ""
  end, "erase up")
end

local function apply_buf_opts(buf, win)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "drawbuf"
  vim.bo[buf].modifiable = false
  vim.bo[buf].textwidth = 0
  -- 必须用 win 选项关掉行号/符号列，否则 textoff 仍占宽，画布会显得「多出几格」
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      vim.wo[win].wrap = false
      vim.wo[win].list = false
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].cursorline = false
      vim.wo[win].foldcolumn = "0"
      vim.wo[win].statuscolumn = ""
      vim.wo[win].colorcolumn = ""
    end)
  end
  pcall(function()
    vim.opt_local.virtualedit = "all"
  end)
  if vim.o.mouse == "" then
    vim.o.mouse = "a"
  end
end

---可用文本宽度（窗口宽 − 行号/sign/fold 等 gutter）
local function win_text_width(win)
  local full = vim.api.nvim_win_get_width(win)
  local info = vim.fn.getwininfo(win)[1]
  local textoff = (info and info.textoff) or 0
  return math.max(1, full - textoff)
end

---默认画布：可用文本区大小，四周留 1 格白边；底栏另占 blank+status
local function default_canvas_size(win)
  local tw = win_text_width(win)
  local wh = vim.api.nvim_win_get_height(win)
  local margin = 1
  local width = math.max(8, tw - margin * 2)
  local height = math.max(4, wh - margin - 2)
  return width, height
end

---@param opts? { width?: number, height?: number, path?: string }
function M.open(opts)
  M.ensure_setup()
  opts = opts or {}
  ensure_hl()
  hl_cache = {}

  local win = vim.api.nvim_get_current_win()
  local path = opts.path
  local width, height, grid

  -- 先挂上 buffer 并关掉行号，再量尺寸（避免把行号 gutter 算进画布宽）
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, path and ("drawbuf://" .. path) or "drawbuf://canvas")
  vim.api.nvim_win_set_buf(win, buf)
  apply_buf_opts(buf, win)

  if path and vim.fn.filereadable(path) == 1 then
    local lines = vim.fn.readfile(path)
    local parsed = parse_draw_file(lines)
    if parsed then
      width = parsed.width
      height = parsed.height
      grid = parsed.grid
    end
  end

  if not width or not height then
    if opts.width and opts.height then
      width, height = opts.width, opts.height
    else
      width, height = default_canvas_size(win)
    end
  end
  if not grid then
    grid = empty_grid(width, height)
  end

  state_by_buf[buf] = {
    width = width,
    height = height,
    grid = grid,
    cx = math.floor(width / 2),
    cy = math.floor(height / 2),
    brush = config.brush_chars[1],
    fg = default_ink_fg(), -- 黑线
    bg = 0,
    tool = TOOL_PENCIL,
    drawing = false,
    anchor = nil,
    undo = {},
    redo = {},
    dirty = false,
    path = path,
    status_hits = {},
    dirty_rows = {},
    preview_map = {},
    rendered = false,
    need_full = true,
    status_dirty = true,
  }

  bind(buf)
  refresh(buf, { full = true })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      state_by_buf[buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("DrawbufHl_" .. buf, { clear = true }),
    callback = function()
      hl_cache = {}
      ensure_hl()
      if vim.api.nvim_buf_is_valid(buf) then
        refresh(buf)
      end
    end,
  })

  return buf
end

function M.open_file(path)
  return M.open({ path = vim.fn.fnamemodify(path, ":p") })
end

---Apply config. Optional: defaults work without calling this.
---Call again anytime to change options (e.g. `setup({ width = 100 })`).
---@param user? DrawbufConfig
function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  -- always force block charset unless user overrides brush_chars
  if not user or not user.brush_chars then
    config.brush_chars = vim.deepcopy(BLOCK_CHARS)
  end
  vim.g.drawbuf_setup_done = true
  hl_cache = {}

  vim.api.nvim_create_user_command("Draw", function(opts)
    if opts.args and opts.args ~= "" then
      local a = opts.args
      if vim.fn.filereadable(a) == 1 then
        M.open_file(a)
      else
        local w, h = a:match("^(%d+)x(%d+)$")
        if w then
          M.open({ width = tonumber(w), height = tonumber(h) })
        else
          M.open_file(a)
        end
      end
    else
      -- 默认：当前窗口大小，四周留白边
      M.open({})
    end
  end, {
    nargs = "?",
    complete = "file",
    desc = "打开绘图画布（默认适应窗口并留白边）",
  })
end

---Ensure defaults are applied once (no-op if setup already ran).
function M.ensure_setup()
  if not vim.g.drawbuf_setup_done then
    M.setup()
  end
end

function M.config()
  return config
end

return M
