---@mod mdview
local config = require("mdview.config")
local parse = require("mdview.parse")
local render = require("mdview.render")
local window = require("mdview.window")
local sync = require("mdview.sync")
local highlight = require("mdview.highlight")
local image_mod = require("mdview.image")
local anchor = require("mdview.anchor")

local M = {}

--- source_buf -> state（折叠/跳转等 per-file）
local states = {}

--- tabpage -> { preview_win, preview_buf, source_buf, source_win, mode }
--- 每个 tab 最多一个 mdview 预览窗
local tab_sessions = {}

--- tabpage -> 跨文件跳转栈（md 链接跳转，供 <C-o> 回上一篇）
--- { path, source_line, preview_line, mode }
local file_nav_by_tab = {}

local follow_installed = false

-- 前向声明：do_render 内会调用 attach_maps；detach 会停外部监视
local attach_maps
local stop_external_watch

local function get_state(source_buf)
  return states[source_buf]
end

local function ensure_state(source_buf)
  local st = states[source_buf]
  if st then
    return st
  end
  st = {
    source_buf = source_buf,
    preview_buf = nil,
    source_win = nil,
    preview_win = nil,
    mode = nil, -- "single" | "side"
    result = nil,
    expanded_codes = {},
    expanded_details = {},
    jump_list = {}, ---@type {preview_line:number, source_line:number}[]
    show_help = nil, -- nil → 跟 config.show_help
    debounce = nil,
    au_group = nil,
    syncing = false,
  }
  states[source_buf] = st
  return st
end

local function is_markdown_buf(buf)
  if not buf or buf == 0 or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if window.is_preview_buf(buf) then
    return false
  end
  if vim.b[buf].mdview_toc_float or vim.b[buf].mdview_image_float or vim.b[buf].mdview_help_float then
    return false
  end
  local ft = vim.bo[buf].filetype or ""
  if ft == "markdown" or ft == "md" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name:match("%.md$") ~= nil or name:match("%.markdown$") ~= nil
end

local function tabpage()
  return vim.api.nvim_get_current_tabpage()
end

local function get_file_nav_stack()
  local t = tabpage()
  if not file_nav_by_tab[t] then
    file_nav_by_tab[t] = {}
  end
  return file_nav_by_tab[t]
end

local function get_tab_session(tab)
  return tab_sessions[tab or tabpage()]
end

local function set_tab_session(tab, sess)
  tab_sessions[tab or tabpage()] = sess
end

---卸载源 buffer 上的预览关联（保留 per-file 折叠状态）
local function detach_source_preview(st)
  if not st then
    return
  end
  if st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
    pcall(function()
      require("mdview.graphics").clear_buf(st.preview_buf)
    end)
  end
  if st.debounce then
    pcall(function()
      st.debounce:stop()
    end)
    st.debounce = nil
  end
  stop_external_watch(st)
  if st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
    st.au_group = nil
  end
  st.preview_win = nil
  st.preview_buf = nil
  st.mode = nil
end

---已注册的全局快捷键 lhs，便于 setup 重入时先卸再挂
local applied_global_keys = {}

---按 config.keys 注册全局快捷键
---@param cfg table|nil
function M._apply_global_keys(cfg)
  cfg = cfg or config.get()
  for _, lhs in ipairs(applied_global_keys) do
    pcall(vim.keymap.del, "n", lhs)
  end
  applied_global_keys = {}

  local keys = cfg.keys
  if keys == false or keys == nil then
    return
  end

  ---@param lhs string|false|nil
  ---@param rhs function
  ---@param desc string
  local function map(lhs, rhs, desc)
    if lhs == false or lhs == nil or lhs == "" then
      return
    end
    if type(lhs) ~= "string" then
      return
    end
    vim.keymap.set("n", lhs, rhs, { silent = true, desc = desc })
    applied_global_keys[#applied_global_keys + 1] = lhs
  end

  map(keys.view, function()
    M.toggle_view()
  end, "mdview: MdView（单窗预览）")

  map(keys.side, function()
    M.toggle_side()
  end, "mdview: MdSideView（侧边预览）")

  map(keys.toc, function()
    M.toggle_toc()
  end, "mdview: TOC outline float")
end

---给已打开的预览 buffer 重绑快捷键（插件热更新后）
local function rebind_all_preview_maps()
  for _, st in pairs(states) do
    if st and st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
      -- 强制下一版本重绑
      pcall(function()
        vim.b[st.preview_buf].mdview_maps_ver = nil
      end)
      attach_maps(st.preview_buf)
    end
  end
  for _, sess in pairs(tab_sessions) do
    if sess and sess.preview_buf and vim.api.nvim_buf_is_valid(sess.preview_buf) then
      pcall(function()
        vim.b[sess.preview_buf].mdview_maps_ver = nil
      end)
      attach_maps(sess.preview_buf)
    end
  end
end

function M.setup(user)
  local cfg = config.setup(user)
  highlight.setup(cfg.highlights)
  M._ensure_tab_follow()
  M._apply_global_keys(cfg)
  rebind_all_preview_maps()
  M._ensure_source_maps_au()
  pcall(function()
    require("mdview.source_mark").ensure_au()
  end)
  return cfg
end

function M.ensure_setup()
  local cfg = config.ensure_setup()
  highlight.ensure()
  M._ensure_tab_follow()
  M._apply_global_keys(cfg)
  rebind_all_preview_maps()
  M._ensure_source_maps_au()
  pcall(function()
    require("mdview.source_mark").ensure_au()
  end)
  return cfg
end

---刷新所有已打开的预览（语言切换后调用）
function M.refresh_all()
  for _, st in pairs(states) do
    if st and st.source_buf and vim.api.nvim_buf_is_valid(st.source_buf) then
      pcall(function()
        M.refresh(st.source_buf)
      end)
    end
  end
  for _, sess in pairs(tab_sessions) do
    if sess and sess.source_buf and vim.api.nvim_buf_is_valid(sess.source_buf) then
      pcall(function()
        M.refresh(sess.source_buf)
      end)
    end
  end
end

---切换中/英文界面并重绘
function M.toggle_ui_lang()
  local i18n = require("mdview.i18n")
  local next_lang = i18n.toggle()
  i18n.save_prefs()
  if next_lang == "en" then
    vim.notify(i18n.t("lang_to_en"), vim.log.levels.INFO)
  else
    vim.notify(i18n.t("lang_to_zh"), vim.log.levels.INFO)
  end
  -- 帮助浮层若开着，关了再用新语言重开
  local help = require("mdview.help")
  local help_was = help.is_open()
  if help_was then
    help.close_float()
  end
  M.refresh_all()
  if help_was then
    help.open_float()
  end
end

local function preview_width(st)
  if st.preview_win and vim.api.nvim_win_is_valid(st.preview_win) then
    return vim.api.nvim_win_get_width(st.preview_win)
  end
  return vim.api.nvim_win_get_width(0)
end

local function do_render(st)
  if not vim.api.nvim_buf_is_valid(st.source_buf) then
    return
  end
  if not st.preview_buf or not vim.api.nvim_buf_is_valid(st.preview_buf) then
    return
  end
  local cfg = config.get()
  local cols = preview_width(st)
  local blocks = parse.parse_buf(st.source_buf, cfg)
  local md_path = vim.api.nvim_buf_get_name(st.source_buf)
  local result = render.render(blocks, {
    cfg = cfg,
    width = cols,
    expanded_codes = st.expanded_codes,
    expanded_details = st.expanded_details,
    md_path = md_path,
  })
  st.result = result
  st.blocks = blocks
  st.headings = anchor.collect_headings(blocks, result.rev_map)
  -- 正文标题预览行（勿用 TOC 占位的映射）
  for _, h in ipairs(st.headings) do
    h.preview_line = (result.heading_preview and result.heading_preview[h.source_start])
      or result.rev_map[h.source_start]
      or h.preview_line
  end
  -- 帮助改为 ? float，不再在底部占行
  render.apply(st.preview_buf, result, {
    show_help = false,
    cols = cols,
  })
  st._last_preview_w = cols

  -- 预览内只用 █ 缩略；高清仅 float / 手动 gh
  pcall(function()
    require("mdview.graphics").clear_buf(st.preview_buf)
  end)

  -- 刷新键位（预览 buffer 复用时也能挂上新快捷键如 gh）
  attach_maps(st.preview_buf)

  -- 禁止水平滚动（内容已按 cols 软折行）
  if st.preview_win and vim.api.nvim_win_is_valid(st.preview_win) then
    pcall(function()
      vim.wo[st.preview_win].wrap = false
      vim.wo[st.preview_win].sidescrolloff = 0
      vim.wo[st.preview_win].list = false
    end)
  end
end

function M.refresh(source_buf)
  source_buf = source_buf or M._current_source()
  if not source_buf then
    return
  end
  local st = get_state(source_buf)
  if not st then
    return
  end
  do_render(st)
  if st.mode == "side" then
    sync.sync_from_source(st)
  end
end

---是否像 Markdown 源缓冲（编辑窗）
---@param buf integer
---@return boolean
local function is_markdown_source_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if window.is_preview_buf(buf) then
    return false
  end
  local ft = vim.bo[buf].filetype or ""
  if ft == "markdown" or ft == "md" or ft == "pandoc" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf):lower()
  return name:match("%.md$") ~= nil
    or name:match("%.markdown$") ~= nil
    or name:match("%.mdx$") ~= nil
end

---仅跳转源码窗到标题行（用 nG 写入 jumplist，便于 <C-o> 返回）
---@param st table
---@param source_line number
local function jump_source_only(st, source_line)
  if not source_line or source_line < 1 then
    return
  end
  local src = st.source_buf
  if not src or not vim.api.nvim_buf_is_valid(src) then
    return
  end
  local max_src = vim.api.nvim_buf_line_count(src)
  local line = math.max(1, math.min(source_line, max_src))
  local swin = st.source_win
  if not swin or not vim.api.nvim_win_is_valid(swin) or vim.api.nvim_win_get_buf(swin) ~= src then
    swin = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == src then
        swin = w
        break
      end
    end
  end
  if not swin then
    -- 当前窗就是源则用当前窗
    if vim.api.nvim_get_current_buf() == src then
      swin = vim.api.nvim_get_current_win()
    end
  end
  if swin and vim.api.nvim_win_is_valid(swin) then
    st.source_win = swin
    pcall(vim.api.nvim_set_current_win, swin)
    -- nG 是 jump 命令，会进入 jumplist；set_cursor 不会
    pcall(vim.api.nvim_win_call, swin, function()
      vim.cmd("normal! " .. line .. "Gzz")
    end)
  end
end

