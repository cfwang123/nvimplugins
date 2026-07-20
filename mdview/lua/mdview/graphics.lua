---@mod mdview.graphics
--- 预览内多图高清叠层：█ 底层 + 宿主 iTerm2/Kitty 像素图
--- 对齐 imgbuf 成功路径：检测终端 → encode PNG → 按可见行定位叠层 → 滚动重绘
local M = {}

--- Neovim 0.9 只有 vim.loop；0.10+ 为 vim.uv
local uv = vim.uv or vim.loop

local CHUNK = 4096
local next_id = 760001

---@type table<integer, table> buf -> overlay state
local overlays = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

-- PNG 等二进制常含 NUL；经 vim.fn.system 的 input 会变成 Blob 并触发 E976。
-- Neovim 0.10+ 用 vim.base64；0.9 走纯 Lua。
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---@param s string 可为含 NUL 的二进制
---@return string
local function b64encode_lua(s)
  local n = #s
  if n == 0 then
    return ""
  end
  local out = {}
  local oi = 1
  local i = 1
  while i <= n do
    local b1 = s:byte(i)
    local b2 = (i + 1 <= n) and s:byte(i + 1) or nil
    local b3 = (i + 2 <= n) and s:byte(i + 2) or nil
    local n2, n3 = b2 ~= nil, b3 ~= nil
    b2, b3 = b2 or 0, b3 or 0
    local v = b1 * 65536 + b2 * 256 + b3
    local c1 = math.floor(v / 262144) % 64
    local c2 = math.floor(v / 4096) % 64
    local c3 = math.floor(v / 64) % 64
    local c4 = v % 64
    out[oi] = B64_ALPHABET:sub(c1 + 1, c1 + 1)
    out[oi + 1] = B64_ALPHABET:sub(c2 + 1, c2 + 1)
    out[oi + 2] = n2 and B64_ALPHABET:sub(c3 + 1, c3 + 1) or "="
    out[oi + 3] = n3 and B64_ALPHABET:sub(c4 + 1, c4 + 1) or "="
    oi = oi + 4
    i = i + 3
  end
  return table.concat(out)
end

---@param s string 可为含 NUL 的二进制
---@return string
local function b64encode(s)
  if type(s) ~= "string" or s == "" then
    return ""
  end
  if vim.base64 and vim.base64.encode then
    local ok, res = pcall(vim.base64.encode, s)
    if ok and type(res) == "string" and res ~= "" then
      return res
    end
  end
  return b64encode_lua(s)
end

local function tty_write(data)
  if not data or data == "" then
    return false
  end
  if vim.api.nvim_ui_send and pcall(vim.api.nvim_ui_send, data) then
    return true
  end
  if pcall(function()
    vim.fn.chansend(2, data)
  end) then
    return true
  end
  if vim.fn.has("win32") ~= 1 then
    local ok = pcall(function()
      local f = assert(io.open("/dev/tty", "w"))
      f:write(data)
      f:flush()
      f:close()
    end)
    if ok then
      return true
    end
  end
  return pcall(function()
    io.stdout:write(data)
    io.stdout:flush()
  end)
end

local function is_wezterm()
  local term = (vim.env.TERM or ""):lower()
  local prog = (vim.env.TERM_PROGRAM or ""):lower()
  return (vim.env.WEZTERM_EXECUTABLE and vim.env.WEZTERM_EXECUTABLE ~= "")
    or (vim.env.WEZTERM_PANE and vim.env.WEZTERM_PANE ~= "")
    or prog:find("wezterm", 1, true) ~= nil
    or term:find("wezterm", 1, true) ~= nil
end

local function in_mux()
  return (vim.env.TMUX and vim.env.TMUX ~= "")
    or (vim.env.ZELLIJ and vim.env.ZELLIJ ~= "")
end

local function terminal_supports_hd()
  local term = (vim.env.TERM or ""):lower()
  local prog = (vim.env.TERM_PROGRAM or ""):lower()
  if vim.env.KITTY_WINDOW_ID and vim.env.KITTY_WINDOW_ID ~= "" then
    return true
  end
  if is_wezterm() then
    return true
  end
  if (vim.env.GHOSTTY_RESOURCES_DIR and vim.env.GHOSTTY_RESOURCES_DIR ~= "")
    or prog:find("ghostty", 1, true)
  then
    return true
  end
  if term == "xterm-kitty" or term:find("kitty", 1, true) then
    return true
  end
  return false
end

