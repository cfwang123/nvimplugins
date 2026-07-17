---@mod imgbuf Terminal-based image preview (chafa / ANSI)
--- 字符画（chafa/python）+ 默认高清叠层（hd=always，终端支持时启用）。
local M = {}

---@class ImgbufConfig
---@field backend "auto"|"chafa"|"python"
---@field mode "block"|"half"|"braille"
---@field scale "fit"|"fill" fit=等比适配窗口，fill=拉伸铺满
---@field dither number
---@field chafa_symbols string
---@field max_width number|nil
---@field max_height number|nil
---@field python string
---@field auto_open boolean
---@field filetypes string[]
---@field mappings table<string, string>
---@field resize_debounce_ms number
---@field show_help boolean 底部按键提示行
---@field hd "always"|"never"|"auto" 默认 always：检测支持则叠高清
---@field hd_tmux boolean
---@field hd_ssh boolean

local default_config = {
  backend = "auto",
  -- block = chafa 1/4 格（▘▝▖▗▀▄▌▐█）
  mode = "block",
  -- fill = 默认拉伸铺满；fit = 等比缩放到窗口内（s 切换）
  scale = "fill",
  dither = 0.35,
  chafa_symbols = "block",
  max_width = nil,
  max_height = nil,
  python = "python",
  auto_open = true,
  show_help = true,
  -- always=默认启用高清叠层（终端支持时）；never=仅字符画
  hd = "always",
  hd_tmux = false,
  hd_ssh = false,
  filetypes = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff" },
  resize_debounce_ms = 100,
  mappings = {
    q = "close",
    r = "refresh",
    ["1"] = "mode_block",
    ["2"] = "mode_half",
    ["3"] = "mode_braille",
    s = "toggle_scale",
    o = "open_system",
    L = "toggle_lang",
  },
  --- 界面语言："auto" | "zh" | "en"；L 切换
  ui_lang = "auto",
}

local config = vim.deepcopy(default_config)
local state_by_buf = {} ---@type table<integer, table>
local resize_timers = {} ---@type table<integer, uv.uv_timer_t>
--- winid -> preview buf (for resize tracking)
local win_preview = {} ---@type table<integer, integer>
--- Guard against re-entrant fixups when reclaiming splits
local reclaiming = false

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function render_script()
  return plugin_root() .. "/scripts/render.py"
end

local function executable_on_path(name)
  return vim.fn.executable(name) == 1
end

local function is_image_path(path)
  if not path or path == "" then
    return false
  end
  local ext = path:match("%.([%w]+)$")
  if not ext then
    return false
  end
  ext = ext:lower()
  for _, e in ipairs(config.filetypes) do
    if e:lower() == ext then
      return true
    end
  end
  return false
end

local function resolve_backend()
  if config.backend == "chafa" then
    return "chafa"
  end
  if config.backend == "python" then
    return "python"
  end
  if executable_on_path("chafa") then
    return "chafa"
  end
  return "python"
end

---Sidebar / file-tree windows must never host the image preview.
local SIDEBAR_FILETYPES = {
  nerdtree = true,
  NerdTree = true,
  NvimTree = true,
  ["neo-tree"] = true,
  CHADTree = true,
  aerial = true,
  ultratree = true,
  Outline = true,
}

local function is_sidebar_win(win)
  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype or ""
  if SIDEBAR_FILETYPES[ft] then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("NERD_tree_") or name:match("NvimTree_") or name:match("neo%-tree") then
    return true
  end
  return false
end

local function is_usable_content_win(win)
  return win
    and win ~= 0
    and vim.api.nvim_win_is_valid(win)
    and not is_sidebar_win(win)
end

