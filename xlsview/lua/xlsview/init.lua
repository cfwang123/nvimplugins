---@mod xlsview
--- 打开 xlsx 进入表格预览：样式 / 多工作表
local config = require("xlsview.config")
local extract_mod = require("xlsview.extract")
local render_mod = require("xlsview.render")
local highlight = require("xlsview.highlight")

local M = {}

---@type table<integer, table>
local states = {}
local auto_installed = false

local function is_xls_path(path)
  return extract_mod.is_supported(path)
end

local function get_state(buf)
  return states[buf]
end

local function win_width(buf)
  local w = vim.fn.bufwinid(buf)
  if w ~= -1 and vim.api.nvim_win_is_valid(w) then
    return math.max(20, vim.api.nvim_win_get_width(w))
  end
  return math.max(20, vim.o.columns - 2)
end

local function apply_winopts(win, cfg)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for k, v in pairs(cfg.winopts or {}) do
    pcall(function()
      vim.wo[win][k] = v
    end)
  end
end

local function do_render(st)
  if not st or not st.buf or not vim.api.nvim_buf_is_valid(st.buf) or not st.data then
    return
  end
  local cfg = config.get()
  local width = win_width(st.buf)
  st.width = width
  local result = render_mod.render(st.data, {
    width = width,
    cfg = cfg,
    sheet_index = st.sheet_index or 1,
  })
  st.result = result
  render_mod.apply(st.buf, result)
end

local function attach_maps(st)
  local buf = st.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if st.maps_version == 1 then
    return
  end
  st.maps_version = 1
  local opts = { buffer = buf, silent = true, nowait = true }

  pcall(function()
    if not tostring(vim.o.mouse or ""):find("a", 1, true) then
      vim.o.mouse = "a"
    end
  end)

  local function with_st(fn)
    return function()
      local s = get_state(buf)
      if s then
        fn(s)
      end
    end
  end

  vim.keymap.set("n", "q", with_st(function(s)
    M.close(s.buf)
  end), opts)
  vim.keymap.set("n", "<Esc>", with_st(function(s)
    M.close(s.buf)
  end), opts)
  vim.keymap.set("n", "r", with_st(function(s)
    M.refresh(s.buf, true)
  end), opts)

  local function next_sheet(s, delta)
    local n = s.data and s.data.sheet_count or #(s.data and s.data.sheets or {})
    if n < 1 then
      return
    end
    local i = (s.sheet_index or 1) + delta
    if i < 1 then
      i = n
    elseif i > n then
      i = 1
    end
    s.sheet_index = i
    do_render(s)
    local name = (s.data.sheets[i] and s.data.sheets[i].name) or tostring(i)
    local i18n = require("xlsview.i18n")
    pcall(vim.api.nvim_echo, {
      { string.format(i18n.t("sheet_echo"), i, n, name), "MoreMsg" },
    }, false, {})
  end

  vim.keymap.set("n", "n", with_st(function(s)
    next_sheet(s, 1)
  end), opts)
  vim.keymap.set("n", "]", with_st(function(s)
    next_sheet(s, 1)
  end), opts)
  vim.keymap.set("n", "gt", with_st(function(s)
    next_sheet(s, 1)
  end), opts)
  vim.keymap.set("n", "p", with_st(function(s)
    next_sheet(s, -1)
  end), opts)
  vim.keymap.set("n", "[", with_st(function(s)
    next_sheet(s, -1)
  end), opts)
  vim.keymap.set("n", "gT", with_st(function(s)
    next_sheet(s, -1)
  end), opts)

  for d = 1, 9 do
    vim.keymap.set("n", tostring(d), with_st(function(s)
      local n = s.data and s.data.sheet_count or 0
      if d <= n then
        s.sheet_index = d
        do_render(s)
      end
    end), opts)
  end

  vim.keymap.set("n", "?", function()
    require("xlsview.help").toggle_float()
  end, opts)

  vim.keymap.set("n", "L", function()
    M.toggle_ui_lang()
  end, vim.tbl_extend("force", opts, { desc = "xlsview: toggle UI language" }))

  vim.keymap.set("n", "<CR>", with_st(function(s)
    M._activate(s)
  end), opts)

  local function on_click()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
        local s = get_state(buf)
        if s then
          M._activate(s)
        end
      end
    end)
  end
  vim.keymap.set("n", "<LeftRelease>", on_click, opts)
  vim.keymap.set("n", "<2-LeftMouse>", on_click, opts)
