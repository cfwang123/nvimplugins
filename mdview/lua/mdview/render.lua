---@mod mdview.render
--- AST → 预览行 + extmarks + 映射 + hit targets
local code_mod = require("mdview.code")
local toc_mod = require("mdview.toc")
local image_mod = require("mdview.image")
local highlight = require("mdview.highlight")
local parse_mod = require("mdview.parse")

local M = {}

local NS = vim.api.nvim_create_namespace("mdview_render")

---@class RenderResult
---@field lines string[]
---@field extmarks table[]
---@field source_map number[] preview_line(1) -> source_line
---@field rev_map table<number, number> source_line -> preview_line_start
---@field block_ranges table[] {preview_start, preview_end, source_start, source_end}
---@field hits table[] {line, kind, payload}

local function str_width(s)
  return vim.fn.strdisplaywidth(s)
end

local function pad_right(s, width)
  local w = str_width(s)
  if w >= width then
    return s
  end
  return s .. string.rep(" ", width - w)
end

---整行内容在 display 宽内居中；返回 padded 文本与左侧空格数（= 字节偏移，空格 1 宽 1 字节）
---@param s string
---@param width number
---@return string text, number left_pad
local function pad_center(s, width)
  s = s or ""
  width = math.max(0, width or 0)
  local w = str_width(s)
  if width <= 0 or w >= width then
    return s, 0
  end
  local left = math.floor((width - w) / 2)
  return string.rep(" ", left) .. s, left
end

---将 ranges 的 col/end_col 整体右移（字节）
---@param ranges table[]|nil
---@param off number
---@return table[]
local function shift_ranges(ranges, off)
  if not ranges or off == 0 then
    return ranges or {}
  end
  local out = {}
  for _, r in ipairs(ranges) do
    out[#out + 1] = {
      col = (r.col or 0) + off,
      end_col = (r.end_col or 0) + off,
      hl = r.hl,
      href = r.href,
      src = r.src,
      kind = r.kind,
      virt_text = r.virt_text,
      virt_text_pos = r.virt_text_pos,
      line_hl = r.line_hl,
      url = r.url,
    }
  end
  return out
end