---Pick the window that should show the image (right editor pane), never NERDTree.
---Prefer: explicit preferred → previous window (#) → current → largest non-sidebar.
local function find_content_win(preferred)
  if is_usable_content_win(preferred) then
    return preferred
  end

  -- NERDTree `o` opens into the previous window; prefer that over a fresh split.
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if is_usable_content_win(prev) then
    return prev
  end

  local cur = vim.api.nvim_get_current_win()
  if is_usable_content_win(cur) then
    return cur
  end

  local best, best_area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_usable_content_win(win) then
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if area > best_area then
        best_area = area
        best = win
      end
    end
  end
  return best or cur
end

local function is_imgbuf_buf(buf)
  return buf
    and vim.api.nvim_buf_is_valid(buf)
    and vim.b[buf].imgbuf_preview == true
end

local function list_content_wins()
  local list = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_usable_content_win(win) then
      table.insert(list, win)
    end
  end
  return list
end

local function find_imgbuf_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_usable_content_win(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if is_imgbuf_buf(buf) then
        return win, buf
      end
    end
  end
  return nil, nil
end

---Stop terminal job and wipe preview buffer so a normal :edit can take the window.
local function abandon_imgbuf_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local jid = vim.b[buf].terminal_job_id
  if jid and jid > 0 then
    pcall(vim.fn.jobstop, jid)
  end
  state_by_buf[buf] = nil
  for w, b in pairs(win_preview) do
    if b == buf then
      win_preview[w] = nil
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---If image was opened in an extra split, close that split after moving to main pane.
local function close_orphan_split(orphan_win, keep_win)
  if not orphan_win or orphan_win == keep_win then
    return
  end
  if not vim.api.nvim_win_is_valid(orphan_win) then
    return
  end
  if is_sidebar_win(orphan_win) then
    return
  end
  -- Don't close if it would leave only sidebars (no other content win)
  local other_content = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= orphan_win and is_usable_content_win(win) then
      other_content = other_content + 1
    end
  end
  if other_content < 1 then
    return
  end
  pcall(vim.api.nvim_win_close, orphan_win, true)
end

local function win_cell_size(win)
  win = find_content_win(win)
  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  -- leave 0–1 row for status; terminal uses full cell grid
  local cols = math.max(8, width)
  local rows = math.max(4, height)
  if config.max_width then
    cols = math.min(cols, config.max_width)
  end
  if config.max_height then
    rows = math.min(rows, config.max_height)
  end
  return cols, rows, win
end

local function norm_scale(scale)
  if scale == "fill" or scale == "stretch" then
    return "fill"
  end
  return "fit"
end

---Bottom help / status text (display width capped to cols).
---@param cols number
---@param mode string
---@param scale string
---@param is_hd boolean|nil
---@return string
local function help_line_text(cols, mode, scale, is_hd)
  local i18n = require("imgbuf.i18n")
  local scale_lab = scale == "fill" and i18n.t("scale_fill") or i18n.t("scale_fit")
  local mode_lab = ({
    block = i18n.t("mode_block"),
    half = i18n.t("mode_half"),
    braille = i18n.t("mode_braille"),
  })[mode] or mode
  local hint
  if is_hd then
    hint = string.format(i18n.t("hint_hd"), scale_lab, scale_lab)
  else
    hint = string.format(i18n.t("hint_cell"), scale_lab, mode_lab, scale_lab)
  end
  cols = math.max(8, cols or 40)
  local w = vim.fn.strwidth(hint)
  if w < cols then
    hint = hint .. string.rep(" ", cols - w)
  else
    while vim.fn.strwidth(hint) > cols and #hint > 0 do
      hint = vim.fn.strcharpart(hint, 0, vim.fn.strchars(hint) - 1)
    end
    local pad = cols - vim.fn.strwidth(hint)
    if pad > 0 then
      hint = hint .. string.rep(" ", pad)
    end
  end
  return hint
end

---Write inverted help row into the terminal channel (after image).
local function send_help_line(term_chan, cols, mode, scale)
  if not term_chan or term_chan <= 0 then
    return
  end
  local hint = help_line_text(cols, mode, scale, false)
  -- reverse video bar
  local line = "\r\n\27[0m\27[7m" .. hint .. "\27[0m"
  pcall(vim.api.nvim_chan_send, term_chan, line)
end

---Build command argv (list form for jobstart).
---@param path string
---@param cols number
---@param rows number
---@param mode string
---@param scale "fit"|"fill"
---@return string[] cmd
---@return string backend
local function build_cmd(path, cols, rows, mode, scale)
  local backend = resolve_backend()
  mode = mode or config.mode
  scale = norm_scale(scale or config.scale)

  if backend == "chafa" then
    local symbols = config.chafa_symbols or "block"
    if mode == "half" then
      symbols = "half"
    elseif mode == "braille" then
      symbols = "braille"
    elseif mode == "block" then
      symbols = "block"
    end
    local cmd = {
      "chafa",
      "-f",
      "symbols",
      "--symbols",
      symbols,
      "-s",
      string.format("%dx%d", cols, rows),
      "--animate",
      "off",
      "--polite",
      "on",
    }
    if scale == "fill" then
      -- ignore aspect ratio, fill the -s box
      table.insert(cmd, "--stretch")
    else
      -- 等比适配，内容在 -s 盒内居中
      table.insert(cmd, "--scale")
      table.insert(cmd, "max")
      -- chafa 1.12+：水平/垂直居中
      table.insert(cmd, "--align")
      table.insert(cmd, "mid,mid")
    end
    table.insert(cmd, path)
    return cmd, backend
  end

  local script = render_script()
  return {
    config.python or "python",
    "-X",
    "utf8",
    script,
    path,
    "--cols",
    tostring(cols),
    "--rows",
    tostring(rows),
    "--mode",
    mode,
    "--scale",
    scale,
    "--dither",
    tostring(config.dither or 0.35),
    "--format",
    "ansi",
  }, "python"
end

local function lock_view(win, buf)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(function()
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({
        lnum = 1,
        col = 0,
        topline = 1,
        leftcol = 0,
        curswant = 0,
      })
      pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    end)
  end)
end

---恢复窗口外观，避免 winhl/winblend 残留污染其它 buffer
---@param win integer|nil
local function restore_window_chrome(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  pcall(function()
    vim.wo[win].winhl = ""
    vim.wo[win].winblend = 0
  end)
end

---关闭预览时清理图层 + 窗口样式
---@param buf integer|nil
---@param win integer|nil
local function cleanup_preview(buf, win)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(function()
      require("imgbuf.graphics").clear_buf(buf)
    end)
    local st = state_by_buf[buf]
    if st and st.win then
      win = win or st.win
    end
  end
  restore_window_chrome(win)
end

local function apply_term_options(buf, win)
  -- terminal buffer options
  pcall(function()
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "imgbuf"
    -- 禁止终端滚动历史
    vim.bo[buf].scrollback = 1
  end)

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      -- 关键清除可能残留的 HD winhl
      vim.wo[win].winhl = ""
      vim.wo[win].winblend = 0
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldcolumn = "0"
      vim.wo[win].list = false
      vim.wo[win].cursorline = false
      vim.wo[win].wrap = false
      vim.wo[win].scrolloff = 0
      vim.wo[win].sidescrolloff = 0
      vim.wo[win].statuscolumn = ""
    end)
  end

  vim.b[buf].imgbuf_preview = true
end

local function map_no_scroll(buf)
  local nop_keys = {
    "j",
    "k",
    "h",
    "l",
    "<Down>",
    "<Up>",
    "<Left>",
    "<Right>",
    "<C-d>",
    "<C-u>",
    "<C-f>",
    "<C-b>",
    "<C-e>",
    "<C-y>",
    "<PageUp>",
    "<PageDown>",
    "gg",
    "G",
    "0",
    "$",
    "w",
    "b",
    "e",
    "<ScrollWheelUp>",
    "<ScrollWheelDown>",
    "<ScrollWheelLeft>",
    "<ScrollWheelRight>",
    "<S-ScrollWheelUp>",
    "<S-ScrollWheelDown>",
    "zt",
    "zz",
    "zb",
    "H",
    "M",
    "L",
    "+",
    "-",
    "<CR>",
  }
  for _, lhs in ipairs(nop_keys) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "imgbuf: no scroll",
    })
    pcall(vim.keymap.set, "t", lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "imgbuf: no scroll",
    })
  end
  -- 禁止进入 terminal-insert（避免滚动/输入）
  pcall(vim.keymap.set, "n", "i", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "a", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "I", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "A", "<Nop>", { buffer = buf, silent = true })
  -- o 留给 open_system；O 仍禁止
  pcall(vim.keymap.set, "n", "O", "<Nop>", { buffer = buf, silent = true })
