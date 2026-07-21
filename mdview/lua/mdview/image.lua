---@mod mdview.image
--- 预览内 █ 缩略；float 大图：█ 底层 + 终端支持时高清叠层
local highlight = require("mdview.highlight")

local M = {}

local BLOCK = "█"
local BLOCK_BYTES = #BLOCK -- UTF-8 3 bytes

local float_state = {
  win = nil,
  buf = nil,
  path = nil,
  graphics = false, ---@type boolean float 高清叠层是否挂上
  resize_au = nil,
}

---用系统默认程序打开本地图片路径
---@param path string
function M.open_with_system(path)
  if not path or path == "" then
    vim.notify("mdview: no image path", vim.log.levels.WARN)
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify("mdview: image not found: " .. path, vim.log.levels.ERROR)
    return
  end
  if vim.ui and vim.ui.open then
    local ok, err = pcall(vim.ui.open, path)
    if ok then
      return
    end
    vim.notify("mdview: open failed: " .. tostring(err), vim.log.levels.WARN)
  end
  if vim.fn.has("win32") == 1 then
    vim.fn.jobstart({ "cmd", "/c", "start", "", path }, { detach = true })
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", path }, { detach = true })
  else
    vim.fn.jobstart({ "xdg-open", path }, { detach = true })
  end
end

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

---@param src string
---@param md_path string|nil
---@return string|nil abs, string|nil err
function M.resolve_path(src, md_path)
  if not src or src == "" then
    return nil, "empty src"
  end
  if src:match("^%w+://") then
    return nil, "remote not supported"
  end
  if src:match("^[A-Za-z]:[\\/]") or src:sub(1, 1) == "/" then
    return vim.fn.fnamemodify(src, ":p"), nil
  end
  local base = md_path and vim.fn.fnamemodify(md_path, ":h") or vim.fn.getcwd()
  local abs = vim.fn.fnamemodify(base .. "/" .. src, ":p")
  return abs, nil
end

local function file_exists(path)
  return path and vim.fn.filereadable(path) == 1
end

local function python_cmd(cfg)
  local py = (cfg.image and cfg.image.python) or "python"
  if vim.fn.executable(py) == 1 then
    return py
  end
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  return nil
end

local function strip_cr(s)
  if not s then
    return s
  end
  -- 去 CR / UTF-8 BOM
  return (s:gsub("\r$", ""):gsub("^\239\187\191", ""))
end

