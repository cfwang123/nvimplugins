---@mod mdview.sync
local highlight = require("mdview.highlight")

local M = {}

local NS = vim.api.nvim_create_namespace("mdview_cursor")

---源窗口是否持有焦点（编辑源码时为 true）
---@param state table
---@return boolean
local function source_has_focus(state)
  if not state or not state.source_buf then
    return false
  end
  local cur = vim.api.nvim_get_current_win()
  if not cur or not vim.api.nvim_win_is_valid(cur) then
    return false
  end
  -- 当前窗就是 source_win
  if state.source_win and vim.api.nvim_win_is_valid(state.source_win) and cur == state.source_win then
    return true
  end
  -- 当前窗显示源 buffer（source_win 可能已变）
  if vim.api.nvim_win_get_buf(cur) == state.source_buf then
    state.source_win = cur
    return true
  end
  return false
end

---清除预览中的对应块 / 光标位置高亮
---@param state table|nil
function M.clear_block_highlight(state)
  if not state then
    return
  end
  local pbuf = state.preview_buf
  if pbuf and vim.api.nvim_buf_is_valid(pbuf) then
    pcall(vim.api.nvim_buf_clear_namespace, pbuf, NS, 0, -1)
  end
  -- 恢复预览窗 cursorline（若曾临时打开）
  if state._preview_cursorline_forced and state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    pcall(function()
      vim.wo[state.preview_win].cursorline = false
    end)
    state._preview_cursorline_forced = nil
  end
end

---源行 → 预览行
---@param state table
---@param source_row number
---@return number
local function preview_line_for_source(state, source_row)
  local rev = state.result and state.result.rev_map or {}
  local target = rev[source_row]
  if not target then
    for r = source_row, 1, -1 do
      if rev[r] then
        target = rev[r]
        break
      end
    end
  end
  return target or 1
end

---在 line 上，从 start_byte 起找到显示宽度为 want_w 的字节终点
---@param line string
---@param start_byte number 0-based
---@param want_w number
---@return number end_byte 0-based
local function byte_after_display_width(line, start_byte, want_w)
  line = line or ""
  local len = #line
  start_byte = math.max(0, math.min(start_byte or 0, len))
  want_w = math.max(0, want_w or 0)
  if want_w == 0 then
    return start_byte
  end
  local acc = 0
  local i = start_byte
  while i < len do
    local cidx = vim.fn.charidx(line, i)
    if cidx < 0 then
      break
    end
    local next_b = vim.fn.byteidx(line, cidx + 1)
    if next_b < 0 then
      next_b = len
    end
    local ch = line:sub(i + 1, next_b)
    local cw = vim.fn.strdisplaywidth(ch)
    if acc + cw > want_w then
      break
    end
    acc = acc + cw
    i = next_b
    if acc >= want_w then
      break
    end
  end
  return i
end

