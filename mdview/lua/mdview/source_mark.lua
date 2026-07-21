---@mod mdview.source_mark
--- 编辑窗就地预览：==mark==、`<font color/style>`、图片链接 `![alt](url)` → 🖼 name
local config = require("mdview.config")
local highlight = require("mdview.highlight")
local html = require("mdview.html")
local window = require("mdview.window")

local M = {}

local NS = vim.api.nvim_create_namespace("mdview_source_mark")
local au_installed = false
--- buf -> uv_timer（不可存 vim.b，userdata 无法转成 Vim 值）
local refresh_timers = {}

local function stop_timer(buf)
  local t = refresh_timers[buf]
  if not t then
    return
  end
  refresh_timers[buf] = nil
  pcall(function()
    t:stop()
    t:close()
  end)
end

---@param buf integer
---@return boolean
local function is_md_source(buf)
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
  if ft == "markdown" or ft == "md" or ft == "pandoc" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf):lower()
  return name:match("%.md$") ~= nil
    or name:match("%.markdown$") ~= nil
    or name:match("%.mdx$") ~= nil
end

---在一行上找 ==inner==（跳过 `行内代码`）
---返回 0-based 半开区间：delim / inner
---@param text string
---@return { d0: integer, d1: integer, i0: integer, i1: integer, d2: integer, d3: integer }[]
local function find_marks_on_line(text)
  local out = {}
  if not text or text == "" or not text:find("==", 1, true) then
    return out
  end
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "`" then
      local j = text:find("`", i + 1, true)
      if j then
        i = j + 1
      else
        break
      end
    elseif text:sub(i, i + 1) == "==" then
      local j = text:find("==", i + 2, true)
      if j and j > i + 2 then
        -- 1-based: open [i,i+1], inner [i+2, j-1], close [j, j+1]
        out[#out + 1] = {
          d0 = i - 1,
          d1 = i + 1, -- open ==
          i0 = i + 1,
          i1 = j - 1, -- inner
          d2 = j - 1,
          d3 = j + 1, -- close ==
        }
        i = j + 2
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return out
end

---行内找 <font…>inner</font>（跳过 `code`），0-based 半开
---@param text string
---@return { o0: integer, o1: integer, i0: integer, i1: integer, c0: integer, c1: integer, fg: string|nil, bg: string|nil, bold: boolean, italic: boolean }[]
local function find_fonts_on_line(text)
  local out = {}
  if not text or text == "" or not text:lower():find("<font", 1, true) then
    return out
  end
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "`" then
      local j = text:find("`", i + 1, true)
      if j then
        i = j + 1
      else
        break
      end
    elseif html.is_font_open_at(text, i) then
      local next_i, sp = html.parse_font_at(text, i)
      if next_i and sp then
        -- open [i, open_end], inner (open_end, close_start), close [close_start, close_end]
        out[#out + 1] = {
          o0 = i - 1,
          o1 = sp.open_end, -- 1-based open_end is '>' → 0-based half-open end = open_end
          i0 = sp.open_end, -- after '>'
          i1 = sp.close_start - 1, -- before '</font'
          c0 = sp.close_start - 1,
          c1 = sp.close_end, -- close_end is last char of tag 1-based → half-open end = close_end
          fg = sp.fg,
          bg = sp.bg,
          bold = sp.bold == true,
          italic = sp.italic == true,
        }
        i = next_i
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return out
end

local function set_conceal(buf, row0, c0, c1)
  if c1 <= c0 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, NS, row0, c0, {
    end_col = c1,
    conceal = "",
    hl_group = "Conceal",
    priority = 110,
    hl_mode = "combine",
  })
end