---规范化 systemlist 输出（Windows 去 \r）
---@param out string[]|nil
---@return string[]
local function normalize_out(out)
  local t = {}
  if type(out) ~= "table" then
    return t
  end
  for _, line in ipairs(out) do
    t[#t + 1] = strip_cr(tostring(line))
  end
  return t
end

---已注册的真彩色 hl 缓存 hex6 -> group name
local truecolor_hl = {}
---缩略结果缓存 key -> { lines, marks, width, height }
local thumb_cache = {}

local function ensure_truecolor_hl(hex6)
  hex6 = (hex6 or "808080"):lower():gsub("^#", "")
  if not hex6:match("^%x%x%x%x%x%x$") then
    hex6 = "808080"
  end
  local name = "MdViewTC_" .. hex6
  local color = "#" .. hex6
  -- 每次都 set_hl：折叠重渲时组可能被清空，仅 hlexists 会留下灰色 █
  pcall(vim.api.nvim_set_hl, 0, name, { fg = color, default = false })
  truecolor_hl[hex6] = name
  return name
end

---重应用 marks 上的真彩色（缓存命中时必须调用）
local function reapply_mark_colors(marks)
  for _, m in ipairs(marks or {}) do
    if m.hl and type(m.hl) == "string" then
      local hex = m.hl:match("^MdViewTC_(%x%x%x%x%x%x)$")
      if hex then
        ensure_truecolor_hl(hex)
      end
    end
  end
end

---解析 MDVIEW_THUMB2 真彩协议（优先）或旧 THUMB1
---@param out string[]
---@return table|nil { lines, marks, width, height }
local function parse_thumb_protocol(out)
  out = normalize_out(out)
  if not out or #out < 3 then
    return nil
  end

  local start = 1
  while start <= #out and out[start] == "" do
    start = start + 1
  end
  local magic = out[start] or ""

  -- 真彩色：每格直接 rrggbb，避免调色板聚类色偏
  if magic:match("MDVIEW_THUMB2") then
    local hdr = out[start + 1]
    if not hdr then
      return nil
    end
    local w, h = hdr:match("^(%d+)%s+(%d+)$")
    w, h = tonumber(w), tonumber(h)
    if not w or not h or w < 1 or h < 1 then
      return nil
    end
    highlight.ensure()
    local lines = {}
    local marks = {}
    for y = 1, h do
      local line = out[start + 1 + y]
      if not line then
        return nil
      end
      local hexes = {}
      for hex in line:gmatch("%x%x%x%x%x%x") do
        hexes[#hexes + 1] = hex:lower()
      end
      while #hexes < w do
        hexes[#hexes + 1] = "808080"
      end
      lines[y] = string.rep(BLOCK, w)
      local x = 1
      while x <= w do
        local hex = hexes[x] or "808080"
        local x2 = x + 1
        while x2 <= w and (hexes[x2] or "") == hex do
          x2 = x2 + 1
        end
        local hl = ensure_truecolor_hl(hex)
        marks[#marks + 1] = {
          row = y - 1,
          col = (x - 1) * BLOCK_BYTES,
          end_col = (x2 - 1) * BLOCK_BYTES,
          hl = hl,
        }
        x = x2
      end
    end
    return { lines = lines, marks = marks, width = w, height = h }
  end

  -- 兼容旧 THUMB1 调色板协议
  if not magic:match("MDVIEW_THUMB1") then
    return nil
  end
  local hdr = out[start + 1]
  if not hdr then
    return nil
  end
  local w, h, n = hdr:match("^(%d+)%s+(%d+)%s+(%d+)$")
  w, h, n = tonumber(w), tonumber(h), tonumber(n)
  if not w or not h or not n or n < 1 then
    return nil
  end
  local base = start + 1
  local palette = {}
  for i = 1, n do
    local line = out[base + i]
    if not line then
      return nil
    end
    local r, g, b = line:match("^(%d+)%s+(%d+)%s+(%d+)$")
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if not r then
      return nil
    end
    palette[i] = { r = r, g = g, b = b }
  end
  highlight.ensure()
  for i = 0, n - 1 do
    local c = palette[i + 1]
    local hex = string.format("#%02x%02x%02x", c.r or 0, c.g or 0, c.b or 0)
    vim.api.nvim_set_hl(0, "MdViewImg" .. i, { fg = hex, default = false })
  end
  local lines = {}
  local marks = {}
  for y = 1, h do
    local line = out[base + n + y]
    if not line then
      return nil
    end
    local row = {}
    for num in line:gmatch("%d+") do
      row[#row + 1] = tonumber(num)
    end
    while #row < w do
      row[#row + 1] = 0
    end
    lines[y] = string.rep(BLOCK, w)
    local x = 1
    while x <= w do
      local idx = row[x] or 0
      local x2 = x + 1
      while x2 <= w and (row[x2] or 0) == idx do
        x2 = x2 + 1
      end
      marks[#marks + 1] = {
        row = y - 1,
        col = (x - 1) * BLOCK_BYTES,
        end_col = (x2 - 1) * BLOCK_BYTES,
        hl = "MdViewImg" .. tostring(idx),
      }
      x = x2
    end
  end
  return { lines = lines, marks = marks, width = w, height = h }
end

---渲染缩略：宽 100%，高度按原图比例；仅 █，最多 palette_size 色
---@param abs_path string
---@param full_w number 目标列数（预览宽 100%）
---@param max_h number|nil 高度上限；nil/0 不限制（仅受比例约束）
---@param cfg table
---@return table|nil { lines, marks, palette, width, height }
function M.render_thumb(abs_path, full_w, max_h, cfg)
  if not file_exists(abs_path) then
    return nil
  end
  -- float 可用更大网格；上限约编辑器列数
  local max_cols = math.max(120, (vim.o.columns or 120) + 20)
  full_w = math.max(4, math.min(full_w or 40, max_cols))
  if max_h ~= nil and max_h > 0 then
    max_h = math.max(1, max_h)
  else
    max_h = 0 -- thumb.py：0 = 不限制高度
  end
  -- width_full=宽100%高按视觉比例；stretch/fill=拉满盒子；fit=盒内等比
  local scale_mode = (cfg.image and cfg.image.thumb_scale) or "width_full"
  if scale_mode == "fill" then
    scale_mode = "stretch"
  end
  -- 终端单元格宽/高（常见 ~0.5，修正 █ 网格正方形假设导致的纵向拉伸）
  local cell_aspect = (cfg.image and cfg.image.cell_aspect) or 0.5
  if type(cell_aspect) ~= "number" or cell_aspect <= 0 then
    cell_aspect = 0.5
  end

  local path_arg = abs_path:gsub("\\", "/")
  local mtime = 0
  pcall(function()
    mtime = vim.fn.getftime(abs_path) or 0
  end)
  local ckey = table.concat({
    path_arg,
    tostring(full_w),
    tostring(max_h),
    scale_mode,
    tostring(cell_aspect),
    tostring(mtime),
  }, "\0")
  local cached = thumb_cache[ckey]
  if cached and cached.lines and cached.marks then
    reapply_mark_colors(cached.marks)
    return {
      lines = cached.lines,
      marks = cached.marks,
      width = cached.width,
      height = cached.height,
    }
  end

  -- 字符画仅 Python+Pillow（scripts/thumb.py），不再依赖 chafa
  local backend = (cfg.image and cfg.image.backend) or "python"
  if backend == "none" then
    return nil
  end

  local py = python_cmd(cfg)
  local script = plugin_root() .. "/scripts/thumb.py"
  script = vim.fn.fnamemodify(script, ":p")
  if not py or vim.fn.filereadable(script) ~= 1 then
    return nil
  end
  local cmd = {
    py,
    "-X",
    "utf8",
    script,
    path_arg,
    tostring(full_w),
    tostring(max_h),
    (scale_mode == "stretch" and "stretch")
      or (scale_mode == "fit" and "fit")
      or "width_full",
    tostring(cell_aspect),
  }
  local ok, out = pcall(vim.fn.systemlist, cmd)
  if ok and type(out) == "table" then
    local parsed = parse_thumb_protocol(out)
    if parsed then
      reapply_mark_colors(parsed.marks)
      local result = {
        lines = parsed.lines,
        marks = parsed.marks,
        width = parsed.width,
        height = parsed.height,
      }
      thumb_cache[ckey] = result
      -- 简单限量
      local n = 0
      for _ in pairs(thumb_cache) do
        n = n + 1
      end
      if n > 40 then
        thumb_cache = { [ckey] = result }
      end
      return result
    end
  end

  return nil
end

function M.close_float()
  if float_state.resize_au then
    pcall(vim.api.nvim_del_autocmd, float_state.resize_au)
    float_state.resize_au = nil
  end
  if float_state.au then
    pcall(vim.api.nvim_del_autocmd, float_state.au)
    float_state.au = nil
  end
  if float_state.leave_au then
    pcall(vim.api.nvim_del_autocmd, float_state.leave_au)
    float_state.leave_au = nil
  end
  -- 先清 float 高清叠层
  if float_state.buf then
    pcall(function()
      require("mdview.graphics").clear_buf(float_state.buf)
    end)
  end
  pcall(function()
    require("mdview.graphics").clear_all()
  end)
  if float_state.win and vim.api.nvim_win_is_valid(float_state.win) then
    pcall(vim.api.nvim_win_close, float_state.win, true)
  end
  if float_state.buf and vim.api.nvim_buf_is_valid(float_state.buf) then
    pcall(vim.api.nvim_buf_delete, float_state.buf, { force = true })
  end
  float_state.win = nil
  float_state.buf = nil
  float_state.path = nil
  float_state.graphics = false
end

local function editor_size()
  local ui = vim.api.nvim_list_uis()[1]
  if ui then
    return ui.width, ui.height
  end
  return vim.o.columns, vim.o.lines
end

---@param win integer
---@param buf integer
---@param title string
---@param abs_path string|nil
local function setup_float_chrome(win, buf, title, abs_path)
  -- 只在 border title 放提示；不用 winbar，避免占掉内容行导致高清叠层相对 █ 偏移
  pcall(vim.api.nvim_win_set_config, win, {
    title = " " .. title .. "  [X]  q/Esc  o ",
    title_pos = "center",
  })
  pcall(function()
    vim.wo[win].winbar = ""
  end)

  local function map_close(b)
    if not b or not vim.api.nvim_buf_is_valid(b) then
      return
    end
    local opts = { buffer = b, silent = true, nowait = true }
    for _, key in ipairs({ "q", "<Esc>", "x", "X" }) do
      vim.keymap.set("n", key, function()
        M.close_float()
      end, opts)
    end
    -- o：系统默认程序打开原图
    vim.keymap.set("n", "o", function()
      local path = abs_path or float_state.path
      M.open_with_system(path)
    end, vim.tbl_extend("force", opts, { desc = "mdview: open image with system" }))
  end

  map_close(buf)

  -- 点击外部（焦点离开 float）自动关闭
  float_state.leave_au = vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if float_state.win and vim.api.nvim_win_is_valid(float_state.win) then
          local cur = vim.api.nvim_get_current_win()
          if cur ~= float_state.win then
            M.close_float()
          end
        end
      end)
    end,
  })

  return map_close
end

---80% 宽高 float；默认等比 fit
---@param abs_path string
---@param cfg table
---@return boolean
function M.open_float(abs_path, cfg)
  cfg = cfg or {}
  if not file_exists(abs_path) then
    vim.notify("mdview: image not found: " .. tostring(abs_path), vim.log.levels.ERROR)
    return false
  end

  M.close_float()

  local ew, eh = editor_size()
  local width = math.max(20, math.floor(ew * 0.8))
  local height = math.max(8, math.floor(eh * 0.8))
  local row = math.max(0, math.floor((eh - height) / 2) - 1)
  local col = math.max(0, math.floor((ew - width) / 2))
  local title = vim.fn.fnamemodify(abs_path, ":t")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.b[buf].mdview_image_float = true

  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. "  [X] ",
    title_pos = "center",
    zindex = 60,
  })
  if not ok_win or not win then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify(
      "mdview: failed to open image float"
        .. (ok_win == false and win and (": " .. tostring(win)) or ""),
      vim.log.levels.ERROR
    )
    return false
  end

  float_state.win = win
  float_state.buf = buf
  float_state.path = abs_path
  float_state.graphics = false

  setup_float_chrome(win, buf, title, abs_path)
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].list = false
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].statuscolumn = ""
  end)

  -- 与真实内容区一致（打开后实测宽高；无 winbar 时即整窗）
  local content_w = math.max(10, vim.api.nvim_win_get_width(win))
  local content_h = math.max(4, vim.api.nvim_win_get_height(win))
  local float_scale = (cfg.image and cfg.image.float_scale) or "fit"

  -- 不透明 float + █ 真彩（默认）。Kitty 高清在 nvim 内不可靠且会 winblend 半透明，仅显式开启时尝试
  pcall(function()
    vim.wo[win].winblend = 0
    vim.api.nvim_set_hl(0, "MdViewImageFloat", { default = false })
    -- 跟 Normal 不透明底，避免半透明叠层
    local nrm = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local bg = nrm and nrm.bg or nil
    if bg then
      vim.api.nvim_set_hl(0, "MdViewImageFloat", { bg = bg, default = false })
    else
      vim.api.nvim_set_hl(0, "MdViewImageFloat", { bg = "#1e1e1e", default = false })
    end
    vim.wo[win].winhl = "Normal:MdViewImageFloat,NormalFloat:MdViewImageFloat,EndOfBuffer:MdViewImageFloat"
  end)

  -- █ 底层（始终）
  M._fill_float_block_art(buf, abs_path, content_w, content_h, cfg, float_scale)

  -- float 高清叠层（默认 always；detect 读 float_hd，不受预览 hd=never 影响）
  local imgcfg = cfg.image or {}
  local ok_g, graphics = pcall(require, "mdview.graphics")
  if ok_g and graphics and graphics.attach_float and graphics.detect(imgcfg, "float") then
    vim.defer_fn(function()
      if not float_state.win or not vim.api.nvim_win_is_valid(float_state.win) then
        return
      end
      if not float_state.buf or not vim.api.nvim_buf_is_valid(float_state.buf) then
        return
      end
      local ok = graphics.attach_float({
        path = abs_path,
        win = float_state.win,
        buf = float_state.buf,
        scale = float_scale == "fit" and "fit" or "fill",
        python = imgcfg.python or "python",
        cfg = imgcfg,
      })
      float_state.graphics = ok and true or false
      if not ok and imgcfg.hd_debug then
        vim.notify("mdview float_hd: attach failed (Pillow/terminal?)", vim.log.levels.WARN)
      end
    end, 100)
  elseif imgcfg.hd_debug then
    local why = "no graphics module"
    if ok_g and graphics then
      why = graphics.detect(imgcfg, "float") and "no attach_float" or "detect=false"
    end
    vim.notify("mdview float_hd skip: " .. why, vim.log.levels.INFO)
  end

  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  float_state.au = vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(win),
    callback = function()
      if float_state.buf then
        pcall(function()
          require("mdview.graphics").clear_buf(float_state.buf)
        end)
      end
      if float_state.resize_au then
        pcall(vim.api.nvim_del_autocmd, float_state.resize_au)
        float_state.resize_au = nil
      end
      float_state.win = nil
      float_state.buf = nil
      float_state.path = nil
      float_state.graphics = false
      float_state.au = nil
      float_state.leave_au = nil
    end,
  })

  return true