end

---用系统默认程序打开当前预览图片
---@param buf integer|nil
local function open_system(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = state_by_buf[buf]
  local path = (st and st.path) or vim.b[buf].imgbuf_path
  if not path or path == "" then
    vim.notify(require("imgbuf.i18n").t("no_path"), vim.log.levels.WARN)
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify(require("imgbuf.i18n").t("not_found") .. path, vim.log.levels.ERROR)
    return
  end
  if vim.ui and vim.ui.open then
    local ok, err = pcall(vim.ui.open, path)
    if ok then
      return
    end
    vim.notify(require("imgbuf.i18n").t("open_fail") .. tostring(err), vim.log.levels.WARN)
  end
  if vim.fn.has("win32") == 1 then
    vim.fn.jobstart({ "cmd", "/c", "start", "", path }, { detach = true })
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", path }, { detach = true })
  else
    vim.fn.jobstart({ "xdg-open", path }, { detach = true })
  end
end

local function map_actions(buf)
  local actions = {
    close = function()
      local st = state_by_buf[buf]
      local win = st and st.win or vim.fn.bufwinid(buf)
      if win == -1 then
        win = nil
      end
      cleanup_preview(buf, win)
      pcall(vim.cmd, "bdelete!")
      -- bdelete 后窗口可能还在，再清一次 winhl
      if win and vim.api.nvim_win_is_valid(win) then
        restore_window_chrome(win)
      end
    end,
    refresh = function()
      M.refresh(buf)
    end,
    mode_block = function()
      local st = state_by_buf[buf]
      if st then
        st.force_ansi = true
      end
      M.set_mode(buf, "block")
    end,
    mode_half = function()
      local st = state_by_buf[buf]
      if st then
        st.force_ansi = true
      end
      M.set_mode(buf, "half")
    end,
    mode_braille = function()
      local st = state_by_buf[buf]
      if st then
        st.force_ansi = true
      end
      M.set_mode(buf, "braille")
    end,
    toggle_scale = function()
      M.toggle_scale(buf)
    end,
    open_system = function()
      open_system(buf)
    end,
    toggle_lang = function()
      M.toggle_ui_lang(buf)
    end,
  }

  -- 先屏蔽滚动键，再挂动作（避免 o 被 Nop 覆盖）
  map_no_scroll(buf)

  for lhs, action in pairs(config.mappings or {}) do
    local fn = actions[action]
    if fn then
      vim.keymap.set("n", lhs, fn, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = "imgbuf:" .. action,
      })
    end
  end
end

local function cancel_resize_timer(key)
  local t = resize_timers[key]
  if t then
    pcall(function()
      t:stop()
      t:close()
    end)
    resize_timers[key] = nil
  end
end

