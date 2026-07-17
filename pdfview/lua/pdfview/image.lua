---@mod pdfview.image
--- 预览内图片：默认 chafa 色块；python+Pillow 回退；float 大图 + 可选高清
local highlight = require("pdfview.highlight")

local M = {}

local BLOCK = "█"
local BLOCK_BYTES = #BLOCK

local float_state = {
  win = nil,
  buf = nil,
  path = nil,
  graphics = false,
  resize_au = nil,
  leave_au = nil,
  au = nil,
}

local truecolor_hl = {}
local thumb_cache = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function strip_cr(s)
  if not s then
    return s
  end
  return (s:gsub("\r$", ""):gsub("^\239\187\191", ""))
end

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

local function python_cmd(cfg)
  local py = (cfg and cfg.image and cfg.image.python) or (cfg and cfg.python) or "python"
  if vim.fn.executable(py) == 1 then
    return py
  end
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  return nil
end

local function ensure_truecolor_hl(hex6)
  hex6 = (hex6 or "808080"):lower():gsub("^#", "")
  if not hex6:match("^%x%x%x%x%x%x$") then
    hex6 = "808080"
  end
  local name = "PdfViewImgTC_" .. hex6
  pcall(vim.api.nvim_set_hl, 0, name, { fg = "#" .. hex6, default = false })
  truecolor_hl[hex6] = name
  return name
end

local function reapply_mark_colors(marks)
  for _, m in ipairs(marks or {}) do
    if m.hl and type(m.hl) == "string" then
      local hex = m.hl:match("^PdfViewImgTC_(%x%x%x%x%x%x)$")
      if hex then
        ensure_truecolor_hl(hex)
      end
    end
  end
end

---解析 MDVIEW_THUMB2 / PDFVIEW_THUMB2
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
  if not (magic:match("THUMB2") or magic:match("PDFVIEW_THUMB2") or magic:match("MDVIEW_THUMB2")) then
    return nil
  end
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

