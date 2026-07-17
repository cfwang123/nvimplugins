---@mod mdview.parse
--- 纯 Lua Markdown 子集解析 → 统一 AST（自研，便于扩展 GFM/HTML）
local html = require("mdview.html")

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  if text == "" then
    return { "" }
  end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---行内解析：产出 spans 列表
---@param text string
---@param cfg table
---@return table[]
function M.parse_inlines(text, cfg)
  cfg = cfg or {}
  local spans = {}
  local i = 1
  local n = #text

  local function push_text(s)
    if s and s ~= "" then
      spans[#spans + 1] = { type = "text", text = s }
    end
  end

  local function take_until(start, pat)
    local a, b, cap = text:find(pat, start)
    return a, b, cap
  end

  while i <= n do
    local c = text:sub(i, i)
    local two = text:sub(i, i + 1)
    local three = text:sub(i, i + 2)

    -- 行内代码
    if c == "`" then
      local j = text:find("`", i + 1, true)
      if j then
        spans[#spans + 1] = { type = "code", text = text:sub(i + 1, j - 1) }
        i = j + 1
      else
        push_text("`")
        i = i + 1
      end
    -- <font color/style>…</font>；其它 `<`（如 <500ms、<etag>）必须前进，否则会死循环
    elseif c == "<" then
      if (cfg.html == nil or cfg.html.font ~= false) and html.is_font_open_at(text, i) then
        local next_i, font_sp = html.parse_font_at(text, i)
        if next_i and font_sp then
          spans[#spans + 1] = font_sp
          i = next_i
        else
          push_text("<")
          i = i + 1
        end
      else
        push_text("<")
        i = i + 1
      end
    -- 图片 ![alt](url)；单独的 `!`（如 !=、!flag）必须前进，否则会死循环
    elseif two == "![" then
      local close = text:find("%]", i + 2)
      if close and text:sub(close + 1, close + 1) == "(" then
        local endp = text:find("%)", close + 2)
        if endp then
          local alt = text:sub(i + 2, close - 1)
          local src = text:sub(close + 2, endp - 1)
          spans[#spans + 1] = { type = "image", text = alt, src = src }
          i = endp + 1
        else
          push_text("!")
          i = i + 1
        end
      else
        push_text("!")
        i = i + 1
      end
    elseif c == "!" then
      push_text("!")
      i = i + 1
    -- 链接 [text](url)
    elseif c == "[" then
      local close = text:find("%]", i + 1)
      if close and text:sub(close + 1, close + 1) == "(" then
        local endp = text:find("%)", close + 2)
        if endp then
          local label = text:sub(i + 1, close - 1)
          local href = text:sub(close + 2, endp - 1)
          spans[#spans + 1] = { type = "link", text = label, href = href }
          i = endp + 1
        else
          push_text("[")
          i = i + 1
        end
      else
        push_text("[")
        i = i + 1
      end
    -- ==mark==
    elseif cfg.mark_highlight ~= false and two == "==" then
      local j = text:find("==", i + 2, true)
      if j then
        spans[#spans + 1] = { type = "mark", text = text:sub(i + 2, j - 1) }
        i = j + 2
      else
        push_text("=")
        i = i + 1
      end
    -- ~~strike~~
    elseif cfg.strikethrough ~= false and two == "~~" then
      local j = text:find("~~", i + 2, true)
      if j then
        spans[#spans + 1] = { type = "strike", text = text:sub(i + 2, j - 1) }
        i = j + 2
      else
        push_text("~")
        i = i + 1
      end
    -- *** bold+italic or ** bold
    elseif three == "***" then
      local j = text:find("%*%*%*", i + 3)
      if j then
        spans[#spans + 1] = { type = "bold_italic", text = text:sub(i + 3, j - 1) }
        i = j + 3
      else
        push_text("*")
        i = i + 1
      end
    elseif two == "**" then
      local j = text:find("%*%*", i + 2)
      if j then
        spans[#spans + 1] = { type = "bold", text = text:sub(i + 2, j - 1) }
        i = j + 2
      else
        push_text("*")
        i = i + 1
      end
    elseif two == "__" then
      local j = text:find("__", i + 2, true)
      if j then
        spans[#spans + 1] = { type = "bold", text = text:sub(i + 2, j - 1) }
        i = j + 2
      else
        push_text("_")
        i = i + 1
      end
    elseif c == "*" then
      local j = text:find("%*", i + 1)
      if j then
        spans[#spans + 1] = { type = "italic", text = text:sub(i + 1, j - 1) }
        i = j + 1
      else
        push_text("*")
        i = i + 1
      end
    elseif c == "_" then
      -- 单词边界启发式：两侧非词字符
      local prev = i > 1 and text:sub(i - 1, i - 1) or " "
      local j = text:find("_", i + 1, true)
      if j then
        local nextc = j < n and text:sub(j + 1, j + 1) or " "
        local inner = text:sub(i + 1, j - 1)
        if not prev:match("[%w]") and not nextc:match("[%w]") and not inner:match("\n") then
          spans[#spans + 1] = { type = "italic", text = inner }
          i = j + 1
        else
          push_text("_")
          i = i + 1
        end
      else
        push_text("_")
        i = i + 1
      end
    else
      -- 连续普通文本（在 special 字符前停下，交由上面分支处理）
      local k = i
      while k <= n do
        local ch = text:sub(k, k)
        local t2 = text:sub(k, k + 1)
        if ch == "`" or ch == "[" or ch == "*" or ch == "_" or ch == "!" or ch == "<"
          or t2 == "==" or t2 == "~~" then
          break
        end
        k = k + 1
      end
      if k > i then
        push_text(text:sub(i, k - 1))
        i = k
      else
        -- 兜底：未知/未消费字符也前进，避免死循环
        push_text(c)
        i = i + 1
      end
    end
  end

  -- 合并相邻 text
  local merged = {}
  for _, sp in ipairs(spans) do
    local last = merged[#merged]
    if sp.type == "text" and last and last.type == "text" then
      last.text = last.text .. sp.text
    else
      merged[#merged + 1] = sp
    end
  end
  return merged
end

local function is_hr(line)
  local s = trim(line)
  if #s < 3 then
    return false
  end
  return s:match("^%-%-%-+%s*$") or s:match("^%*%*%*+%s*$") or s:match("^___+%s*$")
end

local function heading_atx(line)
  local level, text = line:match("^(#+)%s+(.-)%s*$")
  if not level then
    return nil
  end
  level = #level
  if level < 1 or level > 6 then
    return nil
  end
  return level, text
end

local function fence_open(line)
  -- Lua pattern 无 {3,}，用 `+` / 连续匹配
  local indent, fence, info = line:match("^(%s*)(```[`]*|~~~[~]*)%s*(.*)$")
  if not fence then
    -- 至少三个
    indent, fence, info = line:match("^(%s*)(```)%s*(.*)$")
  end
  if not fence then
    indent, fence, info = line:match("^(%s*)(~~~)%s*(.*)$")
  end
  if not fence then
    return nil
  end
  local ch = fence:sub(1, 1)
  return #indent, ch, #fence, trim(info or "")
end

local function is_table_row(line)
  return line:find("|", 1, true) ~= nil and not line:match("^%s*```")
end

local function is_table_sep(line)
  local s = trim(line)
  if not s:find("|", 1, true) then
    return false
  end
  s = s:gsub("^|", ""):gsub("|$", "")
  for cell in (s .. "|"):gmatch("([^|]*)|") do
    local c = trim(cell)
    if c ~= "" and not c:match("^:?%-+:?$") then
      return false
    end
  end
  return true
end

---按 `|` 分列，支持单元格内转义 `\|`（显示为 `|`）
local function split_table_row(line)
  local s = trim(line)
  if s == "" then
    return {}
  end
  -- 去掉行首/行尾未转义的 |
  if s:sub(1, 1) == "|" then
    s = s:sub(2)
  end
  if #s > 0 and s:sub(-1) == "|" then
    -- 行尾 | 前若为奇数个反斜杠则属于转义，不剥
    local bs = 0
    local j = #s - 1
    while j >= 1 and s:sub(j, j) == "\\" do
      bs = bs + 1
      j = j - 1
    end
    if bs % 2 == 0 then
      s = s:sub(1, -2)
    end
  end

  local cells = {}
  local cur = {}
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and i < n and s:sub(i + 1, i + 1) == "|" then
      cur[#cur + 1] = "|"
      i = i + 2
    elseif c == "|" then
      cells[#cells + 1] = trim(table.concat(cur))
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  cells[#cells + 1] = trim(table.concat(cur))
  return cells
end

local function parse_align_row(line)
  local cells = split_table_row(line)
  local aligns = {}
  for _, c in ipairs(cells) do
    local left = c:sub(1, 1) == ":"
    local right = c:sub(-1) == ":"
    if left and right then
      aligns[#aligns + 1] = "center"
    elseif right then
      aligns[#aligns + 1] = "right"
    else
      aligns[#aligns + 1] = "left"
    end
  end
  return aligns
end

local function list_marker(line)
  local indent, marker, rest = line:match("^(%s*)([-*+])%s+(.*)$")
  if marker then
    local task, body = rest:match("^%[([ xX])%]%s+(.*)$")
    if task then
      return #indent, "ul", marker, body, task:lower() == "x"
    end
    return #indent, "ul", marker, rest, nil
  end
  indent, marker, rest = line:match("^(%s*)(%d+)%.%s+(.*)$")
  if marker then
    return #indent, "ol", marker, rest, nil
  end
  return nil
end

local function quote_prefix(line)
  local q, rest = line:match("^(%s*>%s?)(.*)$")
  if q then
    return rest
  end
  return nil
end

---解析若干行文本为 blocks
---@param lines string[]
---@param cfg table
---@param line_offset number 源行号偏移（1-based 起点 - 1）
---@param depth number details 嵌套深度
---@return table[]
function M.parse_lines(lines, cfg, line_offset, depth)
  cfg = cfg or {}
  line_offset = line_offset or 0
  depth = depth or 0
  local blocks = {}
  local i = 1
  local n = #lines
  local max_details = (cfg.html and cfg.html.details_max_depth) or 8

  local function src_line(idx)
    return line_offset + idx
  end

  local function add(block)
    blocks[#blocks + 1] = block
  end

  while i <= n do
    local line = lines[i]
    local trimmed = trim(line)

    -- 空行
    if trimmed == "" then
      i = i + 1
    -- HTML details
    elseif (cfg.html == nil or cfg.html.details ~= false)
      and trimmed:lower():match("^<details[%s>]")
      and depth < max_details
    then
      local det = html.extract_details(lines, i, cfg)
      if det then
        local inner_blocks = M.parse_lines(det.body_lines, cfg, det.body_line_offset - 1, depth + 1)
        add({
          type = "details",
          source_start = src_line(i),
          source_end = src_line(det.end_idx),
          summary = det.summary,
          summary_spans = M.parse_inlines(det.summary, cfg),
          default_open = det.open,
          children = inner_blocks,
        })
        i = det.end_idx + 1
      else
        add({
          type = "html_raw",
          source_start = src_line(i),
          source_end = src_line(i),
          text = line,
        })
        i = i + 1
      end
    -- HTML img
    elseif (cfg.html == nil or cfg.html.img ~= false) and trimmed:lower():match("^<img[%s/>]") then
      local img = html.parse_img_tag(trimmed)
      if img and img.src then
        add({
          type = "image",
          source_start = src_line(i),
          source_end = src_line(i),
          alt = img.alt or "",
          src = img.src,
          from = "html",
        })
      else
        add({
          type = "html_raw",
          source_start = src_line(i),
          source_end = src_line(i),
          text = line,
        })
      end
      i = i + 1
    -- 围栏代码
    elseif fence_open(line) then
      local _, ch, flen, info = fence_open(line)
      local lang = (info:match("^([%w%+%-#%.]+)") or info or ""):lower()
      local code_lines = {}
      local start_i = i
      i = i + 1
      while i <= n do
        local close_m = lines[i]:match("^%s*(" .. vim.pesc(ch) .. "+)%s*$")
        if close_m and #close_m >= flen then
          break
        end
        code_lines[#code_lines + 1] = lines[i]
        i = i + 1
      end
      local end_i = i
      if i <= n then
        end_i = i
        i = i + 1
      end
      add({
        type = "code",
        source_start = src_line(start_i),
        source_end = src_line(end_i),
        lang = lang ~= "" and lang or "text",
        lines = code_lines,
      })
    -- 标题
    elseif heading_atx(line) then
      local level, text = heading_atx(line)
      add({
        type = "heading",
        source_start = src_line(i),
        source_end = src_line(i),
        level = level,
        text = text,
        spans = M.parse_inlines(text, cfg),
      })
      i = i + 1
    -- HR
    elseif is_hr(line) then
      add({
        type = "hr",
        source_start = src_line(i),
        source_end = src_line(i),
      })
      i = i + 1
    -- 表格
    elseif is_table_row(line) and i < n and is_table_sep(lines[i + 1]) then
      local start_i = i
      local header = split_table_row(line)
      local aligns = parse_align_row(lines[i + 1])
      local header_source = src_line(start_i)
      -- 分隔行 |---| 也算表头区，便于光标落在分隔行时高亮表头
      local header_source_end = src_line(start_i + 1)
      i = i + 2
      local rows = {}
      local row_sources = {} ---@type {start:number, end_:number}[]
      while i <= n and is_table_row(lines[i]) and trim(lines[i]) ~= "" and not fence_open(lines[i]) do
        if is_hr(lines[i]) then
          break
        end
        rows[#rows + 1] = split_table_row(lines[i])
        local rs = src_line(i)
        row_sources[#row_sources + 1] = { start = rs, ["end"] = rs }
        i = i + 1
      end
      add({
        type = "table",
        source_start = src_line(start_i),
        source_end = src_line(i - 1),
        header = header,
        header_source = header_source,
        header_source_end = header_source_end,
        aligns = aligns,
        rows = rows,
        row_sources = row_sources,
      })
    -- 引用
    elseif quote_prefix(line) ~= nil then
      local start_i = i
      local qlines = {}
      while i <= n do
        local rest = quote_prefix(lines[i])
        if rest == nil then
          if trim(lines[i]) == "" then
            break
          end
          break
        end
        qlines[#qlines + 1] = rest
        i = i + 1
      end
      local inner = M.parse_lines(qlines, cfg, src_line(start_i) - 1, depth)
      add({
        type = "blockquote",
        source_start = src_line(start_i),
        source_end = src_line(i - 1),
        children = inner,
      })
    -- 列表
    elseif list_marker(line) then
      local start_i = i
      local items = {}
      local list_type = select(2, list_marker(line))
      while i <= n do
        local ind, lt, marker, rest, checked = list_marker(lines[i])
        if not ind or lt ~= list_type then
          -- 续行：缩进更多
          if #items > 0 and lines[i]:match("^%s+%S") and not fence_open(lines[i]) and not heading_atx(lines[i]) then
            local cont = lines[i]:match("^%s+(.*)$")
            items[#items].text = items[#items].text .. "\n" .. cont
            items[#items].source_end = src_line(i)
            i = i + 1
          else
            break
          end
        else
          -- 关闭上一 item 的 source_end（续行会延长）
          if #items > 0 and not items[#items].source_end then
            items[#items].source_end = src_line(i) - 1
          end
          items[#items + 1] = {
            text = rest,
            checked = checked,
            marker = marker,
            indent = ind,
            spans = nil, -- 稍后
            source_start = src_line(i),
            source_end = src_line(i),
          }
          i = i + 1
        end
      end
      -- 续行时拉长当前 item 的 source_end
      -- （上面 cont 分支只改了 text，在此统一收尾）
      local list_end = src_line(i - 1)
      for ii, it in ipairs(items) do
        if ii < #items then
          local next_start = items[ii + 1].source_start or list_end
          it.source_end = math.max(it.source_start or next_start, next_start - 1)
        else
          it.source_end = list_end
        end
        it.spans = M.parse_inlines(it.text:gsub("\n", " "), cfg)
      end
      add({
        type = "list",
        source_start = src_line(start_i),
        source_end = list_end,
        list_type = list_type,
        items = items,
      })
    -- 单独一行 markdown 图片
    elseif trimmed:match("^!%[.-%]%(.-%)$") then
      local alt, src = trimmed:match("^!%[(.-)%]%((.-)%)$")
      add({
        type = "image",
        source_start = src_line(i),
        source_end = src_line(i),
        alt = alt or "",
        src = src or "",
        from = "md",
      })
      i = i + 1
    -- 段落
    else
      local start_i = i
      local plines = { line }
      i = i + 1
      while i <= n do
        local t = trim(lines[i])
        if t == "" or heading_atx(lines[i]) or is_hr(lines[i]) or fence_open(lines[i])
          or list_marker(lines[i]) or quote_prefix(lines[i]) ~= nil
          or (is_table_row(lines[i]) and i < n and is_table_sep(lines[i + 1]))
          or t:lower():match("^<details[%s>]")
          or t:lower():match("^<img[%s/>]")
        then
          break
        end
        plines[#plines + 1] = lines[i]
        i = i + 1
      end
      local text = table.concat(plines, " ")
      add({
        type = "paragraph",
        source_start = src_line(start_i),
        source_end = src_line(i - 1),
        text = text,
        spans = M.parse_inlines(text, cfg),
      })
    end
  end

  return blocks
end

---@param text string
---@param cfg table|nil
---@return table[]
function M.parse(text, cfg)
  local lines = split_lines(text or "")
  return M.parse_lines(lines, cfg or {}, 0, 0)
end

---@param buf number
---@param cfg table|nil
---@return table[]
function M.parse_buf(buf, cfg)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return M.parse_lines(lines, cfg or {}, 0, 0)
end

return M