end

local function attach_autocmds(st)
  if st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
  end
  local buf = st.buf
  local aug = vim.api.nvim_create_augroup("XlsView_" .. buf, { clear = true })
  st.au_group = aug
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = aug,
    buffer = buf,
    callback = function()
      if st.resize_timer then
        pcall(function()
          st.resize_timer:stop()
          st.resize_timer:close()
        end)
      end
      states[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) or vim.fn.bufwinid(buf) == -1 then
        return
      end
      local nw = win_width(buf)
      if st.width and math.abs(nw - st.width) < 2 then
        return
      end
      if st.resize_timer then
        pcall(function()
          st.resize_timer:stop()
        end)
      end
      local timer = vim.uv.new_timer()
      st.resize_timer = timer
      if timer then
        timer:start(120, 0, function()
          vim.schedule(function()
            local s = get_state(buf)
            if s and s.data then
              do_render(s)
            end
          end)
        end)
      end
    end,
  })
end

local function prep_buf(buf)
  pcall(function()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    vim.bo[buf].filetype = "xlsview"
  end)
  vim.b[buf].xlsview_preview = true
end

function M._activate(st)
  if not st or not st.result then
    return
  end
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
  end
  local cur = vim.api.nvim_win_get_cursor(win)
  local row, col = cur[1], cur[2]
  for _, h in ipairs(st.result.hits or {}) do
    if h.kind == "sheet" and h.line == row then
      if h.col == nil or (col >= (h.col or 0) and col < (h.end_col or math.huge)) then
        st.sheet_index = h.sheet
        do_render(st)
        return
      end
    end
  end
end