local function block_writes(buf)
  if vim.b[buf].imgbuf_write_blocked then
    return
  end
  vim.b[buf].imgbuf_write_blocked = true
  vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }, {
    buffer = buf,
    callback = function()
      vim.notify(require("imgbuf.i18n").t("readonly"), vim.log.levels.WARN)
      return true
    end,
  })
end

local function attach_no_scroll(buf, win)
  if vim.b[buf].imgbuf_noscroll_attached then
    return
  end
  vim.b[buf].imgbuf_noscroll_attached = true

  local aug = vim.api.nvim_create_augroup("ImgbufNoScroll_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "TextChangedT" }, {
    group = aug,
    buffer = buf,
    callback = function()
      lock_view(win, buf)
    end,
  })
  vim.api.nvim_create_autocmd("TermEnter", {
    group = aug,
    buffer = buf,
    callback = function()
      -- 立刻退出 terminal insert 模式
      vim.schedule(function()
        pcall(vim.cmd, "stopinsert")
        lock_view(win, buf)
      end)
    end,
  })
end

local function attach_resize(buf, win)
  if vim.b[buf].imgbuf_resize_attached then
    return
  end
  vim.b[buf].imgbuf_resize_attached = true

  local aug = vim.api.nvim_create_augroup("ImgbufResize_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local w = vim.fn.bufwinid(buf)
      if w == -1 then
        return
      end
      cancel_resize_timer(buf)
      local delay = config.resize_debounce_ms or 100
      local timer = vim.uv.new_timer()
      if not timer then
        M.refresh(buf)
        return
      end
      resize_timers[buf] = timer
      timer:start(delay, 0, function()
        vim.schedule(function()
          cancel_resize_timer(buf)
          if vim.api.nvim_buf_is_valid(buf) then
            M.refresh(buf)
          end
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = aug,
    buffer = buf,
    callback = function()
      cancel_resize_timer(buf)
      state_by_buf[buf] = nil
      for w, b in pairs(win_preview) do
        if b == buf then
          win_preview[w] = nil
        end
      end
    end,
  })
end

---Start / restart terminal job drawing the image.
---Always replaces the target content window buffer — never creates a split.
---@param path string
---@param opts? { mode?: string, scale?: string, win?: integer, replace_buf?: integer, close_win?: integer, force_ansi?: boolean }
---@return integer|nil buf
function M.open(path, opts)
  M.ensure_setup()
  opts = opts or {}
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify(require("imgbuf.i18n").t("not_found") .. path, vim.log.levels.ERROR)
    return nil
  end

  -- Never open inside NERDTree / file tree; always cover the editor pane.
  local win = find_content_win(opts.win)
  local orphan = opts.close_win

  local cols, rows, win = win_cell_size(win)
  -- reserve last row for key-help bar
  local help_on = config.show_help ~= false
  local img_rows = help_on and math.max(3, rows - 1) or rows

  -- Fresh terminal buffer each time (term buffer cannot be cleanly re-termopen'd)
  local old_buf = opts.replace_buf
  if not old_buf or not vim.api.nvim_buf_is_valid(old_buf) then
    old_buf = vim.api.nvim_win_get_buf(win)
  end

  -- Carry view state across buffer rebuild (refresh / resize / scale)
  local prev = (old_buf and state_by_buf[old_buf]) or {}
  local b_mode = old_buf and vim.api.nvim_buf_is_valid(old_buf) and vim.b[old_buf].imgbuf_mode or nil
  local b_scale = old_buf and vim.api.nvim_buf_is_valid(old_buf) and vim.b[old_buf].imgbuf_scale or nil
  local mode = opts.mode or prev.mode or b_mode or config.mode
  local scale = norm_scale(opts.scale or prev.scale or b_scale or config.scale)

  -- 字符画始终为主；hd=always 时在字符画上叠像素图（见 on_exit）
  local force_ansi = opts.force_ansi
  if force_ansi == nil then
    force_ansi = prev.force_ansi
  end
  -- 默认 hd=always：终端支持时叠高清；never 关闭
  local want_hd = false
  if not force_ansi
    and config.hd ~= "never"
    and config.hd ~= false
    and config.hd ~= "none"
    and config.hd ~= "off"
  then
    local ok_g, graphics = pcall(require, "imgbuf.graphics")
    want_hd = ok_g and graphics and graphics.detect(config) and true or false
  end

  -- 清旧预览图层 + 恢复窗口样式（防止 winhl 污染）
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    cleanup_preview(old_buf, win)
  else
    restore_window_chrome(win)
  end

  local cmd, backend = build_cmd(path, cols, img_rows, mode, scale)

  -- Stop previous terminal job so nvim won't refuse :edit / force a split (E948)
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    local jid = vim.b[old_buf].terminal_job_id
    if jid and jid > 0 then
      pcall(vim.fn.jobstop, jid)
    end
  end
  local win_buf = vim.api.nvim_win_get_buf(win)
  if win_buf ~= old_buf and vim.api.nvim_buf_is_valid(win_buf) then
    local jid = vim.b[win_buf].terminal_job_id
    if jid and jid > 0 then
      pcall(vim.fn.jobstop, jid)
    end
  end

  local buf = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, buf, "imgbuf://" .. path)
  -- In-place replace only (no vsplit / split)
  vim.api.nvim_win_set_buf(win, buf)

  -- Wipe previous preview / the placeholder buffer created by :edit / BufReadCmd
  local function wipe_if_expendable(b)
    if not b or b == buf or not vim.api.nvim_buf_is_valid(b) then
      return
    end
    if vim.b[b].imgbuf_preview or vim.bo[b].buftype == "terminal" or vim.bo[b].buftype == "nofile" then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      return
    end
    -- Image path buffer created by NERDTree/edit (binary placeholder)
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= "" and is_image_path(name) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  wipe_if_expendable(old_buf)
  if win_buf ~= old_buf then
    wipe_if_expendable(win_buf)
  end

  -- Collapse accidental vertical split from tree openers
  if orphan then
    close_orphan_split(orphan, win)
  end

  apply_term_options(buf, win)
  map_actions(buf)
  block_writes(buf)
  attach_no_scroll(buf, win)
  attach_resize(buf, win)

  state_by_buf[buf] = {
    path = path,
    mode = mode,
    scale = scale,
    backend = backend,
    last_cols = cols,
    last_rows = rows,
    win = win,
    hd = false,
    want_hd = want_hd and true or false,
    force_ansi = force_ansi and true or false,
  }
  win_preview[win] = buf
  vim.b[buf].imgbuf_path = path
  vim.b[buf].imgbuf_mode = mode
  vim.b[buf].imgbuf_scale = scale
  vim.b[buf].imgbuf_backend = backend
  vim.b[buf].imgbuf_hd = false

  -- Use nvim_open_term + jobstart (not termopen):
  -- termopen closes the channel when chafa/python exits; TermRequest handlers then
  -- call nvim_chan_send → "Can't send data to closed stream".
  -- open_term keeps the display channel open after the renderer finishes.
  local term_chan
  local open_ok, open_err = pcall(function()
    vim.api.nvim_win_call(win, function()
      term_chan = vim.api.nvim_open_term(buf, {
        -- ignore key input into the synthetic terminal
        on_input = function() end,
      })
    end)
  end)

  if not open_ok or not term_chan or term_chan <= 0 then
    vim.notify(
      "imgbuf: failed to open terminal: " .. tostring(open_err or term_chan),
      vim.log.levels.ERROR
    )
    pcall(function()
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "imgbuf: failed to open terminal buffer",
        "err: " .. tostring(open_err or term_chan),
      })
      vim.bo[buf].modifiable = false
    end)
    return buf
  end

  vim.b[buf].imgbuf_term_chan = term_chan

  -- Ignore OSC/DCS TermRequest on this buffer (static image; no shell integration)
  vim.api.nvim_create_autocmd("TermRequest", {
    buffer = buf,
    callback = function()
      -- no-op: do not attempt replies on preview terminals
    end,
  })

  local function send_to_term(data)
    if not term_chan or term_chan <= 0 then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if type(data) ~= "table" or #data == 0 then
      return
    end
    -- jobstart splits on NL; rejoin. pcall avoids rare closed-stream races.
    pcall(vim.api.nvim_chan_send, term_chan, table.concat(data, "\n"))
  end

  -- Merge into current env (jobstart `env` replaces the whole environment if set)
  local job_env = vim.fn.environ()
  job_env.TERM = "xterm-256color"
  job_env.COLORTERM = "truecolor"
  job_env.FORCE_COLOR = "1"

  local job_id = vim.fn.jobstart(cmd, {
    cwd = vim.fn.fnamemodify(path, ":h"),
    -- no pty: size/mode already passed via argv; avoids extra OSC from slave side
    env = job_env,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data, _)
      send_to_term(data)
    end,
    on_stderr = function(_, data, _)
      -- chafa sometimes writes progress to stderr; ignore noise
      if not data then
        return
      end
      local msg = table.concat(data, "\n")
      if msg:match("%S") and not msg:match("^%s*$") then
        -- keep silent unless useful for debug; avoid spamming UI
      end
    end,
    on_exit = function(_, code, _)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        vim.b[buf].terminal_job_id = 0
        pcall(vim.cmd, "stopinsert")
        apply_term_options(buf, win)
        lock_view(win, buf)
        if code ~= 0 and code ~= nil then
          -- if renderer failed and buffer looks empty, show a hint once
          local lines = vim.api.nvim_buf_get_lines(buf, 0, 3, false)
          local empty = true
          for _, ln in ipairs(lines) do
            if ln and ln:match("%S") then
              empty = false
              break
            end
          end
          if empty then
            pcall(vim.api.nvim_chan_send, term_chan, string.format(
              "\r\nimgbuf: renderer exited with code %s\r\ncmd: %s\r\n",
              tostring(code),
              table.concat(cmd, " ")
            ))
          end
        end
        -- bottom key-hint bar (reserved row)
        local st = state_by_buf[buf]
        local show_hd = st and st.want_hd
        if help_on then
          -- 有 want_hd 时底栏标注（叠层成功与否都先标尝试）
          send_help_line(term_chan, cols, mode, scale)
          if show_hd then
            pcall(
              vim.api.nvim_chan_send,
              term_chan,
              "\r\n\27[0m\27[7m HD overlay: trying host graphics (iTerm/Kitty) \27[0m"
            )
          end
        end
        lock_view(win, buf)

        -- 字符画就绪后再叠高清（失败则仍显示字符画）
        if show_hd and vim.api.nvim_win_is_valid(win) then
          vim.defer_fn(function()
            if not vim.api.nvim_buf_is_valid(buf) then
              return
            end
            local ok_g, graphics = pcall(require, "imgbuf.graphics")
            if not ok_g or not graphics or not graphics.attach_overlay then
              return
            end
            if not graphics.detect(config) then
              return
            end
            local c, r = win_cell_size(win)
            local ok = graphics.attach_overlay({
              path = path,
              win = win,
              buf = buf,
              cols = c,
              rows = math.max(1, r - 1),
              scale = scale,
              python = config.python,
            })
            if ok then
              local st2 = state_by_buf[buf]
              if st2 then
                st2.hd = true
              end
              vim.b[buf].imgbuf_hd = true
            end
          end, 80)
        end
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    vim.notify(
      "imgbuf: failed to start renderer: " .. tostring(job_id),
      vim.log.levels.ERROR
    )
    pcall(function()
      vim.api.nvim_chan_send(term_chan, "imgbuf: failed to start preview process\r\n")
      vim.api.nvim_chan_send(term_chan, "cmd: " .. table.concat(cmd, " ") .. "\r\n")
      vim.api.nvim_chan_send(term_chan, "Tips: pip install Pillow  or  install chafa\r\n")
    end)
    return buf
  end

  vim.b[buf].terminal_job_id = job_id
  vim.schedule(function()
    pcall(vim.cmd, "stopinsert")
    lock_view(win, buf)
  end)

  return buf
end

function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = state_by_buf[buf]
  local path = st and st.path or vim.b[buf].imgbuf_path
  local mode = (st and st.mode) or vim.b[buf].imgbuf_mode or config.mode
  local scale = (st and st.scale) or vim.b[buf].imgbuf_scale or config.scale
  if not path then
    return
  end

  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    win = st and st.win or vim.api.nvim_get_current_win()
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  M.open(path, {
    mode = mode,
    scale = scale,
    win = win,
    replace_buf = buf,
    force_ansi = st and st.force_ansi or false,
  })
end

function M.set_mode(buf, mode)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = state_by_buf[buf]
  if not st then
    return
  end
  st.mode = mode
  st.force = true
  local map = { block = "block", half = "half", braille = "braille" }
  if map[mode] then
    config.chafa_symbols = map[mode]
  end
  M.refresh(buf)
end

---Toggle fit (keep aspect) ↔ fill (stretch to window).
---@param buf? integer
function M.toggle_scale(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = state_by_buf[buf]
  if not st then
    return
  end
  st.scale = norm_scale(st.scale) == "fit" and "fill" or "fit"
  vim.b[buf].imgbuf_scale = st.scale
  M.refresh(buf)
end

---@param buf? integer
---@param scale "fit"|"fill"
function M.set_scale(buf, scale)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = state_by_buf[buf]
  if not st then
    return
  end
  st.scale = norm_scale(scale)
  vim.b[buf].imgbuf_scale = st.scale
  M.refresh(buf)
end

function M.clipboard_to_temp()
  local tmp = vim.fn.tempname() .. "_imgbuf_clip.png"
  local py = config.python or "python"
  local code = [[
import sys
try:
    from PIL import ImageGrab, Image
except ImportError:
    print("ERROR: Pillow required", file=sys.stderr)
    sys.exit(2)
img = ImageGrab.grabclipboard()
if img is None:
    print("ERROR: clipboard has no image", file=sys.stderr)
    sys.exit(1)
if isinstance(img, list):
    if not img:
        print("ERROR: clipboard has no image", file=sys.stderr)
        sys.exit(1)
    img = Image.open(img[0])
img.convert("RGBA").save(sys.argv[1], "PNG")
]]
  local result = vim.system({ py, "-X", "utf8", "-c", code, tmp }, { text = true }):wait()
  if result.code ~= 0 then
    local err = (result.stderr ~= "" and result.stderr) or result.stdout or "clipboard grab failed"
    return nil, err:gsub("%s+$", "")
  end
  if vim.fn.filereadable(tmp) == 0 then
    return nil, "clipboard image not saved"
  end
  return tmp, nil
end

function M.open_clipboard(opts)
  local path, err = M.clipboard_to_temp()
  if not path then
    vim.notify("imgbuf: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  return M.open(path, opts)
end

---Resolve target editor window for auto-open (NERDTree `o` → cover right pane, no vsplit).
local function resolve_auto_open_wins(placeholder_buf)
  local hint = -1
  if placeholder_buf and vim.api.nvim_buf_is_valid(placeholder_buf) then
    hint = vim.fn.bufwinid(placeholder_buf)
  end

  -- Main content pane: previous window when tree is focused (NERDTree `o` semantics)
  local target = find_content_win(nil)

  local close_win = nil
  if hint ~= -1 and hint ~= target and is_usable_content_win(hint) then
    -- File was opened in a new split; put preview on the main pane and drop the split.
    close_win = hint
  elseif is_usable_content_win(hint) then
    target = hint
  end

  return target, close_win
end

---NERDTree/etc treat terminal windows as unusable → open text in a new vsplit.
---When that happens, move the text buffer onto the imgbuf window and close the split.
local function reclaim_split_onto_imgbuf(file_buf, file_win)
  if reclaiming then
    return
  end
  if not file_buf or not vim.api.nvim_buf_is_valid(file_buf) then
    return
  end
  if is_imgbuf_buf(file_buf) or vim.b[file_buf].imgbuf_placeholder then
    return
  end
  -- Only normal editable files (text / code)
  local bt = vim.bo[file_buf].buftype
  if bt ~= "" then
    return
  end
  if is_image_path(vim.api.nvim_buf_get_name(file_buf)) then
    return
  end

  local img_win, img_buf = find_imgbuf_win()
  if not img_win or not img_buf then
    return
  end
  if not file_win or not vim.api.nvim_win_is_valid(file_win) then
    file_win = vim.fn.bufwinid(file_buf)
  end
  if file_win == -1 or file_win == img_win then
    return
  end
  if is_sidebar_win(file_win) then
    return
  end

  -- Layout: tree + imgbuf + new text split  →  typically 2 content wins
  -- If user already had multiple splits (3+ content), don't force-merge.
  local content = list_content_wins()
  if #content < 2 then
    return
  end
  if #content > 2 then
    -- Still reclaim when the alternate window is exactly the image preview
    -- (NERDTree `o` failed to replace terminal and spawned a neighbor split).
    local alt = vim.fn.win_getid(vim.fn.winnr("#"))
    if alt ~= img_win and file_win ~= img_win then
      -- Only merge if file_win looks like a narrow orphan next to imgbuf:
      -- require that file buffer is not shown in any other window.
      local wins_for_buf = vim.fn.win_findbuf(file_buf)
      if #wins_for_buf ~= 1 then
        return
      end
      -- count how many content wins are imgbuf
      local img_count = 0
      for _, w in ipairs(content) do
        if is_imgbuf_buf(vim.api.nvim_win_get_buf(w)) then
          img_count = img_count + 1
        end
      end
      if img_count < 1 then
        return
      end
    end
  end

  reclaiming = true
  vim.schedule(function()
    local ok, err = pcall(function()
      if not vim.api.nvim_buf_is_valid(file_buf) then
        return
      end
      local iw = select(1, find_imgbuf_win())
      if not iw or not vim.api.nvim_win_is_valid(iw) then
        return
      end
      local fw = vim.fn.bufwinid(file_buf)
      if fw == -1 then
        fw = file_win
      end
      if not vim.api.nvim_win_is_valid(fw) or fw == iw then
        return
      end

      local old_img = vim.api.nvim_win_get_buf(iw)
      -- Put the text file into the image pane (in-place replace)
      vim.api.nvim_win_set_buf(iw, file_buf)
      if is_imgbuf_buf(old_img) then
        abandon_imgbuf_buf(old_img)
      end

      -- Close the unwanted vertical split that NERDTree created
      if vim.api.nvim_win_is_valid(fw) and fw ~= iw then
        pcall(vim.api.nvim_win_close, fw, true)
      end

      if vim.api.nvim_win_is_valid(iw) then
        vim.api.nvim_set_current_win(iw)
      end
    end)
    reclaiming = false
    if not ok then
      vim.notify("imgbuf reclaim: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end)
end

local function setup_reclaim_on_text_open()
  local aug = vim.api.nvim_create_augroup("ImgbufReclaimSplit", { clear = true })
  -- After NERDTree `o` opens a text file into a new vsplit (because prev was terminal)
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = aug,
    callback = function(ev)
      local buf = ev.buf
      if reclaiming or is_imgbuf_buf(buf) then
        return
      end
      if vim.bo[buf].buftype ~= "" then
        return
      end
      local ft = vim.bo[buf].filetype or ""
      if SIDEBAR_FILETYPES[ft] then
        return
      end
      -- Must have an active image preview to reclaim onto
      if not select(1, find_imgbuf_win()) then
        return
      end
      local win = vim.api.nvim_get_current_win()
      reclaim_split_onto_imgbuf(buf, win)
    end,
  })
end

local function setup_auto_open()
  local pat = {}
  for _, ext in ipairs(config.filetypes) do
    table.insert(pat, "*." .. ext)
    table.insert(pat, "*." .. ext:upper())
  end

  local aug = vim.api.nvim_create_augroup("ImgbufAutoOpen", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = pat,
    callback = function(ev)
      local path = ev.file
      if path == nil or path == "" then
        path = vim.api.nvim_buf_get_name(ev.buf)
      end
      -- Don't load binary into buffer
      vim.bo[ev.buf].buftype = "nofile"
      vim.bo[ev.buf].bufhidden = "wipe"
      vim.bo[ev.buf].swapfile = false
      vim.b[ev.buf].imgbuf_placeholder = true

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then
          return
        end
        local target, close_win = resolve_auto_open_wins(ev.buf)
        M.open(path, {
          win = target,
          replace_buf = ev.buf,
          close_win = close_win,
        })
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = aug,
    pattern = pat,
    callback = function(ev)
      if vim.b[ev.buf].imgbuf_preview or vim.b[ev.buf].imgbuf_placeholder then
        return
      end
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if not is_image_path(path) then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) or vim.b[ev.buf].imgbuf_preview then
          return
        end
        local target, close_win = resolve_auto_open_wins(ev.buf)
        M.open(path, {
          win = target,
          replace_buf = ev.buf,
          close_win = close_win,
        })
      end)
    end,
  })