---源插入点字节（normal 在字符后，insert 为插入点）
---@param line string
---@param col number 0-based
---@return number
local function source_insert_byte(line, col)
  line = line or ""
  col = math.max(0, col or 0)
  local mode = vim.api.nvim_get_mode().mode or "n"
  if mode:match("^[iR]") then
    return math.min(#line, col)
  end
  if col < #line then
    local cidx = vim.fn.charidx(line, col)
    if cidx >= 0 then
      local after = vim.fn.byteidx(line, cidx + 1)
      if after >= 0 then
        return after
      end
    end
    return math.min(#line, col + 1)
  end
  return #line
end

---源光标字节列 → 预览行插入 `_` 的字节列
---@param source_line string
---@param source_col number 0-based byte（nvim 光标）
---@param preview_line string
---@param align table|nil result.col_align[preview_line]
---@return number mark_col 0-based byte，`_` 插在此位置之前
local function map_source_col_to_preview(source_line, source_col, preview_line, align)
  source_line = source_line or ""
  preview_line = preview_line or ""
  local insert_byte = source_insert_byte(source_line, source_col)

  -- 标题：源去掉 #+ 前缀，预览跳过自动序号/# 前缀，再按正文显示宽对齐
  if align and align.kind == "heading" then
    local atx = source_line:match("^(#+%s*)") or ""
    local src_body_start = #atx
    local prev_pref_bytes = align.preview_prefix_bytes or 0
    if insert_byte <= src_body_start then
      -- 光标还在 ### 上：标到预览正文起点（序号之后）
      return math.min(prev_pref_bytes, #preview_line)
    end
    local body_pref = source_line:sub(src_body_start + 1, insert_byte)
    local want_w = vim.fn.strdisplaywidth(body_pref)
    return byte_after_display_width(preview_line, prev_pref_bytes, want_w)
  end

  -- 默认：整行按显示宽度对齐
  local pref = source_line:sub(1, insert_byte)
  local want_w = vim.fn.strdisplaywidth(pref)
  return byte_after_display_width(preview_line, 0, want_w)
end

---@param state table
function M.sync_from_source(state)
  if not state or not state.result then
    return
  end
  local swin = state.source_win
  local pwin = state.preview_win
  if not pwin or not vim.api.nvim_win_is_valid(pwin) then
    return
  end
  -- 尽量解析源窗
  if not swin or not vim.api.nvim_win_is_valid(swin) then
    if source_has_focus(state) then
      swin = state.source_win
    end
  end
  if not swin or not vim.api.nvim_win_is_valid(swin) then
    return
  end

  local cfg = require("mdview.config").get()
  local cursor = vim.api.nvim_win_get_cursor(swin)
  local row = cursor[1]
  local col = cursor[2] or 0
  local pbuf = state.preview_buf
  if not pbuf or not vim.api.nvim_buf_is_valid(pbuf) then
    return
  end

  local target = preview_line_for_source(state, row)
  local line_count = vim.api.nvim_buf_line_count(pbuf)
  target = math.max(1, math.min(target, line_count))

  local pline = vim.api.nvim_buf_get_lines(pbuf, target - 1, target, false)[1] or ""
  local sline = ""
  if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
    sline = vim.api.nvim_buf_get_lines(state.source_buf, row - 1, row, false)[1] or ""
  end
  local align = state.result.col_align and state.result.col_align[target]
  local pcol = map_source_col_to_preview(sline, col, pline, align)

  if cfg.sync_scroll ~= false then
    pcall(vim.api.nvim_win_set_cursor, pwin, { target, math.min(pcol, #pline) })
    pcall(vim.fn.win_execute, pwin, "normal! zz")
  end

  if cfg.sync_cursor_block ~= false and source_has_focus(state) then
    M.highlight_block(state, row, target, pcol)
  else
    M.clear_block_highlight(state)
  end
end

---在预览中标出源光标对应位置（焦点在源时可见）
---@param state table
---@param source_row number
---@param preview_row number|nil 已算好的预览行
---@param preview_col number|nil 0-based：`_` 插入点（字符后）
function M.highlight_block(state, source_row, preview_row, preview_col)
  local pbuf = state.preview_buf
  if not pbuf or not vim.api.nvim_buf_is_valid(pbuf) then
    return
  end
  if not source_has_focus(state) then
    M.clear_block_highlight(state)
    return
  end
  highlight.ensure()
  vim.api.nvim_buf_clear_namespace(pbuf, NS, 0, -1)

  local ranges = state.result and state.result.block_ranges or {}
  local best = nil
  for _, r in ipairs(ranges) do
    if source_row >= r.source_start and source_row <= (r.source_end or r.source_start) then
      best = r
      break
    end
  end
  if not best then
    local best_dist = math.huge
    for _, r in ipairs(ranges) do
      local d = math.abs(source_row - r.source_start)
      if d < best_dist then
        best_dist = d
        best = r
      end
    end
  end

  -- 1) 整块浅色高亮
  if best then
    for ln = best.preview_start, best.preview_end do
      pcall(vim.api.nvim_buf_set_extmark, pbuf, NS, ln - 1, 0, {
        line_hl_group = "MdViewCursor",
        end_row = ln - 1,
        priority = 50,
      })
    end
  end

  -- 2) 精确行 + 在插入点插入 `_`（123 光标在 3 上/后 → 123_）
  local target = preview_row or preview_line_for_source(state, source_row)
  local max_p = vim.api.nvim_buf_line_count(pbuf)
  target = math.max(1, math.min(target, max_p))
  local line = vim.api.nvim_buf_get_lines(pbuf, target - 1, target, false)[1] or ""
  local mark_col = preview_col
  if mark_col == nil then
    local swin = state.source_win
    local scol = 0
    if swin and vim.api.nvim_win_is_valid(swin) then
      scol = vim.api.nvim_win_get_cursor(swin)[2] or 0
    end
    local sline = ""
    if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
      sline = vim.api.nvim_buf_get_lines(state.source_buf, source_row - 1, source_row, false)[1] or ""
    end
    local align = state.result and state.result.col_align and state.result.col_align[target]
    mark_col = map_source_col_to_preview(sline, scol, line, align)
  end
  mark_col = math.max(0, math.min(mark_col, #line))

  pcall(vim.api.nvim_buf_set_extmark, pbuf, NS, target - 1, 0, {
    line_hl_group = "MdViewCursorLine",
    end_row = target - 1,
    priority = 100,
  })
  -- inline：插在 mark_col 之前 → mark_col=3 且 line="123" 时为 123_
  local mark_ok = pcall(vim.api.nvim_buf_set_extmark, pbuf, NS, target - 1, mark_col, {
    virt_text = { { "_", "MdViewCursorMark" } },
    virt_text_pos = "inline",
    priority = 110,
    hl_mode = "combine",
  })
  if not mark_ok then
    pcall(vim.api.nvim_buf_set_extmark, pbuf, NS, target - 1, mark_col, {
      virt_text = { { "_", "MdViewCursorMark" } },
      virt_text_pos = "overlay",
      priority = 110,
      hl_mode = "combine",
    })
  end

  local pwin = state.preview_win
  if pwin and vim.api.nvim_win_is_valid(pwin) then
    pcall(function()
      if not vim.wo[pwin].cursorline then
        vim.wo[pwin].cursorline = true
        state._preview_cursorline_forced = true
      end
    end)
  end
end

---@param state table
---@param preview_row number
function M.sync_from_preview(state, preview_row)
  -- 在预览里移动时始终清掉对应块高亮
  M.clear_block_highlight(state)

  local cfg = require("mdview.config").get()
  if not cfg.sync_reverse then
    return
  end
  if not state or not state.result then
    return
  end
  local swin = state.source_win
  if not swin or not vim.api.nvim_win_is_valid(swin) then
    return
  end
  local src = state.result.source_map[preview_row]
  if not src then
    return
  end
  local sbuf = state.source_buf
  local max = vim.api.nvim_buf_line_count(sbuf)
  src = math.max(1, math.min(src, max))
  pcall(vim.api.nvim_win_set_cursor, swin, { src, 0 })
end

return M
