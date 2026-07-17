---@mod mdview.toc
--- 标题收集 + 独立目录 float（t 打开 / q 关闭）
local M = {}

local float_state = {
  win = nil,
  buf = nil,
  source_st = nil,
}

---@param blocks table[]
---@param cfg table
---@return table[] headings {level, text, source_start, preview_target?}
function M.collect(blocks, cfg)
  local min_l = cfg.toc_min_level or 1
  local max_l = cfg.toc_max_level or 6
  local out = {}

  local function walk(bs)
    for _, b in ipairs(bs or {}) do
      if b.type == "heading" and b.level >= min_l and b.level <= max_l then
        out[#out + 1] = {
          level = b.level,
          text = b.text or "",
          source_start = b.source_start,
        }
      elseif b.type == "details" and b.children then
        walk(b.children)
      elseif b.type == "blockquote" and b.children then
        walk(b.children)
      end
    end
  end
  walk(blocks)
  return out
end

function M.close_float()
  if float_state.win and vim.api.nvim_win_is_valid(float_state.win) then
    pcall(vim.api.nvim_win_close, float_state.win, true)
  end
  if float_state.buf and vim.api.nvim_buf_is_valid(float_state.buf) then
    pcall(vim.api.nvim_buf_delete, float_state.buf, { force = true })
  end
  float_state.win = nil
  float_state.buf = nil
  float_state.source_st = nil
  float_state.entries = nil
end

function M.is_open()
  return float_state.win and vim.api.nvim_win_is_valid(float_state.win)
end

---在打开 float 之前解析「当前章节」对应源行 / 预览行。
---必须在 nvim_open_win(..., enter=true) 之前调用，否则当前窗已是 TOC。
---@param st table
---@return number source_line
---@return number|nil preview_line 预览窗光标行（若能取到）
local function resolve_current_position(st)
  local src_line, prev_line = 1, nil
  local cur_win = vim.api.nvim_get_current_win()

  local function from_preview_win(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return nil, nil
    end
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
    if not ok or not cur then
      return nil, nil
    end
    local prow = cur[1]
    local sm = st.result and st.result.source_map
    local sline = (sm and sm[prow]) or 1
    return sline, prow
  end

  local function from_source_win(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return nil
    end
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
    if ok and cur then
      return cur[1]
    end
    return nil
  end

  -- 1) 当前窗优先（用户按 t 时所在处）
  if vim.api.nvim_win_is_valid(cur_win) then
    local cur_buf = vim.api.nvim_win_get_buf(cur_win)
    if st.preview_buf and cur_buf == st.preview_buf then
      local s, p = from_preview_win(cur_win)
      if s then
        return s, p
      end
    end
    if st.source_buf and cur_buf == st.source_buf then
      local s = from_source_win(cur_win)
      if s then
        return s, nil
      end
    end
  end

  -- 2) 预览窗（侧栏阅读时更贴近「当前章节」）
  local pwin = st.preview_win
  if (not pwin or not vim.api.nvim_win_is_valid(pwin)) and st.preview_buf then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == st.preview_buf then
        pwin = w
        break
      end
    end
  end
  do
    local s, p = from_preview_win(pwin)
    if s and p then
      return s, p
    end
  end

  -- 3) 源窗
  local s = from_source_win(st.source_win)
  if s then
    return s, nil
  end
  return src_line, prev_line
end