---解析 chafa ANSI truecolor / 256 输出为 █ + marks
---@param out string[]
---@param full_w number
---@param max_h number
---@return table|nil
local function parse_chafa_ansi(out, full_w, max_h)
  out = normalize_out(out)
  if #out == 0 then
    return nil
  end
  highlight.ensure()
  local lines = {}
  local marks = {}

  for _, raw in ipairs(out) do
    if raw == "" then
      goto continue
    end
    -- 去掉 chafa 可能的结尾 reset
    local i = 1
    local n = #raw
    local row_marks = {}
    local col_cells = 0
    local cur_hex = "808080"
    local row_idx = #lines -- 0-based after push

    while i <= n do
      local c = raw:byte(i)
      if c == 27 and raw:sub(i + 1, i + 1) == "[" then -- ESC[
        local j = i + 2
        while j <= n do
          local bj = raw:byte(j)
          if bj >= 64 and bj <= 126 then -- final byte
            break
          end
          j = j + 1
        end
        local seq = raw:sub(i + 2, j - 1)
        local final = raw:sub(j, j)
        if final == "m" then
          -- SGR
          if seq == "" or seq == "0" then
            cur_hex = "808080"
          else
            -- 38;2;r;g;b
            local r, g, b = seq:match("38;2;(%d+);(%d+);(%d+)")
            if r then
              cur_hex = string.format("%02x%02x%02x", tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0)
            else
              -- 38;5;n 粗略映射
              local n256 = seq:match("38;5;(%d+)")
              if n256 then
                n256 = tonumber(n256) or 0
                if n256 < 16 then
                  local basic = {
                    "000000",
                    "800000",
                    "008000",
                    "808000",
                    "000080",
                    "800080",
                    "008080",
                    "c0c0c0",
                    "808080",
                    "ff0000",
                    "00ff00",
                    "ffff00",
                    "0000ff",
                    "ff00ff",
                    "00ffff",
                    "ffffff",
                  }
                  cur_hex = basic[n256 + 1] or "808080"
                elseif n256 < 232 then
                  local v = n256 - 16
                  local rr = math.floor(v / 36)
                  local gg = math.floor((v % 36) / 6)
                  local bb = v % 6
                  local function level(x)
                    return x == 0 and 0 or (55 + x * 40)
                  end
                  cur_hex = string.format("%02x%02x%02x", level(rr), level(gg), level(bb))
                else
                  local g = 8 + (n256 - 232) * 10
                  cur_hex = string.format("%02x%02x%02x", g, g, g)
                end
              end
            end
          end
        end
        i = j + 1
      else
        -- 可见字符（可能是多字节 UTF-8 块字符）
        local ulen = 1
        if c >= 0xF0 then
          ulen = 4
        elseif c >= 0xE0 then
          ulen = 3
        elseif c >= 0xC0 then
          ulen = 2
        end
        local ch = raw:sub(i, i + ulen - 1)
        if ch ~= "\n" and ch ~= "\r" then
          col_cells = col_cells + 1
          row_marks[#row_marks + 1] = cur_hex
        end
        i = i + ulen
      end
    end

    if col_cells > 0 then
      local w = math.max(col_cells, full_w)
      local line = string.rep(BLOCK, w)
      lines[#lines + 1] = line
      local row = #lines - 1
      local x = 1
      while x <= #row_marks do
        local hex = row_marks[x] or "808080"
        local x2 = x + 1
        while x2 <= #row_marks and row_marks[x2] == hex do
          x2 = x2 + 1
        end
        marks[#marks + 1] = {
          row = row,
          col = (x - 1) * BLOCK_BYTES,
          end_col = math.min(#line, (x2 - 1) * BLOCK_BYTES),
          hl = ensure_truecolor_hl(hex),
        }
        x = x2
      end
      -- 补齐宽度的灰块
      if col_cells < full_w then
        marks[#marks + 1] = {
          row = row,
          col = col_cells * BLOCK_BYTES,
          end_col = full_w * BLOCK_BYTES,
          hl = ensure_truecolor_hl("404040"),
        }
      end
    end
    ::continue::
  end

  if max_h > 0 then
    while #lines > max_h do
      table.remove(lines)
    end
    local keep = {}
    for _, m in ipairs(marks) do
      if m.row < #lines then
        keep[#keep + 1] = m
      end
    end
    marks = keep
  end

  if #lines == 0 then
    return nil
  end
  return { lines = lines, marks = marks, width = full_w, height = #lines }
end

---@param path string
---@param full_w number
---@param max_h number
---@param cfg table
---@return table|nil {lines, marks, width, height}
function M.render_thumb(path, full_w, max_h, cfg)
  if not path or path == "" or vim.fn.filereadable(path) == 0 then
    return nil
  end
  full_w = math.max(4, full_w or 40)
  max_h = max_h or 0
  cfg = cfg or {}
  local imgcfg = cfg.image or {}
  local backend = imgcfg.backend or "chafa"
  local cell_aspect = tonumber(imgcfg.cell_aspect) or 0.5
  local path_arg = vim.fn.fnamemodify(path, ":p")
  local mtime = vim.fn.getftime(path_arg)
  local ckey = table.concat({
    path_arg,
    tostring(full_w),
    tostring(max_h),
    backend,
    tostring(cell_aspect),
    tostring(mtime),
  }, "\0")
  local cached = thumb_cache[ckey]
  if cached and cached.lines then
    reapply_mark_colors(cached.marks)
    return {
      lines = cached.lines,
      marks = cached.marks,
      width = cached.width,
      height = cached.height,
    }
  end

  local function store(result)
    if not result then
      return nil
    end
    thumb_cache[ckey] = result
    local n = 0
    for _ in pairs(thumb_cache) do
      n = n + 1
    end
    if n > 48 then
      thumb_cache = { [ckey] = result }
    end
    return result
  end

  local try_chafa = backend == "chafa" or backend == "auto"
  local try_python = backend == "python" or backend == "auto" or backend == "chafa"

  if try_chafa and vim.fn.executable("chafa") == 1 then
    local box_h = (max_h > 0) and max_h or math.max(4, math.floor(full_w * cell_aspect * 0.85))
    local cmd = {
      "chafa",
      "-f",
      "symbols",
      "--symbols",
      "block",
      "-s",
      string.format("%dx%d", full_w, box_h),
      "--animate",
      "off",
      "--scale",
      "max",
      "--colors",
      "full",
      path_arg,
    }
    local ok, out = pcall(vim.fn.systemlist, cmd)
    if ok and type(out) == "table" and vim.v.shell_error == 0 then
      local parsed = parse_chafa_ansi(out, full_w, max_h)
      if parsed then
        return store(parsed)
      end
    end
  end

  if try_python then
    local py = python_cmd(cfg)
    local script = plugin_root() .. "/scripts/thumb.py"
    script = vim.fn.fnamemodify(script, ":p")
    if py and vim.fn.filereadable(script) == 1 then
      local cmd = {
        py,
        "-X",
        "utf8",
        script,
        path_arg,
        tostring(full_w),
        tostring(max_h),
        "width_full",
        tostring(cell_aspect),
      }
      local ok, out = pcall(vim.fn.systemlist, cmd)
      if ok and type(out) == "table" then
        local parsed = parse_thumb_protocol(out)
        if parsed then
          reapply_mark_colors(parsed.marks)
          return store(parsed)
        end
      end
    end
  end

  -- 占位
  local ph = {
    lines = { "🖼  [image]", path_arg },
    marks = {
      { row = 0, col = 0, end_col = #"🖼  [image]", hl = "PdfViewImage" },
    },
    width = full_w,
    height = 2,
  }
  return store(ph)
end

function M.open_with_system(path)
  local i18n = require("pdfview.i18n")
  if not path or path == "" then
    vim.notify(i18n.t("img_no_path"), vim.log.levels.WARN)
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify(i18n.t("img_not_found") .. path, vim.log.levels.ERROR)
    return
  end
  if vim.ui and vim.ui.open then
    local ok = pcall(vim.ui.open, path)
    if ok then
      return
    end
  end
  if vim.fn.has("win32") == 1 then
    vim.fn.jobstart({ "cmd", "/c", "start", "", path }, { detach = true })
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", path }, { detach = true })
  else
    vim.fn.jobstart({ "xdg-open", path }, { detach = true })
  end
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
  if float_state.buf then
    pcall(function()
      require("pdfview.graphics").clear_buf(float_state.buf)
    end)
  end
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

---float 内 █ 底层
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
  local float_cfg = vim.deepcopy(cfg)
  float_cfg.image = vim.tbl_deep_extend("force", vim.deepcopy(cfg.image or {}), {
    -- float 内用固定盒：chafa/python 都按 max_h 填满
    max_height = content_h,
  })
  local thumb = M.render_thumb(abs_path, content_w, content_h, float_cfg)
  local lines = {}
  if thumb and thumb.lines then
    for _, tl in ipairs(thumb.lines) do
      lines[#lines + 1] = tl
    end
    -- 不足高度时补空行，方便高清叠层铺满
    while #lines < content_h do
      lines[#lines + 1] = string.rep(BLOCK, content_w)
    end
  else
    lines = {
      "pdfview image float",
      abs_path,
      "(need chafa / Python+Pillow / Kitty/WezTerm HD)",
      require("pdfview.i18n").t("float_hint"),
    }
  end
  pcall(function()
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
  end)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("pdfview_float_img")
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  if thumb and thumb.marks then
    for _, m in ipairs(thumb.marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.row, m.col, {
        end_col = m.end_col,
        hl_group = m.hl,
      })
    end
  end
  pcall(function()
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "pdfview_image"
  end)
end

---@param win integer
---@param buf integer
---@param title string
---@param abs_path string
local function setup_float_chrome(win, buf, title, abs_path)
  pcall(vim.api.nvim_win_set_config, win, {
    title = " " .. title .. "  [X]  q/Esc  o ",
    title_pos = "center",
  })
  pcall(function()
    vim.wo[win].winbar = ""
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].list = false
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].statuscolumn = ""
  end)

  local opts = { buffer = buf, silent = true, nowait = true }
  for _, key in ipairs({ "q", "<Esc>", "x", "X" }) do
    vim.keymap.set("n", key, function()
      M.close_float()
    end, opts)
  end
  vim.keymap.set("n", "o", function()
    M.open_with_system(abs_path or float_state.path)
  end, vim.tbl_extend("force", opts, { desc = "pdfview: open image with system" }))

  -- 焦点离开 float → 关闭
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
end

---80% 宽高 float；█ 底层 + 终端支持时 attach_float 高清（同 mdview）
---@param abs_path string
---@param cfg table|nil
---@return boolean
function M.open_float(abs_path, cfg)
  cfg = cfg or {}
  abs_path = vim.fn.fnamemodify(abs_path or "", ":p")
  if vim.fn.filereadable(abs_path) == 0 then
    vim.notify(require("pdfview.i18n").t("img_not_found") .. tostring(abs_path), vim.log.levels.ERROR)
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
  vim.b[buf].pdfview_image_float = true

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
    vim.notify(require("pdfview.i18n").t("float_fail"), vim.log.levels.ERROR)
    return false
  end

  float_state.win = win
  float_state.buf = buf
  float_state.path = abs_path
  float_state.graphics = false

  setup_float_chrome(win, buf, title, abs_path)

  -- 不透明 float 底
  pcall(function()
    vim.wo[win].winblend = 0
    local nrm = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local bg = nrm and nrm.bg or nil
    if bg then
      vim.api.nvim_set_hl(0, "PdfViewImageFloat", { bg = bg, default = false })
    else
      vim.api.nvim_set_hl(0, "PdfViewImageFloat", { bg = "#1e1e1e", default = false })
    end
    vim.wo[win].winhl = "Normal:PdfViewImageFloat,NormalFloat:PdfViewImageFloat,EndOfBuffer:PdfViewImageFloat"
  end)

  local content_w = math.max(10, vim.api.nvim_win_get_width(win))
  local content_h = math.max(4, vim.api.nvim_win_get_height(win))
  local float_scale = (cfg.image and cfg.image.float_scale) or "fill"

  -- █ 底层（始终）
  M._fill_float_block_art(buf, abs_path, content_w, content_h, cfg, float_scale)

  -- float 高清：默认 float_hd=always；detect 读 image 配置
  local imgcfg = cfg.image or {}
  local ok_g, graphics = pcall(require, "pdfview.graphics")
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
        python = imgcfg.python or cfg.python or "python",
        cfg = imgcfg,
      })
      float_state.graphics = ok and true or false
      -- WezTerm/iTerm 偶发需补一帧
      if ok and graphics._repaint_buf then
        vim.defer_fn(function()
          if float_state.buf and graphics.is_active and graphics.is_active(float_state.buf) then
            graphics._repaint_buf(float_state.buf)
          end
        end, 80)
      end
    end, 100)
  end

  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  float_state.au = vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(win),
    callback = function()
      if float_state.buf then
        pcall(function()
          require("pdfview.graphics").clear_buf(float_state.buf)
        end)
      end
      if float_state.resize_au then
        pcall(vim.api.nvim_del_autocmd, float_state.resize_au)
        float_state.resize_au = nil
      end
      if float_state.leave_au then
        pcall(vim.api.nvim_del_autocmd, float_state.leave_au)
        float_state.leave_au = nil
      end
      float_state.win = nil
      float_state.buf = nil
      float_state.path = nil
      float_state.graphics = false
      float_state.au = nil
    end,
  })

  return true
end

---与 mdview 兼容名
function M.open_preview(abs_path, cfg)
  cfg = cfg or {}
  local mode = cfg.image and cfg.image.open_with or "float"
  if mode == "none" then
    return false
  end
  return M.open_float(abs_path, cfg)
end

return M
