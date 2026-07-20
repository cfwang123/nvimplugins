---@mod imgbuf.graphics
--- 高清叠层：在「字符画 terminal」之上，向宿主 TTY 发 iTerm2 / Kitty 像素图。
--- 策略：字符画永远可见；HD 能叠上更好，叠不上也不影响可读性。
--- 不修改 winhl / 全局 highlight，避免污染其它 buffer。
local M = {}

local CHUNK = 4096
local next_id = 771001
--- Neovim 0.9 只有 vim.loop；0.10+ 为 vim.uv
local uv = vim.uv or vim.loop

---@class OverlayState
---@field id integer
---@field path string
---@field win integer
---@field buf integer
---@field scale string
---@field python string|nil
---@field b64 string
---@field protocol "kitty"|"iterm"
---@field timer any
---@field aug integer|nil

---@type table<integer, OverlayState> buf -> state
local overlays = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

-- PNG 等二进制常含 NUL；经 vim.fn.system 的 input 会变成 Blob 并触发 E976。
-- Neovim 0.10+ 用 vim.base64；0.9 走纯 Lua（不经过 Vimscript 字符串/Blob）。
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

---写宿主终端（多路尝试）
---@param data string
---@return boolean
local function tty_write(data)
  if not data or data == "" then
    return false
  end
  if vim.api.nvim_ui_send then
    if pcall(vim.api.nvim_ui_send, data) then
      return true
    end
  end
  -- stderr 接到真实终端时有效
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

local function in_mux()
  return (vim.env.TMUX and vim.env.TMUX ~= "")
    or (vim.env.ZELLIJ and vim.env.ZELLIJ ~= "")
end

---是否 WezTerm
---@return boolean
local function is_wezterm()
  local term = (vim.env.TERM or ""):lower()
  local prog = (vim.env.TERM_PROGRAM or ""):lower()
  return (vim.env.WEZTERM_EXECUTABLE and vim.env.WEZTERM_EXECUTABLE ~= "")
    or (vim.env.WEZTERM_PANE and vim.env.WEZTERM_PANE ~= "")
    or prog:find("wezterm", 1, true) ~= nil
    or term:find("wezterm", 1, true) ~= nil
end

---终端是否支持图形协议（WezTerm / Kitty / Ghostty）
---@return boolean
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
  if prog:find("alacritty", 1, true) or term:find("alacritty", 1, true) then
    return false
  end
  return false
end

---@param cfg table|nil
---@return boolean
function M.detect(cfg)
  cfg = cfg or {}
  local mode = cfg.hd
  if mode == nil then
    mode = "always"
  end
  if mode == false or mode == "never" or mode == "none" or mode == "off" then
    return false
  end
  -- always / auto / kitty / wezterm：均需终端实际支持
  if mode ~= "always" and mode ~= "kitty" and mode ~= "wezterm" and mode ~= "auto" then
    return false
  end
  if in_mux() and cfg.hd_tmux ~= true then
    return false
  end
  if vim.env.SSH_CONNECTION and vim.env.SSH_CONNECTION ~= "" and cfg.hd_ssh ~= true then
    return false
  end
  return terminal_supports_hd()
end

