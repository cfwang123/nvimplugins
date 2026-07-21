---@mod pdfview
--- 打开 PDF / Word 进入结构化预览：文本样式 / 表格 / █ 图 / gh 高清
local config = require("pdfview.config")
local extract_mod = require("pdfview.extract")
local render_mod = require("pdfview.render")
local highlight = require("pdfview.highlight")
local image_mod = require("pdfview.image")

local M = {}

--- Neovim 0.9 只有 vim.loop；0.10+ 为 vim.uv
local uv = vim.uv or vim.loop

---@type table<integer, table> buf -> state
local states = {}
local auto_installed = false

local function is_doc_path(path)
  return extract_mod.is_supported(path)
end

---@param buf integer
---@return table|nil
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

---是否对当前文档启用懒渲染
---@param st table
---@param cfg table
---@return boolean
local function use_lazy(st, cfg)
  if cfg.lazy_render == false then
    return false
  end
  local pc = st.data and (st.data.page_count or #(st.data.pages or {})) or 0
  local th = tonumber(cfg.lazy_threshold) or 12
  return pc >= th
end

---根据窗口 topline/botline 推算可见页区间（含缓冲）
---@param st table
---@param cfg table
---@return table<number, boolean> full_pages set
---@return number lo
---@return number hi
local function viewport_full_pages(st, cfg)
  local pc = st.data and (st.data.page_count or #(st.data.pages or {})) or 1
  pc = math.max(1, pc)
  local buf = tonumber(cfg.viewport_buffer) or 2
  if buf < 0 then
    buf = 0
  end
  if buf > 20 then
    buf = 20
  end

  local lo, hi = 1, math.min(pc, 1 + buf * 2)
  local win = st.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.bufwinid(st.buf)
  end
  if win ~= -1 and vim.api.nvim_win_is_valid(win) then
    local ok, info = pcall(vim.fn.getwininfo, win)
    local topline, botline = 1, 1
    if ok and type(info) == "table" and info[1] then
      topline = info[1].topline or 1
      botline = info[1].botline or topline
    else
      pcall(function()
        topline = vim.api.nvim_win_call(win, function()
          return vim.fn.line("w0")
        end)
        botline = vim.api.nvim_win_call(win, function()
          return vim.fn.line("w$")
        end)
      end)
    end
    local p_top = render_mod.page_at_line(st.result, topline) or st.page or 1
    local p_bot = render_mod.page_at_line(st.result, botline) or p_top
    if p_bot < p_top then
      p_bot = p_top
    end
    lo = math.max(1, p_top - buf)
    hi = math.min(pc, p_bot + buf)
  end

  -- 首次尚无 result：渲染开头
  if not st.result then
    lo, hi = 1, math.min(pc, 1 + buf * 2)
  end

  local set = {}
  for p = lo, hi do
    set[p] = true
  end
  -- 当前页始终在集合内（翻页/跳转）
  if st.page and st.page >= 1 and st.page <= pc then
    set[st.page] = true
    for p = math.max(1, st.page - buf), math.min(pc, st.page + buf) do
      set[p] = true
    end
  end
  return set, lo, hi
end

---@param st table
---@param opts {force?:boolean, preserve_view?:boolean, full_pages?:table}|nil
local function do_render(st, opts)
  opts = opts or {}
  if not st or not st.buf or not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  if not st.data then
    return
  end
  local cfg = config.get()
  local width = win_width(st.buf)
  local width_changed = st.width and math.abs(width - st.width) >= 2
  st.width = width

  if width_changed or opts.force then
    st.page_cache = {}
  end
  st.page_cache = st.page_cache or {}

  local full_pages = opts.full_pages
  local lazy = use_lazy(st, cfg)
  if not lazy then
    full_pages = nil -- 全部完整渲染
  elseif not full_pages then
    full_pages = viewport_full_pages(st, cfg)
  end

  local view
  local anchor_page, anchor_off
  local win = st.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.bufwinid(st.buf)
  end
  if opts.preserve_view ~= false and win ~= -1 and vim.api.nvim_win_is_valid(win) then
    view = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview()
    end)
    if st.result and view and view.topline then
      anchor_page = render_mod.page_at_line(st.result, view.topline)
      if anchor_page and st.result.page_ranges and st.result.page_ranges[anchor_page] then
        anchor_off = view.topline - st.result.page_ranges[anchor_page].start
      end
    end
  end

  local result = render_mod.render(st.data, {
    width = width,
    cfg = cfg,
    full_pages = full_pages,
    page_cache = st.page_cache,
  })
  st.result = result
  st.page_cache = result.page_cache or st.page_cache
  st.full_pages = full_pages
  render_mod.apply(st.buf, result)

  -- 恢复视口：按页锚点，避免 stub→full 后跳动
  if view and win ~= -1 and vim.api.nvim_win_is_valid(win) then
    if anchor_page and result.page_ranges and result.page_ranges[anchor_page] then
      local start = result.page_ranges[anchor_page].start
      local finish = result.page_ranges[anchor_page].finish
      local top = start + math.max(0, anchor_off or 0)
      if top > finish then
        top = start
      end
      view.topline = top
      view.lnum = math.max(top, math.min(view.lnum or top, finish))
    end
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(view)
    end)
  end

  -- 清旧高清（行号已变）
  pcall(function()
    require("pdfview.graphics").clear_buf(st.buf)
  end)
  -- 搜索侧窗仍开时：重渲后恢复关键词高亮
  pcall(function()
    require("pdfview.search").apply_preview_highlight(st)
  end)
  pcall(function()
    require("pdfview.toc").sync_current(st)
  end)
