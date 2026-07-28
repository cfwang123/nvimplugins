---@mod colorpicker.preview 文件内 CSS 颜色左侧预览色块（可点击打开取色器）
local M = {}
local hlpool = require("colorpicker.hlpool")

local NS = vim.api.nvim_create_namespace("colorpicker_preview")
-- 固定组 ColorpickerPrev1..N，refresh 时动态改色，避免 E849
local prev_pool = hlpool.create("ColorpickerPrev", 512)

---@type table
local config = {
  preview = true,
  preview_auto = true,
  preview_max_lines = 4000,
  preview_filetypes = nil,
}

--- buf -> { [lnum_1based] = { {from,to,tok,r,g,b,a}, ... } }
local hits = {} ---@type table<integer, table<integer, table[]>>
local attached = {} ---@type table<integer, boolean>
local timers = {} ---@type table<integer, any>
local augroup = nil ---@type integer|nil
local mouse_keys_applied = false

---@param r integer
---@param g integer
---@param b integer
---@return string
local function swatch_hl(r, g, b)
  return hlpool.solid(prev_pool, r, g, b)
end

---预览色块文本（两格满宽块 + 后跟空格，与色码分开）
local SWATCH_TEXT = "██"
local SWATCH_DISP = 2 -- 显示宽度

---@param buf integer
---@return boolean
local function should_attach(buf)
  if not config.preview then
    return false
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local bt = vim.bo[buf].buftype
  if bt ~= "" and bt ~= "acwrite" then
    return false
  end
  -- 跳过取色器自身
  local ft = vim.bo[buf].filetype
  if ft == "colorpicker" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("colorpicker://") then
    return false
  end
  local fts = config.preview_filetypes
  if type(fts) == "table" and #fts > 0 then
    local ok = false
    for _, f in ipairs(fts) do
      if f == ft then
        ok = true
        break
      end
    end
    if not ok then
      return false
    end
  end
  return true
end

---@param tok string
---@return integer|nil r
---@return integer|nil g
---@return integer|nil b
---@return number|nil a
local function tok_rgb(tok)
  local cp = require("colorpicker")
  local hh, ss, vv, aa = cp.parse_css_color(tok)
  if not hh then
    return nil
  end
  local r, g, b = cp._hsv_to_rgb(hh, ss, vv)
  return r, g, b, aa ~= nil and aa or 1
end

---绘制单个 buffer（不 reset 池；由 refresh 统一 reset 后画全部 attached）
---@param buf integer
local function paint_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not should_attach(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
    hits[buf] = nil
    return
  end

  pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
  local line_hits = {} ---@type table<integer, table[]>
  hits[buf] = line_hits

  local line_count = vim.api.nvim_buf_line_count(buf)
  local max_lines = tonumber(config.preview_max_lines) or 4000
  local start0, end0 = 0, line_count

  if line_count > max_lines then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      local top = vim.fn.line("w0", win)
      local bot = vim.fn.line("w$", win)
      local margin = 40
      start0 = math.max(0, top - 1 - margin)
      end0 = math.min(line_count, bot + margin)
    else
      start0, end0 = 0, math.min(line_count, max_lines)
    end
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start0, end0, false)
  local cp = require("colorpicker")
  local find_all = cp.find_all_colors_in_line

  for i, line in ipairs(lines) do
    local lnum0 = start0 + i - 1
    local lnum1 = lnum0 + 1
    local colors = find_all(line)
    if #colors > 0 then
      local row_list = {}
      for _, c in ipairs(colors) do
        local r, g, b, a = tok_rgb(c.tok)
        if r then
          local aa = a or 1
          local pr = math.floor(r * aa + 255 * (1 - aa) + 0.5)
          local pg = math.floor(g * aa + 255 * (1 - aa) + 0.5)
          local pb = math.floor(b * aa + 255 * (1 - aa) + 0.5)
          local hl = swatch_hl(pr, pg, pb)
          pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum0, c.from, {
            virt_text = {
              { SWATCH_TEXT, hl },
              { " ", "Normal" },
            },
            virt_text_pos = "inline",
            hl_mode = "combine",
            priority = 90,
            right_gravity = false,
          })
          row_list[#row_list + 1] = {
            from = c.from,
            to = c.to,
            tok = c.tok,
            r = r,
            g = g,
            b = b,
            a = aa,
            row = lnum1,
            swatch_w = SWATCH_DISP + 1,
          }
        end
      end
      if #row_list > 0 then
        line_hits[lnum1] = row_list
      end
    end
  end