---行内找 ![alt](url)（跳过 `code`），0-based 半开
---@param text string
---@return { c0: integer, c1: integer, alt: string }[]
local function find_images_on_line(text)
  local out = {}
  if not text or text == "" or not text:find("![", 1, true) then
    return out
  end
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "`" then
      local j = text:find("`", i + 1, true)
      if j then
        i = j + 1
      else
        break
      end
    elseif text:sub(i, i + 1) == "![" then
      local close = text:find("%]", i + 2)
      if close and text:sub(close + 1, close + 1) == "(" then
        local endp = text:find("%)", close + 2)
        if endp then
          -- 1-based: ![ 起 i，] 在 close，) 在 endp
          out[#out + 1] = {
            c0 = i - 1,
            c1 = endp, -- 半开 end = ')' 的 0-based 下一列
            alt = text:sub(i + 2, close - 1),
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
  return out
end

---图片链接隐藏显示：🖼 name（alt 空 → image）
---@param buf integer
---@param row0 integer
---@param c0 integer
---@param c1 integer
---@param alt string
local function set_image_conceal(buf, row0, c0, c1, alt)
  if c1 <= c0 then
    return
  end
  local name = alt
  if type(name) ~= "string" then
    name = ""
  end
  -- 去掉首尾空白；全空则默认 image
  name = (name:match("^%s*(.-)%s*$") or name)
  if name == "" then
    name = "image"
  end
  local label = "🖼 " .. name
  -- 整段 ![…](…) conceal；virt_text 显示为 🖼 name
  -- 默认 concealcursor 为空 → 光标行不隐藏，符合「非光标行」
  -- inline 需 0.10+；0.9 用 overlay（配合 conceal 即可）
  local pos = (vim.fn.has("nvim-0.10") == 1) and "inline" or "overlay"
  pcall(vim.api.nvim_buf_set_extmark, buf, NS, row0, c0, {
    end_col = c1,
    conceal = "",
    virt_text = { { label, "MdViewImage" } },
    virt_text_pos = pos,
    virt_text_hide = true, -- 光标在该行时不叠 virt_text，避免与原文叠字
    priority = 115,
    hl_mode = "combine",
  })
end

---刷新 buffer 内 ==mark== / <font> / 图片链接 高亮与隐藏
---@param buf integer
function M.refresh(buf)
  if not is_md_source(buf) then
    return
  end
  local cfg = config.get()
  highlight.ensure()
  pcall(vim.api.nvim_buf_clear_namespace, buf, NS, 0, -1)

  local do_mark = cfg.mark_highlight ~= false
  local do_font = not (cfg.html and cfg.html.font == false)
  local do_img = cfg.source_image_conceal ~= false

  if not do_mark and not do_font and not do_img then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local in_fence = false
  for row, line in ipairs(lines) do
    -- fenced code：整块跳过
    local fence = line:match("^%s*```") or line:match("^%s*~~~")
    if fence then
      in_fence = not in_fence
    elseif not in_fence then
      if do_mark then
        for _, m in ipairs(find_marks_on_line(line)) do
          set_conceal(buf, row - 1, m.d0, m.d1)
          set_conceal(buf, row - 1, m.d2, m.d3)
          if m.i1 > m.i0 then
            pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, m.i0, {
              end_col = m.i1,
              hl_group = "MdViewMark",
              priority = 120,
              hl_mode = "combine",
            })
          end
        end
      end
      if do_font then
        for _, f in ipairs(find_fonts_on_line(line)) do
          set_conceal(buf, row - 1, f.o0, f.o1)
          set_conceal(buf, row - 1, f.c0, f.c1)
          if f.i1 > f.i0 then
            local hl = highlight.ensure_font_hl(f.fg, f.bg, f.bold, f.italic)
            if hl then
              pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, f.i0, {
                end_col = f.i1,
                hl_group = hl,
                priority = 125,
                hl_mode = "combine",
              })
            end
          end
        end
      end
      if do_img then
        for _, im in ipairs(find_images_on_line(line)) do
          set_image_conceal(buf, row - 1, im.c0, im.c1, im.alt)
        end
      end
    end
  end
end

---@param buf integer
local function schedule_refresh(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  stop_timer(buf)
  local timer = vim.loop.new_timer()
  if not timer then
    vim.schedule(function()
      M.refresh(buf)
    end)
    return
  end
  refresh_timers[buf] = timer
  timer:start(80, 0, function()
    refresh_timers[buf] = nil
    pcall(function()
      timer:stop()
      timer:close()
    end)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.refresh(buf)
      end
    end)
  end)
end

---挂到 markdown 源 buffer（幂等）
---@param buf integer
function M.attach(buf)
  if not is_md_source(buf) then
    return
  end
  if vim.b[buf].mdview_source_mark_attached then
    schedule_refresh(buf)
    return
  end
  vim.b[buf].mdview_source_mark_attached = true

  ---保证窗口 conceallevel≥2，否则 extmark conceal 不生效
  local function ensure_conceal_win()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        local ok, cole = pcall(vim.api.nvim_get_option_value, "conceallevel", { win = w })
        if ok and (type(cole) ~= "number" or cole < 2) then
          pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = w })
        end
      end
    end
  end
  ensure_conceal_win()

  local g = vim.api.nvim_create_augroup("mdview_source_mark_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost" }, {
    group = g,
    buffer = buf,
    callback = function()
      schedule_refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = g,
    buffer = buf,
    callback = function()
      ensure_conceal_win()
      M.refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = g,
    buffer = buf,
    callback = function()
      stop_timer(buf)
      pcall(vim.api.nvim_del_augroup_by_id, g)
    end,
  })

  M.refresh(buf)
end

---全局 FileType / 已有 buffer 安装
function M.ensure_au()
  if not au_installed then
    au_installed = true
    local g = vim.api.nvim_create_augroup("mdview_source_mark_global", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = g,
      pattern = { "markdown", "md", "pandoc" },
      callback = function(ev)
        M.attach(ev.buf)
      end,
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
      group = g,
      callback = function(ev)
        if is_md_source(ev.buf) then
          M.attach(ev.buf)
        end
      end,
    })
    -- 颜色方案切换后重设 MdViewMark 并刷新
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = g,
      callback = function()
        highlight.setup(config.get().highlights)
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(b) and is_md_source(b) then
            M.refresh(b)
          end
        end
      end,
    })
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and is_md_source(b) then
      M.attach(b)
    end
  end
end

return M