end

---滚动时：先确保页已提取，再展开完整渲染
---@param st table
local function ensure_viewport(st)
  if not st or not st.data or not st.buf or not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local cfg = config.get()
  local need, lo, hi = viewport_full_pages(st, cfg)

  -- 更新当前页
  if st.result then
    local win = vim.fn.bufwinid(st.buf)
    if win ~= -1 then
      local top = vim.api.nvim_win_call(win, function()
        return vim.fn.line("w0")
      end)
      local p = render_mod.page_at_line(st.result, top)
      if p then
        st.page = p
        pcall(function()
          require("pdfview.toc").sync_current(st)
        end)
      end
    end
  end

  -- PDF 懒提取：视口页尚未 extract 时异步补提
  local need_extract = false
  if st.kind == "pdf" and st.data.lazy then
    for p = lo, hi do
      if need[p] and not extract_mod.page_ready(st.data, p) then
        need_extract = true
        break
      end
    end
  end

  local function after_data_ready()
    local cache = st.page_cache or {}
    -- 视口内已提取但当前 buffer 仍是 stub/未 full → 必须重绘
    -- （修复：滚走再滚回时 cache 命中却不 assemble，页内容消失）
    local need_rerender = false
    for p = lo, hi do
      if need[p] and extract_mod.page_ready(st.data, p) then
        local shown = st.result and st.result.page_ranges and st.result.page_ranges[p]
        if not shown or not shown.full then
          need_rerender = true
          break
        end
        if not cache[p] or not cache[p].full then
          need_rerender = true
          break
        end
      end
    end
    if need_extract then
      for p = lo, hi do
        if need[p] then
          cache[p] = nil
        end
      end
      st.page_cache = cache
      do_render(st, { full_pages = need, preserve_view = true })
      return
    end
    if need_rerender then
      do_render(st, { full_pages = need, preserve_view = true })
    end
  end

  if need_extract then
    if st.extract_job then
      return -- 已有提取任务
    end
    local job = extract_mod.ensure_pages_async(st.path, st.data, lo, hi, false, function(ok, changed, err)
      st.extract_job = nil
      if not ok then
        if err then
          vim.notify(require("pdfview.i18n").t("err") .. tostring(err), vim.log.levels.WARN)
        end
        return
      end
      if changed then
        after_data_ready()
      end
    end)
    st.extract_job = job
    return
  end

  after_data_ready()
end