end

---刷新预览：共享固定高亮池，一次 reset 后重绘所有 attached buffer
---@param buf? integer 触发来源 buffer（仍会重绘全部，保证槽位与颜色一致）
function M.refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end

  -- 固定组动态改色：统一 reset，再画全部 buffer，避免多 buffer 互相覆盖槽位
  hlpool.reset(prev_pool)

  local any = false
  for b, _ in pairs(attached) do
    if vim.api.nvim_buf_is_valid(b) then
      any = true
      paint_buf(b)
    else
      attached[b] = nil
      hits[b] = nil
    end
  end

  -- 尚未 attach 时也允许对当前 buf 画一次（命令 :ColorPickerPreview）
  if not any and buf and vim.api.nvim_buf_is_valid(buf) and should_attach(buf) then
    paint_buf(buf)
  elseif buf and vim.api.nvim_buf_is_valid(buf) and should_attach(buf) and not attached[buf] then
    paint_buf(buf)
  end
end

---@param buf integer
function M.schedule_refresh(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if timers[buf] then
    pcall(vim.fn.timer_stop, timers[buf])
    timers[buf] = nil
  end
  timers[buf] = vim.fn.timer_start(80, function()
    timers[buf] = nil
    vim.schedule(function()
      M.refresh(buf)
    end)
  end)
end

---命中测试：仅当鼠标点在 hex 色码的 `#` 字符上时触发
---（inline virt_text 色块难以稳定点中；点 `#` 可靠且不会误伤后续 hex 数字）
---@param mouse table
---@return table|nil hit
function M.hit_test(mouse)
  if not mouse or not mouse.winid or mouse.winid == 0 then
    return nil
  end
  if not vim.api.nvim_win_is_valid(mouse.winid) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(mouse.winid)
  local by_line = hits[buf]
  if not by_line then
    return nil
  end
  local row = mouse.line
  local list = by_line[row]
  if not list or #list == 0 then
    return nil
  end

  local col = math.max(0, (mouse.column or 1) - 1) -- 0-based 字节
  local lines = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)
  local line = lines[1] or ""
  if line == "" or col >= #line then
    return nil
  end
  -- 必须点在 `#` 上（不点在 hex 数字 / rgb() 上）
  if line:sub(col + 1, col + 1) ~= "#" then
    return nil
  end

  for _, h in ipairs(list) do
    local tok = h.tok or ""
    if tok:sub(1, 1) == "#" and h.from == col then
      return h
    end
  end
  return nil
end

---点击色块 → 打开取色器（替换该颜色）
---@param hit table
function M.open_hit(hit)
  if not hit then
    return
  end
  local cp = require("colorpicker")
  cp.open_at({
    buf = vim.api.nvim_get_current_buf(),
    row = hit.row,
    col = hit.from,
    from = hit.from,
    to = hit.to,
    tok = hit.tok,
  })
end

---仅在「单击松开」且非 visual 时打开取色器。
---不映射 <LeftMouse>/<LeftDrag>，避免挡住鼠标拖动进入 visual 选文字。
local function on_buffer_left_release()
  -- 拖动选区后松开仍处于 visual/select：绝不抢点击
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19" then
    return
  end

  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid == 0 then
    return
  end
  if not vim.api.nvim_win_is_valid(mouse.winid) then
    return
  end

  local buf = vim.api.nvim_win_get_buf(mouse.winid)
  if vim.bo[buf].filetype == "colorpicker" then
    return
  end
  if not attached[buf] then
    return
  end

  -- 仅预览色块 ██；点色码文字不打开
  local hit = M.hit_test(mouse)
  if not hit then
    return
  end

  pcall(vim.api.nvim_set_current_win, mouse.winid)
  pcall(vim.api.nvim_win_set_cursor, mouse.winid, { hit.row or mouse.line, hit.from })
  vim.schedule(function()
    local m2 = vim.fn.mode()
    if m2 == "v" or m2 == "V" or m2 == "\22" then
      return
    end
    M.open_hit(hit)
  end)