local function pad_align(s, width, align)
  local w = str_width(s)
  if w > width then
    -- 截断按字节粗略处理
    while str_width(s) > width - 1 and #s > 0 do
      s = s:sub(1, -2)
    end
    s = s .. "…"
    w = str_width(s)
  end
  local pad = width - w
  if align == "right" then
    return string.rep(" ", pad) .. s
  elseif align == "center" then
    local l = math.floor(pad / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", pad - l)
  end
  return s .. string.rep(" ", pad)
end

---将 spans 展平为纯文本 + 样式区间（含可点击 link/image）
---@return string text, table[] ranges {col, end_col, hl, href?, src?, kind?}
local function flatten_spans(spans)
  local parts = {}
  local ranges = {}
  local col = 0
  local hl_map = {
    bold = "MdViewBold",
    italic = "MdViewItalic",
    bold_italic = "MdViewBold",
    code = "MdViewInlineCode",
    strike = "MdViewStrike",
    mark = "MdViewMark",
    link = "MdViewLink",
    image = "MdViewImage",
  }
  for _, sp in ipairs(spans or {}) do
    local t = sp.text or ""
    if sp.type == "image" then
      t = sp.text ~= "" and ("🖼 " .. sp.text) or "🖼"
    end
    local start = col
    parts[#parts + 1] = t
    local blen = #t -- 字节长度供 extmark col
    col = col + blen
    local hl = hl_map[sp.type]
    if sp.type == "font" then
      hl = highlight.ensure_font_hl(sp.fg, sp.bg, sp.bold, sp.italic)
    end
    if hl and t ~= "" then
      local r = { col = start, end_col = col, hl = hl }
      if sp.type == "link" and sp.href then
        r.kind = "link"
        r.href = sp.href
      elseif sp.type == "image" and sp.src then
        r.kind = "image_inline"
        r.src = sp.src
      end
      ranges[#ranges + 1] = r
    end
    if sp.type == "bold_italic" then
      ranges[#ranges + 1] = { col = start, end_col = col, hl = "MdViewItalic" }
    end
  end
  return table.concat(parts), ranges
end

local function wrap_text(text, width)
  if width <= 0 then
    return { text }
  end
  if str_width(text) <= width then
    return { text }
  end
  local lines = {}
  local rest = text
  while str_width(rest) > width do
    -- 按显示宽度切
    local acc, i = "", 1
    while i <= #rest do
      local ch = rest:sub(i, i)
      -- utf8 粗略：多字节
      local b = rest:byte(i)
      local len = 1
      if b >= 0xF0 then
        len = 4
      elseif b >= 0xE0 then
        len = 3
      elseif b >= 0xC0 then
        len = 2
      end
      local piece = rest:sub(i, i + len - 1)
      if str_width(acc .. piece) > width then
        break
      end
      acc = acc .. piece
      i = i + len
    end
    if acc == "" then
      acc = rest:sub(1, 1)
      i = 2
    end
    lines[#lines + 1] = acc
    rest = rest:sub(i)
  end
  if rest ~= "" then
    lines[#lines + 1] = rest
  end
  return lines
end

---@param ctx table
---@param opts? { no_rev_map?: boolean, force_rev_map?: boolean }
local function emit_line(ctx, text, source_line, ext_ranges, opts)
  opts = opts or {}
  ctx.lines[#ctx.lines + 1] = text or ""
  local pl = #ctx.lines
  ctx.source_map[pl] = source_line or ctx.last_source or 1
  -- rev_map：源行 → 正文预览行。TOC 不得抢占（否则 TOC/锚点都跳回目录）
  if source_line and not opts.no_rev_map then
    if opts.force_rev_map or not ctx.rev_map[source_line] then
      ctx.rev_map[source_line] = pl
    end
  end
  ctx.last_source = source_line or ctx.last_source
  if ext_ranges then
    for _, r in ipairs(ext_ranges) do
      ctx.extmarks[#ctx.extmarks + 1] = {
        line = pl - 1,
        col = r.col,
        end_col = r.end_col,
        hl = r.hl,
        virt_text = r.virt_text,
        virt_text_pos = r.virt_text_pos,
        line_hl = r.line_hl,
        url = r.url,
      }
    end
  end
  return pl
end

local function begin_block(ctx, source_start, source_end)
  return { preview_start = #ctx.lines + 1, source_start = source_start, source_end = source_end or source_start }
end

local function end_block(ctx, meta)
  meta.preview_end = #ctx.lines
  ctx.block_ranges[#ctx.block_ranges + 1] = meta
end

local function render_inlines_wrapped(ctx, spans, source_line, width, prefix, prefix_hl)
  prefix = prefix or ""
  local text, ranges = flatten_spans(spans)
  local body_width = math.max(8, width - str_width(prefix))
  local pad_prefix = string.rep(" ", str_width(prefix))

  -- 先按源码硬换行拆段，再在段内按宽度软折行（换行原样保留）
  local hard_parts = {} ---@type {t:string, start:number}[]
  do
    local pos = 1
    local n = #text
    if n == 0 then
      hard_parts[1] = { t = "", start = 0 }
    else
      while pos <= n do
        local npos = text:find("\n", pos, true)
        if not npos then
          hard_parts[#hard_parts + 1] = { t = text:sub(pos), start = pos - 1 }
          break
        end
        hard_parts[#hard_parts + 1] = { t = text:sub(pos, npos - 1), start = pos - 1 }
        pos = npos + 1
        if pos > n then
          -- 尾部单独一个换行：仍输出空行以对齐源码
          hard_parts[#hard_parts + 1] = { t = "", start = n }
          break
        end
      end
    end
  end

  for hi, part in ipairs(hard_parts) do
    local src = source_line and (source_line + hi - 1) or source_line
    local wrapped = wrap_text(part.t, body_width)
    if #wrapped == 0 then
      wrapped = { "" }
    end
    local byte_pos = part.start
    for i, wline in ipairs(wrapped) do
      -- 硬换行段的首行才用列表符等 prefix；软折行续行与后续硬换行段用空白对齐
      local line_prefix = (hi == 1 and i == 1) and prefix or pad_prefix
      local line = line_prefix .. wline
      local er = {}
      local line_start = byte_pos
      local line_end = byte_pos + #wline
      if hi == 1 and i == 1 and prefix ~= "" and prefix_hl then
        er[#er + 1] = { col = 0, end_col = #prefix, hl = prefix_hl }
      end
      local off = #line_prefix
      for _, r in ipairs(ranges) do
        -- 与当前展示行有交集的样式/链接
        if r.end_col > line_start and r.col < line_end then
          local c0 = math.max(0, r.col - line_start) + off
          local c1 = math.min(#wline, r.end_col - line_start) + off
          if c1 > c0 then
            local em = { col = c0, end_col = c1, hl = r.hl }
            if r.kind == "link" and r.href then
              em.url = r.href
            end
            er[#er + 1] = em
            if r.kind == "link" and r.href then
              local pl_guess = #ctx.lines + 1
              ctx.hits[#ctx.hits + 1] = {
                line = pl_guess,
                kind = "link",
                href = r.href,
                col = c0,
                end_col = c1,
              }
            elseif r.kind == "image_inline" and r.src then
              local pl_guess = #ctx.lines + 1
              ctx.hits[#ctx.hits + 1] = {
                line = pl_guess,
                kind = "image_inline",
                src = r.src,
                col = c0,
                end_col = c1,
              }
            end
          end
        end
      end
      emit_line(ctx, line, src, er)
      byte_pos = line_end
    end
  end
end

---解析标题前缀序号（已有手写编号则不再自动加）
---支持：`1. ` / `1.1 ` / `1.1. ` / `1.2.3 ` / `1.2.3. `
---注意：Lua pattern 不能对捕获组使用 +/*，故用手写扫描
---@param plain string
---@return number[]|nil
local function parse_heading_num_prefix(plain)
  if not plain or plain == "" then
    return nil
  end
  local i = 1
  local len = #plain
  local nums = {}

  -- 第一段数字
  local j = i
  while j <= len and plain:byte(j) >= 48 and plain:byte(j) <= 57 do
    j = j + 1
  end
  if j == i then
    return nil
  end
  nums[1] = tonumber(plain:sub(i, j - 1))
  i = j
  -- 必须有 '.'
  if i > len or plain:sub(i, i) ~= "." then
    return nil
  end
  i = i + 1

  -- 后续 .数字
  while i <= len do
    local k = i
    while k <= len and plain:byte(k) >= 48 and plain:byte(k) <= 57 do
      k = k + 1
    end
    if k == i then
      break -- 不是数字，结束段
    end
    nums[#nums + 1] = tonumber(plain:sub(i, k - 1))
    i = k
    if i <= len and plain:sub(i, i) == "." then
      i = i + 1 -- 吞掉段间/末尾点，继续看下一段
    else
      break
    end
  end

  -- 序号后必须有空白（或已在末尾点后的空白）
  if i > len then
    return nil
  end
  local sp = plain:byte(i)
  if not (sp == 32 or sp == 9) then
    -- 可能停在末尾点上：`1.1.` 后无空格则不算
    return nil
  end
  while i <= len and (plain:byte(i) == 32 or plain:byte(i) == 9) do
    i = i + 1
  end
  -- 空白后还应有标题正文（或至少吃掉了空白）
  return #nums > 0 and nums or nil
end

local function format_counters(counters, L)
  local parts = {}
  for i = 1, L do
    parts[#parts + 1] = tostring(math.max(1, counters[i] or 1))
  end
  return table.concat(parts, ".") .. ". "
end

---若标题尚无 `1. ` / `1.1. ` 等形式则写入 b.auto_number
local function assign_heading_numbers(blocks)
  local counters = { 0, 0, 0, 0, 0, 0 }
  local function walk(bs)
    for _, b in ipairs(bs or {}) do
      if b.type == "heading" then
        local L = math.min(6, math.max(1, b.level or 1))
        local plain = b.text or ""
        local nums = parse_heading_num_prefix(plain)
        if nums then
          b.auto_number = ""
          -- 与手写序号对齐，供后续子标题延续
          if #nums == 1 then
            counters[1] = nums[1]
            for i = 2, 6 do
              counters[i] = 0
            end
          else
            for i = 1, 6 do
              counters[i] = nums[i] or 0
            end
          end
          for i = L + 1, 6 do
            counters[i] = 0
          end
        else
          counters[L] = (counters[L] or 0) + 1
          for i = L + 1, 6 do
            counters[i] = 0
          end
          for i = 1, L - 1 do
            if (counters[i] or 0) < 1 then
              counters[i] = 1
            end
          end
          b.auto_number = format_counters(counters, L)
        end
      elseif b.children then
        walk(b.children)
      end
    end
  end
  walk(blocks)
end

local function render_blocks(ctx, blocks)

  local cfg = ctx.cfg
  local width = ctx.width

  for _, b in ipairs(blocks or {}) do
    if b.type == "heading" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      local text, ranges = flatten_spans(b.spans)
      local num = b.auto_number or ""
      local prefix = ""
      if num ~= "" then
        prefix = num
        text = num .. text
        local off = #num
        for _, r in ipairs(ranges) do
          r.col = r.col + off
          r.end_col = r.end_col + off
        end
      end
      if not cfg.heading_conceal then
        -- 显示：### 1.1. Title
        local hashes = string.rep("#", b.level) .. " "
        prefix = hashes .. prefix
        text = hashes .. text
        local off = #hashes
        for _, r in ipairs(ranges) do
          r.col = r.col + off
          r.end_col = r.end_col + off
        end
      end
      local hl = "MdViewH" .. tostring(math.min(6, b.level or 1))
      -- 整行标题：MdViewH* 已含 bold + 层级色（勿再叠 MdViewBold，会盖掉颜色）
      local pl = emit_line(ctx, text, b.source_start, {
        { col = 0, end_col = #text, hl = hl },
      }, { force_rev_map = true })
      for _, r in ipairs(ranges) do
        ctx.extmarks[#ctx.extmarks + 1] = {
          line = pl - 1,
          col = r.col,
          end_col = r.end_col,
          hl = r.hl,
        }
      end
      -- 供源→预览光标对齐：预览前缀（自动序号 / 可见 #）与源 ATX 对应
      ctx.col_align = ctx.col_align or {}
      ctx.col_align[pl] = {
        kind = "heading",
        preview_prefix = prefix,
        preview_prefix_bytes = #prefix,
        preview_prefix_disp = str_width(prefix),
        source_atx = true,
      }
      b._preview_line = pl
      ctx.heading_preview = ctx.heading_preview or {}
      ctx.heading_preview[b.source_start] = pl
      end_block(ctx, meta)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "paragraph" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      render_inlines_wrapped(ctx, b.spans, b.source_start, width, "", nil)
      end_block(ctx, meta)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "hr" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      local line = string.rep("─", math.max(1, width))
      emit_line(ctx, line, b.source_start, { { col = 0, end_col = #line, hl = "MdViewHr" } })
      end_block(ctx, meta)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "blockquote" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      local save_w = ctx.width
      ctx.width = math.max(10, width - 2)
      local before = #ctx.lines
      render_blocks(ctx, b.children)
      for li = before + 1, #ctx.lines do
        local t = ctx.lines[li]
        if t ~= "" then
          ctx.lines[li] = "│ " .. t
          ctx.extmarks[#ctx.extmarks + 1] = {
            line = li - 1,
            col = 0,
            end_col = 3,
            hl = "MdViewQuote",
          }
        elseif t == "" then
          ctx.lines[li] = "│"
        end
      end
      ctx.width = save_w
      end_block(ctx, meta)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "list" then
      -- 每个 list item 单独 block_range，便于只高亮当前项
      local bullets = cfg.list_bullets or { "●", "○" }
      -- 列表最小缩进作为 0 级基准
      local min_indent = math.huge
      for _, it in ipairs(b.items or {}) do
        min_indent = math.min(min_indent, it.indent or 0)
      end
      if min_indent == math.huge then
        min_indent = 0
      end
      for _, it in ipairs(b.items or {}) do
        local src0 = it.source_start or b.source_start
        local src1 = it.source_end or src0
        local meta = begin_block(ctx, src0, src1)
        meta.kind = "list_item"
        local ind = it.indent or 0
        local rel = math.max(0, ind - min_indent)
        -- 嵌套层级：有额外缩进至少第 2 层；约 4 列更深一级（兼容 2 空格 / 1 tab）
        local level
        if rel <= 0 then
          level = 1
        else
          level = math.floor((rel - 1) / 4) + 2
        end
        local item_lt = it.list_type or b.list_type
        local bullet
        -- 嵌套层或本项为 ul：用圆点；顶层 ol：保留源码编号
        if level > 1 or item_lt == "ul" then
          if level <= 1 then
            bullet = bullets[1] or "●"
          else
            bullet = bullets[2] or bullets[1] or "○"
          end
        elseif item_lt == "ol" or b.list_type == "ol" then
          if it.marker and tostring(it.marker):match("^%d+$") then
            bullet = tostring(it.marker) .. "."
          else
            bullet = "1."
          end
        else
          bullet = bullets[1] or "●"
        end
        -- 任务列表：列表符 + 复选框，如 `● ☐ todo` / `● ☑ done`
        if it.checked == true then
          bullet = bullet .. " ☑"
        elseif it.checked == false then
          bullet = bullet .. " ☐"
        end
        -- 嵌套缩进：相对层级 * 2 空格
        local pad = string.rep("  ", math.max(0, level - 1))
        local prefix = pad .. bullet .. " "
        render_inlines_wrapped(
          ctx,
          it.spans,
          src0,
          width,
          prefix,
          "MdViewListBullet"
        )
        end_block(ctx, meta)
      end
      emit_line(ctx, "", b.source_end)

    elseif b.type == "table" then
      -- 表内按「表头 / 数据行」分别记 block_range，整表不再记一块
      M._render_table(ctx, b)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "code" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      M._render_code(ctx, b)
      end_block(ctx, meta)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "image" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      M._render_image(ctx, b)
      end_block(ctx, meta)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "details" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      M._render_details(ctx, b)
      end_block(ctx, meta)
      emit_line(ctx, "", b.source_end)

    elseif b.type == "html_raw" then
      local meta = begin_block(ctx, b.source_start, b.source_end)
      if cfg.html and cfg.html.unknown == "hide" then
        -- skip
      else
        emit_line(ctx, b.text or "", b.source_start, {
          { col = 0, end_col = #(b.text or ""), hl = "MdViewCodeBlock" },
        })
      end
      end_block(ctx, meta)
    end
  end
end

---拆分单元格：图片列表 + 非图片 spans
local function split_cell_content(raw, cfg)
  local images = {}
  local non_img = {}
  local spans = parse_mod.parse_inlines(raw or "", cfg)
  for _, sp in ipairs(spans) do
    if sp.type == "image" then
      images[#images + 1] = { alt = sp.text or "", src = sp.src or "" }
    else
      non_img[#non_img + 1] = sp
    end
  end
  -- 单元格内 HTML <img>
  if raw and raw:lower():find("<img", 1, true) then
    local html = require("mdview.html")
    local img = html.parse_img_tag(raw)
    if img and img.src then
      local dup = false
      for _, im in ipairs(images) do
        if im.src == img.src then
          dup = true
          break
        end
      end
      if not dup then
        images[#images + 1] = { alt = img.alt or "", src = img.src }
      end
      if raw:match("^%s*<[Ii][Mm][Gg][^>]*/?>%s*$") then
        non_img = {}
      end
    end
  end
  return images, non_img
end

---单元格文本净宽；含图时至少占 table_w/ncol
local function cell_content_need(text, cfg, table_w, ncol)
  local images, non_img = split_cell_content(text, cfg)
  local w = 1
  if #non_img > 0 then
    local plain = select(1, flatten_spans(non_img))
    if plain and plain ~= "" then
      w = math.max(w, str_width(plain))
    end
  end
  if #images > 0 then
    -- 图列至少预留总宽/列数，且不超过 image.max_width
    local share = math.max(4, math.floor((table_w or 40) / math.max(1, ncol or 1)))
    local max_w = cfg.image and cfg.image.max_width
    if max_w and max_w > 0 then
      share = math.min(share, max_w)
    end
    w = math.max(w, share)
  end
  return w
end

---按显示宽计算内容所需列宽（英文 1、CJK/emoji 2；图列至少 1/总列数）
---@param header string[]
---@param rows string[][]
---@param ncol number
---@param cfg table
---@param table_w number
---@return number[] need
local function table_content_needs(header, rows, ncol, cfg, table_w)
  local need = {}
  for c = 1, ncol do
    need[c] = 1
  end
  for c = 1, ncol do
    need[c] = math.max(need[c], cell_content_need(header[c], cfg, table_w, ncol))
  end
  for _, row in ipairs(rows) do
    for c = 1, ncol do
      need[c] = math.max(need[c], cell_content_need(row[c], cfg, table_w, ncol))
    end
  end
  return need
end

---折行并映射 span 区间
local function wrap_with_ranges(text, ranges, width)
  local wrapped = wrap_text(text or "", width)
  local out = {}
  local byte_pos = 0
  for _, wline in ipairs(wrapped) do
    local line_start = byte_pos
    local line_end = byte_pos + #wline
    local lr = {}
    for _, r in ipairs(ranges or {}) do
      if r.end_col > line_start and r.col < line_end then
        local c0 = math.max(0, r.col - line_start)
        local c1 = math.min(#wline, r.end_col - line_start)
        if c1 > c0 then
          lr[#lr + 1] = {
            col = c0,
            end_col = c1,
            hl = r.hl,
            kind = r.kind,
            href = r.href,
            src = r.src,
          }
        end
      end
    end
    out[#out + 1] = { text = wline, ranges = lr }
    byte_pos = line_end
  end
  if #out == 0 then
    out[1] = { text = "", ranges = {} }
  end
  return out
end

---对齐并平移 ranges（pad 用空格，字节=显示宽）
local function pad_align_ranges(s, width, align, ranges)
  local w = str_width(s)
  local rs = ranges or {}
  if w > width then
    while str_width(s) > width - 1 and #s > 0 do
      s = s:sub(1, -2)
    end
    s = s .. "…"
    w = str_width(s)
    -- 截断后 ranges 简化为整段
    rs = {}
    for _, r in ipairs(ranges or {}) do
      if r.col < #s then
        rs[#rs + 1] = {
          col = r.col,
          end_col = math.min(r.end_col, #s),
          hl = r.hl,
          kind = r.kind,
          href = r.href,
        }
      end
    end
  end
  local pad = width - w
  if pad < 0 then
    pad = 0
  end
  local left = 0
  if align == "right" then
    left = pad
  elseif align == "center" then
    left = math.floor(pad / 2)
  end
  local prefix = string.rep(" ", left)
  local suffix = string.rep(" ", pad - left)
  local off = #prefix
  local new_rs = {}
  for _, r in ipairs(rs) do
    new_rs[#new_rs + 1] = {
      col = r.col + off,
      end_col = r.end_col + off,
      hl = r.hl,
      kind = r.kind,
      href = r.href,
      src = r.src,
    }
  end
  return prefix .. s .. suffix, new_rs
end

---解析单元格 inline，返回折行后的 {text, ranges}[]
---准备单元格行：文本 inline + 表内图片缩略（宽 = table_w/ncol，且不超过列宽）
---@return table[] { text, ranges, image_path? }
local function prepare_cell(raw, cell_w, align, cfg, ctx, ncol, table_w)
  local images, non_img = split_cell_content(raw, cfg)
  local out = {}

  -- 文本部分
  if #non_img > 0 then
    local plain, ranges = flatten_spans(non_img)
    if plain and plain:match("%S") then
      local wrapped = wrap_with_ranges(plain, ranges, cell_w)
      for _, part in ipairs(wrapped) do
        local text, rs = pad_align_ranges(part.text, cell_w, align or "left", part.ranges)
        out[#out + 1] = { text = text, ranges = rs }
      end
    end
  end

  -- 表内图：宽度 ≤ 列宽，且受 image.max_width 限制；高度按比例（含 cell_aspect）自适应
  local img_w = math.max(4, cell_w)
  local max_w = cfg.image and cfg.image.max_width
  if max_w and max_w > 0 then
    img_w = math.min(img_w, max_w)
  end
  local max_h = cfg.image and cfg.image.max_height or 0
  if max_h == nil then
    max_h = 0
  end
  local max_imgs = (cfg.image and cfg.image.max_images) or 20
  local mode = cfg.image and cfg.image.mode or "thumb"

  for _, im in ipairs(images) do
    local abs = select(1, image_mod.resolve_path(im.src, ctx and ctx.md_path))
    if mode == "off" or not abs then
      local ph = "🖼 " .. ((im.alt ~= "" and im.alt) or im.src or "")
      local text, rs = pad_align_ranges(ph, cell_w, align or "left", {
        { col = 0, end_col = #ph, hl = "MdViewImage" },
      })
      out[#out + 1] = { text = text, ranges = rs, image_path = abs }
    else
      ctx.image_count = (ctx.image_count or 0) + 1
      local thumb = nil
      if mode == "thumb" and ctx.image_count <= max_imgs then
        thumb = image_mod.render_thumb(abs, img_w, max_h, cfg)
      end
      if thumb and thumb.lines then
        for i, tl in ipairs(thumb.lines) do
          -- 缩略按列宽生成；若略短则右侧补空对齐列
          local text = tl
          local tw = str_width(text)
          if tw < cell_w then
            text = text .. string.rep(" ", cell_w - tw)
          end
          local ranges = {}
          if thumb.marks then
            for _, m in ipairs(thumb.marks) do
              if m.row == i - 1 then
                ranges[#ranges + 1] = {
                  col = m.col,
                  end_col = m.end_col,
                  hl = m.hl,
                }
              end
            end
          end
          if #ranges == 0 then
            ranges[1] = { col = 0, end_col = #tl, hl = "MdViewImg0" }
          end
          out[#out + 1] = { text = text, ranges = ranges, image_path = abs }
        end
      else
        local ph = "🖼 " .. ((im.alt ~= "" and im.alt) or im.src or "")
        local text, rs = pad_align_ranges(ph, cell_w, align or "left", {
          { col = 0, end_col = #ph, hl = "MdViewImage" },
        })
        out[#out + 1] = { text = text, ranges = rs, image_path = abs }
      end
    end
  end

  if #out == 0 then
    local spans = parse_mod.parse_inlines(raw or "", cfg)
    local plain, ranges = flatten_spans(spans)
    local wrapped = wrap_with_ranges(plain, ranges, cell_w)
    for _, part in ipairs(wrapped) do
      local text, rs = pad_align_ranges(part.text, cell_w, align or "left", part.ranges)
      out[#out + 1] = { text = text, ranges = rs }
    end
  end
  return out
end

---动态分配列宽：
--- 1) 所需总宽 ≤ 可用：严格按 need（表宽 = 内容实际需要，可小于窗口）
--- 2) 否则从短到长：若 need ≤ 当前均分份额则按需给满（避免 "drawbuf" 被挤成 6）
--- 3) 仍放不下的长列按比例分剩余宽度
---@param need number[]
---@param avail number 可分配给单元格的总显示宽
---@return number[] col_w
local function allocate_table_widths(need, avail)
  local ncol = #need
  if ncol == 0 then
    return {}
  end
  avail = math.max(ncol, avail)

  local ideal = {}
  local sum_need = 0
  for c = 1, ncol do
    ideal[c] = math.max(1, need[c] or 1)
    sum_need = sum_need + ideal[c]
  end

  -- 全部放得下：按内容实际需要，不撑满窗口
  if sum_need <= avail then
    return ideal
  end

  -- 短列优先按需锁定（need ≤ 当前剩余均分）
  local order = {}
  for c = 1, ncol do
    order[c] = c
  end
  table.sort(order, function(a, b)
    return ideal[a] < ideal[b]
  end)

  local col_w = {}
  local assigned = {}
  local remain = avail
  local left = ncol

  for _, c in ipairs(order) do
    local n = ideal[c]
    local fair = remain / math.max(1, left)
    if n <= fair then
      col_w[c] = n
      assigned[c] = true
      remain = remain - n
      left = left - 1
    end
  end

  local flex_idx = {}
  local flex_need_sum = 0
  for c = 1, ncol do
    if not assigned[c] then
      flex_idx[#flex_idx + 1] = c
      flex_need_sum = flex_need_sum + ideal[c]
    end
  end

  if #flex_idx == 0 then
    if remain > 0 then
      col_w[ncol] = (col_w[ncol] or 0) + remain
    end
    return col_w
  end

  remain = math.max(#flex_idx, remain)
  local used_flex = 0
  for i, c in ipairs(flex_idx) do
    local n = ideal[c]
    local w
    if i == #flex_idx then
      w = math.max(1, remain - used_flex)
    else
      w = math.max(1, math.floor(remain * n / math.max(1, flex_need_sum)))
      used_flex = used_flex + w
    end
    col_w[c] = w
  end

  local total = 0
  for c = 1, ncol do
    total = total + (col_w[c] or 1)
  end
  if total < avail then
    local last = flex_idx[#flex_idx]
    col_w[last] = col_w[last] + (avail - total)
  elseif total > avail then
    local over = total - avail
    for i = #flex_idx, 1, -1 do
      if over <= 0 then
        break
      end
      local c = flex_idx[i]
      local cut = math.min(over, math.max(0, (col_w[c] or 1) - 1))
      col_w[c] = (col_w[c] or 1) - cut
      over = over - cut
    end
  end

  return col_w
end

function M._render_table(ctx, b)
  local cfg = ctx.cfg
  local width = ctx.width
  local header = b.header or {}
  local rows = b.rows or {}
  local aligns = b.aligns or {}
  local ncol = #header
  for _, r in ipairs(rows) do
    ncol = math.max(ncol, #r)
  end
  if ncol == 0 then
    return
  end

  local style = cfg.table_style or "unicode"
  local sep_h = style == "ascii" and "-" or "─"
  local sep_v = style == "ascii" and "|" or "│"
  local c_tl, c_tr, c_bl, c_br = "┌", "┐", "└", "┘"
  local c_tm, c_bm, c_ml, c_mr, c_mm = "┬", "┴", "├", "┤", "┼"
  if style == "ascii" then
    c_tl, c_tr, c_bl, c_br = "+", "+", "+", "+"
    c_tm, c_bm, c_ml, c_mr, c_mm = "+", "+", "+", "+", "+"
  elseif style == "minimal" then
    sep_h, sep_v = " ", " "
    c_tl, c_tr, c_bl, c_br = " ", " ", " ", " "
    c_tm, c_bm, c_ml, c_mr, c_mm = " ", " ", " ", " ", " "
  end

  -- 边框占 ncol+1 格（│ 分隔）
  local border_w = ncol + 1
  local avail = math.max(ncol, width - border_w)
  local need = table_content_needs(header, rows, ncol, cfg, width)
  local col_w = allocate_table_widths(need, avail)

  local function emit_border(left, mid, right, fill)
    local parts = { left }
    for c = 1, ncol do
      parts[#parts + 1] = string.rep(fill, col_w[c])
      parts[#parts + 1] = (c < ncol) and mid or right
    end
    local line = table.concat(parts)
    emit_line(ctx, line, b.source_start, {
      { col = 0, end_col = #line, hl = "MdViewTableBorder" },
    })
  end

  ---@param cells string[]
  ---@param src number
  ---@param src_end number|nil
  ---@param kind string|nil
  local function emit_data_row(cells, src, src_end, kind)
    src = src or b.source_start
    src_end = src_end or src
    local row_meta = begin_block(ctx, src, src_end)
    row_meta.kind = kind or "table_row"

    local prepared = {}
    local h = 1
    for c = 1, ncol do
      prepared[c] = prepare_cell(
        cells[c] or "",
        col_w[c],
        aligns[c] or "left",
        cfg,
        ctx,
        ncol,
        width
      )
      h = math.max(h, #prepared[c])
    end
    -- 表内图：多行 █ 合并为一个 image_hd（避免高清按行拆成多张上下堆叠）
    ---@type table<string, { path: string, line: integer, line_end: integer, col: integer, end_col: integer }>
    local hd_blocks = {}
    for r = 1, h do
      local pieces = {}
      local ext = {}
      local link_hits = {}
      local image_hits = {}
      local byte_off = 0
      local function push_border(ch)
        pieces[#pieces + 1] = ch
        ext[#ext + 1] = {
          col = byte_off,
          end_col = byte_off + #ch,
          hl = "MdViewTableBorder",
        }
        byte_off = byte_off + #ch
      end
      push_border(sep_v)
      for c = 1, ncol do
        local cell = prepared[c][r] or { text = string.rep(" ", col_w[c]), ranges = {} }
        local text = cell.text
        if str_width(text) < col_w[c] then
          text = text .. string.rep(" ", col_w[c] - str_width(text))
        end
        pieces[#pieces + 1] = text
        local cell_start = byte_off
        for _, rg in ipairs(cell.ranges or {}) do
          local c0 = byte_off + rg.col
          local c1 = byte_off + rg.end_col
          ext[#ext + 1] = {
            col = c0,
            end_col = c1,
            hl = rg.hl,
            url = rg.href,
          }
          if rg.kind == "link" and rg.href then
            link_hits[#link_hits + 1] = { col = c0, end_col = c1, href = rg.href }
          end
        end
        if cell.image_path then
          image_hits[#image_hits + 1] = {
            col = cell_start,
            end_col = cell_start + #text,
            path = cell.image_path,
            dcols = col_w[c], -- 显示宽度（单元格列宽）
            col_index = c,
          }
        end
        byte_off = byte_off + #text
        push_border(sep_v)
      end
      local line = table.concat(pieces)
      local pl = emit_line(ctx, line, src, ext)
      for _, lh in ipairs(link_hits) do
        ctx.hits[#ctx.hits + 1] = {
          line = pl,
          kind = "link",
          href = lh.href,
          col = lh.col,
          end_col = lh.end_col,
        }
      end
      for _, ih in ipairs(image_hits) do
        ctx.hits[#ctx.hits + 1] = {
          line = pl,
          kind = "image",
          path = ih.path,
          col = ih.col,
          end_col = ih.end_col,
        }
        -- 按 path+列 合并多行 █ 为一个 hd 块
        local key = tostring(ih.path) .. "#" .. tostring(ih.col_index or ih.col)
        local blk = hd_blocks[key]
        if not blk then
          hd_blocks[key] = {
            path = ih.path,
            line = pl,
            line_end = pl,
            col = ih.col,
            end_col = ih.end_col,
            dcols = ih.dcols,
          }
        else
          if pl >= blk.line and pl <= blk.line_end + 1 then
            blk.line_end = math.max(blk.line_end, pl)
            -- 保留首行 col；end_col 取较大以覆盖
            if ih.end_col and (not blk.end_col or ih.end_col > blk.end_col) then
              blk.end_col = ih.end_col
            end
          end
        end
      end
    end
    for _, blk in pairs(hd_blocks) do
      ctx.hits[#ctx.hits + 1] = {
        kind = "image_hd",
        path = blk.path,
        line = blk.line,
        line_end = blk.line_end,
        col = blk.col,
        end_col = blk.end_col,
        dcols = blk.dcols, -- 表格列显示宽
      }
    end
    end_block(ctx, row_meta)
  end

  emit_border(c_tl, c_tm, c_tr, sep_h)
  local hdr_src = b.header_source or b.source_start
  local hdr_end = b.header_source_end or hdr_src
  emit_data_row(header, hdr_src, hdr_end, "table_header")
  emit_border(c_ml, c_mm, c_mr, sep_h)
  local row_sources = b.row_sources or {}
  for ri, row in ipairs(rows) do
    local rs = row_sources[ri]
    local s0 = (rs and rs.start) or b.source_start
    local s1 = (rs and rs["end"]) or s0
    emit_data_row(row, s0, s1, "table_row")
  end
  emit_border(c_bl, c_bm, c_br, sep_h)
end

function M._render_code(ctx, b)
  local cfg = ctx.cfg
  local width = ctx.width
  local lines = b.lines or {}
  local lang = b.lang or "text"
  local fold_n = cfg.code_fold_lines or 10
  local block_id = b.source_start
  local expanded = ctx.expanded_codes[block_id]
  local total = #lines
  local show_n = total
  local folded = false
  if fold_n > 0 and total > fold_n and not expanded then
    show_n = fold_n
    folded = true
  end

  local show_ln = cfg.code_line_numbers ~= false
  local ln_w = show_ln and math.max(2, #tostring(total)) or 0
  local gutter = show_ln and (ln_w + 3) or 2 -- │ + space
  local inner_w = math.max(8, width - gutter - 2)

  local function code_line_hl(extra)
    local er = {
      { col = 0, end_col = 0, line_hl = "MdViewCodeBg" },
    }
    for _, e in ipairs(extra or {}) do
      er[#er + 1] = e
    end
    return er
  end

  -- 顶栏：┌─────lua [Copy]/复制]┐
  local copy_label = require("mdview.i18n").t("copy")
  local lang_disp = lang
  local right = lang_disp .. " " .. copy_label
  local dash_w = math.max(1, width - 2 - str_width(right))
  local top = "┌" .. string.rep("─", dash_w) .. right .. "┐"
  while str_width(top) > width and #lang_disp > 1 do
    lang_disp = lang_disp:sub(1, -2)
    right = lang_disp .. " " .. copy_label
    dash_w = math.max(1, width - 2 - str_width(right))
    top = "┌" .. string.rep("─", dash_w) .. right .. "┐"
  end
  local dash_bytes = #string.rep("─", dash_w)
  local lang_byte_start = #"┌" + dash_bytes
  local lang_byte_end = lang_byte_start + #lang_disp
  local copy_byte_start = lang_byte_end + 1 -- 空格后
  local copy_byte_end = copy_byte_start + #copy_label
  local top_pl = emit_line(ctx, top, b.source_start, code_line_hl({
    { col = 0, end_col = lang_byte_start, hl = "MdViewCodeBorder" },
    { col = lang_byte_start, end_col = lang_byte_end, hl = "MdViewCodeLang" },
    { col = lang_byte_end, end_col = copy_byte_start, hl = "MdViewCodeBorder" },
    { col = copy_byte_start, end_col = copy_byte_end, hl = "MdViewCodeCopy" },
    { col = copy_byte_end, end_col = #top, hl = "MdViewCodeBorder" },
  }))
  -- 可点击 Copy
  ctx.hits[#ctx.hits + 1] = {
    line = top_pl,
    kind = "code_copy",
    col = copy_byte_start,
    end_col = copy_byte_end,
    block_id = block_id,
    lines = lines,
    lang = lang,
  }

  local visible = {}
  for i = 1, show_n do
    visible[#visible + 1] = lines[i] or ""
  end
  local hl_marks = code_mod.highlight(lang, visible, cfg.code_highlight or "auto")

  for i = 1, show_n do
    local raw = lines[i] or ""
    -- 截断过长
    if str_width(raw) > inner_w then
      local parts = wrap_text(raw, inner_w)
      raw = parts[1] or raw
    end
    local prefix
    if show_ln then
      prefix = string.format("│ %" .. ln_w .. "d │", i)
    else
      prefix = "│ "
    end
    local line = prefix .. raw
    -- 右侧补 │
    local pad = width - str_width(line) - 1
    if pad < 0 then
      pad = 0
    end
    line = line .. string.rep(" ", pad) .. "│"
    local er = {
      { col = 0, end_col = #prefix, hl = show_ln and "MdViewCodeLinenr" or "MdViewCodeBorder" },
    }
    local body_off = #prefix
    if hl_marks then
      for _, m in ipairs(hl_marks) do
        if m.row == i - 1 then
          er[#er + 1] = {
            col = body_off + m.col,
            end_col = body_off + m.end_col,
            hl = m.hl,
          }
        end
      end
    else
      er[#er + 1] = {
        col = body_off,
        end_col = body_off + #raw,
        hl = "MdViewCodeBlock",
      }
    end
    -- 右边框
    er[#er + 1] = { col = #line - 1, end_col = #line, hl = "MdViewCodeBorder" }
    emit_line(ctx, line, b.source_start + i, code_line_hl(er))
  end

  if folded then
    local more = total - show_n
    local fold_line = string.format("│ ⋯ %d more · <CR> expand ", more)
    local pad = width - str_width(fold_line) - 1
    if pad < 0 then
      pad = 0
    end
    fold_line = fold_line .. string.rep(" ", pad) .. "│"
    local pl = emit_line(ctx, fold_line, b.source_end, code_line_hl({
      { col = 0, end_col = #fold_line, hl = "MdViewCodeFold" },
    }))
    ctx.hits[#ctx.hits + 1] = {
      line = pl,
      kind = "code_fold",
      block_id = block_id,
      expanded = false,
    }
  elseif expanded and fold_n > 0 and total > fold_n then
    local fold_line = "│ ⋯ <CR> collapse "
    local pad = width - str_width(fold_line) - 1
    if pad < 0 then
      pad = 0
    end
    fold_line = fold_line .. string.rep(" ", pad) .. "│"
    local pl = emit_line(ctx, fold_line, b.source_end, code_line_hl({
      { col = 0, end_col = #fold_line, hl = "MdViewCodeFold" },
    }))
    ctx.hits[#ctx.hits + 1] = {
      line = pl,
      kind = "code_fold",
      block_id = block_id,
      expanded = true,
    }
  end

  local bot = "└" .. string.rep("─", math.max(1, width - 2)) .. "┘"
  emit_line(ctx, bot, b.source_end, code_line_hl({
    { col = 0, end_col = #bot, hl = "MdViewCodeBorder" },
  }))

  -- 整块 hit：供 c/yc 复制定位（折叠仅 code_fold 灰字行）
  ctx.hits[#ctx.hits + 1] = {
    line = top_pl,
    line_end = #ctx.lines,
    kind = "code_block",
    block_id = block_id,
    lines = lines,
    total_lines = total,
    foldable = fold_n > 0 and total > fold_n,
    lang = lang,
    source_end = b.source_end or b.source_start,
  }
end

function M._render_image(ctx, b)
  local cfg = ctx.cfg
  local mode = cfg.image and cfg.image.mode or "thumb"
  if mode == "off" then
    return
  end
  local line_w = math.max(4, ctx.width or 80)
  local md_path = ctx.md_path
  local abs, err = image_mod.resolve_path(b.src, md_path)
  local alt = b.alt ~= "" and b.alt or (b.src or "image")
  local title = string.format("🖼 %s · %s", alt, b.src or "")
  local title_c, title_pad = pad_center(title, line_w)
  local pl0 = emit_line(ctx, title_c, b.source_start, {
    { col = title_pad, end_col = title_pad + #title, hl = "MdViewImage" },
  })

  ctx.image_count = (ctx.image_count or 0) + 1
  local max_imgs = (cfg.image and cfg.image.max_images) or 20
  local thumb = nil
  if mode == "thumb" and abs and ctx.image_count <= max_imgs then
    -- 宽受 max_width 限制（默认 60 列）；高按比例。max_height 为上限（nil/0 不限制）
    local max_h = cfg.image and cfg.image.max_height
    if max_h == nil then
      max_h = 0 -- 不限制，完全按比例
    end
    local w = line_w
    local max_w = cfg.image and cfg.image.max_width
    if max_w and max_w > 0 then
      w = math.min(w, max_w)
    end
    w = math.max(4, w)
    thumb = image_mod.render_thumb(abs, w, max_h, cfg)
  end

  ---@type number|nil 缩略显示列宽 / 字节起止（居中后供 image_hd 定位）
  local thumb_dcols = nil
  local thumb_col = nil
  local thumb_end_col = nil

  if thumb and thumb.lines then
    for i, tl in ipairs(thumb.lines) do
      local er = {}
      if thumb.marks then
        for _, m in ipairs(thumb.marks) do
          if m.row == i - 1 then
            er[#er + 1] = {
              col = m.col,
              end_col = m.end_col,
              hl = m.hl,
            }
          end
        end
      end
      if #er == 0 then
        er[#er + 1] = { col = 0, end_col = #tl, hl = "MdViewImg0" }
      end
      -- 整行图在预览宽内居中
      local centered, left = pad_center(tl, line_w)
      er = shift_ranges(er, left)
      if i == 1 then
        thumb_dcols = thumb.width or str_width(tl)
        thumb_col = left
        thumb_end_col = left + #tl
      end
      emit_line(ctx, centered, b.source_start, er)
    end
  elseif err or not abs then
    local msg = "  [image unavailable: " .. (err or "missing") .. "]"
    local cmsg, pad = pad_center(msg, line_w)
    emit_line(ctx, cmsg, b.source_start, {
      { col = pad, end_col = pad + #msg, hl = "MdViewImage" },
    })
  elseif abs and vim.fn.filereadable(abs) ~= 1 then
    local msg = "  [file not found: " .. abs .. "]"
    local cmsg, pad = pad_center(msg, line_w)
    emit_line(ctx, cmsg, b.source_start, {
      { col = pad, end_col = pad + #msg, hl = "MdViewImage" },
    })
  else
    local msg = "  [thumb: pip install Pillow · <CR> open float]"
    local cmsg, pad = pad_center(msg, line_w)
    emit_line(ctx, cmsg, b.source_start, {
      { col = pad, end_col = pad + #msg, hl = "MdViewImage" },
    })
  end

  local pl1 = #ctx.lines
  if abs then
    -- 整块 hit：激活/跳转用
    for ln = pl0, pl1 do
      ctx.hits[#ctx.hits + 1] = {
        line = ln,
        kind = "image",
        path = abs,
      }
    end
    -- 高清叠层专用：缩略内容行（不含 🖼 标题）；带 col/dcols 以便居中后正确定位
    local thumb_line = pl0 + 1
    if pl1 >= thumb_line then
      ctx.hits[#ctx.hits + 1] = {
        kind = "image_hd",
        path = abs,
        line = thumb_line,
        line_end = pl1,
        col = thumb_col,
        end_col = thumb_end_col,
        dcols = thumb_dcols,
      }
    elseif pl1 >= pl0 then
      -- 无缩略时至少标标题行下方占位
      ctx.hits[#ctx.hits + 1] = {
        kind = "image_hd",
        path = abs,
        line = pl0,
        line_end = pl1,
      }
    end
  end
end

function M._render_details(ctx, b)
  local cfg = ctx.cfg
  local block_id = b.source_start
  local expanded = ctx.expanded_details[block_id]
  if expanded == nil then
    expanded = b.default_open and true or false
  end
  local marker = expanded and "▼" or "▸"
  local summary = b.summary or "Details"
  local line = marker .. " " .. summary
  local pl = emit_line(ctx, line, b.source_start, {
    { col = 0, end_col = #marker + 1, hl = "MdViewDetailsMarker" },
    { col = #marker + 1, end_col = #line, hl = "MdViewDetailsSummary" },
  })
  ctx.hits[#ctx.hits + 1] = {
    line = pl,
    kind = "details",
    block_id = block_id,
    expanded = expanded,
  }
  if expanded then
    local save_w = ctx.width
    ctx.width = math.max(10, ctx.width - 2)
    local before = #ctx.lines
    render_blocks(ctx, b.children)
    for li = before + 1, #ctx.lines do
      if ctx.lines[li] ~= "" then
        ctx.lines[li] = "  " .. ctx.lines[li]
      end
    end
    ctx.width = save_w
  end
end

---@param blocks table[]
---@param opts table
---@return RenderResult
function M.render(blocks, opts)
  highlight.ensure()
  opts = opts or {}
  local cfg = opts.cfg or require("mdview.config").get()
  local width = opts.width or 80
  if width < 20 then
    width = 20
  end

  local ctx = {
    cfg = cfg,
    width = width,
    lines = {},
    extmarks = {},
    source_map = {},
    rev_map = {},
    heading_preview = {}, ---@type table<number, number> source_line -> body preview line
    col_align = {}, ---@type table<number, table> preview_line -> 源/预览列对齐信息
    block_ranges = {},
    hits = {},
    expanded_codes = opts.expanded_codes or {},
    expanded_details = opts.expanded_details or {},
    md_path = opts.md_path,
    image_count = 0,
    last_source = 1,
  }

  -- 自动标题序号（先于 TOC / 正文）
  assign_heading_numbers(blocks)

  -- 顶部灰色快捷键提示（不写入 rev_map）
  if cfg.show_key_hint ~= false then
    local hint = M.help_line_text(width)
    emit_line(ctx, hint, nil, {
      { col = 0, end_col = #hint, hl = "MdViewKeyHint", line_hl = "MdViewKeyHint" },
    }, { no_rev_map = true })
    emit_line(ctx, "", nil, nil, { no_rev_map = true })
  end

  -- TOC（不写入 rev_map，避免占住标题源行映射）
  if cfg.toc and cfg.toc_position ~= "none" then
    local heads = toc_mod.collect(blocks, cfg)
    if #heads > 0 then
      local title = require("mdview.i18n").t("contents")
      emit_line(ctx, title, nil, { { col = 0, end_col = #title, hl = "MdViewTocTitle" } }, { no_rev_map = true })
      local toc_entries = {}
      -- 建立 source_start → auto_number
      local num_by_src = {}
      local function collect_nums(bs)
        for _, b in ipairs(bs or {}) do
          if b.type == "heading" then
            num_by_src[b.source_start] = b.auto_number or ""
          elseif b.children then
            collect_nums(b.children)
          end
        end
      end
      collect_nums(blocks)
      for _, h in ipairs(heads) do
        local indent = string.rep("  ", math.max(0, h.level - (cfg.toc_min_level or 1)))
        local num = num_by_src[h.source_start] or ""
        local tline = indent .. "· " .. num .. h.text
        local pl = emit_line(ctx, tline, h.source_start, {
          { col = 0, end_col = #tline, hl = "MdViewTocItem" },
          { col = 0, end_col = #tline, hl = "MdViewBold" },
        }, { no_rev_map = true })
        toc_entries[#toc_entries + 1] = { line = pl, source_start = h.source_start, text = h.text }
      end
      local sep = string.rep("─", math.min(width, 40))
      emit_line(ctx, sep, nil, { { col = 0, end_col = #sep, hl = "MdViewTocSep" } }, { no_rev_map = true })
      emit_line(ctx, "", nil, nil, { no_rev_map = true })
      ctx._toc_entries = toc_entries
    end
  end

  -- 按顶层 AST 段渲染并记录预览行范围（供按段增量）
  local fps = opts.fingerprints
  ctx.segments = {}
  for i, b in ipairs(blocks or {}) do
    local ps = #ctx.lines + 1
    render_blocks(ctx, { b })
    ctx.segments[#ctx.segments + 1] = {
      index = i,
      type = b.type,
      source_start = b.source_start,
      source_end = b.source_end,
      preview_start = ps,
      preview_end = #ctx.lines,
      fingerprint = fps and fps[i] or nil,
    }
  end

  -- TOC hits：跳到正文标题预览行（heading_preview / rev_map）
  if ctx._toc_entries then
    for _, e in ipairs(ctx._toc_entries) do
      local target = (ctx.heading_preview and ctx.heading_preview[e.source_start])
        or ctx.rev_map[e.source_start]
      ctx.hits[#ctx.hits + 1] = {
        line = e.line,
        kind = "toc",
        source_start = e.source_start,
        preview_target = target,
      }
    end
  end

  if #ctx.lines == 0 then
    emit_line(ctx, "(empty)", 1, nil)
  end

  return {
    lines = ctx.lines,
    extmarks = ctx.extmarks,
    source_map = ctx.source_map,
    rev_map = ctx.rev_map,
    heading_preview = ctx.heading_preview,
    col_align = ctx.col_align,
    block_ranges = ctx.block_ranges,
    hits = ctx.hits,
    segments = ctx.segments,
    body_start = ctx.segments[1] and ctx.segments[1].preview_start or (#ctx.lines + 1),
    has_key_hint = cfg.show_key_hint ~= false,
  }
end

function M.namespace()
  return NS
end

---为 blocks 写入 auto_number（增量渲染前须对整棵 AST 调用）
function M.assign_heading_numbers(blocks)
  assign_heading_numbers(blocks)
end

---仅渲染一个代码块为片段（行号从 1 / extmark 行从 0 起）
---@param b table { lines, lang, source_start, source_end }
---@param opts? { cfg?: table, width?: number, expanded_codes?: table }
---@return table fragment { lines, extmarks, source_map, rev_map, hits }
local function copy_shallow(t)
  local c = {}
  for k, v in pairs(t) do
    c[k] = v
  end
  return c
end

local function new_render_ctx(opts)
  opts = opts or {}
  local cfg = opts.cfg or require("mdview.config").get()
  local width = opts.width or 80
  if width < 20 then
    width = 20
  end
  return {
    cfg = cfg,
    width = width,
    lines = {},
    extmarks = {},
    source_map = {},
    rev_map = {},
    heading_preview = {},
    col_align = {},
    block_ranges = {},
    hits = {},
    expanded_codes = opts.expanded_codes or {},
    expanded_details = opts.expanded_details or {},
    md_path = opts.md_path,
    image_count = 0,
    last_source = 1,
  }
end

-- extmark.url 仅 Neovim 0.10+；0.9 传入会导致整次 set_extmark 失败（含 hl_group）
local has_extmark_url = vim.fn.has("nvim-0.10") == 1

---@param buf number
---@param result table
---@param em table
local function set_one_extmark(buf, result, em)
  local line_count = #(result.lines or {})
  local eopts = {}
  if em.hl then
    eopts.hl_group = em.hl
    eopts.end_col = em.end_col
    if em.hl == "MdViewLink" or em.url then
      eopts.priority = 120
    end
  end
  if em.line_hl then
    eopts.line_hl_group = em.line_hl
    if not eopts.end_col or eopts.end_col == 0 then
      local line = result.lines[em.line + 1] or ""
      eopts.end_col = #line
      eopts.hl_group = eopts.hl_group or "MdViewCodeBg"
    end
  end
  if em.virt_text then
    eopts.virt_text = em.virt_text
    eopts.virt_text_pos = em.virt_text_pos or "eol"
  end
  if has_extmark_url and em.url and em.url ~= "" then
    eopts.url = em.url
  end
  if em.line >= 0 and em.line < line_count then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, em.line, em.col or 0, eopts)
  end
end

function M.render_code_fragment(b, opts)
  highlight.ensure()
  local ctx = new_render_ctx(opts)
  ctx.last_source = b.source_start or 1
  M._render_code(ctx, b)
  return {
    lines = ctx.lines,
    extmarks = ctx.extmarks,
    source_map = ctx.source_map,
    rev_map = ctx.rev_map,
    hits = ctx.hits,
    heading_preview = ctx.heading_preview,
    col_align = ctx.col_align,
    block_ranges = ctx.block_ranges,
  }
end

---渲染若干顶层 block 为片段（标题序号须已由调用方处理）
---@param blocks table[]
---@param opts? table
---@return table fragment
function M.render_blocks_fragment(blocks, opts)
  highlight.ensure()
  opts = opts or {}
  local ctx = new_render_ctx(opts)
  local fps = opts.fingerprints
  local segs = {}
  for i, b in ipairs(blocks or {}) do
    local ps = #ctx.lines + 1
    render_blocks(ctx, { b })
    segs[#segs + 1] = {
      index = i,
      type = b.type,
      source_start = b.source_start,
      source_end = b.source_end,
      preview_start = ps,
      preview_end = #ctx.lines,
      fingerprint = fps and fps[i] or nil,
    }
  end
  return {
    lines = ctx.lines,
    extmarks = ctx.extmarks,
    source_map = ctx.source_map,
    rev_map = ctx.rev_map,
    hits = ctx.hits,
    heading_preview = ctx.heading_preview,
    col_align = ctx.col_align,
    block_ranges = ctx.block_ranges,
    segments = segs,
  }
end

---按 delta 平移「预览行号」键表（col_align 等）
local function shift_preview_keyed(map, start_1, end_1, delta)
  local out = {}
  for pl, v in pairs(map or {}) do
    if type(pl) == "number" then
      if pl < start_1 then
        out[pl] = v
      elseif pl > end_1 then
        out[pl + delta] = v
      end
    end
  end
  return out
end

---将 frag 拼入 result 的 [start_line, old_end]（1-based inclusive；可空插入 old_end=start_line-1）
---@param result table
---@param start_line number
---@param old_end number
---@param frag table
---@param opts? { replace_segments?: { lo: number, hi: number, list: table[] }, code_block_id?: number }
---@return table info
function M.splice_fragment(result, start_line, old_end, frag, opts)
  opts = opts or {}
  frag = frag or { lines = {} }
  local new_n = #(frag.lines or {})
  local old_n = old_end - start_line + 1
  if old_n < 0 then
    old_n = 0
  end
  local delta = new_n - old_n
  local base = start_line - 1

  local new_lines = {}
  for i = 1, start_line - 1 do
    new_lines[i] = result.lines[i]
  end
  for i = 1, new_n do
    new_lines[start_line + i - 1] = frag.lines[i]
  end
  local dest = start_line + new_n
  for i = old_end + 1, #(result.lines or {}) do
    new_lines[dest] = result.lines[i]
    dest = dest + 1
  end
  result.lines = new_lines

  local sm = {}
  for pl, src in pairs(result.source_map or {}) do
    if pl < start_line then
      sm[pl] = src
    elseif pl > old_end then
      sm[pl + delta] = src
    end
  end
  for pl, src in pairs(frag.source_map or {}) do
    sm[base + pl] = src
  end
  result.source_map = sm

  local rev = {}
  for src, pl in pairs(result.rev_map or {}) do
    if pl < start_line then
      rev[src] = pl
    elseif pl > old_end then
      rev[src] = pl + delta
    end
  end
  for src, pl in pairs(frag.rev_map or {}) do
    rev[src] = base + pl
  end
  result.rev_map = rev

  local hp = {}
  for src, pl in pairs(result.heading_preview or {}) do
    if pl < start_line then
      hp[src] = pl
    elseif pl > old_end then
      hp[src] = pl + delta
    end
  end
  for src, pl in pairs(frag.heading_preview or {}) do
    hp[src] = base + pl
  end
  result.heading_preview = hp

  result.col_align = shift_preview_keyed(result.col_align, start_line, old_end, delta)
  for pl, v in pairs(frag.col_align or {}) do
    result.col_align[base + pl] = v
  end

  local brs = {}
  for _, br in ipairs(result.block_ranges or {}) do
    local ps = br.preview_start or 0
    local pe = br.preview_end or ps
    if pe < start_line then
      brs[#brs + 1] = br
    elseif ps > old_end then
      local c = copy_shallow(br)
      c.preview_start = ps + delta
      c.preview_end = pe + delta
      brs[#brs + 1] = c
    end
  end
  for _, br in ipairs(frag.block_ranges or {}) do
    local c = copy_shallow(br)
    c.preview_start = (br.preview_start or 1) + base
    c.preview_end = (br.preview_end or br.preview_start or 1) + base
    brs[#brs + 1] = c
  end
  result.block_ranges = brs

  local start_0 = start_line - 1
  local old_end_0 = old_end - 1
  local ems = {}
  for _, em in ipairs(result.extmarks or {}) do
    local ln = em.line or 0
    if ln < start_0 then
      ems[#ems + 1] = em
    elseif ln > old_end_0 then
      local c = copy_shallow(em)
      c.line = ln + delta
      ems[#ems + 1] = c
    end
  end
  for _, em in ipairs(frag.extmarks or {}) do
    local c = copy_shallow(em)
    c.line = (em.line or 0) + start_0
    ems[#ems + 1] = c
  end
  result.extmarks = ems

  local hits = {}
  for _, h in ipairs(result.hits or {}) do
    local a = h.line or 0
    if old_n > 0 and a >= start_line and a <= old_end then
      -- drop
    else
      local c = h
      local need = false
      if a > old_end then
        c = copy_shallow(h)
        c.line = a + delta
        if h.line_end then
          c.line_end = h.line_end + delta
        end
        need = true
      end
      local pt = h.preview_target
      if pt and pt > old_end then
        if not need then
          c = copy_shallow(h)
        end
        c.preview_target = pt + delta
      end
      hits[#hits + 1] = c
    end
  end
  for _, h in ipairs(frag.hits or {}) do
    local c = copy_shallow(h)
    c.line = (h.line or 1) + base
    if h.line_end then
      c.line_end = h.line_end + base
    end
    hits[#hits + 1] = c
  end
  result.hits = hits

  if result.segments then
    if opts.replace_segments then
      local lo = opts.replace_segments.lo
      local hi = opts.replace_segments.hi
      local list = opts.replace_segments.list or {}
      local out = {}
      for i = 1, lo - 1 do
        out[#out + 1] = result.segments[i]
      end
      for _, s in ipairs(list) do
        local c = copy_shallow(s)
        c.preview_start = (s.preview_start or 1) + base
        c.preview_end = (s.preview_end or s.preview_start or 1) + base
        out[#out + 1] = c
      end
      for i = hi + 1, #result.segments do
        local s = result.segments[i]
        local c = copy_shallow(s)
        c.preview_start = (s.preview_start or 0) + delta
        c.preview_end = (s.preview_end or 0) + delta
        out[#out + 1] = c
      end
      for i, s in ipairs(out) do
        s.index = i
      end
      result.segments = out
    else
      for _, s in ipairs(result.segments) do
        local ps = s.preview_start or 0
        local pe = s.preview_end or ps
        if pe < start_line then
          -- before
        elseif ps > old_end then
          s.preview_start = ps + delta
          s.preview_end = pe + delta
        elseif opts.code_block_id and s.source_start == opts.code_block_id and s.type == "code" then
          local trail = pe - old_end
          if trail < 0 then
            trail = 0
          end
          s.preview_end = start_line + new_n - 1 + trail
        elseif ps >= start_line and pe <= old_end then
          s.preview_start = start_line
          s.preview_end = start_line + new_n - 1
        elseif pe >= start_line and ps <= old_end then
          s.preview_end = start_line + new_n - 1
        end
      end
    end
  end

  if result.segments and result.segments[1] then
    result.body_start = result.segments[1].preview_start
  end

  local new_end = start_line + new_n - 1
  return {
    start_line = start_line,
    old_end = old_end,
    new_end = new_end,
    delta = delta,
  }
end

---增量替换 result 中某个代码块 UI（不含段后空行）
function M.patch_code_block(result, opts)
  if not result or not opts or not opts.block_id then
    return nil
  end
  local block_id = opts.block_id
  local start_line, old_end
  local lines = opts.lines
  local lang = opts.lang
  local source_end = opts.source_end
  for _, h in ipairs(result.hits or {}) do
    if h.kind == "code_block" and h.block_id == block_id then
      start_line = h.line
      old_end = h.line_end or h.line
      lines = lines or h.lines
      lang = lang or h.lang
      source_end = source_end or h.source_end
      break
    end
  end
  if not start_line or not old_end or not lines then
    return nil
  end
  source_end = source_end or (block_id + #lines + 1)

  local expanded_codes = {}
  expanded_codes[block_id] = opts.expanded and true or false
  local frag = M.render_code_fragment({
    type = "code",
    lines = lines,
    lang = lang or "text",
    source_start = block_id,
    source_end = source_end,
  }, {
    cfg = opts.cfg,
    width = opts.width,
    expanded_codes = expanded_codes,
  })
  if #(frag.lines or {}) == 0 then
    return nil
  end
  return M.splice_fragment(result, start_line, old_end, frag, { code_block_id = block_id })
end

---按段替换正文：旧 segments[lo..hi_old] → frag
function M.replace_segments(result, lo, hi_old, frag)
  if not result or not result.segments then
    return nil
  end
  local nseg = #result.segments
  local start_line
  local old_end
  if lo >= 1 and lo <= nseg and hi_old >= lo and hi_old <= nseg then
    start_line = result.segments[lo].preview_start
    old_end = result.segments[hi_old].preview_end
  elseif lo >= 1 and lo <= nseg + 1 and hi_old < lo then
    if lo <= nseg then
      start_line = result.segments[lo].preview_start
    elseif nseg >= 1 then
      start_line = result.segments[nseg].preview_end + 1
    else
      start_line = result.body_start or (#(result.lines or {}) + 1)
    end
    old_end = start_line - 1
  else
    return nil
  end
  local hi = hi_old
  if hi < lo - 1 then
    hi = lo - 1
  end
  return M.splice_fragment(result, start_line, old_end, frag, {
    replace_segments = {
      lo = lo,
      hi = hi,
      list = frag.segments or {},
    },
  })
end

---仅刷新界面文案（顶栏 / TOC 标题 / Copy 标签）
function M.patch_ui_strings(result, width)
  local changed = {}
  if not result or not result.lines then
    return changed
  end
  local i18n = require("mdview.i18n")
  local copy = i18n.t("copy")
  local contents = i18n.t("contents")
  width = width or 80

  -- 顶栏可能被截断而不含 "mdview"；用 has_key_hint 或常见快捷键特征识别
  local line1 = result.lines[1]
  local is_hint = result.has_key_hint
    or (line1 and (line1:find("mdview", 1, true)
      or line1:find("Close(", 1, true)
      or line1:find("关闭(", 1, true)
      or line1:find("Refresh(", 1, true)
      or line1:find("刷新(", 1, true)))
  if is_hint and line1 then
    local hint = M.help_line_text(width)
    if line1 ~= hint then
      result.lines[1] = hint
      changed[#changed + 1] = 1
      local ems = {}
      for _, em in ipairs(result.extmarks or {}) do
        if em.line ~= 0 then
          ems[#ems + 1] = em
        end
      end
      ems[#ems + 1] = {
        line = 0,
        col = 0,
        end_col = #hint,
        hl = "MdViewKeyHint",
        line_hl = "MdViewKeyHint",
      }
      result.extmarks = ems
    end
  end

  for i, line in ipairs(result.lines) do
    if line == "◆ Contents" or line == "◆ 目录" then
      if line ~= contents then
        result.lines[i] = contents
        changed[#changed + 1] = i
        local ems = {}
        for _, em in ipairs(result.extmarks or {}) do
          if em.line ~= i - 1 then
            ems[#ems + 1] = em
          end
        end
        ems[#ems + 1] = {
          line = i - 1,
          col = 0,
          end_col = #contents,
          hl = "MdViewTocTitle",
        }
        result.extmarks = ems
      end
      break
    end
  end

  for _, h in ipairs(result.hits or {}) do
    if h.kind == "code_copy" and h.line and result.lines[h.line] then
      local row = h.line
      local line = result.lines[row]
      local has_old = line:find("%[Copy%]")
        or line:find("%[复制%]")
        or line:find("%[Copied%]")
        or line:find("%[已复制%]")
      if has_old and not line:find(copy, 1, true) then
        local lang = h.lang or "text"
        local right = lang .. " " .. copy
        local dash_w = math.max(1, width - 2 - vim.fn.strdisplaywidth(right))
        local top = "┌" .. string.rep("─", dash_w) .. right .. "┐"
        local lang_disp = lang
        while vim.fn.strdisplaywidth(top) > width and #lang_disp > 1 do
          lang_disp = lang_disp:sub(1, -2)
          right = lang_disp .. " " .. copy
          dash_w = math.max(1, width - 2 - vim.fn.strdisplaywidth(right))
          top = "┌" .. string.rep("─", dash_w) .. right .. "┐"
        end
        result.lines[row] = top
        local dash_bytes = #string.rep("─", dash_w)
        local lang_byte_start = #"┌" + dash_bytes
        local lang_byte_end = lang_byte_start + #lang_disp
        local copy_byte_start = lang_byte_end + 1
        local copy_byte_end = copy_byte_start + #copy
        h.col = copy_byte_start
        h.end_col = copy_byte_end
        local ems = {}
        for _, em in ipairs(result.extmarks or {}) do
          if em.line ~= row - 1 then
            ems[#ems + 1] = em
          end
        end
        local function add_em(col, end_col, hl)
          ems[#ems + 1] = {
            line = row - 1,
            col = col,
            end_col = end_col,
            hl = hl,
            line_hl = "MdViewCodeBg",
          }
        end
        add_em(0, lang_byte_start, "MdViewCodeBorder")
        add_em(lang_byte_start, lang_byte_end, "MdViewCodeLang")
        add_em(lang_byte_end, copy_byte_start, "MdViewCodeBorder")
        add_em(copy_byte_start, copy_byte_end, "MdViewCodeCopy")
        add_em(copy_byte_end, #top, "MdViewCodeBorder")
        result.extmarks = ems
        changed[#changed + 1] = row
      end
    end
  end

  return changed
end

---局部替换预览 buffer 行并重挂该段 extmark
function M.apply_range(buf, result, info)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not result or not info then
    return
  end
  highlight.ensure()
  local start_line = info.start_line
  local old_end = info.old_end
  local new_end = info.new_end
  local seg = {}
  if new_end >= start_line then
    for i = start_line, new_end do
      seg[#seg + 1] = result.lines[i] or ""
    end
  end
  local mod = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  -- old_end 为 1-based inclusive；纯插入时 old_end = start_line-1 → exclusive end = start_line-1
  vim.api.nvim_buf_set_lines(buf, start_line - 1, old_end, false, seg)
  if new_end >= start_line then
    pcall(vim.api.nvim_buf_clear_namespace, buf, NS, start_line - 1, new_end)
    local s0 = start_line - 1
    local e0 = new_end - 1
    for _, em in ipairs(result.extmarks or {}) do
      local ln = em.line or -1
      if ln >= s0 and ln <= e0 then
        set_one_extmark(buf, result, em)
      end
    end
  end
  vim.bo[buf].modifiable = mod
end

---把若干 1-based 行写回 buffer
function M.apply_line_updates(buf, result, rows)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not result or not rows or #rows == 0 then
    return
  end
  highlight.ensure()
  local mod = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local seen = {}
  for _, row in ipairs(rows) do
    if row and not seen[row] and result.lines[row] then
      seen[row] = true
      vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { result.lines[row] })
      pcall(vim.api.nvim_buf_clear_namespace, buf, NS, row - 1, row)
      for _, em in ipairs(result.extmarks or {}) do
        if em.line == row - 1 then
          set_one_extmark(buf, result, em)
        end
      end
    end
  end
  vim.bo[buf].modifiable = mod
end

local HELP_NS = vim.api.nvim_create_namespace("mdview_help")

---顶部/底部快捷键文案（按窗口列数截断/补空）
---@param cols number
---@return string
function M.help_line_text(cols)
  local hint = require("mdview.i18n").t("key_hint")
  cols = math.max(8, cols or 40)
  local w = vim.fn.strdisplaywidth(hint)
  if w < cols then
    hint = hint .. string.rep(" ", cols - w)
  else
    while vim.fn.strdisplaywidth(hint) > cols and #hint > 0 do
      hint = vim.fn.strcharpart(hint, 0, vim.fn.strchars(hint) - 1)
    end
    local pad = cols - vim.fn.strdisplaywidth(hint)
    if pad > 0 then
      hint = hint .. string.rep(" ", pad)
    end
  end
  return hint
end

---在预览 buffer 末尾附加/移除帮助行。
---重要：不得改写 0..base_n-1 的正文行，否则会清掉语法/样式 extmark。
---@param buf number
---@param result RenderResult
---@param show boolean
---@param cols number|nil
function M.apply_help_line(buf, result, show, cols)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  highlight.ensure()
  local base_n = result and result.lines and #result.lines or 0
  if base_n == 0 then
    return
  end
  cols = cols or 80
  local mod = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true

  local cur_n = vim.api.nvim_buf_line_count(buf)
  -- 只删「正文之后」的附加行（旧帮助条），不动正文
  if cur_n > base_n then
    vim.api.nvim_buf_set_lines(buf, base_n, -1, false, {})
  end

  vim.api.nvim_buf_clear_namespace(buf, HELP_NS, 0, -1)
  if show then
    local hint = M.help_line_text(cols)
    -- 在末尾插入一行，不触碰 0..base_n-1（遗留底部条；默认已改顶部）
    vim.api.nvim_buf_set_lines(buf, base_n, base_n, false, { hint })
    pcall(vim.api.nvim_buf_set_extmark, buf, HELP_NS, base_n, 0, {
      end_row = base_n,
      end_col = #hint,
      hl_group = "MdViewKeyHint",
      line_hl_group = "MdViewKeyHint",
    })
  end

  vim.bo[buf].modifiable = mod
end

---@param buf number
---@param result RenderResult
---@param opts? { show_help?: boolean, cols?: number }
function M.apply(buf, result, opts)
  highlight.ensure()
  opts = opts or {}
  vim.bo[buf].modifiable = true
  -- 整缓冲替换正文（帮助行随后再挂）
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, HELP_NS, 0, -1)
  for _, em in ipairs(result.extmarks or {}) do
    set_one_extmark(buf, result, em)
  end
  vim.bo[buf].modifiable = false

  -- 帮助已改为 ? float，默认不再追加底部提示行
  if opts.show_help then
    M.apply_help_line(buf, result, true, opts.cols)
  end
end

return M