---@param st table
local function attach_maps(st)
  local buf = st.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if st.maps_version == 9 then
    return
  end
  st.maps_version = 9
  local opts = { buffer = buf, silent = true, nowait = true }

  -- 图片点击需要 mouse
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

  -- q/Esc：先关搜索，再关 TOC，最后才关预览
  vim.keymap.set("n", "q", with_st(function(s)
    local search = require("pdfview.search")
    if search.is_open(s) or search.has_session(s) then
      search.close(s)
      return
    end
    local toc = require("pdfview.toc")
    if toc.is_open(s) then
      toc.close(s)
      return
    end
    M.close(s.buf)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: close search/toc/preview" }))

  vim.keymap.set("n", "<Esc>", with_st(function(s)
    local search = require("pdfview.search")
    if search.is_open(s) or search.has_session(s) then
      search.close(s)
      return
    end
    local toc = require("pdfview.toc")
    if toc.is_open(s) then
      toc.close(s)
      return
    end
    M.close(s.buf)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: close search/toc/preview" }))

  vim.keymap.set("n", "r", with_st(function(s)
    M.refresh(s.buf, true)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: refresh" }))

  -- 翻页只用 ] / [；n/N 仅搜索结果下/上一条
  vim.keymap.set("n", "]", with_st(function(s)
    M.goto_page(s, (s.page or 1) + 1)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: next page" }))

  vim.keymap.set("n", "[", with_st(function(s)
    M.goto_page(s, (s.page or 1) - 1)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: prev page" }))

  vim.keymap.set("n", "n", with_st(function(s)
    local search = require("pdfview.search")
    if search.has_session(s) then
      search.jump_relative(s, 1)
    else
      vim.notify(require("pdfview.i18n").t("search_no_session"), vim.log.levels.INFO)
    end
  end), vim.tbl_extend("force", opts, { desc = "pdfview: next search hit" }))

  vim.keymap.set("n", "N", with_st(function(s)
    local search = require("pdfview.search")
    if search.has_session(s) then
      search.jump_relative(s, -1)
    else
      vim.notify(require("pdfview.i18n").t("search_no_session"), vim.log.levels.INFO)
    end
  end), vim.tbl_extend("force", opts, { desc = "pdfview: prev search hit" }))

  -- 页面跳转：gg 首页；G 末页；42G / 42gg 跳到第 42 页；gp 输入页码
  local function max_page(s)
    return (s.data and (s.data.page_count or #(s.data.pages or {}))) or 1
  end

  vim.keymap.set("n", "gg", with_st(function(s)
    local count = vim.v.count
    if count > 0 then
      M.goto_page(s, count)
    else
      M.goto_page(s, 1)
    end
  end), vim.tbl_extend("force", opts, { desc = "pdfview: first page / {count}gg" }))

  vim.keymap.set("n", "G", with_st(function(s)
    local count = vim.v.count
    local maxp = max_page(s)
    if count > 0 then
      M.goto_page(s, count)
    else
      M.goto_page(s, maxp)
    end
  end), vim.tbl_extend("force", opts, { desc = "pdfview: last page / {count}G" }))

  vim.keymap.set("n", "gp", with_st(function(s)
    local i18n = require("pdfview.i18n")
    local maxp = max_page(s)
    local cur = s.page or 1
    vim.ui.input({
      prompt = string.format(i18n.t("goto_page_prompt"), maxp),
      default = tostring(cur),
    }, function(input)
      if not input or vim.trim(input) == "" then
        return
      end
      local n = tonumber(vim.trim(input))
      if not n or n ~= math.floor(n) then
        vim.notify(i18n.t("goto_page_bad"), vim.log.levels.WARN)
        return
      end
      n = math.max(1, math.min(maxp, n))
      M.goto_page(s, n)
    end)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: go to page number" }))

  vim.keymap.set("n", "gi", with_st(function(s)
    M._open_image_at_cursor(s)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: image float" }))

  vim.keymap.set("n", "gh", with_st(function(s)
    M._toggle_page_hd(s)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: page HD overlay" }))

  vim.keymap.set("n", "o", with_st(function(s)
    local path = M._image_path_at_cursor(s)
    if path then
      image_mod.open_with_system(path)
    else
      local doc = s.path
      if doc and vim.fn.filereadable(doc) == 1 then
        image_mod.open_with_system(doc)
      end
    end
  end), vim.tbl_extend("force", opts, { desc = "pdfview: system open" }))

  vim.keymap.set("n", "?", function()
    require("pdfview.help").toggle_float()
  end, vim.tbl_extend("force", opts, { desc = "pdfview: help" }))

  vim.keymap.set("n", "L", function()
    M.toggle_ui_lang()
  end, vim.tbl_extend("force", opts, { desc = "pdfview: toggle UI language" }))

  -- 全文搜索（PDF 用 PyMuPDF 扫全书，不依赖懒提取 buffer）
  vim.keymap.set("n", "/", with_st(function(s)
    require("pdfview.search").prompt_and_search(s)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: full-text search" }))

  -- 左侧大纲 TOC
  vim.keymap.set("n", "t", with_st(function(s)
    require("pdfview.toc").toggle(s, { focus = true })
  end), vim.tbl_extend("force", opts, { desc = "pdfview: toggle TOC" }))

  -- Enter / 点击：打开图片 float（支持时加载高清）
  vim.keymap.set("n", "<CR>", with_st(function(s)
    M._activate_at_cursor(s)
  end), vim.tbl_extend("force", opts, { desc = "pdfview: activate" }))

  local function on_mouse_click()
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      local s = get_state(buf)
      if s then
        M._activate_at_cursor(s)
      end
    end)
  end
  vim.keymap.set("n", "<LeftRelease>", on_mouse_click, opts)
  vim.keymap.set("n", "<2-LeftMouse>", on_mouse_click, opts)
end

---@param st table
local function attach_autocmds(st)
  if st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
  end
  local buf = st.buf
  local aug = vim.api.nvim_create_augroup("PdfView_" .. buf, { clear = true })
  st.au_group = aug

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = aug,
    buffer = buf,
    callback = function()
      pcall(function()
        require("pdfview.graphics").clear_buf(buf)
      end)
      if st.resize_timer then
        pcall(function()
          st.resize_timer:stop()
          st.resize_timer:close()
        end)
        st.resize_timer = nil
      end
      if st.viewport_timer then
        pcall(function()
          st.viewport_timer:stop()
          st.viewport_timer:close()
        end)
        st.viewport_timer = nil
      end
      states[buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local w = vim.fn.bufwinid(buf)
      if w == -1 then
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
      local timer = uv.new_timer()
      st.resize_timer = timer
      if timer then
        timer:start(120, 0, function()
          vim.schedule(function()
            local s = get_state(buf)
            if s and s.data then
              do_render(s, { force = true, preserve_view = true })
            end
          end)
        end)
      end
    end,
  })

  -- 滚动 / 光标移动：靠近未渲染页时再展开
  local function schedule_viewport()
    if st.viewport_timer then
      pcall(function()
        st.viewport_timer:stop()
      end)
    end
    local timer = uv.new_timer()
    st.viewport_timer = timer
    if timer then
      timer:start(60, 0, function()
        vim.schedule(function()
          local s = get_state(buf)
          if s and s.data then
            ensure_viewport(s)
          end
        end)
      end)
    end
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = aug,
    buffer = buf,
    callback = function()
      schedule_viewport()
    end,
  })
  -- WinScrolled 无 buffer 过滤；只在本预览仍显示时处理
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = aug,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.fn.bufwinid(buf) == -1 then
        return
      end
      schedule_viewport()
    end,
  })
end

---准备预览 buffer 选项（渲染前保持可写）
---@param buf integer
local function prep_buf(buf)
  pcall(function()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    vim.bo[buf].filetype = "pdfview"
    vim.bo[buf].binary = false
  end)
  vim.b[buf].pdfview_preview = true
end

---打开路径的 PDF / Word 预览
---@param path string|nil
---@param opts {force?:boolean, win?:integer}|nil
function M.open(path, opts)
  opts = opts or {}
  config.ensure_setup()
  highlight.setup(config.get().highlights)
  highlight.ensure()

  path = path and path ~= "" and path or vim.fn.expand("%:p")
  path = vim.fn.fnamemodify(path, ":p")
  local i18n = require("pdfview.i18n")
  if not is_doc_path(path) then
    vim.notify(i18n.t("not_supported") .. tostring(path), vim.log.levels.WARN)
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

  -- 复用已有预览
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

  local kind = extract_mod.kind_of(path) or "doc"
  if kind == "pdf" then
    vim.notify(string.format(i18n.t("extracting"), "pdf") .. " · lazy", vim.log.levels.INFO)
  else
    vim.notify(string.format(i18n.t("extracting"), kind), vim.log.levels.INFO)
  end
  local data, err = extract_mod.extract(path, opts.force)
  if not data then
    vim.notify(i18n.t("err") .. tostring(err), vim.log.levels.ERROR)
    return
  end
  data.kind = data.kind or kind

  local buf = vim.api.nvim_create_buf(true, false)
  prep_buf(buf)
  pcall(vim.api.nvim_buf_set_name, buf, path .. " [pdfview]")

  local st = {
    buf = buf,
    win = win,
    path = path,
    kind = kind,
    data = data,
    page = 1,
    result = nil,
    page_cache = {},
    width = nil,
    maps_version = 0,
    extract_job = nil,
  }
  states[buf] = st

  vim.api.nvim_win_set_buf(win, buf)
  apply_winopts(win, config.get())
  do_render(st, { force = true, preserve_view = false })
  attach_maps(st)
  attach_autocmds(st)
  -- 有大纲且配置开启：默认打开左侧 TOC（焦点留在预览）
  if config.get().toc ~= false and kind == "pdf" then
    pcall(function()
      require("pdfview.toc").open(st, { focus = false })
    end)
  end
  -- 打开后再按真实窗口高度补一帧视口（可能触发异步提取）
  vim.schedule(function()
    local s = get_state(buf)
    if s then
      ensure_viewport(s)
      pcall(function()
        require("pdfview.toc").sync_current(s)
      end)
    end
  end)

  local pc = data.page_count or #(data.pages or {})
  local ready = 0
  for i = 1, pc do
    if extract_mod.page_ready(data, i) then
      ready = ready + 1
    end
  end
  local fmt = (kind == "pdf") and i18n.t("open_echo_pages") or i18n.t("open_echo_sections")
  local msg = string.format(fmt, vim.fn.fnamemodify(path, ":t"), pc)
  if kind == "pdf" and data.lazy and ready < pc then
    msg = msg .. string.format(" · loaded %d/%d", ready, pc)
  end
  pcall(vim.api.nvim_echo, { { msg, "MoreMsg" } }, false, {})
  return buf
end

---关闭预览
---@param buf integer|nil
function M.close(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = states[buf]
  pcall(function()
    require("pdfview.graphics").clear_buf(buf)
  end)
  image_mod.close_float()
  require("pdfview.help").close()
  pcall(function()
    require("pdfview.search").close(st)
  end)
  pcall(function()
    require("pdfview.toc").close(st)
  end)
  if st and st.au_group then
    pcall(vim.api.nvim_del_augroup_by_id, st.au_group)
  end
  if st and st.viewport_timer then
    pcall(function()
      st.viewport_timer:stop()
      st.viewport_timer:close()
    end)
  end
  if st and st.resize_timer then
    pcall(function()
      st.resize_timer:stop()
      st.resize_timer:close()
    end)
  end
  if st and st.extract_job and st.extract_job > 0 then
    pcall(vim.fn.jobstop, st.extract_job)
    st.extract_job = nil
  end
  states[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].pdfview_preview then
    -- 尝试打开原 PDF 的二进制 buffer 或关闭
    local path = st and st.path
    local wins = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        wins[#wins + 1] = w
      end
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if path and #wins > 0 then
      -- 用新空 buffer 占位，避免只剩空白
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
end

---@param buf integer|nil
---@param force boolean|nil
function M.refresh(buf, force)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = states[buf]
  if not st then
    return
  end
  local i18n = require("pdfview.i18n")
  local data, err = extract_mod.extract(st.path, force)
  if not data then
    vim.notify(i18n.t("err") .. tostring(err), vim.log.levels.ERROR)
    return
  end
  st.data = data
  st.page_cache = {}
  st.extract_job = nil
  do_render(st, { force = true, preserve_view = false })
  vim.notify(i18n.t("refreshed"), vim.log.levels.INFO)
end

---@param st table
---@param page number
function M.goto_page(st, page)
  if not st or not st.data then
    return
  end
  local maxp = st.data.page_count or #(st.data.pages or {}) or 1
  page = math.max(1, math.min(maxp, page))
  st.page = page

  local cfg = config.get()
  local bufn = tonumber(cfg.viewport_buffer) or 2
  local lo = math.max(1, page - bufn)
  local hi = math.min(maxp, page + bufn)

  local function jump()
    local need = {}
    for p = lo, hi do
      need[p] = true
    end
    if use_lazy(st, cfg) then
      do_render(st, { full_pages = need, preserve_view = false })
    else
      do_render(st, { preserve_view = false })
    end
    local line = st.result and st.result.page_map and st.result.page_map[page]
    if line and st.buf and vim.api.nvim_buf_is_valid(st.buf) then
      -- 优先 st.win（预览窗），避免落到搜索侧窗
      local win = st.win
      if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= st.buf then
        win = vim.fn.bufwinid(st.buf)
      end
      if win ~= -1 then
        st.win = win
        pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zt")
        end)
      end
    end
    pcall(vim.api.nvim_echo, {
      { string.format("pdfview: page %d / %d", page, maxp), "MoreMsg" },
    }, false, {})
    pcall(function()
      require("pdfview.toc").sync_current(st)
    end)
  end

  -- 目标页未提取：同步抽一小段（跳页应立刻可见）
  if st.kind == "pdf" and st.data.lazy then
    local ok, err = extract_mod.ensure_pages_sync(st.path, st.data, lo, hi, false)
    if not ok and err then
      vim.notify(require("pdfview.i18n").t("err") .. tostring(err), vim.log.levels.WARN)
    end
    -- 清缓存以便用新数据渲染
    st.page_cache = st.page_cache or {}
    for p = lo, hi do
      st.page_cache[p] = nil
    end
  end
  jump()
end

---@param st table
---@param row number 1-based
---@param col number 0-based byte
---@return table|nil
function M._hit_at(st, row, col)
  if not st or not st.result then
    return nil
  end
  for _, h in ipairs(st.result.hits or {}) do
    local a = h.line or 1
    local b = h.line_end or a
    if row >= a and row <= b then
      if h.col == nil or h.end_col == nil or (col >= (h.col or 0) and col < (h.end_col or math.huge)) then
        return h
      end
      -- 整宽块图：无严格列约束时仍命中
      if h.kind == "image" or h.kind == "image_hd" then
        return h
      end
    end
  end
  return nil
end

---@param st table
---@return string|nil
function M._image_path_at_cursor(st)
  if not st or not st.result then
    return nil
  end
  local win = vim.fn.bufwinid(st.buf)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1], cursor[2]
  local hit = M._hit_at(st, row, col)
  if hit and hit.path and (hit.kind == "image" or hit.kind == "image_hd") then
    return hit.path
  end
  for _, h in ipairs(st.result.hits or {}) do
    if h.kind == "image" and h.path then
      local a, b = h.line or 1, h.line_end or h.line or 1
      if row >= a and row <= b then
        return h.path
      end
    end
  end
  return nil
end

---Enter / 点击：图片 → float 高清预览
function M._activate_at_cursor(st)
  local path = M._image_path_at_cursor(st)
  if path then
    image_mod.open_preview(path, config.get())
    return
  end
  -- 非图片：忽略（Word/PDF 暂无其它可激活目标）
end

function M._open_image_at_cursor(st)
  local path = M._image_path_at_cursor(st)
  if path then
    image_mod.open_preview(path, config.get())
  else
    vim.notify(require("pdfview.i18n").t("no_image"), vim.log.levels.INFO)
  end
end

function M._toggle_page_hd(st)
  local i18n = require("pdfview.i18n")
  if not st then
    return
  end
  local buf = st.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify(i18n.t("no_preview"), vim.log.levels.WARN)
    return
  end
  local ok_g, graphics = pcall(require, "pdfview.graphics")
  if not ok_g or not graphics then
    vim.notify(i18n.t("gfx_fail"), vim.log.levels.ERROR)
    return
  end
  if graphics.is_active and graphics.is_active(buf) then
    graphics.clear_buf(buf)
    vim.notify(i18n.t("page_hd_off"), vim.log.levels.INFO)
    return
  end
  local cfg = config.get()
  local imgcfg = cfg.image or {}
  if graphics.detect and not graphics.detect(imgcfg, "float") then
    vim.notify(i18n.t("page_hd_unsupported"), vim.log.levels.INFO)
    return
  end
  local win = st.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.bufwinid(buf)
  end
  if not win or win == -1 then
    win = vim.api.nvim_get_current_win()
  end
  st.win = win
  local hits = st.result and st.result.hits or {}
  local ok = graphics.attach_preview({
    buf = buf,
    win = win,
    hits = hits,
    max_images = imgcfg.max_images or 20,
    scale = imgcfg.float_scale == "fit" and "fit" or "fill",
    python = imgcfg.python or cfg.python or "python",
    visible_only = true,
    clear_on_scroll = true,
  })
  if not ok then
    vim.notify(i18n.t("page_hd_none"), vim.log.levels.INFO)
  else
    pcall(vim.api.nvim_echo, {
      { i18n.t("page_hd_on"), "MoreMsg" },
    }, false, {})
    vim.defer_fn(function()
      if graphics.is_active and graphics.is_active(buf) and graphics._repaint_buf then
        graphics._repaint_buf(buf)
      end
    end, 60)
  end
end

---当前 buffer 是否为 pdfview 预览
function M.is_preview_buf(buf)
  buf = buf or 0
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  return vim.b[buf].pdfview_preview == true
end

---切换中/英文并重绘所有预览
function M.toggle_ui_lang()
  local i18n = require("pdfview.i18n")
  local next_lang = i18n.toggle()
  i18n.save_prefs()
  if next_lang == "en" then
    vim.notify(i18n.t("lang_to_en"), vim.log.levels.INFO)
  else
    vim.notify(i18n.t("lang_to_zh"), vim.log.levels.INFO)
  end
  local help = require("pdfview.help")
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
  -- 修正 zip 插件抢 .docx（须在 auto 打开之前）
  pcall(function()
    require("pdfview.zipfix").install()
  end)
  M._install_auto()
end

---@param buf integer
---@param path string
local function try_open_from_buf(buf, path)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.b[buf].pdfview_preview or vim.b[buf].pdfview_skip then
    return
  end
  if not is_doc_path(path) then
    return
  end
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if vim.b[buf].pdfview_preview then
      return
    end
    local win = vim.fn.bufwinid(buf)
    if win == -1 then
      win = vim.api.nvim_get_current_win()
    end
    local opened = M.open(path, { win = win })
    if opened and vim.api.nvim_buf_is_valid(buf) and buf ~= opened then
      vim.b[buf].pdfview_skip = true
      pcall(function()
        if vim.bo[buf].buflisted then
          vim.bo[buf].bufhidden = "wipe"
        end
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
end

function M._install_auto()
  if auto_installed then
    return
  end
  auto_installed = true
  local aug = vim.api.nvim_create_augroup("PdfViewAuto", { clear = true })

  local word_pat = { "*.docx", "*.DOCX", "*.docm", "*.DOCM", "*.dotx", "*.DOTX", "*.doc", "*.DOC" }
  local all_pat = {
    "*.pdf",
    "*.PDF",
    "*.docx",
    "*.DOCX",
    "*.docm",
    "*.DOCM",
    "*.dotx",
    "*.DOTX",
    "*.doc",
    "*.DOC",
  }

  -- 兜底：若仍有 BufReadCmd 抢文件，我们自己读空 buffer 再进预览（nested）
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = word_pat,
    nested = true,
    desc = "pdfview: open Word without zip#Browse",
    callback = function(args)
      local cfg = config.get()
      if cfg.auto_open == false then
        -- 不预览时仍避免 zip：按二进制占位
        local path = vim.fn.fnamemodify(args.file ~= "" and args.file or args.match, ":p")
        pcall(vim.api.nvim_buf_set_lines, args.buf, 0, -1, false, {
          "pdfview: auto_open=false · use :PdfView to preview",
          path,
        })
        vim.bo[args.buf].buftype = "nofile"
        vim.bo[args.buf].swapfile = false
        return
      end
      local path = vim.fn.fnamemodify(args.file ~= "" and args.file or args.match, ":p")
      -- 占位，满足 BufReadCmd「自行填充 buffer」约定
      pcall(vim.api.nvim_buf_set_lines, args.buf, 0, -1, false, { "pdfview: loading…" })
      pcall(function()
        vim.bo[args.buf].buftype = "nofile"
        vim.bo[args.buf].swapfile = false
        vim.bo[args.buf].modifiable = false
        vim.b[args.buf].pdfview_skip = true -- 防止随后 BufReadPost 再开一次
      end)
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

  -- 正常读入后（pdf / 已解除 zip 的 word）进入预览
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = aug,
    pattern = all_pat,
    callback = function(args)
      local cfg = config.get()
      if cfg.auto_open == false then
        return
      end
      local buf = args.buf
      local path = vim.api.nvim_buf_get_name(buf)
      try_open_from_buf(buf, path)
    end,
  })
end

---供命令用：对当前文件打开
function M.open_current()
  M.ensure_setup()
  return M.open(vim.fn.expand("%:p"))
end

return M
