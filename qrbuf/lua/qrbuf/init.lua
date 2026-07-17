---@mod qrbuf 终端二维码预览
local i18n = require("qrbuf.i18n")

local M = {}

local default_config = {
  python = "python",
  ---放大倍数（每个模块用 zoom x zoom 字符块）
  zoom = 1,
  ---反色：true 时黑底白码（部分终端更清晰）
  invert = false,
  ui_lang = "auto",
  keys_open = "<leader>qr",
  border = "rounded",
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}

local state = {
  buf = nil,
  win = nil,
  text = "",
  matrix = nil, ---@type integer[][]|nil
  zoom = 1,
}

local NS = vim.api.nvim_create_namespace("qrbuf")

local function ensure_hl()
  pcall(vim.api.nvim_set_hl, 0, "QrbufNormal", { fg = "#111111", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "QrbufTitle", { fg = "#111111", bg = "#ffffff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "QrbufHelp", { fg = "#666666", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "QrbufBorder", { fg = "#888888", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "QrbufModOn", { fg = "#000000", bg = "#000000", force = true })
  pcall(vim.api.nvim_set_hl, 0, "QrbufModOff", { fg = "#ffffff", bg = "#ffffff", force = true })
end

local function script_path()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  -- .../qrbuf/lua/qrbuf/init.lua → .../qrbuf/scripts/qrgen.py
  local root = vim.fn.fnamemodify(src, ":p:h:h:h")
  return root .. "/scripts/qrgen.py"
end

local function resolve_python()
  local cands = { config.python, "python", "python3" }
  if vim.fn.has("win32") == 1 then
    table.insert(cands, "py")
  end
  for _, c in ipairs(cands) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      -- 尽量用绝对路径，避免 Windows 下 vim.system spawn 失败
      local abs = vim.fn.exepath(c)
      if abs == nil or abs == "" then
        abs = c
      end
      abs = vim.fn.fnamemodify(abs, ":p")
      if c == "py" or abs:lower():match("[/\\]py%.exe$") then
        return { abs, "-3" }
      end
      return { abs }
    end
  end
  return nil
end

---稳健执行外部命令，返回 stdout 文本
---@param cmd string[]
---@param opts? { stdin?: string }
---@return string|nil out
---@return string|nil err
local function run_cmd(cmd, opts)
  opts = opts or {}
  -- 1) vim.system（部分 Windows 会 spawn error -1，需 pcall + 回退）
  if vim.system then
    local ok, r = pcall(function()
      return vim.system(cmd, {
        text = true,
        stdin = opts.stdin,
        cwd = vim.fn.fnamemodify(cmd[#cmd] or ".", ":p:h"),
      }):wait()
    end)
    if ok and type(r) == "table" then
      local out = r.stdout or ""
      local err = r.stderr or ""
      if (r.code or 0) == 0 or (out ~= "" and out:find("{", 1, true)) then
        return out, err
      end
      if out == "" and err ~= "" then
        return nil, err
      end
      if out ~= "" then
        return out, err
      end
      -- fall through
    end
  end

  -- 2) jobstart（更兼容 Windows）
  local chunks, err_chunks = {}, {}
  local done = false
  local code = -1
  local jopts = {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            chunks[#chunks + 1] = line
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            err_chunks[#err_chunks + 1] = line
          end
        end
      end
    end,
    on_exit = function(_, c)
      code = c
      done = true
    end,
  }
  local job = vim.fn.jobstart(cmd, jopts)
  if job > 0 then
    if opts.stdin and opts.stdin ~= "" then
      pcall(vim.fn.chansend, job, opts.stdin)
      pcall(vim.fn.chanclose, job, "stdin")
    end
    -- 最多等 15s
    local t0 = vim.loop.hrtime()
    while not done do
      vim.wait(50, function()
        return done
      end, 50)
      if (vim.loop.hrtime() - t0) / 1e6 > 15000 then
        pcall(vim.fn.jobstop, job)
        break
      end
    end
    local out = table.concat(chunks, "\n")
    local err = table.concat(err_chunks, "\n")
    if out ~= "" or code == 0 then
      return out, err
    end
    if err ~= "" then
      return nil, err
    end
  end

  -- 3) vim.fn.system 字符串命令（最后手段）
  local parts = {}
  for _, a in ipairs(cmd) do
    if a:find("[ %s\"']") then
      parts[#parts + 1] = '"' .. a:gsub('"', '\\"') .. '"'
    else
      parts[#parts + 1] = a
    end
  end
  local cmdline = table.concat(parts, " ")
  local out = vim.fn.system(cmdline)
  if vim.v.shell_error ~= 0 and (out == nil or out == "") then
    return nil, "shell_error " .. tostring(vim.v.shell_error)
  end
  return out, nil
end

---读取当前可视选区文本（须在仍处于 visual / 刚离开后用 '< '> 时调用）
---@param mode? string  "v"|"V"|"\22"|""；空则尝试 mode() 与 visualmode()
---@return string
local function get_visual_text(mode)
  mode = mode or vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    mode = vim.fn.visualmode()
  end
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return ""
  end

  local s, e
  -- 仍在 visual 时用 v / .；否则用 '< '>
  local cur = vim.fn.mode()
  if cur == "v" or cur == "V" or cur == "\22" then
    s = vim.fn.getpos("v")
    e = vim.fn.getpos(".")
  else
    s = vim.fn.getpos("'<")
    e = vim.fn.getpos("'>")
  end

  local sr, sc = s[2], s[3]
  local er, ec = e[2], e[3]
  if sr == 0 or er == 0 then
    return ""
  end
  -- 规范化起止顺序
  if sr > er or (sr == er and sc > ec) then
    sr, er = er, sr
    sc, ec = ec, sc
  end

  if mode == "V" then
    local lines = vim.api.nvim_buf_get_lines(0, sr - 1, er, false)
    return table.concat(lines, "\n")
  end

  -- 字符选 / 块选：nvim_buf_get_text 的 end_col 为 exclusive
  -- visual 的 col 是 inclusive，且 getpos 为 1-based byte col
  local end_col = ec
  -- 多字节字符：用 getline + strcharpart 更稳
  if sr == er then
    local line = vim.api.nvim_buf_get_lines(0, sr - 1, sr, false)[1] or ""
    -- col 是字节位置 1-based inclusive
    if sc < 1 then
      sc = 1
    end
    if ec > #line then
      ec = #line
    end
    if sc > #line then
      return ""
    end
    return line:sub(sc, ec)
  end

  local lines = {}
  local all = vim.api.nvim_buf_get_lines(0, sr - 1, er, false)
  if #all == 0 then
    return ""
  end
  for i, line in ipairs(all) do
    if i == 1 then
      lines[#lines + 1] = line:sub(sc)
    elseif i == #all then
      lines[#lines + 1] = line:sub(1, math.min(ec, #line))
    else
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\n")
end

---取编码文本：显式 text > 可视选区/range > 当前行 > 剪贴板
---@param opts? { text?: string, line1?: integer, line2?: integer, col1?: integer, col2?: integer, visual?: boolean|string }
---@return string
local function resolve_text(opts)
  opts = opts or {}
  if type(opts.text) == "string" and opts.text ~= "" then
    return opts.text
  end

  -- 调用方已标明 visual，或当前正处于 visual
  local mode = vim.fn.mode()
  if opts.visual or mode == "v" or mode == "V" or mode == "\22" then
    local t = get_visual_text(type(opts.visual) == "string" and opts.visual or mode)
    if t ~= "" then
      return t
    end
  end

  -- 带列信息的 range（字符级）
  if opts.line1 and opts.line2 and opts.col1 and opts.col2 then
    local sr, er = opts.line1, opts.line2
    local sc, ec = opts.col1, opts.col2
    if sr == er then
      local line = vim.api.nvim_buf_get_lines(0, sr - 1, sr, false)[1] or ""
      return line:sub(sc, math.min(ec, #line))
    end
    local all = vim.api.nvim_buf_get_lines(0, sr - 1, er, false)
    local lines = {}
    for i, line in ipairs(all) do
      if i == 1 then
        lines[#lines + 1] = line:sub(sc)
      elseif i == #all then
        lines[#lines + 1] = line:sub(1, math.min(ec, #line))
      else
        lines[#lines + 1] = line
      end
    end
    if #lines > 0 then
      return table.concat(lines, "\n")
    end
  end

  -- 仅行 range（整行）
  if opts.line1 and opts.line2 then
    local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
    if #lines > 0 then
      return table.concat(lines, "\n")
    end
  end

  local line = vim.api.nvim_get_current_line()
  if line and line ~= "" then
    return line
  end
  local clip = vim.fn.getreg("+")
  if clip == "" then
    clip = vim.fn.getreg("*")
  end
  return tostring(clip or "")
end

---供 visual 映射：立即抓取选区再打开
function M.open_visual()
  M.ensure_setup()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    mode = vim.fn.visualmode()
  end
  local text = get_visual_text(mode)
  -- 退出 visual，避免残留
  if vim.fn.mode():find("[vV\22]") then
    vim.cmd("normal! \27")
  end
  if text == "" then
    -- 回退到 marks
    text = resolve_text({
      line1 = vim.fn.line("'<"),
      line2 = vim.fn.line("'>"),
      col1 = vim.fn.col("'<"),
      col2 = vim.fn.col("'>"),
      visual = mode,
    })
  end
  M.open({ text = text })
end

---@param text string
---@return integer[][]|nil matrix
---@return string|nil err
local function generate_matrix(text)
  local py = resolve_python()
  if not py then
    return nil, i18n.t("need_python")
  end
  local script = script_path()
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) ~= 1 then
    return nil, i18n.t("script_missing") .. script
  end
  -- 旁路 argv/spawn 编码问题：写临时 UTF-8 文件
  local tmp = vim.fn.tempname() .. "_qrbuf.txt"
  tmp = vim.fn.fnamemodify(tmp, ":p")
  local wr_ok = pcall(function()
    -- 用 \n 分行写，保证 UTF-8
    local lines = vim.split(text, "\n", { plain = true })
    if #lines == 0 then
      lines = { text }
    end
    vim.fn.writefile(lines, tmp)
  end)
  if not wr_ok then
    return nil, "cannot write temp file"
  end

  local cmd = {}
  for _, a in ipairs(py) do
    cmd[#cmd + 1] = a
  end
  cmd[#cmd + 1] = "-X"
  cmd[#cmd + 1] = "utf8"
  cmd[#cmd + 1] = script
  cmd[#cmd + 1] = "--border"
  cmd[#cmd + 1] = "4"
  cmd[#cmd + 1] = "--file"
  cmd[#cmd + 1] = tmp

  local out, err_out = run_cmd(cmd)
  pcall(vim.fn.delete, tmp)

  if (not out or out == "") and err_out then
    return nil, err_out
  end
  if not out or out == "" then
    return nil, "empty output from qrgen"
  end

  out = out:gsub("^\239\187\191", "") -- BOM
  out = out:gsub("\r", "")
  local json_str = vim.trim(out)
  local last = json_str:match("(%b{})%s*$")
  if last then
    json_str = last
  end
  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= "table" then
    return nil, "bad json: " .. tostring(out):sub(1, 200)
  end
  if data.error then
    return nil, tostring(data.error)
  end
  if type(data.matrix) ~= "table" or #data.matrix < 21 then
    return nil, "no matrix"
  end
  return data.matrix, nil
end

---屏幕可给二维码本体的最大宽/高（字符列 / 屏幕行）
---@return integer max_w
---@return integer max_h
local function qr_screen_budget()
  -- 边框/边距 + 标题/帮助/分隔 约占
  local max_w = math.max(12, vim.o.columns - 6)
  local max_h = math.max(6, vim.o.lines - 10)
  return max_w, max_h
end

---给定矩阵边长 n，zoom 后半块渲染的宽高
---@param n integer
---@param zoom integer
---@return integer w
---@return integer h
local function zoom_dims(n, zoom)
  zoom = math.max(1, zoom or 1)
  -- 先宽高同时放大模块，再半块合并：高 = ceil(n*zoom/2)，宽 = n*zoom
  local w = n * zoom
  local h = math.ceil((n * zoom) / 2)
  return w, h
end

---在屏幕限制内允许的最大 zoom（宽高同时放大且不换行、不超出）
---@param n integer 矩阵边长
---@return integer
local function max_zoom_allowed(n)
  if not n or n < 1 then
    return 1
  end
  local max_w, max_h = qr_screen_budget()
  local maxz = 1
  for z = 1, 16 do
    local w, h = zoom_dims(n, z)
    if w <= max_w and h <= max_h then
      maxz = z
    else
      break
    end
  end
  return maxz
end

---@param z integer
---@return integer
local function clamp_zoom(z)
  local n = state.matrix and #state.matrix or 1
  local maxz = max_zoom_allowed(n)
  z = math.floor(tonumber(z) or 1)
  if z < 1 then
    z = 1
  end
  if z > maxz then
    z = maxz
  end
  return z
end

---将每个模块复制为 zoom×zoom，实现宽高同步缩放
---@param matrix integer[][]
---@param zoom integer
---@return integer[][]
local function expand_matrix(matrix, zoom)
  zoom = math.max(1, zoom or 1)
  if zoom == 1 then
    return matrix
  end
  local n = #matrix
  local out = {}
  for y = 1, n do
    local src = matrix[y]
    for _zy = 1, zoom do
      local row = {}
      for x = 1, n do
        local v = src and src[x] or 0
        for _zx = 1, zoom do
          row[#row + 1] = v
        end
      end
      out[#out + 1] = row
    end
  end
  return out
end

---半高模块渲染：两行模块合并为一行 ▀▄█ 空格
---matrix 已含静区；1=黑模块。zoom 先宽高同步放大再渲染。
---@param matrix integer[][]
---@param zoom integer
---@return string[]
local function render_lines(matrix, zoom)
  zoom = clamp_zoom(zoom or 1)
  local expanded = expand_matrix(matrix, zoom)
  local n = #expanded
  if n == 0 then
    return { "" }
  end
  local lines = {}
  local inv = config.invert

  local function mod_at(y, x)
    -- y,x 0-based
    if y < 0 or x < 0 or y >= n or x >= n then
      return 0
    end
    local row = expanded[y + 1]
    if type(row) ~= "table" then
      return 0
    end
    local v = row[x + 1]
    if type(v) == "boolean" then
      v = v and 1 or 0
    end
    v = tonumber(v) or 0
    if inv then
      v = 1 - v
    end
    return v
  end

  -- 垂直：每 2 行模块合成 1 行字符（半块）；水平已在 expand 中放大
  local y = 0
  while y < n do
    local parts = {}
    local row_len = type(expanded[1]) == "table" and #expanded[1] or n
    for x = 0, row_len - 1 do
      local top = mod_at(y, x)
      local bot = (y + 1 < n) and mod_at(y + 1, x) or 0
      local ch
      if top == 1 and bot == 1 then
        ch = "█"
      elseif top == 1 and bot == 0 then
        ch = "▀"
      elseif top == 0 and bot == 1 then
        ch = "▄"
      else
        ch = " "
      end
      parts[#parts + 1] = ch
    end
    lines[#lines + 1] = table.concat(parts)
    y = y + 2
  end
  return lines
end

local function close_ui()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf = nil, nil
end

local function draw()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  ensure_hl()
  local matrix = state.matrix
  if not matrix then
    return
  end
  -- 缩放钳制：宽高同步且不超出屏幕
  state.zoom = clamp_zoom(state.zoom or 1)
  local body = render_lines(matrix, state.zoom)
  local help = i18n.t("help")
  local preview = state.text:gsub("[\r\n]+", " ")
  if vim.fn.strdisplaywidth(preview) > 48 then
    preview = vim.fn.strcharpart(preview, 0, 40) .. "…"
  end
  local zoom_info = string.format("  ×%d", state.zoom)
  local lines = {
    "  " .. i18n.t("win_title") .. "  ·  " .. preview .. zoom_info,
    help,
    string.rep("─", math.max(20, vim.fn.strdisplaywidth(body[1] or "") )),
  }
  for _, l in ipairs(body) do
    lines[#lines + 1] = l
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 0, 0, {
    end_col = #lines[1],
    hl_group = "QrbufTitle",
  })
  pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 1, 0, {
    end_col = #lines[2],
    hl_group = "QrbufHelp",
  })

  -- 窗口紧贴内容，禁止换行；宽高不超过屏幕
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local content_w = 0
    for _, l in ipairs(lines) do
      content_w = math.max(content_w, vim.fn.strdisplaywidth(l))
    end
    local max_w = math.max(12, vim.o.columns - 4)
    local max_h = math.max(6, vim.o.lines - 4)
    local w = math.min(content_w, max_w)
    local h = math.min(#lines, max_h)
    -- 若内容宽超过窗口（不应发生，clamp 已限制），仍不 wrap
    pcall(function()
      vim.wo[state.win].wrap = false
      vim.wo[state.win].linebreak = false
    end)
    pcall(vim.api.nvim_win_set_config, state.win, {
      relative = "editor",
      width = w,
      height = h,
      row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    })
  end
end

local function bind(buf)
  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", o, { desc = "qrbuf: " .. desc }))
  end
  map("q", close_ui, "close")
  map("<Esc>", close_ui, "close")
  map("y", function()
    pcall(vim.fn.setreg, "+", state.text)
    pcall(vim.fn.setreg, "*", state.text)
    vim.notify(i18n.t("copied"), vim.log.levels.INFO)
  end, "copy text")
  map("L", function()
    local l = i18n.toggle()
    vim.notify(l == "en" and i18n.t("lang_to_en") or i18n.t("lang_to_zh"), vim.log.levels.INFO)
    draw()
  end, "lang")
  map("+", function()
    local n = state.matrix and #state.matrix or 1
    local maxz = max_zoom_allowed(n)
    local nextz = (state.zoom or 1) + 1
    if nextz > maxz then
      vim.notify(string.format("qrbuf: max zoom ×%d (screen limit)", maxz), vim.log.levels.INFO)
      return
    end
    state.zoom = nextz
    draw()
  end, "zoom in")
  map("=", function()
    local n = state.matrix and #state.matrix or 1
    local maxz = max_zoom_allowed(n)
    local nextz = (state.zoom or 1) + 1
    if nextz > maxz then
      vim.notify(string.format("qrbuf: max zoom ×%d (screen limit)", maxz), vim.log.levels.INFO)
      return
    end
    state.zoom = nextz
    draw()
  end, "zoom in")
  map("-", function()
    state.zoom = math.max(1, (state.zoom or 1) - 1)
    draw()
  end, "zoom out")
end

---@param opts? { text?: string, line1?: integer, line2?: integer, zoom?: integer }
function M.open(opts)
  opts = opts or {}
  M.ensure_setup()
  local text = resolve_text(opts)
  text = vim.trim(text or "")
  if text == "" then
    vim.notify(i18n.t("empty"), vim.log.levels.WARN)
    return
  end
  local matrix, err = generate_matrix(text)
  if not matrix then
    vim.notify(i18n.t("gen_fail") .. tostring(err), vim.log.levels.ERROR)
    return
  end

  close_ui()
  ensure_hl()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "qrbuf"
  pcall(vim.api.nvim_buf_set_name, buf, "qrbuf://qr")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 40,
    height = 20,
    row = 2,
    col = 4,
    style = "minimal",
    border = config.border or "rounded",
    title = i18n.t("title"),
    title_pos = "center",
    zindex = 60,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight =
      "Normal:QrbufNormal,NormalFloat:QrbufNormal,FloatBorder:QrbufBorder,FloatTitle:QrbufTitle"
  end)

  state.buf = buf
  state.win = win
  state.text = text
  state.matrix = matrix
  -- 初始 zoom：配置值，但不超过屏幕能容纳的最大等比缩放
  state.zoom = clamp_zoom(opts.zoom or config.zoom or 1)
  bind(buf)
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].linebreak = false
  end)
  draw()
end

local function apply_keys()
  for _, item in ipairs(keys_applied) do
    if type(item) == "table" then
      pcall(vim.keymap.del, item.mode, item.lhs)
    else
      pcall(vim.keymap.del, "n", item)
    end
  end
  keys_applied = {}
  local lhs = config.keys_open
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, function()
      M.open({})
    end, { silent = true, desc = "qrbuf: open QR" })
    keys_applied[#keys_applied + 1] = { mode = "n", lhs = lhs }

    -- visual / select：用选中文字生成二维码（先抓选区再退出 visual）
    vim.keymap.set({ "v", "x" }, lhs, function()
      M.open_visual()
    end, { silent = true, desc = "qrbuf: QR from selection" })
    keys_applied[#keys_applied + 1] = { mode = "v", lhs = lhs }
    keys_applied[#keys_applied + 1] = { mode = "x", lhs = lhs }
  end
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
  apply_keys()
  setup_done = true
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

return M