---打开目录 float；callback(entry) 在选中时调用
---@param st table mdview state（需 headings / result）
---@param on_jump fun(entry: table)
function M.open_float(st, on_jump)
  if M.is_open() then
    M.close_float()
    return
  end

  -- 先记下当前位置，再开 float（enter 后当前窗会变成 TOC）
  local cur_src, cur_prev = resolve_current_position(st)

  require("mdview.highlight").ensure()

  local headings = st.headings
  if not headings or #headings == 0 then
    local cfg = require("mdview.config").get()
    if st.blocks then
      headings = M.collect(st.blocks, cfg)
    end
  end
  if not headings or #headings == 0 then
    vim.notify(require("mdview.i18n").t("toc_empty"), vim.log.levels.INFO)
    return
  end

  local i18n = require("mdview.i18n")
  local hp = st.result and st.result.heading_preview or {}
  local rev = st.result and st.result.rev_map or {}
  local entries = {}
  local lines = {
    i18n.get() == "zh" and "◆ 大纲" or "◆ Outline",
    i18n.get() == "zh" and "  Enter 跳转 · q 关闭" or "  Enter jump · q close",
    "",
  }

  local num_by_src = {}
  if st.blocks then
    local function walk(bs)
      for _, b in ipairs(bs or {}) do
        if b.type == "heading" then
          num_by_src[b.source_start] = b.auto_number or ""
        elseif b.children then
          walk(b.children)
        end
      end
    end
    walk(st.blocks)
  end

  -- 相对最小标题级别缩进（每级 4 空格，子标题层级清晰）
  local min_level = 6
  for _, h in ipairs(headings) do
    min_level = math.min(min_level, h.level or 1)
  end
  if min_level < 1 or min_level > 6 then
    min_level = 1
  end

  for _, h in ipairs(headings) do
    local lv = math.max(1, math.min(6, h.level or 1))
    local depth = math.max(0, lv - min_level)
    local indent = string.rep("    ", depth) -- 4 空格/级
    local num = num_by_src[h.source_start] or h.auto_number or ""
    local body = num .. (h.text or "")
    local bullet = depth == 0 and "● " or "○ "
    local text = indent .. bullet .. body
    lines[#lines + 1] = text
    entries[#entries + 1] = {
      line = #lines,
      text = h.text,
      level = lv,
      source_start = h.source_start,
      preview_line = h.preview_line or hp[h.source_start] or rev[h.source_start],
      full = text,
    }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "mdview_toc"
  vim.b[buf].mdview_toc_float = true

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width + 6, 32), math.floor(vim.o.columns * 0.55))
  local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.65))
  height = math.max(height, 8)

  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " TOC ",
    title_pos = "center",
    zindex = 50,
  })
  if not ok or not win then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify(require("mdview.i18n").t("toc_fail"), vim.log.levels.ERROR)
    return
  end

  float_state.win = win
  float_state.buf = buf
  float_state.source_st = st
  float_state.entries = entries

  pcall(function()
    vim.wo[win].cursorline = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    vim.wo[win].signcolumn = "no"
    -- 纯白背景
    vim.wo[win].winhl = table.concat({
      "Normal:MdViewTocFloat",
      "NormalFloat:MdViewTocFloat",
      "FloatBorder:MdViewTocFloatBorder",
      "FloatTitle:MdViewTocFloatTitle",
      "CursorLine:MdViewTocFloatCursor",
    }, ",")
  end)

  local ns = vim.api.nvim_create_namespace("mdview_toc_float")
  -- 头两行提示
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, {
    end_col = #lines[1],
    hl_group = "MdViewTocFloatTitle",
  })
  if lines[2] then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, 1, 0, {
      end_col = #lines[2],
      hl_group = "MdViewTocFloatHint",
    })
  end
  -- 条目：整行 bold
  for _, e in ipairs(entries) do
    local line = lines[e.line] or ""
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, e.line - 1, 0, {
      end_col = #line,
      hl_group = "MdViewTocItem",
    })
  end

  local function entry_at_cursor()
    local row1 = vim.api.nvim_win_get_cursor(win)[1]
    for _, e in ipairs(entries) do
      if e.line == row1 then
        return e
      end
    end
    return nil
  end

  local map_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", function()
    M.close_float()
  end, map_opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close_float()
  end, map_opts)
  vim.keymap.set("n", "<CR>", function()
    local e = entry_at_cursor()
    if e and on_jump then
      on_jump(e)
    end
    M.close_float()
  end, map_opts)
  vim.keymap.set("n", "<LeftRelease>", function()
    vim.schedule(function()
      if not M.is_open() then
        return
      end
      local e = entry_at_cursor()
      if e and on_jump then
        on_jump(e)
        M.close_float()
      end
    end)
  end, map_opts)

  -- 光标落到「当前章节」：优先按预览行（heading 正文预览行），否则按源行
  local focus_line = entries[1] and entries[1].line or 1
  if #entries > 0 then
    local best = entries[1]
    local matched = false
    if cur_prev and cur_prev > 0 then
      -- 预览：选 preview_line <= 光标行 的最后一个标题
      for _, e in ipairs(entries) do
        local pl = e.preview_line or 0
        if pl > 0 and pl <= cur_prev then
          best = e
          matched = true
        end
      end
    end
    if not matched then
      for _, e in ipairs(entries) do
        if (e.source_start or 0) <= (cur_src or 1) then
          best = e
        end
      end
    end
    focus_line = best.line
  end
  pcall(vim.api.nvim_win_set_cursor, win, { focus_line, 0 })
  pcall(vim.fn.win_execute, win, "normal! zz")

  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(win),
    callback = function()
      float_state.win = nil
      float_state.buf = nil
      float_state.source_st = nil
      float_state.entries = nil
    end,
  })
end

function M.toggle_float(st, on_jump)
  if M.is_open() then
    M.close_float()
  else
    M.open_float(st, on_jump)
  end
end

return M
