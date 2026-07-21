---@mod pdfview.search
--- `/` 全文搜索：结果在右侧专用窗口；n/N 跳转；预览与结果窗高亮关键词
local config = require("pdfview.config")
local extract_mod = require("pdfview.extract")
local highlight = require("pdfview.highlight")

local M = {}

local SEARCH_NS = vim.api.nvim_create_namespace("pdfview_search_hl")
---结果列表顶部固定行数（标题 / 帮助 / 分隔线）
local HEADER_LINES = 3

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function python_cmd()
  local cfg = config.get()
  local py = cfg.python or "python"
  if vim.fn.executable(py) == 1 then
    return py
  end
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  return nil
end

local function ensure_hl()
  highlight.ensure()
  -- 搜索高亮（黄底，接近 Search）
  pcall(vim.api.nvim_set_hl, 0, "PdfViewSearchMatch", {
    bg = "#ffcc66",
    fg = "#000000",
    bold = true,
    default = false,
  })
  pcall(vim.api.nvim_set_hl, 0, "PdfViewSearchCur", {
    bg = "#ff8800",
    fg = "#000000",
    bold = true,
    default = false,
  })
  pcall(vim.api.nvim_set_hl, 0, "PdfViewSearchHeader", {
    fg = "#003366",
    bold = true,
    default = false,
  })
end

---在指定窗内删除 match（match 是 window-local）
---@param win integer|nil
---@param ids integer[]|nil
local function matchdelete_in_win(win, ids)
  if not ids or #ids == 0 then
    return
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, function()
      for _, id in ipairs(ids) do
        pcall(vim.fn.matchdelete, id)
      end
    end)
  else
    for _, id in ipairs(ids) do
      pcall(vim.fn.matchdelete, id)
    end
  end
end

---清除搜索 match / extmark
---@param st table
local function clear_buf_matches(st, which)
  if not st or not st.search then
    return
  end
  local ids = st.search.match_ids or {}
  local pwin = st.win
  if pwin and (not vim.api.nvim_win_is_valid(pwin) or vim.api.nvim_win_get_buf(pwin) ~= st.buf) then
    pwin = vim.fn.bufwinid(st.buf)
  end
  local lwin = st.search.win
  if which == "preview" or not which then
    matchdelete_in_win(pwin, ids.preview)
    ids.preview = {}
    if st.buf and vim.api.nvim_buf_is_valid(st.buf) then
      pcall(vim.api.nvim_buf_clear_namespace, st.buf, SEARCH_NS, 0, -1)
    end
  end
  if which == "list" or not which then
    matchdelete_in_win(lwin, ids.list)
    ids.list = {}
    if st.search.buf and vim.api.nvim_buf_is_valid(st.search.buf) then
      pcall(vim.api.nvim_buf_clear_namespace, st.search.buf, SEARCH_NS, 0, -1)
    end
  end
  st.search.match_ids = ids
end