---@param cfg table|nil image 配置
---@param which "preview"|"float"|nil 检测预览还是 float（默认 float）
function M.detect(cfg, which)
  cfg = cfg or {}
  which = which or "float"
  -- 预览内高清默认关；float 默认开
  local mode
  if which == "preview" then
    mode = cfg.hd
    if mode == nil then
      mode = "never"
    end
  else
    mode = cfg.float_hd
    if mode == nil then
      mode = cfg.hd -- 旧配置
    end
    if mode == nil or mode == "never" then
      -- 若只写了 graphics / 未配 float_hd，float 默认 always
      if cfg.float_hd == nil and (cfg.graphics == "always" or cfg.graphics == nil) then
        mode = "always"
      end
    end
    if mode == nil then
      mode = "always"
    end
  end
  if mode == false or mode == "never" or mode == "none" or mode == "off" then
    return false
  end
  if in_mux() and cfg.hd_tmux ~= true and cfg.graphics_tmux ~= true then
    return false
  end
  if vim.env.SSH_CONNECTION and vim.env.SSH_CONNECTION ~= "" then
    if cfg.hd_ssh ~= true and cfg.graphics_ssh ~= true then
      return false
    end
  end
  return terminal_supports_hd()
end

local function delete_id(id)
  if id then
    pcall(tty_write, string.format("\27_Ga=d,d=i,i=%d,q=2\27\\", id))
  end
end

local function stop_overlay(ov)
  if not ov then
    return
  end
  if ov.timer then
    pcall(function()
      ov.timer:stop()
      ov.timer:close()
    end)
    ov.timer = nil
  end
  if ov.aug then
    pcall(vim.api.nvim_del_augroup_by_id, ov.aug)
    ov.aug = nil
  end
  for _, p in ipairs(ov.places or {}) do
    delete_id(p.id)
  end
  pcall(tty_write, "\27[0m")
end

function M.clear_buf(buf)
  if not buf then
    return
  end
  local ov = overlays[buf]
  if ov then
    stop_overlay(ov)
    overlays[buf] = nil
  end
end

---是否有高清叠层（含 float / 预览临时）
---@param buf integer|nil
---@return boolean
function M.is_active(buf)
  return buf ~= nil and overlays[buf] ~= nil
end

function M.clear_all()
  for b, _ in pairs(overlays) do
    M.clear_buf(b)
  end
end

