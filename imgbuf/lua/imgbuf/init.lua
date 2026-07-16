---@mod imgbuf Terminal-based image preview (chafa / ANSI)
--- 用 Neovim terminal 显示图片，颜色由终端 ANSI 负责，不再创建海量 highlight 组。
local M = {}

---@class ImgbufConfig
---@field backend "auto"|"chafa"|"python"
---@field mode "block"|"half"|"braille"
---@field dither number
---@field chafa_symbols string
---@field max_width number|nil
---@field max_height number|nil
---@field python string
---@field auto_open boolean
---@field filetypes string[]
---@field mappings table<string, string>
---@field resize_debounce_ms number

local default_config = {
  backend = "auto",
  -- block = chafa 1/4 格（▘▝▖▗▀▄▌▐█）
  mode = "block",
  dither = 0.35,
  chafa_symbols = "block",
  max_width = nil,
  max_height = nil,
  python = "python",
  auto_open = true,
  filetypes = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff" },
  resize_debounce_ms = 100,
  mappings = {
    q = "close",
    r = "refresh",
    ["1"] = "mode_block",
    ["2"] = "mode_half",
    ["3"] = "mode_braille",
  },
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

---Build command argv (list form for termopen).
local function build_cmd(path, cols, rows, mode)
  local backend = resolve_backend()
  mode = mode or config.mode

  if backend == "chafa" then
    local symbols = config.chafa_symbols or "block"
    if mode == "half" then
      symbols = "half"
    elseif mode == "braille" then
      symbols = "braille"
    elseif mode == "block" then
      symbols = "block"
    end
    return {
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
      path,
    }, backend
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
  pcall(vim.keymap.set, "n", "o", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "O", "<Nop>", { buffer = buf, silent = true })
end

local function map_actions(buf)
  local actions = {
    close = function()
      pcall(vim.cmd, "bdelete!")
    end,
    refresh = function()
      M.refresh(buf)
    end,
    mode_block = function()
      M.set_mode(buf, "block")
    end,
    mode_half = function()
      M.set_mode(buf, "half")
    end,
    mode_braille = function()
      M.set_mode(buf, "braille")
    end,
  }

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
  map_no_scroll(buf)
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
      vim.notify("imgbuf: 预览为只读，不会写入原图片", vim.log.levels.WARN)
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
---@param opts? { mode?: string, win?: integer, replace_buf?: integer, close_win?: integer }
---@return integer|nil buf
function M.open(path, opts)
  M.ensure_setup()
  opts = opts or {}
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify("imgbuf: file not found: " .. path, vim.log.levels.ERROR)
    return nil
  end

  -- Never open inside NERDTree / file tree; always cover the editor pane.
  local win = find_content_win(opts.win)
  local orphan = opts.close_win

  local cols, rows, win = win_cell_size(win)
  local mode = opts.mode or config.mode
  local cmd, backend = build_cmd(path, cols, rows, mode)

  -- Fresh terminal buffer each time (term buffer cannot be cleanly re-termopen'd)
  local old_buf = opts.replace_buf
  if not old_buf or not vim.api.nvim_buf_is_valid(old_buf) then
    old_buf = vim.api.nvim_win_get_buf(win)
  end

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
    backend = backend,
    last_cols = cols,
    last_rows = rows,
    win = win,
  }
  win_preview[win] = buf
  vim.b[buf].imgbuf_path = path
  vim.b[buf].imgbuf_mode = mode
  vim.b[buf].imgbuf_backend = backend

  local job_opts = {
    cwd = vim.fn.fnamemodify(path, ":h"),
    on_exit = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        pcall(vim.cmd, "stopinsert")
        apply_term_options(buf, win)
        lock_view(win, buf)
      end)
    end,
  }

  -- termopen must run with target buffer as current in that window
  local job_id
  local ok, err = pcall(function()
    vim.api.nvim_win_call(win, function()
      job_id = vim.fn.termopen(cmd, job_opts)
    end)
  end)

  if not ok or not job_id or job_id <= 0 then
    vim.notify(
      "imgbuf: failed to start terminal: " .. tostring(err or job_id),
      vim.log.levels.ERROR
    )
    pcall(function()
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "imgbuf: failed to start preview",
        "cmd: " .. table.concat(cmd, " "),
        "err: " .. tostring(err or job_id),
        "",
        "Tips: pip install Pillow  或  安装 chafa 到 PATH",
      })
      vim.bo[buf].modifiable = false
    end)
    return buf
  end

  vim.b[buf].terminal_job_id = job_id
  vim.schedule(function()
    pcall(vim.cmd, "stopinsert")
    lock_view(win, buf)
  end)

  -- After process exits, keep buffer easy to abandon (NERDTree `o` on text files)
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      pcall(function()
        vim.bo[buf].bufhidden = "wipe"
        vim.b[buf].terminal_job_id = 0
      end)
    end,
  })

  return buf
end

function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = state_by_buf[buf]
  local path = st and st.path or vim.b[buf].imgbuf_path
  local mode = (st and st.mode) or vim.b[buf].imgbuf_mode or config.mode
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
    win = win,
    replace_buf = buf,
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
function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  vim.g.imgbuf_setup_done = true

  vim.api.nvim_create_user_command("Imgbuf", function(opts)
    local path = opts.args
    if path == nil or path == "" then
      path = vim.fn.expand("%:p")
    end
    if path == nil or path == "" then
      vim.notify("imgbuf: provide an image path", vim.log.levels.ERROR)
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
      vim.notify("imgbuf: mode must be block|half|braille", vim.log.levels.ERROR)
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

return M