---@param id integer|nil
local function delete_id(id)
  local parts = { "\27[0m" }
  if id then
    parts[#parts + 1] = string.format("\27_Ga=d,d=i,i=%d,q=2\27\\", id)
  end
  -- 清光标处 / 可见 placement（尽量干净）
  parts[#parts + 1] = "\27_Ga=d,d=c,q=2\27\\"
  pcall(tty_write, table.concat(parts))
end

local function stop_timer(st)
  if st and st.timer then
    pcall(function()
      st.timer:stop()
      st.timer:close()
    end)
    st.timer = nil
  end
end

---@param buf integer|nil
function M.clear_buf(buf)
  if not buf then
    pcall(tty_write, "\27[0m")
    return
  end
  local st = overlays[buf]
  if st then
    stop_timer(st)
    if st.aug then
      pcall(vim.api.nvim_del_augroup_by_id, st.aug)
      st.aug = nil
    end
    delete_id(st.id)
    overlays[buf] = nil
  else
    pcall(tty_write, "\27[0m")
  end
end

function M.clear_all()
  for buf, _ in pairs(overlays) do
    M.clear_buf(buf)
  end
end

---@param path string
---@param cols integer
---@param rows integer
---@param scale string
---@param python string|nil
---@return string|nil b64, string|nil err
local function encode_png_b64(path, cols, rows, scale, python)
  local py = python or "python"
  if vim.fn.executable(py) ~= 1 then
    if vim.fn.executable("python3") == 1 then
      py = "python3"
    else
      return nil, "no python"
    end
  end
  local script = plugin_root() .. "/scripts/gfx_prepare.py"
  if vim.fn.filereadable(script) == 0 then
    return nil, "no gfx_prepare.py"
  end
  local out = vim.fn.system({
    py,
    "-X",
    "utf8",
    script,
    path,
    tostring(cols),
    tostring(rows),
    scale == "fill" and "fill" or "fit",
  })
  if vim.v.shell_error ~= 0 then
    return nil, "gfx_prepare failed: " .. tostring(out)
  end
  local png = vim.trim(out or "")
  if png == "" or vim.fn.filereadable(png) == 0 then
    return nil, "no png"
  end
  local f = io.open(png, "rb")
  if not f then
    return nil, "open png"
  end
  local bin = f:read("*a")
  f:close()
  pcall(os.remove, png)
  if not bin or #bin == 0 then
    return nil, "empty png"
  end
  local b64 = b64encode(bin)
  if b64 == "" then
    return nil, "b64"
  end
  return b64, nil
end

---@param win integer
---@return integer, integer, integer, integer row,col,w,h (1-based row/col)
local function win_cells(win)
  local pos = vim.api.nvim_win_get_position(win)
  local w = vim.api.nvim_win_get_width(win)
  local h = vim.api.nvim_win_get_height(win)
  return pos[1] + 1, pos[2] + 1, w, h
end

---@param b64 string
---@param cols integer
---@param rows integer
---@param id integer
---@param row integer
---@param col integer
---@return boolean
---Kitty：叠在文字之上（z 足够大），与窗口同格对齐
---@param b64 string
---@param cols integer
---@param rows integer
---@param id integer
---@param row integer
---@param col integer
---@return boolean
local function send_kitty(b64, cols, rows, id, row, col)
  local parts = {
    "\27[s",
    string.format("\27[%d;%dH", row, col),
  }
  local n = #b64
  local i = 1
  local first = true
  while i <= n do
    local chunk = b64:sub(i, i + CHUNK - 1)
    i = i + CHUNK
    local more = i <= n
    if first then
      -- C=1 不挪光标；z=2147483647 尽量画在字符画之上
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

---@param b64 string
---@param cols integer
---@param rows integer
---@param row integer
---@param col integer
---@return boolean
local function send_iterm(b64, cols, rows, row, col)
  -- PNG 已按 fit/fill 处理（fit 时图居中+透明边）；铺满图像区格数
  local name_b64 = b64encode("imgbuf.png")
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

---绘制一次叠层（使用缓存 b64）
---@param st OverlayState
---@return boolean
local function paint(st)
  if not st or not st.b64 then
    return false
  end
  if not vim.api.nvim_win_is_valid(st.win) or not vim.api.nvim_buf_is_valid(st.buf) then
    return false
  end
  -- 仅当该 buffer 仍显示在目标窗口
  if vim.api.nvim_win_get_buf(st.win) ~= st.buf then
    return false
  end

  local row, col, w, h = win_cells(st.win)
  -- 与字符画同一区域：整窗宽 × (高-1 帮助行)
  local rows = math.max(1, h - 1)
  local cols = math.max(1, w)

  delete_id(st.id)

  -- 与字符画同一坐标系：窗口左上角 → 图像区
  -- fit/fill 的差异只在 PNG 内容（居中 letterbox vs 拉伸），叠层位置与尺寸一致
  local ok
  if st.protocol == "iterm" then
    ok = send_iterm(st.b64, cols, rows, row, col)
  else
    ok = send_kitty(st.b64, cols, rows, st.id, row, col)
    if not ok then
      ok = send_iterm(st.b64, cols, rows, row, col)
    end
  end
  return ok and true or false
end

---选择协议
---@return "iterm"|"kitty"
local function pick_protocol()
  if is_wezterm() then
    return "iterm"
  end
  return "kitty"
end

---在字符画 buffer 上挂高清叠层（异步编码后循环重绘）
---@param opts { path: string, win: integer, buf: integer, scale: string, python?: string, cols?: integer, rows?: integer }
---@return boolean started
function M.attach_overlay(opts)
  local buf = opts.buf
  local win = opts.win
  local path = opts.path
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if not path or vim.fn.filereadable(path) == 0 then
    return false
  end

  M.clear_buf(buf)

  local _, _, w, h = win_cells(win)
  local cols = math.max(8, opts.cols or w)
  local rows = math.max(4, opts.rows or math.max(1, h - 1))
  local scale = opts.scale == "fill" and "fill" or "fit"

  local b64, err = encode_png_b64(path, cols, rows, scale, opts.python)
  if not b64 then
    -- 静默失败，字符画仍在
    return false
  end

  local id = next_id
  next_id = next_id + 1
  if next_id > 790000 then
    next_id = 771001
  end

  local st = {
    id = id,
    path = path,
    win = win,
    buf = buf,
    scale = scale,
    python = opts.python,
    b64 = b64,
    protocol = pick_protocol(),
    timer = nil,
    aug = nil,
  }
  overlays[buf] = st

  -- 立即画 + 多次补画（对抗 nvim 重绘）
  paint(st)
  vim.defer_fn(function()
    if overlays[buf] == st then
      paint(st)
    end
  end, 50)
  vim.defer_fn(function()
    if overlays[buf] == st then
      paint(st)
    end
  end, 200)

  -- 焦点在预览时周期性重绘（nvim 重绘会盖掉图层）
  local timer = uv and uv.new_timer and uv.new_timer() or nil
  if timer then
    st.timer = timer
    timer:start(300, 300, function()
      vim.schedule(function()
        local cur = overlays[buf]
        if cur ~= st then
          return
        end
        if not vim.api.nvim_buf_is_valid(buf) then
          M.clear_buf(buf)
          return
        end
        -- 仅当前窗口显示该 buf 时重绘
        local w0 = vim.fn.bufwinid(buf)
        if w0 ~= -1 then
          st.win = w0
          paint(st)
        end
      end)
    end)
  end

  local aug = vim.api.nvim_create_augroup("ImgbufOverlay_" .. buf, { clear = true })
  st.aug = aug
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "BufEnter", "WinEnter" }, {
    group = aug,
    buffer = buf,
    callback = function()
      vim.defer_fn(function()
        if overlays[buf] == st then
          -- 尺寸变了需要重编码
          local ww = vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_get_width(st.win) or cols
          local hh = vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_get_height(st.win) or rows
          local nc, nr = ww, math.max(1, hh - 1)
          if math.abs(nc - cols) > 2 or math.abs(nr - rows) > 2 then
            cols, rows = nc, nr
            local b2 = encode_png_b64(path, cols, rows, scale, opts.python)
            if b2 then
              st.b64 = b2
            end
          end
          paint(st)
        end
      end, 30)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave", "BufWipeout", "WinClosed" }, {
    group = aug,
    buffer = buf,
    callback = function()
      -- 离开时清图层，避免残影盖住其它 buffer
      M.clear_buf(buf)
    end,
  })

  return true
end

---兼容旧 API
function M.show(opts)
  return M.attach_overlay(opts)
end

return M