end

---Apply config and side effects. Optional: defaults work without calling this.
---Call again anytime to change options (e.g. `setup({ mode = "half" })`).
---@param user? ImgbufConfig
---切换中/英文界面并刷新当前预览
---@param buf? integer
function M.toggle_ui_lang(buf)
  local i18n = require("imgbuf.i18n")
  local next_lang = i18n.toggle()
  i18n.save_prefs()
  if next_lang == "en" then
    vim.notify(i18n.t("lang_to_en"), vim.log.levels.INFO)
  else
    vim.notify(i18n.t("lang_to_zh"), vim.log.levels.INFO)
  end
  buf = buf or vim.api.nvim_get_current_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) and state_by_buf[buf] then
    M.refresh(buf)
  end
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  local i18n = require("imgbuf.i18n")
  local remembered = i18n.load_prefs()
  local lang_opt = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang_opt = user.ui_lang
  elseif remembered then
    lang_opt = remembered
  end
  if lang_opt == "zh" or lang_opt == "en" then
    i18n.setup(lang_opt)
  else
    i18n.setup("auto")
  end
  vim.g.imgbuf_setup_done = true

  vim.api.nvim_create_user_command("Imgbuf", function(opts)
    local path = opts.args
    if path == nil or path == "" then
      path = vim.fn.expand("%:p")
    end
    if path == nil or path == "" then
      vim.notify(require("imgbuf.i18n").t("need_path"), vim.log.levels.ERROR)
      return
    end
    M.open(path)
  end, {
    nargs = "?",
    complete = "file",
    desc = "Preview image in terminal (chafa/ANSI)",
  })

  vim.api.nvim_create_user_command("ImgbufClipboard", function()
    M.open_clipboard()
  end, { desc = "Preview clipboard image" })

  vim.api.nvim_create_user_command("ImgbufMode", function(opts)
    local mode = opts.args
    if mode ~= "block" and mode ~= "half" and mode ~= "braille" then
      vim.notify(require("imgbuf.i18n").t("bad_mode"), vim.log.levels.ERROR)
      return
    end
    M.set_mode(vim.api.nvim_get_current_buf(), mode)
  end, {
    nargs = 1,
    complete = function()
      return { "block", "half", "braille" }
    end,
  })

  vim.api.nvim_create_user_command("ImgbufRefresh", function()
    M.refresh()
  end, { desc = "Refresh imgbuf preview" })

  vim.api.nvim_create_user_command("ImgbufScale", function(opts)
    local arg = vim.trim(opts.args or ""):lower()
    if arg == "" or arg == "toggle" then
      M.toggle_scale()
      return
    end
    if arg ~= "fit" and arg ~= "fill" and arg ~= "stretch" then
      vim.notify(require("imgbuf.i18n").t("bad_scale"), vim.log.levels.ERROR)
      return
    end
    if arg == "stretch" then
      arg = "fill"
    end
    M.set_scale(nil, arg)
  end, {
    nargs = "?",
    complete = function()
      return { "fit", "fill", "toggle" }
    end,
    desc = "等比(fit) / 填充(fill) / 切换",
  })

  ---全刷屏动画压力测试（默认 10fps，模拟视频字符画路径）
  vim.api.nvim_create_user_command("ImgbufAnimTest", function(opts)
    local fps = tonumber(opts.args)
    if opts.args ~= nil and opts.args ~= "" and not fps then
      vim.notify(require("imgbuf.i18n").t("anim_arg"), vim.log.levels.ERROR)
      return
    end
    require("imgbuf.animtest").start({ fps = fps or 10 })
  end, {
    nargs = "?",
    desc = "全刷屏动画测试（默认 10fps；q 退出 Space 暂停）",
  })

  if config.auto_open then
    setup_auto_open()
  else
    -- clear previous auto_open autocmds when disabled via later setup()
    vim.api.nvim_create_augroup("ImgbufAutoOpen", { clear = true })
  end
  -- Always on: fix NERDTree `o` on text while right pane is image terminal
  setup_reclaim_on_text_open()
end

---Ensure defaults are applied once (no-op if setup already ran).
function M.ensure_setup()
  if not vim.g.imgbuf_setup_done then
    M.setup()
  end
end

function M.config()
  return config
end

---全刷屏动画压力测试（默认 10fps）
---@param opts? { fps?: number, win?: integer }
function M.anim_test(opts)
  return require("imgbuf.animtest").start(opts or { fps = 10 })
end

return M