end

---fit 时把 █ 画布 letterbox 居中到 content 盒（与高清 gfx fit 对齐）
---@param thumb table {lines, marks, width?, height?}
---@param content_w number
---@param content_h number
---@return table
local function letterbox_block_art(thumb, content_w, content_h)
  local src_lines = thumb.lines or {}
  local img_h = #src_lines
  if img_h < 1 then
    return thumb
  end
  local img_w = tonumber(thumb.width) or 0
  if img_w < 1 then
    img_w = vim.fn.strdisplaywidth(src_lines[1] or "")
  end
  content_w = math.max(1, content_w or img_w)
  content_h = math.max(1, content_h or img_h)

  local pad_top = math.max(0, math.floor((content_h - img_h) / 2))
  local pad_left = math.max(0, math.floor((content_w - img_w) / 2))
  if pad_top == 0 and pad_left == 0 and img_h >= content_h then
    -- 已铺满或更大：裁到盒高即可
    local lines = {}
    for i = 1, math.min(img_h, content_h) do
      lines[i] = src_lines[i]
    end
    local marks = {}
    for _, m in ipairs(thumb.marks or {}) do
      if m.row < #lines then
        marks[#marks + 1] = m
      end
    end
    return { lines = lines, marks = marks, width = img_w, height = #lines }
  end

  local left_pad = string.rep(" ", pad_left)
  local left_bytes = #left_pad
  local lines = {}
  for _ = 1, pad_top do
    lines[#lines + 1] = ""
  end
  for _, tl in ipairs(src_lines) do
    lines[#lines + 1] = left_pad .. tl
  end
  while #lines < content_h do
    lines[#lines + 1] = ""
  end

  local marks = {}
  for _, m in ipairs(thumb.marks or {}) do
    local row = m.row + pad_top
    if row >= 0 and row < #lines then
      marks[#marks + 1] = {
        row = row,
        col = (m.col or 0) + left_bytes,
        end_col = (m.end_col or m.col or 0) + left_bytes,
        hl = m.hl,
      }
    end
  end
  return { lines = lines, marks = marks, width = content_w, height = #lines }
end

---float 内 █ 块渲染（无高清协议时）
---@param buf integer
---@param abs_path string
---@param content_w number
---@param content_h number
---@param cfg table
---@param float_scale string
function M._fill_float_block_art(buf, abs_path, content_w, content_h, cfg, float_scale)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- fit=等比居中；fill/stretch=拉满盒子（默认 fit）
  local do_fit = float_scale == "fit"
  local thumb_scale = do_fit and "fit" or "stretch"
  local float_cfg = vim.deepcopy(cfg)
  float_cfg.image = vim.tbl_deep_extend("force", vim.deepcopy(cfg.image or {}), {
    thumb_scale = thumb_scale,
  })
  local thumb = M.render_thumb(abs_path, content_w, content_h, float_cfg)
  if thumb and thumb.lines and do_fit then
    thumb = letterbox_block_art(thumb, content_w, content_h)
  end
  local lines = {}
  if thumb and thumb.lines then
    for _, tl in ipairs(thumb.lines) do
      lines[#lines + 1] = tl
    end
  else
    lines = {
      "mdview image float",
      abs_path,
      "(need Python+Pillow，或 Kitty/WezTerm 高清协议)",
      "q/Esc 关闭 · o 系统打开",
    }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("mdview_float_img")
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  if thumb and thumb.marks then
    for _, m in ipairs(thumb.marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.row, m.col, {
        end_col = m.end_col,
        hl_group = m.hl,
      })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "mdview_image"
end

function M.open_preview(abs_path, cfg)
  cfg = cfg or {}
  local mode = cfg.image and cfg.image.open_with or "float"
  if mode == "none" then
    return false
  end
  -- imgbuf / imgterm：兼容旧配置名，均走本地 float
  if mode == "float" or mode == "imgbuf" or mode == "imgterm" then
    return M.open_float(abs_path, cfg)
  end
  if mode == "edit" then
    vim.cmd.edit(vim.fn.fnameescape(abs_path))
    return true
  end
  return M.open_float(abs_path, cfg)
end

function M.open_fullscreen(abs_path, cfg)
  return M.open_preview(abs_path, cfg)
end

return M
