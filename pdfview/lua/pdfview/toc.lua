---@mod pdfview.toc
--- 左侧大纲（PDF bookmarks / outline）；Enter 跳页；t 开关
local config = require("pdfview.config")

local M = {}

local TOC_NS = vim.api.nvim_create_namespace("pdfview_toc")

local function ensure_hl()
  require("pdfview.highlight").ensure()
  pcall(vim.api.nvim_set_hl, 0, "PdfViewTocTitle", { fg = "#003366", bold = true, default = false })
  pcall(vim.api.nvim_set_hl, 0, "PdfViewTocItem", { fg = "#111111", default = false })
  pcall(vim.api.nvim_set_hl, 0, "PdfViewTocPage", { fg = "#666666", default = false })
  pcall(vim.api.nvim_set_hl, 0, "PdfViewTocCur", { bg = "#e8f0ff", bold = true, default = false })
  pcall(vim.api.nvim_set_hl, 0, "PdfViewTocHint", { fg = "#888888", default = false })
end

---@param data table|nil
---@return table[] toc {level, title, page}
function M.entries_from_data(data)
  if not data then
    return {}
  end
  local toc = data.toc
  if type(toc) ~= "table" then
    return {}
  end
  local out = {}
  for _, e in ipairs(toc) do
    if type(e) == "table" and e.title and e.page then
      out[#out + 1] = {
        level = tonumber(e.level) or 1,
        title = tostring(e.title),
        page = math.max(1, tonumber(e.page) or 1),
      }
    end
  end
  return out
end

---@param st table|nil
---@return boolean
function M.is_open(st)
  return st
    and st.toc
    and st.toc.win
    and vim.api.nvim_win_is_valid(st.toc.win)
    or false
end

---@param st table|nil
function M.close(st)
  if not st or not st.toc then
    return
  end
  local w, b = st.toc.win, st.toc.buf
  st.toc.win = nil
  st.toc.buf = nil
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
  end
  if b and vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end

---@param st table
---@return boolean has_toc
function M.has_toc(st)
  local entries = st and st.toc and st.toc.entries
  if entries and #entries > 0 then
    return true
  end
  entries = M.entries_from_data(st and st.data)
  return #entries > 0
end

---根据当前预览页，高亮 TOC 中最近条目
---@param st table
function M.sync_current(st)
  if not M.is_open(st) or not st.toc or not st.toc.buf then
    return
  end
  local entries = st.toc.entries or {}
  if #entries == 0 then
    return
  end
  local page = st.page or 1
  local best = 1
  for i, e in ipairs(entries) do
    if e.page <= page then
      best = i
    else
      break
    end
  end
  st.toc.idx = best
  local line = best + (st.toc.header_lines or 2)
  local buf = st.toc.buf
  local win = st.toc.win
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  if line < 1 or line > n then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  -- 清旧当前行高亮，标新行
  pcall(vim.api.nvim_buf_clear_namespace, buf, TOC_NS, 0, -1)
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  pcall(vim.api.nvim_buf_set_extmark, buf, TOC_NS, line - 1, 0, {
    end_col = #text,
    hl_group = "PdfViewTocCur",
    priority = 200,
  })
end

---@param st table
---@param entry table
local function jump_entry(st, entry)
  if not entry or not entry.page then
    return
  end
  local init = require("pdfview.init")
  if init.goto_page then
    init.goto_page(st, entry.page)
  end
  -- 焦点回预览
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_set_current_win, st.win)
  end
  M.sync_current(st)
end