end

---安装/修复 buffer 鼠标映射（可重复调用）
---@param buf integer
local function ensure_mouse_maps(buf)
  local o = { buffer = buf, silent = true, noremap = true, nowait = true }
  -- 去掉旧版会阻断 visual 拖选的映射
  pcall(vim.keymap.del, "n", "<LeftMouse>", { buffer = buf })
  pcall(vim.keymap.del, "n", "<2-LeftMouse>", { buffer = buf })
  -- 只用 LeftRelease：保留默认 LeftMouse/LeftDrag → visual 选区
  pcall(vim.keymap.set, "n", "<LeftRelease>", on_buffer_left_release, vim.tbl_extend("force", o, {
    desc = "colorpicker: click color swatch (release)",
  }))
  -- visual 下松开不打开取色器
  pcall(vim.keymap.set, "x", "<LeftRelease>", function() end, vim.tbl_extend("force", o, {
    desc = "colorpicker: ignore release in visual",
  }))
end

---@param buf integer
function M.attach(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not should_attach(buf) then
    return
  end
  -- 已 attach 时仍刷新映射（修复旧版 LeftMouse 抢 visual）
  ensure_mouse_maps(buf)
  if attached[buf] then
    M.schedule_refresh(buf)
    return
  end
  attached[buf] = true

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    buffer = buf,
    group = augroup,
    callback = function(args)
      M.schedule_refresh(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    group = augroup,
    once = true,
    callback = function()
      attached[buf] = nil
      hits[buf] = nil
      if timers[buf] then
        pcall(vim.fn.timer_stop, timers[buf])
        timers[buf] = nil
      end
    end,
  })

  M.refresh(buf)
end

---@param buf? integer
function M.detach(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  attached[buf] = nil
  hits[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)
    pcall(vim.keymap.del, "n", "<LeftRelease>", { buffer = buf })
    pcall(vim.keymap.del, "x", "<LeftRelease>", { buffer = buf })
    -- 清理旧版误映射（若仍存在）
    pcall(vim.keymap.del, "n", "<LeftMouse>", { buffer = buf })
    pcall(vim.keymap.del, "n", "<2-LeftMouse>", { buffer = buf })
  end
end

---@param user_cfg table
function M.setup(user_cfg)
  user_cfg = user_cfg or {}
  if user_cfg.preview ~= nil then
    config.preview = user_cfg.preview
  end
  if user_cfg.preview_auto ~= nil then
    config.preview_auto = user_cfg.preview_auto
  end
  if user_cfg.preview_max_lines ~= nil then
    config.preview_max_lines = user_cfg.preview_max_lines
  end
  if user_cfg.preview_filetypes ~= nil then
    config.preview_filetypes = user_cfg.preview_filetypes
  end

  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = vim.api.nvim_create_augroup("ColorpickerPreview", { clear = true })

  if not config.preview then
    return
  end

  if config.preview_auto then
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
      group = augroup,
      callback = function(args)
        M.attach(args.buf)
      end,
    })
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = augroup,
      callback = function()
        local buf = vim.api.nvim_get_current_buf()
        if attached[buf] then
          M.schedule_refresh(buf)
        end
      end,
    })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = augroup,
      callback = function()
        -- 组仍固定；重绘以重新 set_hl 颜色
        M.schedule_refresh(vim.api.nvim_get_current_buf())
      end,
    })
    -- 当前已打开的 buffer
    vim.schedule(function()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          M.attach(b)
        end
      end
    end)
  end
end

return M