---编码 PNG 为 b64
---@param path string
---@param cols integer 输出列数
---@param rows integer 输出行数（屏幕上占用的格）
---@param scale string
---@param python string|nil
---@param layout_rows integer|nil 完整布局行数
---@param skip_rows integer|nil 从完整布局顶部跳过的行数（取下半截时用）
---@return string|nil
local function encode_png_b64(path, cols, rows, scale, python, layout_rows, skip_rows)
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local py = python or "python"
  if vim.fn.executable(py) ~= 1 then
    if vim.fn.executable("python3") == 1 then
      py = "python3"
    else
      return nil
    end
  end
  local script = plugin_root() .. "/scripts/gfx_prepare.py"
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) == 0 then
    return nil
  end
  cols = math.max(1, cols)
  rows = math.max(1, rows)
  skip_rows = math.max(0, skip_rows or 0)
  layout_rows = math.max(rows + skip_rows, layout_rows or (rows + skip_rows))
  local args = {
    py,
    "-X",
    "utf8",
    script,
    path,
    tostring(cols),
    tostring(rows),
    scale == "fit" and "fit" or "fill",
  }
  if layout_rows > rows or skip_rows > 0 then
    args[#args + 1] = tostring(layout_rows)
    args[#args + 1] = tostring(skip_rows)
  end
  local out = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local png = vim.trim(out or "")
  if png == "" or vim.fn.filereadable(png) == 0 then
    return nil
  end
  local f = io.open(png, "rb")
  if not f then
    return nil
  end
  local bin = f:read("*a")
  f:close()
  pcall(os.remove, png)
  if not bin or #bin < 32 then
    return nil
  end
  local b64 = b64encode(bin)
  if b64 == "" then
    return nil
  end
  return b64
end

---place 在可见窗口内的裁切参数：skip=滚出顶部行数，draw=可见行数
---@param place table
---@param topline integer
---@param botline integer
---@return integer skip_rows, integer draw_rows
local function place_visible_slice(place, topline, botline)
  local full = math.max(1, place.rows or (place.line_end - place.line + 1))
  local a = place.line or 1
  local b = place.line_end or (a + full - 1)
  local vis_a = math.max(a, topline)
  local vis_b = math.min(b, botline)
  if vis_b < vis_a then
    return 0, 0
  end
  local skip = math.max(0, vis_a - a)
  local draw = math.max(1, vis_b - vis_a + 1)
  if skip + draw > full then
    draw = math.max(1, full - skip)
  end
  return skip, draw
end

---取 place 可见切片的 b64：完整布局后按 skip/draw 裁切（不整体压扁）
---@param place table
---@param draw_rows integer
---@param skip_rows integer
---@param python string|nil
---@return string|nil
local function place_b64_for_slice(place, draw_rows, skip_rows, python)
  if not place then
    return nil
  end
  draw_rows = math.max(1, draw_rows)
  skip_rows = math.max(0, skip_rows or 0)
  local full = place.rows or draw_rows
  if skip_rows == 0 and draw_rows >= full then
    return place.b64
  end
  place._crop = place._crop or {}
  local key = string.format("%d:%d", skip_rows, draw_rows)
  if place._crop[key] then
    return place._crop[key]
  end
  if not place.path then
    return place.b64
  end
  local b64 = encode_png_b64(
    place.path,
    place.cols or 1,
    draw_rows,
    place.scale or "fill",
    python,
    full,
    skip_rows
  )
  if b64 then
    place._crop[key] = b64
    return b64
  end
  return place.b64
end

---兼容旧调用：仅顶部裁切
---@param place table
---@param draw_rows integer
---@param python string|nil
---@return string|nil
local function place_b64_for_rows(place, draw_rows, python)
  return place_b64_for_slice(place, draw_rows, 0, python)
end

local function send_kitty(b64, cols, rows, id, row, col)
  local parts = { "\27[s", string.format("\27[%d;%dH", row, col) }
  local n = #b64
  local i = 1
  local first = true
  while i <= n do
    local chunk = b64:sub(i, i + CHUNK - 1)
    i = i + CHUNK
    local more = i <= n
    if first then
      parts[#parts + 1] = string.format(
        "\27_Ga=T,f=100,t=d,c=%d,r=%d,i=%d,C=1,z=2147483647,q=2,m=%d;%s\27\\",
        cols,
        rows,
        id,
        more and 1 or 0,
        chunk
      )
      first = false
    else
      parts[#parts + 1] = string.format("\27_Gm=%d;%s\27\\", more and 1 or 0, chunk)
    end
  end
  parts[#parts + 1] = "\27[u"
  return tty_write(table.concat(parts))
end

local function send_iterm(b64, cols, rows, row, col)
  local name_b64 = b64encode("mdview.png")
  local seq = string.format(
    "\27[s\27[%d;%dH\27]1337;File=name=%s;inline=1;width=%d;height=%d;preserveAspectRatio=0;doNotMoveCursor=1:%s\7\27[u",
    row,
    col,
    name_b64,
    cols,
    rows,
    b64
  )
  return tty_write(seq)
end

---@param a number|nil
---@param b number|nil
---@return boolean
local function col_near(a, b)
  if a == nil and b == nil then
    return true
  end
  if a == nil or b == nil then
    return false
  end
  -- 表格多行 █ 的 end_col 可能因字节长度略有漂移
  return math.abs(a - b) <= 8
end

---同 path + 相近列的连续行合并为一个区域（表格多行图只算 1 张）
---@param raw table[]
---@return table[]
local function merge_regions(raw)
  table.sort(raw, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    local ac, bc = a.col or -1, b.col or -1
    if ac ~= bc then
      return ac < bc
    end
    return (a.path or "") < (b.path or "")
  end)
  local regions = {}
  for _, r in ipairs(raw) do
    local last = regions[#regions]
    -- 同 path + 相近起点列 + 连续/重叠行 → 一张图
    local same_slot = last and last.path == r.path and col_near(last.col, r.col)
    if last and same_slot and r.line <= last.line_end + 1 then
      last.line_end = math.max(last.line_end, r.line_end)
      if r.dcols and not last.dcols then
        last.dcols = r.dcols
      end
      if r.end_col and (not last.end_col or r.end_col > last.end_col) then
        last.end_col = r.end_col
      end
    else
      regions[#regions + 1] = {
        path = r.path,
        line = r.line,
        line_end = r.line_end,
        col = r.col,
        end_col = r.end_col,
        dcols = r.dcols,
      }
    end
  end
  return regions
end

---收集高清区域（每图一块，不重复）
function M.collect_image_regions(hits)
  local raw = {}
  for _, h in ipairs(hits or {}) do
    if h.kind == "image_hd" and h.path and h.path ~= "" then
      local a = h.line or 1
      local b = h.line_end or h.line or a
      if b < a then
        a, b = b, a
      end
      raw[#raw + 1] = {
        path = vim.fn.fnamemodify(h.path, ":p"),
        line = a,
        line_end = b,
        col = h.col,
        end_col = h.end_col,
        dcols = h.dcols,
      }
    end
  end
  if #raw > 0 then
    return merge_regions(raw)
  end

  -- 回退：由 per-line image hits 合并连续同 path（同列）
  local items = {}
  for _, h in ipairs(hits or {}) do
    if h.kind == "image" and h.path and h.path ~= "" then
      items[#items + 1] = {
        line = h.line or 1,
        line_end = h.line_end or h.line or 1,
        path = vim.fn.fnamemodify(h.path, ":p"),
        col = h.col,
        end_col = h.end_col,
        dcols = h.dcols,
      }
    end
  end
  local regions = merge_regions(items)
  -- 块图多行：首行常为 🖼 标题，叠层从下一行开始（无 col 的整宽图）
  for _, r in ipairs(regions) do
    if r.col == nil and r.line_end > r.line then
      r.line = r.line + 1
    end
  end
  return regions
end

---窗口可见行范围
local function win_view(win)
  local info = vim.fn.getwininfo(win)[1]
  if info then
    return info.topline or 1, info.botline or 1, info.winrow or 1, info.wincol or 1
  end
  local top, bot
  vim.api.nvim_win_call(win, function()
    top = vim.fn.line("w0")
    bot = vim.fn.line("w$")
  end)
  local pos = vim.api.nvim_win_get_position(win)
  return top or 1, bot or 1, pos[1] + 1, pos[2] + 1
end

---按 buffer 行列算显示列宽（表格图用）
---@param buf integer
---@param line integer 1-based
---@param col integer|nil 0-based byte
---@param end_col integer|nil 0-based byte end
---@param win_w integer
---@param prefer_dcols integer|nil 表格列宽（显示格）优先
---@return integer cols, integer dcol 显示宽度, 行内显示起点
local function region_display_geom(buf, line, col, end_col, win_w, prefer_dcols)
  if prefer_dcols and prefer_dcols > 0 then
    local dcol = 0
    if col and buf and vim.api.nvim_buf_is_valid(buf) then
      local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
      dcol = vim.fn.strdisplaywidth(text:sub(1, col))
    end
    return math.max(1, math.min(win_w, prefer_dcols)), dcol
  end
  if not col or not end_col or end_col <= col then
    return math.max(1, win_w), 0
  end
  local text = ""
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local lines = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)
    text = lines[1] or ""
  end
  local pre = text:sub(1, col)
  local mid = text:sub(col + 1, end_col)
  if mid == "" and end_col > col then
    mid = text:sub(col + 1, math.min(#text, end_col))
  end
  local dcol = vim.fn.strdisplaywidth(pre)
  local dcols = math.max(1, vim.fn.strdisplaywidth(mid))
  if dcols < 1 then
    dcols = math.max(1, end_col - col)
  end
  dcols = math.min(win_w, dcols)
  return dcols, dcol
end

---屏幕上可用于图形的最后一行（1-based，不含 statusline / cmdline）
---@return integer
local function screen_content_bottom()
  local lines = vim.o.lines or 24
  local bottom = lines
  -- cmdline
  local ch = vim.o.cmdheight or 1
  if type(ch) == "number" then
    bottom = bottom - math.max(0, ch)
  end
  -- statusline（全局或至少有一个窗）
  local ls = vim.o.laststatus or 0
  if ls == 2 or ls == 3 then
    bottom = bottom - 1
  elseif ls == 1 then
    -- 多窗时有 statusline
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      bottom = bottom - 1
    end
  end
  -- messages 行（偶尔）
  if vim.o.display and tostring(vim.o.display):find("msgsep", 1, true) then
    -- ignore
  end
  return math.max(1, bottom)
end

---把图像高度裁到不越过窗口底与 statusline
---@param win integer
---@param screen_row integer 1-based
---@param rows integer
---@param place_line integer
---@param place_line_end integer
---@param botline integer
---@return integer rows
local function clip_rows_to_screen(win, screen_row, rows, place_line, place_line_end, botline)
  rows = math.max(1, rows)
  -- 1) 不超过窗口可见 buffer 行
  local vis_end = math.min(place_line_end, botline)
  local by_view = math.max(1, vis_end - place_line + 1)
  rows = math.min(rows, by_view)

  -- 2) 不超过窗口在屏幕上的底边
  local info = vim.fn.getwininfo(win)[1]
  if info and (info.winrow or 0) > 0 and (info.height or 0) > 0 then
    local win_bottom = (info.winrow or 1) + (info.height or 1) - 1
    rows = math.min(rows, math.max(1, win_bottom - screen_row + 1))
  end

  -- 3) 不超过 statusline / cmdline 之上
  local screen_bottom = screen_content_bottom()
  if screen_row > screen_bottom then
    return 0
  end
  rows = math.min(rows, math.max(1, screen_bottom - screen_row + 1))
  return math.max(0, rows)
end

local function paint_one(ov, place)
  if not place.b64 then
    return
  end
  if not vim.api.nvim_win_is_valid(ov.win) or vim.api.nvim_win_get_buf(ov.win) ~= ov.buf then
    return
  end

  local top, bot = win_view(ov.win)
  if place.line_end < top or place.line > bot then
    if ov.protocol ~= "iterm" then
      delete_id(place.id)
    end
    return
  end

  local full_rows = math.max(1, place.rows or (place.line_end - place.line + 1))
  local cols = math.max(1, place.cols or 1)

  -- 可见切片：上半滚出 → skip>0 取下半；底部不够 → skip=0 取上半
  local skip_rows, draw_rows = place_visible_slice(place, top, bot)
  if draw_rows < 1 then
    return
  end

  -- 绘制起点 = 可见区首行（图块首行或窗口 topline）
  local vis_start = math.max(place.line, top)

  local screen_row, screen_col
  local byte_col = (place.col or 0) + 1
  local sp = vim.fn.screenpos(ov.win, vis_start, byte_col)
  if sp and (sp.row or 0) > 0 and (sp.col or 0) > 0 then
    screen_row, screen_col = sp.row, sp.col
  else
    local info = vim.fn.getwininfo(ov.win)[1]
    if info and (info.winrow or 0) > 0 then
      screen_row = (info.winrow or 1) + (vis_start - top)
      screen_col = (info.wincol or 1) + (info.textoff or 0) + (place.dcol or 0)
    else
      local pos = vim.api.nvim_win_get_position(ov.win)
      screen_row = pos[1] + (vis_start - top) + 1
      screen_col = pos[2] + 1 + (place.dcol or 0)
    end
  end

  -- 再裁 statusline / 窗底
  draw_rows = clip_rows_to_screen(
    ov.win,
    screen_row,
    draw_rows,
    vis_start,
    math.min(place.line_end, bot),
    bot
  )
  if draw_rows < 1 then
    return
  end
  -- clip 可能再缩短；skip 不变（仍从原图同一偏移取）
  if skip_rows + draw_rows > full_rows then
    draw_rows = math.max(1, full_rows - skip_rows)
  end

  local b64 = place_b64_for_slice(place, draw_rows, skip_rows, ov.python)
  if not b64 then
    return
  end

  -- iTerm 无法按 id 删除：同一 place 只允许 paint 有限次，防竖直堆叠
  if ov.protocol == "iterm" then
    place._paint_n = (place._paint_n or 0) + 1
    if place._paint_n > 2 then
      return true
    end
  else
    delete_id(place.id)
  end

  local ok = false
  if ov.protocol == "iterm" then
    ok = send_iterm(b64, cols, draw_rows, screen_row, screen_col)
    if not ok then
      ok = send_kitty(b64, cols, draw_rows, place.id, screen_row, screen_col)
    end
  else
    ok = send_kitty(b64, cols, draw_rows, place.id, screen_row, screen_col)
    if not ok then
      ok = send_iterm(b64, cols, draw_rows, screen_row, screen_col)
    end
  end
  return ok
end

local function paint_all(ov)
  local any = false
  for _, p in ipairs(ov.places or {}) do
    if paint_one(ov, p) then
      any = true
    end
  end
  return any
end

---强制重画某 buffer 的叠层（echo/redraw 后补帧）
---@param buf integer|nil
---@return boolean
function M._repaint_buf(buf)
  local ov = buf and overlays[buf]
  if not ov then
    return false
  end
  if not (ov.win and vim.api.nvim_win_is_valid(ov.win)) then
    local w0 = vim.fn.bufwinid(buf)
    if w0 ~= -1 then
      ov.win = w0
    end
  end
  return paint_all(ov) and true or false
end

---@param opts {
---  buf: integer,
---  win: integer,
---  hits: table[],
---  max_images?: integer,
---  scale?: string,
---  python?: string,
---  visible_only?: boolean,   -- 仅当前窗口可见行上的图
---  clear_on_scroll?: boolean, -- 滚动/改大小清除（临时预览高清）
---}
---@return boolean
function M.attach_preview(opts)
  local buf = opts.buf
  local win = opts.win
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  M.clear_buf(buf)

  local regions = M.collect_image_regions(opts.hits)
  if #regions == 0 then
    return false
  end

  local top, bot = win_view(win)
  if opts.visible_only then
    local filtered = {}
    for _, r in ipairs(regions) do
      -- 与可见区有交集即保留整块（高度用完整 █ 行数，不裁成 1 行）
      if r.line_end >= top and r.line <= bot then
        filtered[#filtered + 1] = {
          path = r.path,
          line = r.line,
          line_end = r.line_end,
          col = r.col,
          end_col = r.end_col,
          dcols = r.dcols,
        }
      end
    end
    regions = filtered
  end
  if #regions == 0 then
    return false
  end

  local max_imgs = opts.max_images or 20
  local scale = opts.scale == "fit" and "fit" or "fill"
  local python = opts.python
  local win_w = math.max(4, vim.api.nvim_win_get_width(win))
  local clear_on_scroll = opts.clear_on_scroll == true or opts.clear_on_cursor == true

  local places = {}
  local seen = {}
  for _, r in ipairs(regions) do
    if #places >= max_imgs then
      break
    end
    local path = r.path
    if path and vim.fn.filereadable(path) == 1 then
      local key = string.format("%s:%d:%s", path, r.line, tostring(r.col or -1))
      if not seen[key] then
        seen[key] = true
        local rows = math.max(1, r.line_end - r.line + 1)
        local cols, dcol = region_display_geom(buf, r.line, r.col, r.end_col, win_w, r.dcols)
        local b64 = encode_png_b64(path, cols, rows, scale, python)
        if b64 then
          local id = next_id
          next_id = next_id + 1
          if next_id > 769999 then
            next_id = 760001
          end
          places[#places + 1] = {
            id = id,
            path = path,
            line = r.line,
            line_end = r.line_end,
            col = r.col,
            end_col = r.end_col,
            dcol = dcol,
            cols = cols,
            rows = rows,
            b64 = b64,
            scale = scale,
            _paint_n = 0,
          }
        end
      end
    end
  end

  if #places == 0 then
    return false
  end

  local protocol = is_wezterm() and "iterm" or "kitty"

  local ov = {
    win = win,
    buf = buf,
    places = places,
    protocol = protocol,
    python = python,
    ephemeral = clear_on_scroll,
  }
  overlays[buf] = ov

  -- 画 1～2 次即可。iTerm 多次 paint 会竖直堆叠残影
  paint_all(ov)
  vim.defer_fn(function()
    if overlays[buf] == ov then
      paint_all(ov)
    end
  end, 80)

  -- Kitty 可低频补画对抗 redraw；iTerm 不再 timer 重画（防堆叠）
  if protocol ~= "iterm" then
    local timer = uv.new_timer()
    if timer then
      ov.timer = timer
      timer:start(400, 400, function()
        vim.schedule(function()
          if overlays[buf] ~= ov then
            return
          end
          if not vim.api.nvim_buf_is_valid(buf) then
            M.clear_buf(buf)
            return
          end
          local w0 = vim.fn.bufwinid(buf)
          if w0 ~= -1 then
            ov.win = w0
            paint_all(ov)
          end
        end)
      end)
    end
  end

  local aug = vim.api.nvim_create_augroup("MdviewGfx_" .. buf, { clear = true })
  ov.aug = aug

  if clear_on_scroll then
    -- 滚动 / 改大小 / 焦点离开预览窗 时清除（移光标不关）
    local function should_clear_scroll(args)
      if args.event == "WinScrolled" then
        local wins = vim.v.event and vim.v.event.windows or {}
        if type(wins) == "table" then
          for _, w in pairs(wins) do
            if w == ov.win or w == win then
              return true
            end
          end
        end
        local w0 = vim.fn.bufwinid(buf)
        if w0 ~= -1 then
          local tnow = select(1, win_view(w0))
          if ov._topline and ov._topline ~= tnow then
            return true
          end
          if not ov._topline then
            return true
          end
        end
        return false
      end
      return true -- VimResized / WinResized
    end

    vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized", "WinResized" }, {
      group = aug,
      callback = function(args)
        if overlays[buf] ~= ov then
          return
        end
        if should_clear_scroll(args) then
          M.clear_buf(buf)
        end
      end,
    })

    -- 焦点切换（打开 float/弹窗、切到源窗或其它窗）→ 清高清
    -- 用 WinLeave 挂在预览窗；并用 WinEnter 兜底「当前窗不再是预览」
    ov._focus_grace = uv.hrtime()
    local focus_grace_ns = 200 * 1000000
    vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
      group = aug,
      buffer = buf,
      callback = function()
        if overlays[buf] ~= ov then
          return
        end
        local now = uv.hrtime()
        if ov._focus_grace and (now - ov._focus_grace) < focus_grace_ns then
          return
        end
        -- 延后判断：进入 float 时 Leave 先触发
        vim.schedule(function()
          if overlays[buf] ~= ov then
            return
          end
          local cur = vim.api.nvim_get_current_win()
          if ov.win and vim.api.nvim_win_is_valid(ov.win) and cur == ov.win then
            return
          end
          M.clear_buf(buf)
        end)
      end,
    })
    vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
      group = aug,
      callback = function()
        if overlays[buf] ~= ov then
          return
        end
        local now = uv.hrtime()
        if ov._focus_grace and (now - ov._focus_grace) < focus_grace_ns then
          return
        end
        local cur = vim.api.nvim_get_current_win()
        if ov.win and vim.api.nvim_win_is_valid(ov.win) and cur == ov.win then
          return
        end
        -- 当前焦点不在预览窗（含 float/源窗）
        M.clear_buf(buf)
      end,
    })

    ov._topline = select(1, win_view(win))
  else
    vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized", "WinResized", "BufEnter", "WinEnter" }, {
      group = aug,
      buffer = buf,
      callback = function()
        vim.defer_fn(function()
          if overlays[buf] ~= ov then
            return
          end
          local w0 = vim.fn.bufwinid(buf)
          if w0 == -1 then
            return
          end
          ov.win = w0
          paint_all(ov)
        end, 50)
      end,
    })
  end

  vim.api.nvim_create_autocmd({ "BufWipeout" }, {
    group = aug,
    buffer = buf,
    callback = function()
      M.clear_buf(buf)
    end,
  })

  return true