---打开左侧 TOC 窗
---@param st table
---@param opts? { focus?: boolean }
---@return boolean ok
function M.open(st, opts)
  opts = opts or {}
  if not st or not st.buf or not vim.api.nvim_buf_is_valid(st.buf) then
    return false
  end
  local cfg = config.get()
  if cfg.toc == false then
    return false
  end

  local entries = M.entries_from_data(st.data)
  if #entries == 0 then
    return false
  end

  -- 已打开则只刷新
  if M.is_open(st) then
    st.toc.entries = entries
    M.sync_current(st)
    if opts.focus and st.toc.win then
      pcall(vim.api.nvim_set_current_win, st.toc.win)
    end
    return true
  end

  ensure_hl()
  local i18n = require("pdfview.i18n")
  local header_lines = 2
  local lines = {}
  lines[#lines + 1] = i18n.t("toc_title")
  lines[#lines + 1] = i18n.t("toc_help")

  local line_to_idx = {} ---@type table<number, number> buffer line -> entry idx
  for i, e in ipairs(entries) do
    local indent = string.rep("  ", math.max(0, (e.level or 1) - 1))
    local title = e.title or ""
    local page_s = tostring(e.page or "?")
    -- 截断过长标题
    local max_t = 36
    if vim.fn.strdisplaywidth(title) > max_t then
      title = vim.fn.strcharpart(title, 0, max_t - 1) .. "…"
    end
    local row = string.format("%s%s  %s", indent, title, page_s)
    lines[#lines + 1] = row
    line_to_idx[#lines] = i
  end

  local tbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, lines)
  vim.bo[tbuf].modifiable = false
  vim.bo[tbuf].buftype = "nofile"
  vim.bo[tbuf].bufhidden = "wipe"
  vim.bo[tbuf].swapfile = false
  vim.bo[tbuf].filetype = "pdfview_toc"
  vim.b[tbuf].pdfview_toc = true
  pcall(vim.api.nvim_buf_set_name, tbuf, "pdfview://toc")

  local preview_win = st.win
  if not preview_win or not vim.api.nvim_win_is_valid(preview_win) then
    preview_win = vim.fn.bufwinid(st.buf)
  end
  if preview_win == -1 or not vim.api.nvim_win_is_valid(preview_win) then
    preview_win = vim.api.nvim_get_current_win()
  end

  -- 预览左侧分栏
  local twin
  vim.api.nvim_win_call(preview_win, function()
    vim.cmd("leftabove vsplit")
    twin = vim.api.nvim_get_current_win()
  end)
  if not twin or not vim.api.nvim_win_is_valid(twin) then
    return false
  end

  vim.api.nvim_win_set_buf(twin, tbuf)
  local width = tonumber(cfg.toc_width) or 32
  width = math.max(22, math.min(48, width))
  pcall(vim.api.nvim_win_set_width, twin, width)
  pcall(function()
    vim.wo[twin].number = false
    vim.wo[twin].relativenumber = false
    vim.wo[twin].wrap = false
    vim.wo[twin].cursorline = true
    vim.wo[twin].signcolumn = "no"
    vim.wo[twin].foldcolumn = "0"
    vim.wo[twin].list = false
    vim.wo[twin].winfix = "pdfview-toc"
  end)

  -- 标题样式
  pcall(vim.api.nvim_buf_set_extmark, tbuf, TOC_NS, 0, 0, {
    end_col = #lines[1],
    hl_group = "PdfViewTocTitle",
  })
  pcall(vim.api.nvim_buf_set_extmark, tbuf, TOC_NS, 1, 0, {
    end_col = #lines[2],
    hl_group = "PdfViewTocHint",
  })
  -- 页码列淡色（粗略：行尾数字）
  for li = header_lines + 1, #lines do
    local line = lines[li]
    local p0, p1 = line:find("%d+%s*$")
    if p0 then
      pcall(vim.api.nvim_buf_set_extmark, tbuf, TOC_NS, li - 1, p0 - 1, {
        end_col = p1,
        hl_group = "PdfViewTocPage",
      })
    end
  end

  st.toc = st.toc or {}
  st.toc.win = twin
  st.toc.buf = tbuf
  st.toc.entries = entries
  st.toc.line_to_idx = line_to_idx
  st.toc.header_lines = header_lines
  st.toc.idx = 1
  st.win = preview_win

  local function entry_at_cursor()
    local l = vim.api.nvim_win_get_cursor(twin)[1]
    local idx = line_to_idx[l]
    if not idx then
      return nil
    end
    return entries[idx], idx
  end

  local function select()
    local e, idx = entry_at_cursor()
    if not e then
      return
    end
    st.toc.idx = idx
    jump_entry(st, e)
  end

  local o = { buffer = tbuf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "q", function()
    M.close(st)
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_set_current_win, preview_win)
    end
  end, vim.tbl_extend("force", o, { desc = "pdfview: close toc" }))

  vim.keymap.set("n", "t", function()
    M.toggle(st)
  end, vim.tbl_extend("force", o, { desc = "pdfview: toggle toc" }))

  vim.keymap.set("n", "<CR>", select, vim.tbl_extend("force", o, { desc = "pdfview: toc jump" }))
  vim.keymap.set("n", "<2-LeftMouse>", function()
    vim.schedule(select)
  end, o)

  -- 也支持 o 跳转
  vim.keymap.set("n", "o", select, o)

  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(twin),
    callback = function()
      if st.toc and st.toc.win == twin then
        st.toc.win = nil
        st.toc.buf = nil
      end
    end,
  })

  M.sync_current(st)

  if opts.focus then
    pcall(vim.api.nvim_set_current_win, twin)
  else
    -- 默认焦点留在预览
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_set_current_win, preview_win)
    end
  end
  return true
end

---切换 TOC
---@param st table
---@param opts? { focus?: boolean }
function M.toggle(st, opts)
  if M.is_open(st) then
    M.close(st)
    if st.win and vim.api.nvim_win_is_valid(st.win) then
      pcall(vim.api.nvim_set_current_win, st.win)
    end
    return false
  end
  local ok = M.open(st, opts or { focus = true })
  if not ok then
    vim.notify(require("pdfview.i18n").t("toc_empty"), vim.log.levels.INFO)
  end
  return ok
end

return M