---打开 / 关闭 TOC float。
---可在预览窗（同 `t`）或 Markdown 编辑窗调用；编辑窗会按当前 buffer 解析标题。
function M.toggle_toc()
  M.ensure_setup()
  local toc = require("mdview.toc")
  if toc.is_open() then
    toc.close_float()
    return
  end

  local cur_buf = vim.api.nvim_get_current_buf()
  local cfg = config.get()
  if cfg.toc == false then
    vim.notify(require("mdview.i18n").t("toc_empty"), vim.log.levels.INFO)
    return
  end

  -- 预览窗：与 buffer-local `t` 相同
  if window.is_preview_buf(cur_buf) then
    local st = st_from_preview(cur_buf)
    if not st then
      return
    end
    toc.toggle_float(st, function(entry)
      M._jump_both(st, entry.source_start, entry.preview_line, true)
    end)
    return
  end

  if not is_markdown_source_buf(cur_buf) then
    vim.notify(require("mdview.i18n").t("need_markdown"), vim.log.levels.INFO)
    return
  end

  -- 编辑窗：用当前 buffer 解析标题（不依赖预览是否已开）
  local blocks = parse.parse_buf(cur_buf, cfg)
  local headings = toc.collect(blocks, cfg)
  local live = get_state(cur_buf)
  ---@type table
  local st = {
    source_buf = cur_buf,
    source_win = vim.api.nvim_get_current_win(),
    blocks = blocks,
    headings = headings,
    -- 若已有预览会话，带上以便跳转时双窗同步
    preview_buf = live and live.preview_buf,
    preview_win = live and live.preview_win,
    result = live and live.result,
    jump_stack = live and live.jump_stack,
    mode = live and live.mode,
  }

  toc.open_float(st, function(entry)
    local jump_st = live or st
    jump_st.source_buf = cur_buf
    if not jump_st.source_win or not vim.api.nvim_win_is_valid(jump_st.source_win) then
      jump_st.source_win = st.source_win
    end
    if jump_st.preview_win and vim.api.nvim_win_is_valid(jump_st.preview_win) and jump_st.result then
      M._jump_both(jump_st, entry.source_start, entry.preview_line, true)
    else
      jump_source_only(jump_st, entry.source_start)
    end
  end)
end

function M._current_source()
  local buf = vim.api.nvim_get_current_buf()
  if window.is_preview_buf(buf) then
    return vim.b[buf].mdview_source
  end
  -- 是否有关联
  if states[buf] then
    return buf
  end
  -- markdown 文件
  local ft = vim.bo[buf].filetype
  if ft == "markdown" or ft == "md" then
    return buf
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("%.md$") or name:match("%.markdown$") then
    return buf
  end
  return buf
end

---从预览 buffer 解析当前 state（动态，便于 tab 内切换源文件）
local function st_from_preview(pbuf)
  if not pbuf or not vim.api.nvim_buf_is_valid(pbuf) then
    return nil
  end
  local src = vim.b[pbuf].mdview_source
  if not src then
    return nil
  end
  local st = get_state(src)
  if not st then
    -- 预览仍在但 state 被卸掉：补一份，避免链接跳转退化成普通 edit
    st = ensure_state(src)
  end
  st.preview_buf = pbuf
  local sess = get_tab_session()
  if sess then
    if sess.preview_win and vim.api.nvim_win_is_valid(sess.preview_win) then
      st.preview_win = sess.preview_win
    end
    if sess.preview_buf and vim.api.nvim_buf_is_valid(sess.preview_buf) then
      st.preview_buf = sess.preview_buf
    end
    if sess.source_win and vim.api.nvim_win_is_valid(sess.source_win) then
      st.source_win = sess.source_win
    end
    -- 关键 session 恢复 mode（detach 后常为 nil，导致 md 链接无法进预览）
    if sess.mode == "side" or sess.mode == "single" then
      st.mode = sess.mode
    end
  end
  if not st.mode or (st.mode ~= "side" and st.mode ~= "single") then
    -- 根据窗口布局推断
    local pwin = st.preview_win
    if (not pwin or not vim.api.nvim_win_is_valid(pwin)) and pbuf then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == pbuf then
          pwin = w
          st.preview_win = w
          break
        end
      end
    end
    if pwin and vim.api.nvim_win_is_valid(pwin) then
      local src_win = st.source_win
      if src_win and vim.api.nvim_win_is_valid(src_win) and src_win ~= pwin then
        st.mode = "side"
      else
        -- 另有窗显示源 → side，否则 single
        local other_src = false
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if w ~= pwin and src and vim.api.nvim_win_get_buf(w) == src then
            other_src = true
            st.source_win = w
            break
          end
        end
        st.mode = other_src and "side" or "single"
      end
    else
      st.mode = "single"
    end
  end
  return st
end

---预览 buffer 键位版本：升级插件后靠重绑生效（buffer 常被复用）
local PREVIEW_MAPS_VER = 5