end

---float 是否有边框（单格边）
---@param win integer
---@return integer 0|1
local function float_border_pad(win)
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if not ok or type(cfg) ~= "table" then
    return 0
  end
  local b = cfg.border
  if not b or b == "none" or b == "" then
    return 0
  end
  return 1
end

---float 内容区矩形：叠在 █ 上（位置对齐正文首格；尺寸=整窗内容格，不少 1）
---@param win integer
---@param buf integer
---@return integer row, integer col, integer cols, integer rows  -- 1-based 屏坐标 / 正整数格数
local function float_content_rect(win, buf)
  local cw = math.max(1, vim.api.nvim_win_get_width(win))
  local ch = math.max(1, vim.api.nvim_win_get_height(win))

  local bar = 0
  pcall(function()
    local wb = vim.wo[win].winbar
    if type(wb) == "string" and wb ~= "" then
      bar = 1
    end
  end)

  -- float 已关 number/signcolumn；勿用 textoff（偶发 1 会让宽度少 1 格）
  local textoff = 0

  local info = vim.fn.getwininfo(win)[1]

  -- 窗口内容区左上角（1-based；nvim 不含 outer border）
  local winrow, wincol
  local wsp = vim.fn.win_screenpos(win)
  if type(wsp) == "table" and (wsp[1] or 0) > 0 then
    winrow, wincol = wsp[1], wsp[2]
  elseif info and (info.winrow or 0) > 0 then
    winrow, wincol = info.winrow, info.wincol
  else
    local pos = vim.api.nvim_win_get_position(win)
    winrow, wincol = pos[1] + 1, pos[2] + 1
  end

  local min_row = winrow + bar
  local min_col = wincol + textoff

  local row, col

  -- 1) screenpos：buffer 第 1 行第 1 列的真实屏格
  local sp = vim.fn.screenpos(win, 1, 1)
  if sp and (sp.row or 0) > 0 and (sp.col or 0) > 0 then
    row, col = sp.row, sp.col
  end

  -- 2) 当前窗且光标在首行：screenrow/screencol
  if (not row or not col) and vim.api.nvim_get_current_win() == win then
    local okc, cur = pcall(vim.api.nvim_win_get_cursor, win)
    if okc and cur and cur[1] == 1 then
      local sr = vim.fn.screenrow()
      local sc = vim.fn.screencol()
      if (sr or 0) > 0 and (sc or 0) > 0 then
        row = row or sr
        if cur[2] == 0 then
          col = col or sc
        end
      end
    end
  end

  -- 3) 窗口原点 + winbar
  if not row or row <= 0 then
    row = min_row
  end
  if not col or col <= 0 then
    col = min_col
  end

  -- 位置只往「内容起点」校正，避免落在 border 上；不因此缩小尺寸
  if row < min_row then
    row = min_row
  end
  if col < min_col then
    col = min_col
  end

  -- 尺寸：与 █ 一致 = 整窗宽 × (高−winbar)。
  -- 不要用 max_row/max_col 按起点再钳一次（起点偏 1 时会宽高各少 1）
  local cols = cw
  local rows = math.max(1, ch - bar)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local lc = vim.api.nvim_buf_line_count(buf)
    -- buffer 行数不足时按实际 █ 行；行数 ≥ 窗口高时铺满窗口
    if lc > 0 and lc < rows then
      rows = lc
    end
  end

  return row, col, cols, rows