---在指定窗口 matchadd 关键词
---@param win integer
---@param query string
---@return integer[] match_ids
local function matchadd_query(win, query)
  if not win or win == -1 or not vim.api.nvim_win_is_valid(win) then
    return {}
  end
  if not query or query == "" then
    return {}
  end
  local ids = {}
  pcall(function()
    vim.api.nvim_win_call(win, function()
      local pat = "\\c\\V" .. vim.fn.escape(query, "\\")
      local id = vim.fn.matchadd("PdfViewSearchMatch", pat, 20)
      if type(id) == "number" and id > 0 then
        ids[#ids + 1] = id
      end
    end)
  end)
  return ids
end

---结果列表高亮（标题 + 每行关键词 extmark）
---@param st table
local function apply_list_highlight(st)
  if not st or not st.search or not st.search.buf then
    return
  end
  if not vim.api.nvim_buf_is_valid(st.search.buf) then
    return
  end
  ensure_hl()
  local buf = st.search.buf
  local query = st.search.query or ""
  pcall(vim.api.nvim_buf_clear_namespace, buf, SEARCH_NS, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if lines[1] then
    pcall(vim.api.nvim_buf_set_extmark, buf, SEARCH_NS, 0, 0, {
      end_col = #lines[1],
      hl_group = "PdfViewSearchHeader",
      priority = 100,
    })
  end
  if lines[2] then
    pcall(vim.api.nvim_buf_set_extmark, buf, SEARCH_NS, 1, 0, {
      end_col = #lines[2],
      hl_group = "PdfViewMeta",
      priority = 100,
    })
  end

  if query == "" then
    return
  end
  local q_low = query:lower()
  local q_len = #query
  for i, line in ipairs(lines) do
    if i <= HEADER_LINES then
      goto continue
    end
    local low = line:lower()
    local col = 1
    while true do
      local pos = low:find(q_low, col, true)
      if not pos then
        break
      end
      local matched = line:sub(pos, pos + q_len - 1)
      local end_col = pos - 1 + math.max(1, #matched)
      pcall(vim.api.nvim_buf_set_extmark, buf, SEARCH_NS, i - 1, pos - 1, {
        end_col = end_col,
        hl_group = "PdfViewSearchMatch",
        priority = 200,
      })
      col = pos + math.max(1, q_len)
    end
    ::continue::
  end
end

---预览区高亮（搜索窗存在时保持）
---@param st table
function M.apply_preview_highlight(st)
  if not st or not st.search or not st.search.query or st.search.query == "" then
    return
  end
  if not M.is_open(st) then
    return
  end
  ensure_hl()
  local pwin = st.win
  if not pwin or not vim.api.nvim_win_is_valid(pwin) or vim.api.nvim_win_get_buf(pwin) ~= st.buf then
    pwin = vim.fn.bufwinid(st.buf)
  end
  matchdelete_in_win(pwin, (st.search.match_ids and st.search.match_ids.preview) or {})
  st.search.match_ids = st.search.match_ids or { preview = {}, list = {} }
  st.search.match_ids.preview = matchadd_query(pwin, st.search.query)
end

---搜索窗是否打开
---@param st table|nil
---@return boolean
function M.is_open(st)
  if st and st.search and st.search.win and vim.api.nvim_win_is_valid(st.search.win) then
    return true
  end
  -- 兼容无 st 时的全局探测
  return false
end

---关闭搜索侧窗并清高亮
---@param st table|nil
function M.close(st)
  if st and st.search then
    clear_buf_matches(st, nil)
    local w = st.search.win
    local b = st.search.buf
    st.search.win = nil
    st.search.buf = nil
    -- 保留 query/hits 可选；按需求关闭即结束会话，n 恢复翻页
    st.search.hits = nil
    st.search.idx = nil
    st.search.query = nil
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

-- 兼容旧名
function M.close_float(st)
  M.close(st)
end

---从已提取的 Word/PDF data 里搜（仅已加载页）
---@param data table
---@param query string
---@param max_hits number
---@return table[] hits
local function search_in_data(data, query, max_hits)
  local hits = {}
  if not data or not data.pages or query == "" then
    return hits
  end
  local q = query:lower()
  for _, page in ipairs(data.pages) do
    if page._pending then
      goto continue
    end
    local pno = page.page or 1
    local chunks = {}
    for _, block in ipairs(page.blocks or {}) do
      if block.type == "text" then
        for _, line in ipairs(block.lines or {}) do
          local parts = {}
          for _, sp in ipairs(line.spans or {}) do
            parts[#parts + 1] = sp.text or ""
          end
          local t = table.concat(parts, "")
          if t ~= "" then
            chunks[#chunks + 1] = t
          end
        end
      elseif block.type == "table" then
        for _, row in ipairs(block.rows or {}) do
          chunks[#chunks + 1] = table.concat(row, " ")
        end
      end
    end
    local full = table.concat(chunks, "\n")
    local low = full:lower()
    local start = 1
    local per = 0
    while per < 6 and #hits < max_hits do
      local pos = low:find(q, start, true)
      if not pos then
        break
      end
      local a = math.max(1, pos - 40)
      local b = math.min(#full, pos + #query + 40)
      local snip = full:sub(a, b):gsub("%s+", " ")
      if a > 1 then
        snip = "…" .. snip
      end
      if b < #full then
        snip = snip .. "…"
      end
      hits[#hits + 1] = {
        page = pno,
        snippet = snip,
        line = snip,
      }
      per = per + 1
      start = pos + #query
    end
    ::continue::
  end
  return hits
end

---@param path string
---@param query string
---@param max_hits number
---@param on_done fun(ok:boolean, result:table|nil, err?:string)
local function search_pdf_async(path, query, max_hits, on_done)
  local py = python_cmd()
  if not py then
    on_done(false, nil, "python not found")
    return
  end
  local script = plugin_root() .. "/scripts/search.py"
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) ~= 1 then
    on_done(false, nil, "search.py missing")
    return
  end
  local chunks, errc = {}, {}
  local job = vim.fn.jobstart({
    py,
    "-X",
    "utf8",
    script,
    path,
    query,
    tostring(max_hits or 200),
  }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          chunks[#chunks + 1] = line
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          errc[#errc + 1] = line
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local raw = table.concat(chunks, "\n"):gsub("^\239\187\191", ""):gsub("\r", "")
        local json_str = raw:match("(%b{})%s*$") or raw
        local okj, data = pcall(vim.json.decode, vim.trim(json_str))
        if not okj or type(data) ~= "table" then
          on_done(false, nil, table.concat(errc, " ") ~= "" and table.concat(errc, " ") or "bad search json")
          return
        end
        if data.ok == false then
          on_done(false, nil, tostring(data.error or "search failed"))
          return
        end
        on_done(true, data, nil)
      end)
    end,
  })
  if job <= 0 then
    on_done(false, nil, "jobstart failed")
  end
end

---从 buffer 文本识别第 page 页的起止行（1-based inclusive）
---@param buf integer
---@param page number
---@return number|nil start, number|nil finish
local function page_range_from_buf(buf, page)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil, nil
  end
  page = tonumber(page) or 0
  if page < 1 then
    return nil, nil
  end
  local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_l
  -- 兼容中英文页眉：── Page 52 / 1136  /  ── 第 52 / 1136 页
  local eng = string.format("Page %d /", page)
  local zhs = string.format("第 %d /", page)
  for i, line in ipairs(all) do
    if line:find(eng, 1, true) or line:find(zhs, 1, true) then
      start_l = i
      break
    end
  end
  if not start_l then
    return nil, nil
  end
  local end_l = #all
  for i = start_l + 1, #all do
    local line = all[i]
    if line:match("^──%s*Page%s+%d+") or line:match("^──%s*第%s+%d+") then
      end_l = i - 1
      break
    end
  end
  return start_l, end_l
end

---在页行范围内扫 buffer 定位关键词
---@param buf integer
---@param win integer
---@param page_start number 1-based
---@param page_end number 1-based inclusive
---@param query string
---@param hit table|nil
---@param which_occ number|nil 同页第几个匹配（1-based）
---@return boolean found
local function locate_within_page(buf, win, page_start, page_end, query, hit, which_occ)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if not win or win == -1 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  page_start = math.max(1, page_start or 1)
  page_end = math.max(page_start, page_end or page_start)
  which_occ = math.max(1, tonumber(which_occ) or 1)
  query = query or ""
  if query == "" then
    pcall(vim.api.nvim_win_set_cursor, win, { page_start, 0 })
    return false
  end

  -- inclusive → exclusive end for get_lines
  local lines = vim.api.nvim_buf_get_lines(buf, page_start - 1, page_end, false)
  if #lines == 0 then
    -- 再试：整 buffer 扫（page_ranges 可能失效）
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    page_start = 1
  end

  local function find_in_lines(needle, occ_target)
    if not needle or needle == "" then
      return nil
    end
    local n_low = needle:lower()
    local n_byte = #needle
    local seen = 0
    for i, line in ipairs(lines) do
      local low = line:lower()
      local col = 1
      while true do
        local pos = low:find(n_low, col, true)
        if not pos then
          break
        end
        seen = seen + 1
        if seen == occ_target then
          return page_start + i - 1, pos - 1
        end
        col = pos + math.max(1, n_byte)
      end
    end
    return nil
  end

  local row, col
  -- 纯 query 第 N 次（与结果列表「同页第几条」一致）
  row, col = find_in_lines(query, which_occ)
  if not row then
    row, col = find_in_lines(query, 1)
  end

  if row then
    -- 夹紧列到行长
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    if col > #line then
      col = math.max(0, #line - 1)
    end
    pcall(vim.api.nvim_win_set_cursor, win, { row, col or 0 })
    pcall(vim.api.nvim_win_call, win, function()
      -- 让匹配处出现在窗口中部偏上
      vim.cmd("normal! zz")
    end)
    return true
  end

  pcall(vim.api.nvim_win_set_cursor, win, { page_start, 0 })
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zt")
  end)
  return false
end

---同页命中中，当前是第几条（1-based）
---@param st table
---@param page number
---@param idx number
---@return number
local function occurrence_on_page(st, page, idx)
  if not st or not st.search or not st.search.hits then
    return 1
  end
  local n = 0
  for i = 1, idx do
    local h = st.search.hits[i]
    if h and tonumber(h.page) == page then
      n = n + 1
    end
  end
  return math.max(1, n)
end

---解析预览窗（必须是显示 st.buf 的窗，不能是搜索侧栏）
---@param st table
---@return integer|nil win
local function preview_win_of(st)
  if st.win and vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_get_buf(st.win) == st.buf then
    return st.win
  end
  if st.buf and vim.api.nvim_buf_is_valid(st.buf) then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == st.buf then
        -- 排除搜索窗（搜索窗 buf 不同，这里已是 preview buf）
        st.win = w
        return w
      end
    end
  end
  return nil
end

---@param st table
---@param hit table
---@param query string
---@param opts? { focus_preview?: boolean }
local function jump_to_hit(st, hit, query, opts)
  opts = opts or {}
  if not st or not hit or not hit.page then
    return
  end
  local page = tonumber(hit.page) or 1
  local idx = (st.search and st.search.idx) or 1
  local occ = occurrence_on_page(st, page, idx)

  if st.kind == "pdf" and st.data and st.data.lazy then
    local cfg = config.get()
    local bufn = tonumber(cfg.viewport_buffer) or 2
    local maxp = st.data.page_count or 1
    local lo = math.max(1, page - bufn)
    local hi = math.min(maxp, page + bufn)
    extract_mod.ensure_pages_sync(st.path, st.data, lo, hi, false)
    st.page_cache = st.page_cache or {}
    for p = lo, hi do
      st.page_cache[p] = nil
    end
  end
  local init = require("pdfview.init")
  if init.goto_page then
    init.goto_page(st, page)
  end

  local win = preview_win_of(st)
  if opts.focus_preview ~= false and win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end

  -- 结果列表同步当前条（不抢焦点）
  if st.search and st.search.win and vim.api.nvim_win_is_valid(st.search.win) and st.search.idx then
    local line = (st.search.idx or 1) + HEADER_LINES
    if st.search.buf and vim.api.nvim_buf_is_valid(st.search.buf) then
      local bc = vim.api.nvim_buf_line_count(st.search.buf)
      if line >= 1 and line <= bc then
        pcall(vim.api.nvim_win_set_cursor, st.search.win, { line, 0 })
      end
    end
  end

  -- 延后定位：等 goto_page 的 set_lines / 光标 zt 全部结束
  local function do_locate()
    if not st.buf or not vim.api.nvim_buf_is_valid(st.buf) then
      return
    end
    local w = preview_win_of(st)
    if not w then
      return
    end
    -- 优先从 buffer 文本识别页范围（不依赖可能过期的 page_ranges）
    local ps, pe = page_range_from_buf(st.buf, page)
    if not ps and st.result and st.result.page_ranges and st.result.page_ranges[page] then
      ps = st.result.page_ranges[page].start
      pe = st.result.page_ranges[page].finish
    end
    if not ps and st.result and st.result.page_map and st.result.page_map[page] then
      ps = st.result.page_map[page]
      local nm = st.result.page_map[page + 1]
      pe = nm and (nm - 1) or (ps + 800)
    end
    if not ps then
      ps, pe = 1, vim.api.nvim_buf_line_count(st.buf)
    end
    locate_within_page(st.buf, w, ps, pe or ps, query or "", hit, occ)
    M.apply_preview_highlight(st)
    if opts.focus_preview ~= false and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_set_current_win, w)
    end
  end
  vim.schedule(do_locate)
  -- 再补一帧：大页 re-render 偶发晚于第一帧 schedule
  vim.defer_fn(do_locate, 40)
end

---结果行号 → hit 下标（header 3 行）
local function hit_index_from_cursor(st)
  if not st or not st.search or not st.search.win then
    return nil
  end
  if not vim.api.nvim_win_is_valid(st.search.win) then
    return nil
  end
  local l = vim.api.nvim_win_get_cursor(st.search.win)[1]
  local idx = l - HEADER_LINES
  local hits = st.search.hits or {}
  if idx < 1 or idx > #hits then
    return nil
  end
  return idx
end

---@param st table
---@param result table
local function open_results_side(st, result)
  M.close(st) -- 关掉旧窗

  local i18n = require("pdfview.i18n")
  ensure_hl()
  local hits = result.hits or {}
  local query = result.query or ""

  local lines = {}
  local title = string.format(i18n.t("search_title"), query, #hits, result.total or #hits)
  if result.truncated then
    title = title .. " " .. i18n.t("search_truncated")
  end
  lines[#lines + 1] = title
  lines[#lines + 1] = i18n.t("search_help")
  lines[#lines + 1] = string.rep("─", 40)

  if #hits == 0 then
    lines[#lines + 1] = i18n.t("search_empty")
  else
    for i, h in ipairs(hits) do
      local snip = (h.line or h.snippet or ""):gsub("%s+", " ")
      if vim.fn.strdisplaywidth(snip) > 48 then
        snip = vim.fn.strcharpart(snip, 0, 46) .. "…"
      end
      lines[#lines + 1] = string.format("%3d p.%-4s %s", i, tostring(h.page or "?"), snip)
    end
  end

  local sbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
  vim.bo[sbuf].modifiable = false
  vim.bo[sbuf].buftype = "nofile"
  vim.bo[sbuf].bufhidden = "wipe"
  vim.bo[sbuf].swapfile = false
  vim.bo[sbuf].filetype = "pdfview_search"
  vim.b[sbuf].pdfview_search = true
  pcall(vim.api.nvim_buf_set_name, sbuf, "pdfview://search")

  -- 在预览窗右侧开竖分栏
  local preview_win = st.win
  if not preview_win or not vim.api.nvim_win_is_valid(preview_win) then
    preview_win = vim.fn.bufwinid(st.buf)
  end
  if preview_win == -1 or not vim.api.nvim_win_is_valid(preview_win) then
    preview_win = vim.api.nvim_get_current_win()
  end

  local swin
  vim.api.nvim_win_call(preview_win, function()
    vim.cmd("rightbelow vsplit")
    swin = vim.api.nvim_get_current_win()
  end)
  if not swin or not vim.api.nvim_win_is_valid(swin) then
    vim.notify(i18n.t("err") .. "search split failed", vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_win_set_buf(swin, sbuf)
  local w = math.max(28, math.min(48, math.floor(vim.o.columns * 0.32)))
  pcall(vim.api.nvim_win_set_width, swin, w)
  pcall(function()
    vim.wo[swin].number = false
    vim.wo[swin].relativenumber = false
    vim.wo[swin].wrap = false
    vim.wo[swin].cursorline = true
    vim.wo[swin].signcolumn = "no"
    vim.wo[swin].foldcolumn = "0"
    vim.wo[swin].list = false
    vim.wo[swin].winfix = "pdfview-search"
  end)

  st.search = {
    query = query,
    hits = hits,
    idx = #hits > 0 and 1 or 0,
    total = result.total or #hits,
    truncated = result.truncated,
    win = swin,
    buf = sbuf,
    match_ids = { preview = {}, list = {} },
  }
  st.win = preview_win -- 保持预览窗引用

  apply_list_highlight(st)
  M.apply_preview_highlight(st)
  -- matchadd/extmark 偶发需在窗就绪后再刷一次
  vim.defer_fn(function()
    if st.search and st.search.buf == sbuf then
      apply_list_highlight(st)
      M.apply_preview_highlight(st)
    end
  end, 30)

  if #hits > 0 then
    pcall(vim.api.nvim_win_set_cursor, swin, { HEADER_LINES + 1, 0 })
  end

  local function select_hit()
    local idx = hit_index_from_cursor(st)
    if not idx then
      return
    end
    st.search.idx = idx
    -- 跳转并把焦点放到 PDF 内容出现的位置
    jump_to_hit(st, hits[idx], query, { focus_preview = true })
  end

  local o = { buffer = sbuf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "q", function()
    M.close(st)
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_set_current_win, preview_win)
    end
  end, vim.tbl_extend("force", o, { desc = "pdfview: close search" }))

  vim.keymap.set("n", "<CR>", function()
    select_hit()
  end, vim.tbl_extend("force", o, { desc = "pdfview: jump hit" }))

  -- 双击
  vim.keymap.set("n", "<2-LeftMouse>", function()
    vim.schedule(select_hit)
  end, o)

  vim.keymap.set("n", "n", function()
    M.jump_relative(st, 1)
  end, vim.tbl_extend("force", o, { desc = "pdfview: next hit" }))

  vim.keymap.set("n", "N", function()
    M.jump_relative(st, -1)
  end, vim.tbl_extend("force", o, { desc = "pdfview: prev hit" }))

  -- 窗关闭时清会话
  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(swin),
    callback = function()
      if st.search and st.search.win == swin then
        clear_buf_matches(st, nil)
        st.search.win = nil
        st.search.buf = nil
        st.search.hits = nil
        st.search.query = nil
      end
    end,
  })

  -- 搜索完成：焦点必须在结果窗口
  pcall(vim.api.nvim_set_current_win, swin)
end

---提示输入并搜索
---@param st table
---@param initial string|nil
function M.prompt_and_search(st, initial)
  if not st or not st.path then
    return
  end
  local i18n = require("pdfview.i18n")
  local def = initial or (st.search and st.search.query) or ""
  vim.ui.input({
    prompt = i18n.t("search_prompt"),
    default = def,
  }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    local query = vim.trim(input)
    local max_hits = 200
    vim.notify(string.format(i18n.t("search_running"), query), vim.log.levels.INFO)

    if st.kind == "pdf" then
      search_pdf_async(st.path, query, max_hits, function(ok, result, err)
        if not ok then
          vim.notify(i18n.t("err") .. tostring(err), vim.log.levels.WARN)
          return
        end
        open_results_side(st, result)
        local n = result.total or #(result.hits or {})
        vim.notify(string.format(i18n.t("search_done"), n, query), vim.log.levels.INFO)
      end)
    else
      local hits = search_in_data(st.data, query, max_hits)
      open_results_side(st, {
        query = query,
        hits = hits,
        total = #hits,
        truncated = false,
      })
      vim.notify(string.format(i18n.t("search_done"), #hits, query), vim.log.levels.INFO)
    end
  end)
end

---是否有可用搜索会话（侧窗打开且有结果）
---@param st table
---@return boolean
function M.has_session(st)
  return st
    and st.search
    and type(st.search.hits) == "table"
    and #st.search.hits > 0
    and st.search.win
    and vim.api.nvim_win_is_valid(st.search.win)
end

---跳到下一条 / 上一条
---@param st table
---@param dir number +1 / -1
function M.jump_relative(st, dir)
  if not st or not st.search or not st.search.hits or #st.search.hits == 0 then
    vim.notify(require("pdfview.i18n").t("search_no_session"), vim.log.levels.INFO)
    return
  end
  local n = #st.search.hits
  local idx = (st.search.idx or 1) + (dir or 1)
  if idx < 1 then
    idx = n
  elseif idx > n then
    idx = 1
  end
  st.search.idx = idx
  local hit = st.search.hits[idx]
  vim.notify(
    string.format(require("pdfview.i18n").t("search_jump"), idx, n, hit.page or "?"),
    vim.log.levels.INFO
  )
  -- n/N：跳转后焦点到 PDF 内容位置
  jump_to_hit(st, hit, st.search.query or "", { focus_preview = true })
end

return M