function M.open(path, opts)
  opts = opts or {}
  config.ensure_setup()
  highlight.setup(config.get().highlights)
  highlight.ensure()

  path = path and path ~= "" and path or vim.fn.expand("%:p")
  path = vim.fn.fnamemodify(path, ":p")
  local i18n = require("xlsview.i18n")
  if not is_xls_path(path) then
    vim.notify(i18n.t("not_xlsx") .. tostring(path), vim.log.levels.WARN)
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify(i18n.t("not_found") .. path, vim.log.levels.ERROR)
    return
  end

  local win = opts.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  for b, st in pairs(states) do
    if st.path == path and vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_win_set_buf(win, b)
      apply_winopts(win, config.get())
      st.win = win
      if opts.force then
        M.refresh(b, true)
      end
      return b
    end
  end

  vim.notify(i18n.t("extracting"), vim.log.levels.INFO)
  local data, err = extract_mod.extract(path, opts.force)
  if not data then
    vim.notify(i18n.t("err") .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local buf = vim.api.nvim_create_buf(true, false)
  prep_buf(buf)
  pcall(vim.api.nvim_buf_set_name, buf, path .. " [xlsview]")

  local st = {
    buf = buf,
    win = win,
    path = path,
    data = data,
    sheet_index = 1,
    result = nil,
    width = nil,
    maps_version = 0,
  }
  states[buf] = st

  vim.api.nvim_win_set_buf(win, buf)
  apply_winopts(win, config.get())
  do_render(st)
  attach_maps(st)
  attach_autocmds(st)

  local n = data.sheet_count or #(data.sheets or {})
  pcall(vim.api.nvim_echo, {
    {
      string.format(i18n.t("open_echo"), vim.fn.fnamemodify(path, ":t"), n),
      "MoreMsg",
    },
  }, false, {})
  return buf
end

function M.close(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = states[buf]
  require("xlsview.help").close()
  if st and st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
  end
  states[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].xlsview_preview then
    local wins = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        wins[#wins + 1] = w
      end
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    for _, w in ipairs(wins) do
      if vim.api.nvim_win_is_valid(w) then
        pcall(function()
          vim.api.nvim_win_call(w, function()
            vim.cmd("enew")
          end)
        end)
      end
    end
  end
end

function M.refresh(buf, force)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = states[buf]
  if not st then
    return
  end
  local i18n = require("xlsview.i18n")
  local data, err = extract_mod.extract(st.path, force)
  if not data then
    vim.notify(i18n.t("err") .. tostring(err), vim.log.levels.ERROR)
    return
  end
  st.data = data
  local n = data.sheet_count or 1
  st.sheet_index = math.min(st.sheet_index or 1, n)
  do_render(st)
  vim.notify(i18n.t("refreshed"), vim.log.levels.INFO)
end

---切换中/英文并重绘所有预览
function M.toggle_ui_lang()
  local i18n = require("xlsview.i18n")
  local next_lang = i18n.toggle()
  i18n.save_prefs()
  if next_lang == "en" then
    vim.notify(i18n.t("lang_to_en"), vim.log.levels.INFO)
  else
    vim.notify(i18n.t("lang_to_zh"), vim.log.levels.INFO)
  end
  local help = require("xlsview.help")
  local help_was = help.is_open and help.is_open()
  if help_was then
    help.close()
  end
  for b, st in pairs(states) do
    if st and vim.api.nvim_buf_is_valid(b) then
      pcall(do_render, st)
    end
  end
  if help_was then
    help.toggle_float()
  end
end

function M.setup(user)
  config.setup(user)
  highlight.setup(config.get().highlights)
  M._install_auto()
  return config.get()
end

function M.ensure_setup()
  config.ensure_setup()
  highlight.ensure()
  pcall(function()
    require("xlsview.zipfix").install()
  end)
  M._install_auto()
end

function M._install_auto()
  if auto_installed then
    return
  end
  auto_installed = true
  local aug = vim.api.nvim_create_augroup("XlsViewAuto", { clear = true })
  local pats = { "*.xlsx", "*.XLSX", "*.xlsm", "*.XLSM", "*.xltx", "*.XLTX", "*.xltm", "*.XLTM" }

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = pats,
    nested = true,
    desc = "xlsview: open workbook without zip#Browse",
    callback = function(args)
      local cfg = config.get()
      local path = vim.fn.fnamemodify(args.file ~= "" and args.file or args.match, ":p")
      pcall(vim.api.nvim_buf_set_lines, args.buf, 0, -1, false, {
        cfg.auto_open == false and "xlsview: auto_open=false · :XlsView" or "xlsview: loading…",
        path,
      })
      pcall(function()
        vim.bo[args.buf].buftype = "nofile"
        vim.bo[args.buf].swapfile = false
        vim.bo[args.buf].modifiable = false
        vim.b[args.buf].xlsview_skip = true
      end)
      if cfg.auto_open == false then
        return
      end
      vim.schedule(function()
        local win = vim.fn.bufwinid(args.buf)
        if win == -1 then
          win = vim.api.nvim_get_current_win()
        end
        local opened = M.open(path, { win = win })
        if opened and vim.api.nvim_buf_is_valid(args.buf) and args.buf ~= opened then
          pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = aug,
    pattern = pats,
    callback = function(args)
      local cfg = config.get()
      if cfg.auto_open == false then
        return
      end
      local buf = args.buf
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.b[buf].xlsview_preview or vim.b[buf].xlsview_skip then
        return
      end
      local path = vim.api.nvim_buf_get_name(buf)
      if not is_xls_path(path) then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].xlsview_preview then
          return
        end
        local win = vim.fn.bufwinid(buf)
        if win == -1 then
          win = vim.api.nvim_get_current_win()
        end
        local opened = M.open(path, { win = win })
        if opened and vim.api.nvim_buf_is_valid(buf) and buf ~= opened then
          vim.b[buf].xlsview_skip = true
          pcall(function()
            local still = false
            for _, w in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_get_buf(w) == buf then
                still = true
                break
              end
            end
            if not still then
              pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
          end)
        end
      end)
    end,
  })
end

return M