end

---float 全窗高清叠层：叠在 █ 内容上（对齐正文首格）
---@param opts { path: string, win: integer, buf: integer, scale?: string, python?: string, cfg?: table }
---@return boolean
function M.attach_float(opts)
  local path = opts.path
  local win = opts.win
  local buf = opts.buf
  if not path or not win or not buf then
    return false
  end
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    return false
  end

  local imgcfg = opts.cfg
  if not imgcfg then
    pcall(function()
      imgcfg = require("mdview.config").get().image or {}
    end)
    imgcfg = imgcfg or {}
  end
  if not M.detect(imgcfg, "float") then
    return false
  end

  M.clear_buf(buf)

  local scale = opts.scale == "fit" and "fit" or "fill"
  local python = opts.python or imgcfg.python or "python"
  local _, _, cols0, rows0 = float_content_rect(win, buf)

  local b64 = encode_png_b64(path, cols0, rows0, scale, python)
  if not b64 then
    return false
  end

  local id = next_id
  next_id = next_id + 1
  if next_id > 769999 then
    next_id = 760001
  end

  local places = {
    {
      id = id,
      path = path,
      cols = cols0,
      rows = rows0,
      b64 = b64,
      scale = scale,
    },
  }

  local ov = {
    win = win,
    buf = buf,
    places = places,
    protocol = is_wezterm() and "iterm" or "kitty",
    python = python,
    float_mode = true,
    debug_once = false,
  }
  overlays[buf] = ov

  local function paint_float()
    if overlays[buf] ~= ov then
      return
    end
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end

    local screen_row, screen_col, cw, ch = float_content_rect(win, buf)
    local p = places[1]
    if math.abs(cw - p.cols) > 0 or math.abs(ch - p.rows) > 0 then
      local b2 = encode_png_b64(path, cw, ch, scale, python)
      if b2 then
        p.b64 = b2
        p.cols = cw
        p.rows = ch
      end
    end
    -- 裁到 statusline 之上：显示完整布局的顶部，不整体压扁
    local draw_rows = p.rows
    local screen_bottom = screen_content_bottom()
    if screen_row > 0 then
      draw_rows = math.min(draw_rows, math.max(0, screen_bottom - screen_row + 1))
    end
    if draw_rows < 1 then
      return
    end
    local b64 = place_b64_for_rows(p, draw_rows, python)
    if not b64 then
      return
    end
    if imgcfg.hd_debug and not ov.debug_once then
      ov.debug_once = true
      vim.notify(
        string.format(
          "mdview float_hd @%d,%d size %dx%d (draw_rows=%d crop_top) border=%d",
          screen_row,
          screen_col,
          p.cols,
          p.rows,
          draw_rows,
          float_border_pad(win)
        ),
        vim.log.levels.INFO
      )
    end
    delete_id(p.id)
    if ov.protocol == "iterm" then
      send_iterm(b64, p.cols, draw_rows, screen_row, screen_col)
    else
      if not send_kitty(b64, p.cols, draw_rows, p.id, screen_row, screen_col) then
        send_iterm(b64, p.cols, draw_rows, screen_row, screen_col)
      end
    end
  end

  -- 布局稳定后再画（光标屏坐标依赖 redraw）
  vim.defer_fn(paint_float, 50)
  vim.defer_fn(paint_float, 150)
  vim.defer_fn(paint_float, 350)

  local timer = uv.new_timer()
  if timer then
    ov.timer = timer
    timer:start(400, 400, function()
      vim.schedule(paint_float)
    end)
  end

  local aug = vim.api.nvim_create_augroup("MdviewFloatGfx_" .. buf, { clear = true })
  ov.aug = aug
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "BufEnter", "WinEnter", "CursorMoved" }, {
    group = aug,
    buffer = buf,
    callback = function()
      vim.defer_fn(paint_float, 40)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout" }, {
    group = aug,
    buffer = buf,
    callback = function()
      M.clear_buf(buf)
    end,
  })

  return true
end

return M