attach_maps = function(preview_buf)
  if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
    return
  end
  -- 版本一致才跳过；否则强制重绑（修复旧会话没有 gh 等新键）
  if vim.b[preview_buf].mdview_maps_ver == PREVIEW_MAPS_VER then
    return
  end
  vim.b[preview_buf].mdview_maps = true
  vim.b[preview_buf].mdview_maps_ver = PREVIEW_MAPS_VER
  local opts = { buffer = preview_buf, silent = true, nowait = true, noremap = true }

  local function with_st(fn)
    return function(...)
      local st = st_from_preview(preview_buf)
      if not st then
        -- 兜底：从 b.mdview_source 建 state
        local src = vim.b[preview_buf].mdview_source
        if src and vim.api.nvim_buf_is_valid(src) then
          st = ensure_state(src)
          st.preview_buf = preview_buf
          local w = vim.fn.bufwinid(preview_buf)
          if w ~= -1 then
            st.preview_win = w
          end
          if not st.mode then
            st.mode = "side"
          end
        end
      end
      if st then
        return fn(st, ...)
      end
      vim.notify(require("mdview.i18n").t("state_missing"), vim.log.levels.WARN)
    end
  end

  vim.keymap.set("n", "q", with_st(function(st)
    M.close_for(st.source_buf)
  end), vim.tbl_extend("force", opts, { desc = "mdview: close" }))

  vim.keymap.set("n", "r", with_st(function(st)
    M.refresh(st.source_buf)
  end), vim.tbl_extend("force", opts, { desc = "mdview: refresh" }))

  vim.keymap.set("n", "<CR>", with_st(function(st)
    M._activate_at_cursor(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: activate" }))

  vim.keymap.set("n", "gi", with_st(function(st)
    M._open_image_at_cursor(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: image float" }))

  -- gh：临时显示当前页高清叠层（覆盖默认 select-mode gh）
  vim.keymap.set("n", "gh", with_st(function(st)
    M._toggle_page_hd(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: page HD overlay" }))

  -- o：光标在图片上时用系统程序打开原图
  vim.keymap.set("n", "o", with_st(function(st)
    M._open_image_system_at_cursor(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: system open image" }))

  -- c：代码块内一键复制（预览只读，不占用改写语义）；yc 兼容保留
  vim.keymap.set("n", "c", with_st(function(st)
    M._yank_code_at_cursor(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: copy code block" }))

  vim.keymap.set("n", "yc", with_st(function(st)
    M._yank_code_at_cursor(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: yank code" }))

  vim.keymap.set("n", "gs", with_st(function(st)
    M._goto_source(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: goto source" }))

  vim.keymap.set("n", "go", with_st(function(st)
    if st.preview_win and vim.api.nvim_win_is_valid(st.preview_win) then
      vim.api.nvim_set_current_win(st.preview_win)
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { 1, 0 })
  end), vim.tbl_extend("force", opts, { desc = "mdview: goto TOC top" }))

  vim.keymap.set("n", "t", with_st(function(st)
    local toc = require("mdview.toc")
    toc.toggle_float(st, function(entry)
      M._jump_both(st, entry.source_start, entry.preview_line, true)
    end)
  end), vim.tbl_extend("force", opts, { desc = "mdview: outline" }))

  vim.keymap.set("n", "<C-o>", with_st(function(st)
    M._jump_back(st)
  end), vim.tbl_extend("force", opts, { desc = "mdview: jump back" }))

  vim.keymap.set("n", "?", function()
    require("mdview.help").toggle_float()
  end, vim.tbl_extend("force", opts, { desc = "mdview: help" }))

  -- L：切换中/英文界面并刷新所有预览
  vim.keymap.set("n", "L", function()
    M.toggle_ui_lang()
  end, vim.tbl_extend("force", opts, { desc = "mdview: toggle UI language" }))

  local function on_mouse_click()
    -- 立刻用 getmousepos 判定（勿等 schedule 后光标被吸到行尾导致误点链接）
    if not vim.api.nvim_buf_is_valid(preview_buf) then
      return
    end
    local st = st_from_preview(preview_buf)
    if not st then
      return
    end
    if M._activate_at_mouse(st) then
      return
    end
  end
  vim.keymap.set("n", "<LeftRelease>", on_mouse_click, opts)
  vim.keymap.set("n", "<2-LeftMouse>", on_mouse_click, opts)
end

---预览需要鼠标点击时确保 mouse 含 a/n
local mouse_saved = nil
function M.ensure_mouse()
  local m = vim.o.mouse or ""
  if not m:find("a") and not m:find("n") then
    if mouse_saved == nil then
      mouse_saved = m
    end
    vim.o.mouse = "a"
  end
end

---停止磁盘监视（uv.fs_event）
stop_external_watch = function(st)
  if not st then
    return
  end
  if st.file_watch then
    pcall(function()
      st.file_watch:stop()
      st.file_watch:close()
    end)
    st.file_watch = nil
  end
  if st.ext_debounce then
    pcall(function()
      st.ext_debounce:stop()
    end)
    st.ext_debounce = nil
  end
end

---防抖重绘预览（外部改盘后）
local function schedule_external_render(st)
  local cfg = config.get()
  if st.ext_debounce then
    pcall(function()
      st.ext_debounce:stop()
    end)
  end
  st.ext_debounce = vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(st.source_buf) then
      return
    end
    if not st.preview_buf or not vim.api.nvim_buf_is_valid(st.preview_buf) then
      return
    end
    do_render(st)
    if st.mode == "side" then
      pcall(sync.sync_from_source, st)
    end
  end, cfg.debounce_ms or 150)
end

---源 buffer 未修改时从磁盘重新读入并重绘
local function reload_source_from_disk(st)
  if not st or not vim.api.nvim_buf_is_valid(st.source_buf) then
    return
  end
  -- 有未保存修改时不覆盖用户编辑
  if vim.bo[st.source_buf].modified then
    return
  end
  local path = vim.api.nvim_buf_get_name(st.source_buf)
  if path == "" or vim.fn.filereadable(path) ~= 1 then
    return
  end
  -- 优先 checktime + autoread
  pcall(vim.cmd, "silent! checktime " .. st.source_buf)
  -- 若内容仍与磁盘不一致（部分环境下 checktime 不可靠），直接读盘
  if vim.bo[st.source_buf].modified then
    return
  end
  local ok, disk_lines = pcall(vim.fn.readfile, path)
  if not ok or type(disk_lines) ~= "table" then
    schedule_external_render(st)
    return
  end
  local cur = vim.api.nvim_buf_get_lines(st.source_buf, 0, -1, false)
  local same = #cur == #disk_lines
  if same then
    for i = 1, #disk_lines do
      if cur[i] ~= disk_lines[i] then
        same = false
        break
      end
    end
  end
  if not same then
    local was_mod = vim.bo[st.source_buf].modifiable
    vim.bo[st.source_buf].modifiable = true
    vim.api.nvim_buf_set_lines(st.source_buf, 0, -1, false, disk_lines)
    vim.bo[st.source_buf].modified = false
    if not was_mod then
      vim.bo[st.source_buf].modifiable = false
    end
  end
  schedule_external_render(st)
end

---监视源文件路径的外部写入
local function start_external_watch(st)
  stop_external_watch(st)
  local cfg = config.get()
  if cfg.watch_external == false then
    return
  end
  local path = vim.api.nvim_buf_get_name(st.source_buf)
  if path == "" or vim.fn.filereadable(path) ~= 1 then
    return
  end
  -- 便于 checktime / 外部更新
  pcall(function()
    vim.bo[st.source_buf].autoread = true
  end)
  local uv = vim.uv or vim.loop
  if not uv or not uv.new_fs_event then
    return
  end
  local handle = uv.new_fs_event()
  if not handle then
    return
  end
  st.file_watch = handle
  local ok_start = pcall(function()
    handle:start(path, {}, function(err, _fname, _status)
      if err then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(st.source_buf) then
          return
        end
        reload_source_from_disk(st)
      end)
    end)
  end)
  if not ok_start then
    stop_external_watch(st)
  end
end

local function attach_autocmds(st)
  if st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
  end
  stop_external_watch(st)
  local g = vim.api.nvim_create_augroup("mdview_" .. st.source_buf, { clear = true })
  st.au_group = g
  local cfg = config.get()

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = g,
    buffer = st.source_buf,
    callback = function()
      if st.debounce then
        st.debounce:stop()
      end
      st.debounce = vim.defer_fn(function()
        do_render(st)
        if st.mode == "side" then
          sync.sync_from_source(st)
        end
      end, cfg.debounce_ms or 150)
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = g,
    buffer = st.source_buf,
    callback = function()
      do_render(st)
      if st.mode == "side" then
        sync.sync_from_source(st)
      end
    end,
  })

  ---i / a / I / A / o 等进入插入：字节列可能不变，但插入点语义变了，需立刻刷新预览 `_`
  vim.api.nvim_create_autocmd({ "InsertEnter", "ModeChanged" }, {
    group = g,
    buffer = st.source_buf,
    callback = function(args)
      if st.mode ~= "side" or st.syncing then
        return
      end
      -- ModeChanged：仅在进出插入/替换时同步（避免噪音）
      if args.event == "ModeChanged" then
        local match = args.match or ""
        -- 如 n:i、v:i、n:R、i:n
        if not (match:match(":i") or match:match(":R") or match:match("i:") or match:match("R:")) then
          return
        end
      end
      st.syncing = true
      vim.schedule(function()
        if st.mode == "side" then
          sync.sync_from_source(st)
        end
        st.syncing = false
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = g,
    buffer = st.source_buf,
    callback = function()
      if st.mode ~= "side" or st.syncing then
        return
      end
      st.syncing = true
      vim.schedule(function()
        sync.sync_from_source(st)
        st.syncing = false
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = g,
    buffer = st.source_buf,
    callback = function()
      M.close_for(st.source_buf, true)
    end,
  })

  -- 磁盘被外部程序改写后：Neovim 重载 buffer → 重绘预览
  if cfg.watch_external ~= false then
    pcall(function()
      vim.bo[st.source_buf].autoread = true
    end)
    vim.api.nvim_create_autocmd("FileChangedShellPost", {
      group = g,
      buffer = st.source_buf,
      callback = function()
        schedule_external_render(st)
      end,
    })
    -- 重新获得焦点时 checktime（配合 autoread）
    vim.api.nvim_create_autocmd({ "FocusGained", "TermClose", "TermLeave" }, {
      group = g,
      callback = function()
        if not vim.api.nvim_buf_is_valid(st.source_buf) then
          return
        end
        if vim.bo[st.source_buf].modified then
          return
        end
        pcall(vim.cmd, "silent! checktime " .. st.source_buf)
      end,
    })
    -- 源文件改名/换路径时重挂监视
    vim.api.nvim_create_autocmd({ "BufFilePost", "FileChangedShell" }, {
      group = g,
      buffer = st.source_buf,
      callback = function()
        start_external_watch(st)
      end,
    })
    start_external_watch(st)
  end

  -- 预览窗宽度变化 → 按新宽度重排（避免水平滚动）
  vim.api.nvim_create_autocmd("WinResized", {
    group = g,
    callback = function()
      local pwin = st.preview_win
      if (not pwin or not vim.api.nvim_win_is_valid(pwin)) and st.preview_buf then
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_win_get_buf(w) == st.preview_buf then
            pwin = w
            st.preview_win = w
            break
          end
        end
      end
      if not pwin or not vim.api.nvim_win_is_valid(pwin) then
        return
      end
      -- 仅当预览窗在本次 resized 列表中，或宽度确实变了
      local resized = vim.v.event and vim.v.event.windows or {}
      local hit = false
      for _, w in ipairs(resized) do
        if w == pwin then
          hit = true
          break
        end
      end
      local wnow = vim.api.nvim_win_get_width(pwin)
      if not hit and st._last_preview_w == wnow then
        return
      end
      if st._resize_timer then
        pcall(function()
          st._resize_timer:stop()
        end)
      end
      st._resize_timer = vim.defer_fn(function()
        st._resize_timer = nil
        if not get_state(st.source_buf) then
          return
        end
        if not vim.api.nvim_win_is_valid(pwin) then
          return
        end
        local w2 = vim.api.nvim_win_get_width(pwin)
        if st._last_preview_w == w2 then
          return
        end
        do_render(st)
      end, 60)
    end,
  })

  if st.preview_buf then
    -- 焦点进入预览：去掉源码对应块高亮
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
      group = g,
      buffer = st.preview_buf,
      callback = function()
        -- 仅当焦点真在预览时清（源窗 set_cursor 到预览时不误清）
        if vim.api.nvim_get_current_buf() ~= st.preview_buf then
          return
        end
        sync.clear_block_highlight(st)
      end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = g,
      buffer = st.preview_buf,
      callback = function()
        -- 仅预览持有焦点时处理；源窗 sync 改预览光标不应清掉高亮
        if vim.api.nvim_get_current_buf() ~= st.preview_buf then
          return
        end
        sync.clear_block_highlight(st)
        if st.mode ~= "side" or st.syncing or not config.get().sync_reverse then
          return
        end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        st.syncing = true
        vim.schedule(function()
          sync.sync_from_preview(st, row)
          st.syncing = false
        end)
      end,
    })
  end
end

local HIT_PRIORITY = {
  link = 100,
  code_copy = 95, -- 顶栏 [Copy] 优先于整块折叠
  image_inline = 90,
  image = 80,
  toc = 70,
  -- 代码块优先于 details，便于块内任意位置回车折叠
  code_fold = 65,
  code_block = 60,
  details = 50,
}

function M._hit_at(st, row, col)
  if not st.result then
    return nil
  end
  col = col or 0
  local best, best_pri = nil, -1
  for _, h in ipairs(st.result.hits or {}) do
    local a = h.line
    local b = h.line_end or h.line
    if row >= a and row <= b then
      -- 有列范围则必须点在区间内（链接/行内图）
      if h.col ~= nil and h.end_col ~= nil then
        if col < h.col or col >= h.end_col then
          goto continue
        end
      end
      local pri = HIT_PRIORITY[h.kind] or 0
      if pri > best_pri then
        best = h
        best_pri = pri
      end
    end
    ::continue::
  end
  return best
end

---显示列（1-based）→ 行内字节列（0-based）。超出正文显示宽度返回 nil（行尾空白）。
---@param line_text string
---@param screen_col integer 1-based display column within line text
---@return integer|nil
local function display_col_to_byte(line_text, screen_col)
  if not line_text or screen_col < 1 then
    return nil
  end
  local disp = vim.fn.strdisplaywidth(line_text)
  if screen_col > disp then
    return nil -- 点在行尾空白，不算点中文字/链接
  end
  local d = 0
  local i = 1
  while i <= #line_text do
    local b = line_text:byte(i)
    local len = 1
    if b >= 0xF0 then
      len = 4
    elseif b >= 0xE0 then
      len = 3
    elseif b >= 0xC0 then
      len = 2
    end
    local ch = line_text:sub(i, i + len - 1)
    local w = vim.fn.strwidth(ch)
    if w < 1 then
      w = 1
    end
    if d + w >= screen_col then
      return i - 1
    end
    d = d + w
    i = i + len
  end
  return nil
end

---根据鼠标位置激活（不依赖光标被吸到行尾）
---@param st table
---@return boolean handled
function M._activate_at_mouse(st)
  if not st or not st.preview_buf or not vim.api.nvim_buf_is_valid(st.preview_buf) then
    return false
  end
  local mp = vim.fn.getmousepos()
  local win = mp.winid
  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.api.nvim_win_get_buf(win) ~= st.preview_buf then
    return false
  end
  local row = mp.line
  if row < 1 then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(st.preview_buf, row - 1, row, false)[1] or ""
  local info = vim.fn.getwininfo(win)[1] or {}
  local textoff = info.textoff or 0
  local leftcol = info.leftcol or 0
  local wpos = vim.api.nvim_win_get_position(win)
  -- 正文区显示列（1-based）：优先 screencol 推算，与 drawbuf 一致
  local vcol = (mp.screencol or 0) - wpos[2] - textoff + leftcol
  if vcol < 1 then
    vcol = (mp.wincol or 0) - textoff
  end
  if vcol < 1 then
    vcol = mp.column or 1
  end
  if vcol < 1 then
    return false
  end
  local col = display_col_to_byte(line, vcol)
  if col == nil then
    return false -- 行尾空白：不激活链接
  end
  local hit = M._hit_at(st, row, col)
  if not hit then
    return false
  end
  M._activate_hit(st, hit, row)
  return true
end

---钳制列到该行合法字节列（0-based）
---@param buf integer
---@param line number 1-based
---@param col number|nil 0-based
---@return number
local function clamp_col(buf, line, col)
  col = col or 0
  if col < 0 then
    col = 0
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return col
  end
  local lines = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)
  local text = lines[1] or ""
  local maxc = #text
  if col > maxc then
    col = maxc
  end
  return col
end

---记录跳转前位置，供 <C-o> 返回（含列）
---@param st table
local function push_jump(st)
  st.jump_list = st.jump_list or {}
  local preview_line, source_line = 1, 1
  local preview_col, source_col = 0, 0

  local pwin = st.preview_win
  if pwin and vim.api.nvim_win_is_valid(pwin) then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, pwin)
    if ok and cur then
      preview_line, preview_col = cur[1], cur[2] or 0
    end
  elseif st.preview_buf and vim.api.nvim_get_current_buf() == st.preview_buf then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
    if ok and cur then
      preview_line, preview_col = cur[1], cur[2] or 0
    end
  end

  local swin = st.source_win
  if swin and vim.api.nvim_win_is_valid(swin) then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, swin)
    if ok and cur then
      source_line, source_col = cur[1], cur[2] or 0
    end
  elseif st.result and st.result.source_map and st.result.source_map[preview_line] then
    source_line = st.result.source_map[preview_line]
  end

  st.jump_list[#st.jump_list + 1] = {
    preview_line = preview_line,
    source_line = source_line,
    preview_col = preview_col,
    source_col = source_col,
  }
  while #st.jump_list > 50 do
    table.remove(st.jump_list, 1)
  end
end

---记录「跳到另一 md 文件」前的位置（跨文件 <C-o>，含列）
---@param st table
local function push_file_nav(st)
  if not st or not st.source_buf or not vim.api.nvim_buf_is_valid(st.source_buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(st.source_buf)
  if not path or path == "" then
    return
  end
  path = vim.fn.fnamemodify(path, ":p")

  local preview_line, source_line = 1, 1
  local preview_col, source_col = 0, 0
  local pwin = st.preview_win
  if pwin and vim.api.nvim_win_is_valid(pwin) then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, pwin)
    if ok and cur then
      preview_line, preview_col = cur[1], cur[2] or 0
    end
  elseif st.preview_buf and vim.api.nvim_get_current_buf() == st.preview_buf then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
    if ok and cur then
      preview_line, preview_col = cur[1], cur[2] or 0
    end
  end
  local swin = st.source_win
  if swin and vim.api.nvim_win_is_valid(swin) then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, swin)
    if ok and cur then
      source_line, source_col = cur[1], cur[2] or 0
    end
  elseif st.result and st.result.source_map and st.result.source_map[preview_line] then
    source_line = st.result.source_map[preview_line]
  end

  local stack = get_file_nav_stack()
  stack[#stack + 1] = {
    path = path,
    source_line = source_line,
    preview_line = preview_line,
    source_col = source_col,
    preview_col = preview_col,
    mode = st.mode,
  }
  while #stack > 30 do
    table.remove(stack, 1)
  end
end

---源码 + 预览双窗跳到指定源行（TOC / 标题锚点共用）
---@param st table
---@param source_line number
---@param preview_line number|nil 显式预览目标（优先于 rev_map）
---@param record_jump boolean|nil 是否压入跳转栈（默认 true）
---@param cols? { source_col?: number, preview_col?: number } 0-based 列
function M._jump_both(st, source_line, preview_line, record_jump, cols)
  if not source_line or source_line < 1 then
    return
  end
  if record_jump ~= false then
    push_jump(st)
  end
  st.syncing = true
  cols = cols or {}
  local source_col = cols.source_col or 0
  local preview_col = cols.preview_col or 0

  local max_src = vim.api.nvim_buf_is_valid(st.source_buf) and vim.api.nvim_buf_line_count(st.source_buf) or 1
  local src = math.max(1, math.min(source_line, max_src))

  -- 预览行：显式参数 > heading_preview > rev_map
  local prev_line = preview_line
  if not prev_line and st.result then
    if st.result.heading_preview then
      prev_line = st.result.heading_preview[src]
    end
    if not prev_line and st.result.rev_map then
      prev_line = st.result.rev_map[src]
      if not prev_line then
        for r = src, 1, -1 do
          if st.result.rev_map[r] then
            prev_line = st.result.rev_map[r]
            break
          end
        end
      end
    end
  end
  prev_line = prev_line or 1

  -- 源窗
  local swin = st.source_win
  if (not swin or not vim.api.nvim_win_is_valid(swin)) then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == st.source_buf then
        swin = w
        st.source_win = w
        break
      end
    end
  end
  if swin and vim.api.nvim_win_is_valid(swin) then
    local sc = clamp_col(st.source_buf, src, source_col)
    pcall(vim.api.nvim_win_set_cursor, swin, { src, sc })
    pcall(vim.fn.win_execute, swin, "normal! zz")
  end

  -- 预览窗（侧边或单窗）
  local pwin = st.preview_win
  if (not pwin or not vim.api.nvim_win_is_valid(pwin)) and st.preview_buf then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == st.preview_buf then
        pwin = w
        st.preview_win = w
        break
      end
    end
  end
  if pwin and vim.api.nvim_win_is_valid(pwin) and st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
    local max_p = vim.api.nvim_buf_line_count(st.preview_buf)
    prev_line = math.max(1, math.min(prev_line, max_p))
    local pc = clamp_col(st.preview_buf, prev_line, preview_col)
    pcall(vim.api.nvim_win_set_cursor, pwin, { prev_line, pc })
    pcall(vim.fn.win_execute, pwin, "normal! zz")
    if config.get().sync_cursor_block then
      sync.highlight_block(st, src)
    else
      sync.clear_block_highlight(st)
    end
  end

  vim.schedule(function()
    st.syncing = false
  end)
end

---恢复跨文件导航条目（不压栈）
---@param entry table
local function restore_file_nav(entry)
  if not entry or not entry.path then
    return
  end
  if vim.fn.filereadable(entry.path) == 0 then
    vim.notify(require("mdview.i18n").t("prev_gone") .. tostring(entry.path), vim.log.levels.WARN)
    return
  end
  -- 用当前预览态作上下文打开旧文件
  local cur = st_from_preview(vim.api.nvim_get_current_buf())
  if not cur then
    local src = M._current_source()
    cur = src and get_state(src) or nil
  end
  if not cur then
    -- 无会话时：直接 edit + 尽量开侧栏/单窗
    vim.cmd.edit(vim.fn.fnameescape(entry.path))
    return
  end
  M._open_md_file(cur, entry.path, nil, { no_push = true })
  -- 打开后定位到离开时的行
  vim.schedule(function()
    local buf = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == entry.path then
        buf = b
        break
      end
    end
    -- 路径规范化后再比
    if not buf then
      local want = vim.fn.fnamemodify(entry.path, ":p")
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
          local n = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p")
          if n == want then
            buf = b
            break
          end
        end
      end
    end
    local new_st = buf and get_state(buf) or nil
    if not new_st then
      local sess = get_tab_session()
      if sess and sess.source_buf then
        new_st = get_state(sess.source_buf)
      end
    end
    if new_st then
      M._jump_both(new_st, entry.source_line or 1, entry.preview_line, false, {
        source_col = entry.source_col or 0,
        preview_col = entry.preview_col or 0,
      })
      if new_st.preview_win and vim.api.nvim_win_is_valid(new_st.preview_win) then
        pcall(vim.api.nvim_set_current_win, new_st.preview_win)
      end
    end
  end)
end

---<C-o>：先回文内跳转；再回上一篇 md 预览
function M._jump_back(st)
  st.jump_list = st.jump_list or {}
  local entry = table.remove(st.jump_list)
  if entry then
    -- 文内（TOC / 锚点）
    M._jump_both(st, entry.source_line or 1, entry.preview_line, false, {
      source_col = entry.source_col or 0,
      preview_col = entry.preview_col or 0,
    })
    return
  end
  local stack = get_file_nav_stack()
  local file_entry = table.remove(stack)
  if file_entry then
    restore_file_nav(file_entry)
    return
  end
  vim.notify(require("mdview.i18n").t("jump_empty"), vim.log.levels.INFO)
end

---本地 md 是否像 markdown 路径
---@param path string
---@return boolean
local function path_looks_markdown(path)
  if not path or path == "" then
    return false
  end
  local lower = path:lower()
  return lower:match("%.md$") ~= nil
    or lower:match("%.markdown$") ~= nil
    or lower:match("%.mdx$") ~= nil
end

---在 buffer 中按锚点找标题行（1-based）
---@param buf number
---@param frag string|nil
---@return number|nil
local function find_heading_line_in_buf(buf, frag)
  if not frag or frag == "" or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local want = anchor.slugify(anchor.normalize_anchor(frag))
  if want == "" then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local title = line:match("^#+%s+(.+)$")
    if title and anchor.slugify(title) == want then
      return i
    end
  end
  return nil
end

---解析侧栏模式下的源窗口
---@param st table
---@return number|nil
local function resolve_source_win(st)
  if st.source_win and vim.api.nvim_win_is_valid(st.source_win) then
    return st.source_win
  end
  local sess = get_tab_session()
  if sess and sess.source_win and vim.api.nvim_win_is_valid(sess.source_win) then
    return sess.source_win
  end
  local pwin = st.preview_win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= pwin then
      local b = vim.api.nvim_win_get_buf(w)
      if not window.is_preview_buf(b) then
        return w
      end
    end
  end
  return nil
end

---推断当前应使用 side / single（mode 丢失时仍能进预览）
---@param st table
---@return "side"|"single"
local function resolve_view_mode(st)
  if st and (st.mode == "side" or st.mode == "single") then
    return st.mode
  end
  local sess = get_tab_session()
  if sess and sess.preview_win and vim.api.nvim_win_is_valid(sess.preview_win) then
    if sess.mode == "single" then
      return "single"
    end
    return "side"
  end
  if st and st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
    local pwin = st.preview_win
    if pwin and vim.api.nvim_win_is_valid(pwin) then
      local src = st.source_buf
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= pwin and src and vim.api.nvim_win_get_buf(w) == src then
          return "side"
        end
      end
      return "single"
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == st.preview_buf then
        return "single"
      end
    end
  end
  local wins = window.list_preview_wins(tabpage())
  if #wins > 0 then
    return "side"
  end
  -- 当前在预览 buffer 上
  if window.is_preview_buf(vim.api.nvim_get_current_buf()) then
    return "single"
  end
  return "single"
end

---确保侧栏 session 存在（_bind_tab_source 依赖它）
---@param st table
---@return table|nil sess
local function ensure_side_session(st)
  local tab = tabpage()
  local sess = get_tab_session(tab)
  if sess and sess.preview_win and vim.api.nvim_win_is_valid(sess.preview_win) then
    sess.mode = "side"
    set_tab_session(tab, sess)
    return sess
  end
  local pwin = st and st.preview_win
  if not pwin or not vim.api.nvim_win_is_valid(pwin) then
    local wins = window.list_preview_wins(tab)
    pwin = wins[1]
  end
  if not pwin or not vim.api.nvim_win_is_valid(pwin) then
    return nil
  end
  local pbuf = vim.api.nvim_win_get_buf(pwin)
  if not window.is_preview_buf(pbuf) then
    if st and st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
      pbuf = st.preview_buf
      vim.api.nvim_win_set_buf(pwin, pbuf)
    else
      return nil
    end
  end
  sess = {
    preview_win = pwin,
    preview_buf = pbuf,
    source_buf = st and st.source_buf or nil,
    source_win = st and st.source_win or nil,
    mode = "side",
  }
  set_tab_session(tab, sess)
  return sess
end

---单窗：打开目标 md 并显示其预览
---@param abs string
---@param frag string|nil
---@param prefer_win number|nil
---@return table|nil new_st
local function open_md_as_single_preview(abs, frag, prefer_win)
  local win = prefer_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(abs))
  local new_buf = vim.api.nvim_get_current_buf()
  if not is_markdown_buf(new_buf) then
    return nil
  end
  local src_line = find_heading_line_in_buf(new_buf, frag) or 1
  pcall(vim.api.nvim_win_set_cursor, win, { src_line, 0 })

  local new_st = ensure_state(new_buf)
  new_st.source_win = win
  new_st.mode = "single"
  M.ensure_preview_buf(new_st)
  attach_autocmds(new_st)
  do_render(new_st)
  vim.api.nvim_win_set_buf(win, new_st.preview_buf)
  window.apply_winopts(win, config.get())
  new_st.preview_win = win
  return new_st
end

---点击 md 链接：打开目标文件的 md 预览（源同步），焦点在预览
---@param st table
---@param abs string
---@param frag string|nil
---@param opts? { no_push?: boolean }
---@return boolean handled
function M._open_md_file(st, abs, frag, opts)
  opts = opts or {}
  abs = vim.fn.fnamemodify(abs, ":p")
  if vim.fn.filereadable(abs) == 0 then
    return false
  end
  if not path_looks_markdown(abs) then
    return false
  end

  -- 同一文件仅锚点跳转：不压跨文件栈
  local function norm_p(p)
    return (vim.fn.fnamemodify(p or "", ":p"):gsub("\\", "/"):lower())
  end
  local cur_path = st.source_buf and vim.api.nvim_buf_get_name(st.source_buf) or ""
  local same_file = cur_path ~= "" and norm_p(cur_path) == norm_p(abs)

  if not opts.no_push and not same_file then
    push_file_nav(st)
  end

  local function focus_preview_and_jump(new_st, fragment)
    if not new_st then
      return
    end
    local pwin = new_st.preview_win
    if (not pwin or not vim.api.nvim_win_is_valid(pwin)) and new_st.preview_buf then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == new_st.preview_buf then
          pwin = w
          new_st.preview_win = w
          break
        end
      end
    end
    if fragment and fragment ~= "" then
      local h = anchor.find_heading(new_st.headings, fragment)
      if h then
        M._jump_both(new_st, h.source_start, h.preview_line, false)
      end
    else
      local swin = new_st.source_win
      if swin and vim.api.nvim_win_is_valid(swin) then
        pcall(vim.api.nvim_win_set_cursor, swin, { 1, 0 })
      end
      if pwin and vim.api.nvim_win_is_valid(pwin) and new_st.preview_buf then
        pcall(vim.api.nvim_win_set_cursor, pwin, { 1, 0 })
      end
    end
    if pwin and vim.api.nvim_win_is_valid(pwin) then
      vim.api.nvim_set_current_win(pwin)
    end
  end

  local mode = resolve_view_mode(st)
  st.mode = mode

  -- 侧栏：源窗打开 md，绑定并重渲预览，焦点在预览
  if mode == "side" then
    if not ensure_side_session(st) then
      -- 无侧栏预览窗：退化为单窗预览
      local new_st = open_md_as_single_preview(abs, frag, st.source_win or st.preview_win)
      if new_st then
        focus_preview_and_jump(new_st, frag)
        return true
      end
      return false
    end

    local swin = resolve_source_win(st)
    if not swin then
      local new_st = open_md_as_single_preview(abs, frag, st.preview_win)
      if new_st then
        focus_preview_and_jump(new_st, frag)
        return true
      end
      return false
    end

    local edit_ok = pcall(function()
      vim.api.nvim_win_call(swin, function()
        vim.cmd("keepalt edit " .. vim.fn.fnameescape(abs))
      end)
    end)
    if not edit_ok then
      vim.api.nvim_set_current_win(swin)
      vim.cmd.edit(vim.fn.fnameescape(abs))
    end

    local new_buf = vim.api.nvim_win_get_buf(swin)
    if not is_markdown_buf(new_buf) then
      vim.api.nvim_set_current_win(swin)
      return true
    end

    local src_line = find_heading_line_in_buf(new_buf, frag) or 1
    pcall(vim.api.nvim_win_set_cursor, swin, { src_line, 0 })

    M._bind_tab_source(tabpage(), new_buf, swin)
    local new_st = get_state(new_buf)
    if not new_st then
      -- bind 失败时仍尽量单窗预览目标
      local s2 = open_md_as_single_preview(abs, frag, st.preview_win or swin)
      if s2 then
        focus_preview_and_jump(s2, frag)
      end
      return true
    end
    focus_preview_and_jump(new_st, frag)
    vim.schedule(function()
      local s = get_state(new_buf)
      if s and s.preview_win and vim.api.nvim_win_is_valid(s.preview_win) then
        pcall(vim.api.nvim_set_current_win, s.preview_win)
      end
    end)
    return true
  end

  -- 单窗预览：打开目标 md → 渲染预览并显示
  local win = st.source_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = st.preview_win
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end
  local new_st = open_md_as_single_preview(abs, frag, win)
  if not new_st then
    return false
  end
  focus_preview_and_jump(new_st, frag)
  return true
end

---打开本地非 md 文件（源窗 edit，焦点源窗）
---@param st table
---@param abs string
---@return boolean
local function open_local_other_file(st, abs)
  abs = vim.fn.fnamemodify(abs, ":p")
  if vim.fn.filereadable(abs) == 0 then
    return false
  end
  if st.mode == "side" then
    local swin = resolve_source_win(st)
    if swin then
      vim.api.nvim_set_current_win(swin)
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(abs))
  return true
end

---解码路径中的 %XX（如 %20）
---@param s string
---@return string
local function uri_decode(s)
  if not s or s == "" then
    return s
  end
  local ok, out = pcall(function()
    return (s:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end))
  end)
  if ok and type(out) == "string" then
    return out
  end
  return s
end

---编辑窗打开本地 md 源码（不切预览）；可选 #fragment
---:edit 会进 jumplist，便于 <C-o> 回到原文件
---@param st table
---@param abs string
---@param frag string|nil
---@return boolean
local function open_md_as_source_edit(st, abs, frag)
  abs = vim.fn.fnamemodify(abs, ":p")
  if vim.fn.filereadable(abs) == 0 then
    return false
  end

  local win = st.source_win
  if (not win or not vim.api.nvim_win_is_valid(win)) and st.source_buf then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == st.source_buf then
        win = w
        break
      end
    end
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end
  st.source_win = win

  local edit_ok = pcall(function()
    vim.api.nvim_win_call(win, function()
      -- 不用 keepalt：保留 jumplist / alternate 以便 <C-o>
      vim.cmd("edit " .. vim.fn.fnameescape(abs))
    end)
  end)
  if not edit_ok then
    vim.api.nvim_set_current_win(win)
    vim.cmd.edit(vim.fn.fnameescape(abs))
  else
    pcall(vim.api.nvim_set_current_win, win)
  end

  local new_buf = vim.api.nvim_win_get_buf(win)
  local line = find_heading_line_in_buf(new_buf, frag) or 1
  -- 用 set_cursor 落锚点，避免再记一次 jumplist（一次 <C-o> 回原文件）
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  pcall(vim.fn.win_execute, win, "normal! zz")
  return true
end

---页内锚点跳转（源码 / 双窗）
---@param st table
---@param source_line number
---@param preview_line number|nil
---@param opts? { from_source?: boolean }
local function jump_anchor(st, source_line, preview_line, opts)
  opts = opts or {}
  if opts.from_source then
    -- 源码 nG 写入 jumplist；预览仅同步光标（不 push 自定义栈）
    jump_source_only(st, source_line)
    local pwin = st.preview_win
    if pwin and vim.api.nvim_win_is_valid(pwin) and st.result and preview_line then
      pcall(vim.api.nvim_win_set_cursor, pwin, { preview_line, 0 })
    end
    return
  end
  M._jump_both(st, source_line, preview_line)
end

---@param href string
---@param st table
---@param opts? { from_source?: boolean } from_source=编辑窗：md 开源码、<C-o> 可回
function M._open_href(href, st, opts)
  if not href or href == "" then
    return
  end
  opts = opts or {}
  local from_source = opts.from_source == true
  href = vim.trim(href)

  -- 页内锚点 [Quote](#Quote)
  if href:sub(1, 1) == "#" then
    local h = anchor.find_heading(st.headings, href)
    if h then
      jump_anchor(st, h.source_start, h.preview_line, opts)
    else
      vim.notify(require("mdview.i18n").t("heading_nf") .. href, vim.log.levels.INFO)
    end
    return
  end

  local is_url = href:match("^[%w+.-]+://") or href:match("^mailto:")

  -- 相对/本地路径（可带 #fragment）
  if not is_url then
    local file_part, frag = href:match("^(.-)#(.+)$")
    if not file_part then
      file_part, frag = href, nil
    end
    file_part = uri_decode(vim.trim(file_part or ""))
    if frag then
      frag = uri_decode(frag)
    end
    if file_part == "" and frag then
      local h = anchor.find_heading(st.headings, frag)
      if h then
        jump_anchor(st, h.source_start, h.preview_line, opts)
      else
        vim.notify(require("mdview.i18n").t("heading_nf") .. "#" .. frag, vim.log.levels.INFO)
      end
      return
    end

    local md_path = vim.api.nvim_buf_get_name(st.source_buf)
    local abs = select(1, image_mod.resolve_path(file_part, md_path))
    -- 再试：去掉 query、补 .md
    if (not abs or vim.fn.filereadable(abs) == 0) and file_part ~= "" then
      local bare = file_part:gsub("%?.*$", "")
      if bare ~= file_part then
        abs = select(1, image_mod.resolve_path(bare, md_path))
      end
      if (not abs or vim.fn.filereadable(abs) == 0) and not path_looks_markdown(bare) then
        local try_md = bare .. ".md"
        local a2 = select(1, image_mod.resolve_path(try_md, md_path))
        if a2 and vim.fn.filereadable(a2) == 1 then
          abs = a2
        end
      end
    end
    if abs and vim.fn.filereadable(abs) == 1 then
      if path_looks_markdown(abs) then
        if from_source then
          -- 编辑窗：打开目标 md 源码（非预览）
          if open_md_as_source_edit(st, abs, frag) then
            return
          end
        else
          -- 预览窗：打开目标 md 预览
          if M._open_md_file(st, abs, frag) then
            return
          end
        end
      end
      if open_local_other_file(st, abs) then
        return
      end
    end
  end

  if vim.ui and vim.ui.open then
    local ok, err = pcall(vim.ui.open, href)
    if ok then
      return
    end
    vim.notify(require("mdview.i18n").t("open_fail") .. tostring(err), vim.log.levels.WARN)
  end
  if vim.fn.has("win32") == 1 then
    vim.fn.jobstart({ "cmd", "/c", "start", "", href }, { detach = true })
  elseif vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", href }, { detach = true })
  else
    vim.fn.jobstart({ "xdg-open", href }, { detach = true })
  end
end

---重渲后把光标限制在指定代码块内
---@param st table
---@param block_id number
---@param rel number 相对块顶的行偏移（0-based 优先）
local function cursor_in_code_block(st, block_id, rel)
  if not st.result then
    return
  end
  local block
  for _, h in ipairs(st.result.hits or {}) do
    if h.kind == "code_block" and h.block_id == block_id then
      block = h
      break
    end
  end
  if not block then
    return
  end
  local top = block.line or 1
  local bot = block.line_end or top
  rel = rel or 0
  if rel < 0 then
    rel = 0
  end
  local target = top + rel
  if target > bot then
    target = bot
  end
  if target < top then
    target = top
  end
  local win = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
end

---切换代码块折叠；成功返回 true
---@param st table
---@param hit table code_fold 或 code_block
---@param cursor_row number
local function toggle_code_fold(st, hit, cursor_row)
  local block_id = hit.block_id
  if not block_id then
    return false
  end
  local fold_n = config.get().code_fold_lines or 10
  local total = hit.lines and #hit.lines or hit.total_lines or 0
  -- code_fold 命中时 lines 可能只在 code_block 上
  if total <= 0 then
    for _, h in ipairs(st.result and st.result.hits or {}) do
      if h.kind == "code_block" and h.block_id == block_id then
        total = h.lines and #h.lines or 0
        hit = h
        break
      end
    end
  end
  if fold_n <= 0 or total <= fold_n then
    return false
  end
  local top = hit.line or cursor_row
  local rel = cursor_row - top
  if rel < 0 then
    rel = 0
  end
  st.expanded_codes[block_id] = not st.expanded_codes[block_id]
  do_render(st)
  cursor_in_code_block(st, block_id, rel)
  return true
end

---激活 hit（键盘回车 / 鼠标共用）
---@param st table
---@param hit table
---@param row integer
function M._activate_hit(st, hit, row)
  if not hit then
    return
  end
  if hit.kind == "toc" then
    M._jump_both(st, hit.source_start or 1, hit.preview_target)
  elseif hit.kind == "code_copy" then
    M._yank_code_lines(hit.lines, hit.lang, st, hit)
  elseif hit.kind == "code_fold" or hit.kind == "code_block" then
    -- 光标在代码块任意位置：回车切换展开/折叠
    if not toggle_code_fold(st, hit, row) then
      -- 不可折叠：忽略
    end
  elseif hit.kind == "details" then
    local cur = st.expanded_details[hit.block_id]
    if cur == nil then
      cur = hit.expanded
    end
    st.expanded_details[hit.block_id] = not cur
    do_render(st)
  elseif hit.kind == "image" then
    image_mod.open_preview(hit.path, config.get())
  elseif hit.kind == "image_inline" then
    local md_path = vim.api.nvim_buf_get_name(st.source_buf)
    local abs = select(1, image_mod.resolve_path(hit.src, md_path))
    if abs then
      image_mod.open_preview(abs, config.get())
    end
  elseif hit.kind == "link" then
    M._open_href(hit.href, st)
  end
end

function M._activate_at_cursor(st)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local hit = M._hit_at(st, row, col)
  if not hit then
    return
  end
  M._activate_hit(st, hit, row)
end

---解析光标处图片绝对路径（块图 / 行内图 / 表格图）；不在图上则 nil
---@param st table
---@return string|nil
function M._image_path_at_cursor(st)
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1], cur[2]
  local hit = M._hit_at(st, row, col)
  local md_path = st.source_buf and vim.api.nvim_buf_get_name(st.source_buf) or ""

  local function path_from_hit(h)
    if not h then
      return nil
    end
    if h.kind == "image" and h.path and h.path ~= "" then
      return h.path
    end
    if h.kind == "image_inline" and h.src then
      return select(1, image_mod.resolve_path(h.src, md_path))
    end
    return nil
  end

  local p = path_from_hit(hit)
  if p then
    return p
  end

  -- 整行块图：无列约束时任意列都算；有列约束则须落在区间内
  for _, h in ipairs(st.result and st.result.hits or {}) do
    if h.kind == "image" or h.kind == "image_inline" then
      local a, b = h.line, h.line_end or h.line
      if row >= a and row <= b then
        if h.col == nil or h.end_col == nil or (col >= h.col and col < h.end_col) then
          p = path_from_hit(h)
          if p then
            return p
          end
        end
      end
    end
  end
  return nil
end

function M._open_image_at_cursor(st)
  local path = M._image_path_at_cursor(st)
  if not path then
    -- 兼容旧行为：找不到时取文档中第一张块图
    for _, h in ipairs(st.result and st.result.hits or {}) do
      if h.kind == "image" and h.path then
        path = h.path
        break
      end
    end
  end
  if path then
    image_mod.open_preview(path, config.get())
  else
    vim.notify(require("mdview.i18n").t("no_image"), vim.log.levels.INFO)
  end
end

---光标在图片上时用系统默认程序打开；否则提示
function M._open_image_system_at_cursor(st)
  local path = M._image_path_at_cursor(st)
  if path then
    image_mod.open_with_system(path)
  else
    vim.notify(require("mdview.i18n").t("no_image"), vim.log.levels.INFO)
  end
end

---gh：临时显示当前页（窗口可见区）图片高清叠层；再按 gh 或移动光标/滚动清除
---@param st table
function M._toggle_page_hd(st)
  if not st then
    return
  end
  local buf = st.preview_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    -- 当前 buffer 即预览
    local cur = vim.api.nvim_get_current_buf()
    if window.is_preview_buf(cur) then
      buf = cur
      st.preview_buf = cur
    else
      vim.notify(require("mdview.i18n").t("no_preview_buf"), vim.log.levels.WARN)
      return
    end
  end

  local ok_g, graphics = pcall(require, "mdview.graphics")
  if not ok_g or not graphics then
    vim.notify(require("mdview.i18n").t("gfx_fail") .. tostring(graphics), vim.log.levels.ERROR)
    return
  end
  -- 已在显示 → 关闭
  if graphics.is_active and graphics.is_active(buf) then
    graphics.clear_buf(buf)
    vim.notify(require("mdview.i18n").t("page_hd_off"), vim.log.levels.INFO)
    return
  end

  local cfg = config.get()
  local imgcfg = (cfg and cfg.image) or {}
  if graphics.detect and not graphics.detect(imgcfg, "float") then
    vim.notify(require("mdview.i18n").t("page_hd_unsupported"), vim.log.levels.INFO)
    return
  end

  local win = st.preview_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.bufwinid(buf)
  end
  if not win or win == -1 or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end
  st.preview_win = win

  -- 无 hits 时先重渲再试
  if not st.result or not st.result.hits or #st.result.hits == 0 then
    do_render(st)
  end
  local hits = st.result and st.result.hits or {}

  local ok = graphics.attach_preview({
    buf = buf,
    win = win,
    hits = hits,
    max_images = imgcfg.max_images or 20,
    scale = imgcfg.float_scale == "fit" and "fit" or "fill",
    python = imgcfg.python or "python",
    visible_only = true,
    clear_on_scroll = true, -- 滚动/改大小/焦点离开清除；移光标不关
  })
  if not ok then
    vim.notify(require("mdview.i18n").t("page_hd_none"), vim.log.levels.INFO)
  else
    pcall(vim.api.nvim_echo, {
      { require("mdview.i18n").t("page_hd_on"), "MoreMsg" },
    }, false, {})
    -- iTerm 最多补 1 次；多次会堆叠
    vim.defer_fn(function()
      if graphics.is_active and graphics.is_active(buf) and graphics._repaint_buf then
        graphics._repaint_buf(buf)
      end
    end, 60)
  end
end

---复制后顶栏 [复制]/Copy] → [已复制]/Copied]，3 秒恢复
---@param st table
---@param hit table code_copy hit
local function flash_copy_label(st, hit)
  local buf = st.preview_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not hit or not hit.line then
    return
  end
  local i18n = require("mdview.i18n")
  local copy_lab = i18n.t("copy")
  local copied_lab = i18n.t("copied")
  local row = hit.line -- 1-based
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not line or not line:find(copy_lab, 1, true) then
    return
  end
  local new_line = line:gsub(vim.pesc(copy_lab), copied_lab, 1)
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, { new_line })
  vim.bo[buf].modifiable = false

  -- 临时高亮已复制
  local ns = vim.api.nvim_create_namespace("mdview_copy_flash")
  local s, e = new_line:find(copied_lab, 1, true)
  if s and e then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, s - 1, {
      end_col = e,
      hl_group = "MdViewCodeCopied",
    })
  end

  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(buf) or not st.result then
      return
    end
    local orig = st.result.lines and st.result.lines[row]
    if not orig then
      return
    end
    local cur = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    if not cur or not cur:find(copied_lab, 1, true) then
      return
    end
    vim.bo[buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, buf, row - 1, row, false, { orig })
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    local NS = render.namespace()
    for _, em in ipairs(st.result.extmarks or {}) do
      if em.line == row - 1 then
        local eopts = {}
        if em.hl then
          eopts.hl_group = em.hl
          eopts.end_col = em.end_col
        end
        if em.line_hl then
          eopts.line_hl_group = em.line_hl
        end
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, em.line, em.col or 0, eopts)
      end
    end
  end, 3000)
end

function M._yank_code_lines(lines, lang, st, hit)
  local i18n = require("mdview.i18n")
  if not lines or #lines == 0 then
    vim.notify(i18n.t("empty_code"), vim.log.levels.INFO)
    return
  end
  local text = table.concat(lines, "\n")
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify(string.format(i18n.t("copied_n"), #lines, lang or "text"), vim.log.levels.INFO)
  if st and hit then
    flash_copy_label(st, hit)
  end
end

function M._yank_code_at_cursor(st)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local hit = nil
  for _, h in ipairs(st.result and st.result.hits or {}) do
    if h.kind == "code_block" then
      local a, b = h.line, h.line_end or h.line
      if row >= a and row <= b then
        hit = h
        break
      end
    end
  end
  if not hit or not hit.lines then
    vim.notify(require("mdview.i18n").t("no_code"), vim.log.levels.INFO)
    return
  end
  -- yc：找同块的 code_copy hit 以便闪烁顶栏
  local copy_hit = nil
  for _, h in ipairs(st.result.hits or {}) do
    if h.kind == "code_copy" and h.block_id == hit.block_id then
      copy_hit = h
      break
    end
  end
  M._yank_code_lines(hit.lines, hit.lang, st, copy_hit)
end

function M._goto_source(st)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local src = st.result and st.result.source_map[row] or 1
  if st.mode == "single" then
    if vim.api.nvim_win_is_valid(st.source_win or 0) then
      vim.api.nvim_set_current_win(st.source_win)
    end
    vim.api.nvim_win_set_buf(0, st.source_buf)
    st.mode = nil
    pcall(vim.api.nvim_win_set_cursor, 0, { src, 0 })
  elseif st.mode == "side" then
    if st.source_win and vim.api.nvim_win_is_valid(st.source_win) then
      vim.api.nvim_set_current_win(st.source_win)
      pcall(vim.api.nvim_win_set_cursor, st.source_win, { src, 0 })
    end
  end
end

function M.ensure_preview_buf(st)
  if st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
    window.bind_preview_source(st.preview_buf, st.source_buf)
    attach_maps(st.preview_buf)
    return st.preview_buf
  end
  st.preview_buf = window.create_preview_buf(st.source_buf)
  attach_maps(st.preview_buf)
  return st.preview_buf
end

---把 tab 内预览绑定到指定 md 源并渲染
function M._bind_tab_source(tab, source_buf, source_win)
  tab = tab or tabpage()
  local sess = get_tab_session(tab)
  if not sess or not sess.preview_win or not vim.api.nvim_win_is_valid(sess.preview_win) then
    return
  end
  if not is_markdown_buf(source_buf) then
    return
  end

  -- 卸下旧源
  if sess.source_buf and sess.source_buf ~= source_buf then
    local old = get_state(sess.source_buf)
    if old then
      detach_source_preview(old)
    end
  end

  local st = ensure_state(source_buf)
  if not sess.preview_buf or not vim.api.nvim_buf_is_valid(sess.preview_buf) then
    sess.preview_buf = vim.api.nvim_win_get_buf(sess.preview_win)
    if not window.is_preview_buf(sess.preview_buf) then
      sess.preview_buf = window.create_preview_buf(source_buf)
      vim.api.nvim_win_set_buf(sess.preview_win, sess.preview_buf)
    end
  end

  st.preview_buf = sess.preview_buf
  st.preview_win = sess.preview_win
  st.source_win = source_win or vim.api.nvim_get_current_win()
  st.mode = sess.mode or "side"
  st.source_buf = source_buf

  window.bind_preview_source(st.preview_buf, source_buf)
  if vim.api.nvim_win_get_buf(sess.preview_win) ~= st.preview_buf then
    vim.api.nvim_win_set_buf(sess.preview_win, st.preview_buf)
  end

  sess.source_buf = source_buf
  sess.source_win = st.source_win
  sess.preview_buf = st.preview_buf
  set_tab_session(tab, sess)

  attach_maps(st.preview_buf)
  attach_autocmds(st)
  do_render(st)
  if st.mode == "side" then
    sync.sync_from_source(st)
  end
end

-- ---------------------------------------------------------------------------
-- NERDTree / 文件树 `o`：nofile 预览窗无法被替换时会多出 vsplit，在此回收
-- · 仅 mdview 内容窗：覆盖预览窗（md→单窗预览；其它→直接打开文本，不留 vsplit）
-- · mdview + 编辑窗：打开到编辑窗；md 则更新侧栏预览
-- ---------------------------------------------------------------------------

local reclaiming = false

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

local function list_content_wins(tab)
  local list = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    if not is_sidebar_win(win) then
      list[#list + 1] = win
    end
  end
  return list
end

local function find_tab_preview_win(tab)
  tab = tab or tabpage()
  local sess = get_tab_session(tab)
  if sess and sess.preview_win and vim.api.nvim_win_is_valid(sess.preview_win) then
    local b = vim.api.nvim_win_get_buf(sess.preview_win)
    if window.is_preview_buf(b) then
      return sess.preview_win, sess
    end
  end
  local wins = window.list_preview_wins(tab)
  if wins[1] then
    return wins[1], sess
  end
  return nil, sess
end

---卸掉侧栏 session，不关窗口（窗口将用于放普通文件）
local function drop_side_session(tab, pwin)
  tab = tab or tabpage()
  local sess = get_tab_session(tab)
  if sess and sess.source_buf then
    local st = get_state(sess.source_buf)
    if st then
      detach_source_preview(st)
    end
  end
  -- 单窗预览：按预览 buffer 找 state
  if pwin and vim.api.nvim_win_is_valid(pwin) then
    local pb = vim.api.nvim_win_get_buf(pwin)
    if window.is_preview_buf(pb) then
      local src = vim.b[pb].mdview_source
      local st = get_state(src)
      if st and st.mode == "single" then
        detach_source_preview(st)
      end
    end
  end
  set_tab_session(tab, nil)
end

---在指定窗以单窗模式打开 md 预览
local function open_md_single_on_win(source_buf, win)
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local tab = tabpage()
  drop_side_session(tab, win)

  local st = ensure_state(source_buf)
  st.source_win = win
  M.ensure_preview_buf(st)
  do_render(st)
  attach_autocmds(st)
  vim.api.nvim_win_set_buf(win, st.preview_buf)
  window.apply_winopts(win, config.get())
  M.ensure_mouse()
  st.mode = "single"
  st.preview_win = win
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

local function close_orphan_win(orphan, keep)
  if orphan and orphan ~= keep and vim.api.nvim_win_is_valid(orphan) then
    pcall(vim.api.nvim_win_close, orphan, true)
  end
end

---把 file 放到编辑窗（非预览），关闭误开的 vsplit；md 则绑定侧栏
local function place_in_editor_and_maybe_preview(file_buf, file_win, pwin, sess, editors)
  local tab = tabpage()
  local target = nil
  if sess and sess.source_win and vim.api.nvim_win_is_valid(sess.source_win) and sess.source_win ~= pwin then
    target = sess.source_win
  end
  if not target then
    for _, w in ipairs(editors) do
      if w ~= file_win and w ~= pwin then
        target = w
        break
      end
    end
  end
  if not target then
    target = file_win
  end

  if file_win ~= target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_win_set_buf(target, file_buf)
    close_orphan_win(file_win, target)
    file_win = target
  end

  if is_markdown_buf(file_buf) then
    if sess and sess.preview_win and vim.api.nvim_win_is_valid(sess.preview_win) then
      sess.source_win = file_win
      set_tab_session(tab, sess)
      M._bind_tab_source(tab, file_buf, file_win)
    else
      -- 有预览窗但无 session：重建 side session
      local pbuf = vim.api.nvim_win_get_buf(pwin)
      if not window.is_preview_buf(pbuf) then
        pbuf = window.create_preview_buf(file_buf)
        vim.api.nvim_win_set_buf(pwin, pbuf)
      end
      set_tab_session(tab, {
        preview_win = pwin,
        preview_buf = pbuf,
        source_buf = file_buf,
        source_win = file_win,
        mode = "side",
      })
      M._bind_tab_source(tab, file_buf, file_win)
    end
    if vim.api.nvim_win_is_valid(file_win) then
      vim.api.nvim_set_current_win(file_win)
    end
  else
    if vim.api.nvim_win_is_valid(file_win) then
      vim.api.nvim_set_current_win(file_win)
    end
  end
end

---仅预览内容区时：用 file 覆盖预览窗并关掉多余 split
local function cover_preview_with_file(file_buf, file_win, pwin)
  local tab = tabpage()
  local is_md = is_markdown_buf(file_buf)

  if is_md then
    close_orphan_win(file_win, pwin)
    open_md_single_on_win(file_buf, pwin)
    return
  end

  -- 普通文件：覆盖预览窗，清 session
  drop_side_session(tab, pwin)
  if vim.api.nvim_win_is_valid(pwin) then
    vim.api.nvim_win_set_buf(pwin, file_buf)
  end
  close_orphan_win(file_win, pwin)
  if vim.api.nvim_win_is_valid(pwin) then
    vim.api.nvim_set_current_win(pwin)
  end
end

---NERDTree `o` 等打开普通 buffer 后回收布局
function M._reclaim_tree_open(buf)
  if reclaiming then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if window.is_preview_buf(buf) then
    return
  end
  if vim.b[buf].mdview_toc_float or vim.b[buf].mdview_image_float or vim.b[buf].mdview_help_float then
    return
  end
  local bt = vim.bo[buf].buftype
  if bt ~= "" then
    return
  end
  local ft = vim.bo[buf].filetype or ""
  if SIDEBAR_FILETYPES[ft] then
    return
  end

  local tab = tabpage()
  local pwin = select(1, find_tab_preview_win(tab))
  if not pwin or not vim.api.nvim_win_is_valid(pwin) then
    return
  end

  local file_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(file_win) ~= buf then
    local id = vim.fn.bufwinid(buf)
    if id == -1 then
      return
    end
    file_win = id
  end
  if is_sidebar_win(file_win) then
    return
  end

  reclaiming = true
  vim.schedule(function()
    local ok, err = pcall(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local pw = select(1, find_tab_preview_win(tab))
      if not pw or not vim.api.nvim_win_is_valid(pw) then
        return
      end

      local fw = file_win
      if not vim.api.nvim_win_is_valid(fw) or vim.api.nvim_win_get_buf(fw) ~= buf then
        local id = vim.fn.bufwinid(buf)
        if id == -1 then
          return
        end
        fw = id
      end
      if is_sidebar_win(fw) then
        return
      end

      -- 已在预览窗内打开
      if fw == pw then
        if is_markdown_buf(buf) then
          open_md_single_on_win(buf, pw)
        else
          drop_side_session(tab, pw)
        end
        return
      end

      local eds = {}
      for _, w in ipairs(list_content_wins(tab)) do
        if w ~= pw then
          local b = vim.api.nvim_win_get_buf(w)
          if not window.is_preview_buf(b) then
            eds[#eds + 1] = w
          end
        end
      end

      local sess2 = get_tab_session(tab)
      local side_ok = sess2
        and sess2.mode == "side"
        and sess2.source_win
        and vim.api.nvim_win_is_valid(sess2.source_win)
        and sess2.source_win ~= pw

      -- 右侧原先只有 mdview：文件在误开的 vsplit → 覆盖预览窗
      if #eds <= 1 and not (side_ok and sess2.source_win == fw) then
        cover_preview_with_file(buf, fw, pw)
        return
      end

      -- 有编辑窗（或 side 健康）：打开到编辑区；md 更新预览
      if side_ok or #eds >= 2 then
        place_in_editor_and_maybe_preview(buf, fw, pw, sess2, eds)
      end
    end)
    reclaiming = false
    if not ok then
      vim.notify("mdview reclaim: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end)
end

function M._ensure_tab_follow()
  if follow_installed then
    return
  end
  follow_installed = true
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("mdview_tab_follow", { clear = true }),
    callback = function(args)
      vim.schedule(function()
        -- 先回收文件树误开的 vsplit，再跟随源文件
        if args.event == "BufWinEnter" then
          M._reclaim_tree_open(args.buf)
        end
        -- reclaim 异步进行中时跳过；结束后布局/绑定已由 reclaim 处理
        if not reclaiming then
          M._on_focus_change(args.buf)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("mdview_tab_closed", { clear = true }),
    callback = function(args)
      -- args.file is tab number as string sometimes
      local closed = tonumber(args.file)
      if closed then
        tab_sessions[closed] = nil
        file_nav_by_tab[closed] = nil
      end
    end,
  })
end

function M._on_focus_change(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if window.is_preview_buf(buf) then
    return
  end
  if vim.b[buf].mdview_toc_float or vim.b[buf].mdview_image_float or vim.b[buf].mdview_help_float then
    return
  end

  local tab = tabpage()
  local sess = get_tab_session(tab)
  if not sess then
    return
  end
  if not sess.preview_win or not vim.api.nvim_win_is_valid(sess.preview_win) then
    set_tab_session(tab, nil)
    return
  end

  -- 非 md：忽略，预览保持上次内容
  if not is_markdown_buf(buf) then
    return
  end

  local win = vim.api.nvim_get_current_win()
  if win == sess.preview_win then
    return
  end

  if sess.source_buf == buf then
    local st = get_state(buf)
    if st then
      st.source_win = win
      sess.source_win = win
      if st.mode == "side" then
        sync.sync_from_source(st)
      end
    end
    return
  end

  M._bind_tab_source(tab, buf, win)
end

---关闭 tab 内多余预览窗，只留一个
local function enforce_one_preview_win(tab, keep_win)
  local wins = window.list_preview_wins(tab)
  for _, w in ipairs(wins) do
    if w ~= keep_win then
      window.close_win(w)
    end
  end
end

--- 单窗切换
function M.toggle_view()
  M.ensure_setup()
  local buf = vim.api.nvim_get_current_buf()
  -- 若当前在预览，回到源
  if window.is_preview_buf(buf) then
    local src = vim.b[buf].mdview_source
    local st = get_state(src)
    if st then
      vim.api.nvim_win_set_buf(0, src)
      local sess = get_tab_session()
      if sess and sess.mode == "side" and sess.preview_win and vim.api.nvim_win_is_valid(sess.preview_win) then
        st.mode = "side"
        st.preview_win = sess.preview_win
        st.preview_buf = sess.preview_buf
      else
        st.mode = nil
      end
      st.source_win = vim.api.nvim_get_current_win()
    else
      if src and vim.api.nvim_buf_is_valid(src) then
        vim.api.nvim_win_set_buf(0, src)
      end
    end
    return
  end

  local source_buf = M._current_source()
  if not is_markdown_buf(source_buf) then
    vim.notify(require("mdview.i18n").t("not_md"), vim.log.levels.INFO)
    return
  end
  local st = ensure_state(source_buf)

  if st.mode == "single" and st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
    st.source_win = vim.api.nvim_get_current_win()
    M.ensure_preview_buf(st)
    do_render(st)
    vim.api.nvim_win_set_buf(0, st.preview_buf)
    window.apply_winopts(0, config.get())
    return
  end

  st.source_win = vim.api.nvim_get_current_win()
  M.ensure_preview_buf(st)
  do_render(st)
  attach_autocmds(st)
  vim.api.nvim_win_set_buf(st.source_win, st.preview_buf)
  window.apply_winopts(st.source_win, config.get())
  M.ensure_mouse()
  st.mode = "single"
  st.preview_win = st.source_win
end

function M.side_open()
  M.ensure_setup()
  local source_buf = M._current_source()
  if window.is_preview_buf(source_buf) then
    source_buf = vim.b[source_buf].mdview_source or source_buf
  end
  if not is_markdown_buf(source_buf) then
    vim.notify(require("mdview.i18n").t("open_md_first"), vim.log.levels.INFO)
    return
  end

  local tab = tabpage()
  local curwin = vim.api.nvim_get_current_win()
  if window.is_preview_buf(vim.api.nvim_win_get_buf(curwin)) then
    -- 焦点在预览上：用已关联源
    source_buf = vim.b[vim.api.nvim_win_get_buf(curwin)].mdview_source or source_buf
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(w) == source_buf then
        curwin = w
        break
      end
    end
  end

  local sess = get_tab_session(tab)
  local existing = window.list_preview_wins(tab)

  -- 已有预览窗：复用，只换源
  if #existing > 0 then
    local pwin = existing[1]
    enforce_one_preview_win(tab, pwin)
    local pbuf = vim.api.nvim_win_get_buf(pwin)
    if not window.is_preview_buf(pbuf) then
      pbuf = window.create_preview_buf(source_buf)
      vim.api.nvim_win_set_buf(pwin, pbuf)
    end
    sess = {
      preview_win = pwin,
      preview_buf = pbuf,
      source_buf = source_buf,
      source_win = curwin,
      mode = "side",
    }
    set_tab_session(tab, sess)
    M._bind_tab_source(tab, source_buf, curwin)
    M.ensure_mouse()
    return
  end

  -- 新建侧边
  local st = ensure_state(source_buf)
  st.source_win = curwin
  M.ensure_preview_buf(st)
  do_render(st)
  local pwin = window.open_side(st.source_win, st.preview_buf, config.get())
  enforce_one_preview_win(tab, pwin)
  st.preview_win = pwin
  st.mode = "side"
  attach_autocmds(st)
  set_tab_session(tab, {
    preview_win = pwin,
    preview_buf = st.preview_buf,
    source_buf = source_buf,
    source_win = curwin,
    mode = "side",
  })
  M.ensure_mouse()
  sync.sync_from_source(st)
end

function M.side_close()
  local tab = tabpage()
  local sess = get_tab_session(tab)
  local pwin = sess and sess.preview_win
  if not pwin or not vim.api.nvim_win_is_valid(pwin) then
    local wins = window.list_preview_wins(tab)
    pwin = wins[1]
  end
  if pwin and vim.api.nvim_win_is_valid(pwin) then
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    if #wins > 1 then
      window.close_win(pwin)
    else
      local src = sess and sess.source_buf
      if src and vim.api.nvim_buf_is_valid(src) then
        vim.api.nvim_win_set_buf(pwin, src)
      end
    end
  end
  -- 卸下关联
  if sess and sess.source_buf then
    local st = get_state(sess.source_buf)
    if st then
      detach_source_preview(st)
    end
  end
  set_tab_session(tab, nil)
  -- 关掉可能残留的预览窗
  for _, w in ipairs(window.list_preview_wins(tab)) do
    if #vim.api.nvim_tabpage_list_wins(tab) > 1 then
      window.close_win(w)
    end
  end
end

function M.toggle_side()
  M.ensure_setup()
  local tab = tabpage()
  local sess = get_tab_session(tab)
  if sess and sess.preview_win and vim.api.nvim_win_is_valid(sess.preview_win) then
    M.side_close()
  else
    local wins = window.list_preview_wins(tab)
    if #wins > 0 then
      -- 有窗无 session：视为已开，关闭
      M.side_close()
    else
      M.side_open()
    end
  end
end

function M.close_for(source_buf, wipe)
  local st = get_state(source_buf)
  local tab = tabpage()
  local sess = get_tab_session(tab)

  if st then
    if st.debounce then
      pcall(function()
        st.debounce:stop()
      end)
    end
    stop_external_watch(st)
    if st.au_group then
      pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
      st.au_group = nil
    end
  end

  -- 关 tab 预览
  if sess and (not source_buf or sess.source_buf == source_buf or wipe) then
    M.side_close()
  elseif st and st.mode == "single" then
    local win = vim.api.nvim_get_current_win()
    if window.is_preview_buf(vim.api.nvim_win_get_buf(win)) then
      if vim.api.nvim_buf_is_valid(st.source_buf) then
        vim.api.nvim_win_set_buf(win, st.source_buf)
      end
    end
    st.mode = nil
  end

  if wipe and st and st.preview_buf and vim.api.nvim_buf_is_valid(st.preview_buf) then
    -- 仅当不是 tab 共享预览时删除
    local shared = sess and sess.preview_buf == st.preview_buf
    if not shared then
      pcall(vim.api.nvim_buf_delete, st.preview_buf, { force = true })
    end
  end
  if wipe then
    states[source_buf] = nil
  else
    detach_source_preview(st)
  end
end

function M.sync_now()
  local source_buf = M._current_source()
  local st = get_state(source_buf)
  if st and st.mode == "side" then
    sync.sync_from_source(st)
  end
end

---去掉 markdown 目标里的可选 title：path "t" / path 't' / <path>
---@param s string|nil
---@return string
local function clean_md_dest(s)
  s = vim.trim(s or "")
  if s == "" then
    return s
  end
  local angled = s:match("^<([^>]+)>$")
  if angled then
    s = vim.trim(angled)
  end
  -- path + 可选 title
  local bare = s:match('^(%S+)%s+".-"%s*$')
    or s:match("^(%S+)%s+'.-'%s*$")
    or s:match("^(%S+)%s+%b()%s*$")
  if bare then
    return bare
  end
  return s
end

---在一行文本上找所有 ![alt](src) / [label](href)，返回 0-based 字节区间
---@param text string
---@return { kind: "image"|"link", target: string, col0: integer, col1: integer }[]
local function find_md_markup_spans(text)
  local spans = {}
  if not text or text == "" then
    return spans
  end
  local i = 1
  local n = #text
  while i <= n do
    local two = text:sub(i, i + 1)
    if two == "![" then
      local close = text:find("%]", i + 2)
      if close and text:sub(close + 1, close + 1) == "(" then
        local endp = text:find("%)", close + 2)
        if endp then
          local src = clean_md_dest(text:sub(close + 2, endp - 1))
          -- 覆盖整个 ![…](…)（含括号），col1 为闭区间末字节+1（0-based 半开）
          spans[#spans + 1] = {
            kind = "image",
            target = src,
            col0 = i - 1,
            col1 = endp, -- endp 是 1-based 的 ')' 位置 → 0-based 半开 end = endp
          }
          i = endp + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    elseif text:sub(i, i) == "[" then
      local close = text:find("%]", i + 1)
      if close and text:sub(close + 1, close + 1) == "(" then
        local endp = text:find("%)", close + 2)
        if endp then
          local href = clean_md_dest(text:sub(close + 2, endp - 1))
          spans[#spans + 1] = {
            kind = "link",
            target = href,
            col0 = i - 1,
            col1 = endp,
          }
          i = endp + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return spans
end

---检测源 buffer 指定行列是否落在图片/链接语法上
---@param buf integer
---@param row integer 1-based
---@param col integer 0-based byte
---@return { kind: "image"|"link", target: string }|nil
function M._detect_source_markup_at(buf, row, col)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not row or row < 1 then
    return nil
  end
  col = col or 0
  if col < 0 then
    col = 0
  end
  local lines = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)
  local text = lines[1]
  if not text then
    return nil
  end
  -- 光标在行尾时仍允许点在最后一字符上
  local maxc = #text
  if col > maxc then
    col = maxc
  end
  local hit
  for _, sp in ipairs(find_md_markup_spans(text)) do
    if col >= sp.col0 and col < sp.col1 then
      hit = sp
      -- 图片优先（后写的若重叠会覆盖；![] 先于 [] 扫描，同位置图已先入）
      if sp.kind == "image" then
        return { kind = "image", target = sp.target }
      end
    end
  end
  if hit then
    return { kind = hit.kind, target = hit.target }
  end
  return nil
end

---为源 buffer 准备带 headings 的持久 state（可无预览）
---@param buf integer
---@return table
local function ensure_source_activate_st(buf)
  local st = ensure_state(buf)
  local win = vim.api.nvim_get_current_win()
  if not st.source_win or not vim.api.nvim_win_is_valid(st.source_win) then
    st.source_win = win
  elseif vim.api.nvim_win_get_buf(win) == buf then
    st.source_win = win
  end
  -- 每次从源激活时刷新 headings（标题可能刚改过）
  local cfg = config.get()
  local blocks = parse.parse_buf(buf, cfg)
  local rev = st.result and st.result.rev_map or nil
  st.headings = anchor.collect_headings(blocks, rev)
  return st
end

---打开源码里的图片目标
---@param src string
---@param buf integer
---@return boolean
local function open_source_image(src, buf)
  if not src or src == "" then
    return false
  end
  -- 远程图 → 系统/浏览器
  if src:match("^[%w+.-]+://") then
    if vim.ui and vim.ui.open then
      local ok = pcall(vim.ui.open, src)
      if ok then
        return true
      end
    end
    if vim.fn.has("win32") == 1 then
      vim.fn.jobstart({ "cmd", "/c", "start", "", src }, { detach = true })
    elseif vim.fn.has("mac") == 1 then
      vim.fn.jobstart({ "open", src }, { detach = true })
    else
      vim.fn.jobstart({ "xdg-open", src }, { detach = true })
    end
    return true
  end
  local md_path = vim.api.nvim_buf_get_name(buf)
  local abs = select(1, image_mod.resolve_path(src, md_path))
  if abs and vim.fn.filereadable(abs) == 1 then
    -- 离开 mapping 上下文再开 float（expr/CR 里直接 open_win 会失败）
    local cfg = config.get()
    vim.schedule(function()
      image_mod.open_preview(abs, cfg)
    end)
    return true
  end
  vim.notify(require("mdview.i18n").t("no_image") .. (abs and (": " .. abs) or ""), vim.log.levels.INFO)
  return false
end

---激活编辑窗光标处的图片 / 链接。命中并处理后返回 true（未命中返回 false，便于 <CR> 透传）
---@param row integer|nil
---@param col integer|nil
---@return boolean
function M._activate_source_at(row, col)
  M.ensure_setup()
  local buf = vim.api.nvim_get_current_buf()
  if not is_markdown_source_buf(buf) then
    return false
  end
  if not row or not col then
    local cur = vim.api.nvim_win_get_cursor(0)
    row, col = cur[1], cur[2]
  end
  local hit = M._detect_source_markup_at(buf, row, col)
  if not hit then
    return false
  end
  if hit.kind == "image" then
    return open_source_image(hit.target, buf)
  end
  if hit.kind == "link" then
    local st = ensure_source_activate_st(buf)
    M._open_href(hit.target, st, { from_source = true })
    return true
  end
  return false
end

function M._activate_source_at_cursor()
  return M._activate_source_at(nil, nil)
end

local SOURCE_MAPS_VER = 2
local source_maps_au = false

---给 Markdown 源 buffer 绑 Enter / Ctrl+左键
---@param buf integer
local function attach_source_maps(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not is_markdown_source_buf(buf) then
    return
  end
  if vim.b[buf].mdview_source_maps_ver == SOURCE_MAPS_VER then
    return
  end
  vim.b[buf].mdview_source_maps_ver = SOURCE_MAPS_VER

  local opts = { buffer = buf, silent = true, nowait = true, noremap = true }

  -- 非 expr：expr 映射里 open_win / 改光标会失败或被吞
  -- 命中则 schedule 激活；未命中用 normal! 执行默认 <CR>
  vim.keymap.set("n", "<CR>", function()
    local cur = vim.api.nvim_win_get_cursor(0)
    local row, col = cur[1], cur[2]
    if not M._detect_source_markup_at(buf, row, col) then
      local n = vim.v.count1
      vim.cmd("normal! " .. n .. "\r")
      return
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      M._activate_source_at(row, col)
    end)
  end, vim.tbl_extend("force", opts, {
    desc = "mdview: Enter open image/link in editor",
  }))

  -- Ctrl+左键：先落点再激活（此前已验证可用）
  vim.keymap.set(
    "n",
    "<C-LeftMouse>",
    "<LeftMouse><Cmd>lua require('mdview')._activate_source_at_cursor()<CR>",
    vim.tbl_extend("force", opts, {
      desc = "mdview: Ctrl-click open image/link in editor",
    })
  )

  M.ensure_mouse()
end

---安装源 buffer 键位 autocmd（幂等）
function M._ensure_source_maps_au()
  if source_maps_au then
    -- 仍扫一遍已打开 buffer（热更新后版本号可能变）
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and is_markdown_source_buf(b) then
        -- 允许热更新时强制重绑
        if vim.b[b].mdview_source_maps_ver ~= SOURCE_MAPS_VER then
          attach_source_maps(b)
        end
      end
    end
    return
  end
  source_maps_au = true
  local g = vim.api.nvim_create_augroup("mdview_source_maps", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = g,
    pattern = { "markdown", "md", "pandoc" },
    callback = function(ev)
      attach_source_maps(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = g,
    callback = function(ev)
      if is_markdown_source_buf(ev.buf) then
        attach_source_maps(ev.buf)
      end
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and is_markdown_source_buf(b) then
      attach_source_maps(b)
    end
  end
end

return M
