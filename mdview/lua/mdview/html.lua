---@mod mdview.html
--- HTML 白名单：img / details / summary / font
local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---简易属性解析
---@param tag string
---@return table<string, string>
function M.parse_attrs(tag)
  local attrs = {}
  -- name="value" | name='value' | name=value
  for name, val in tag:gmatch('([%w:_-]+)%s*=%s*"([^"]*)"') do
    attrs[name:lower()] = val
  end
  for name, val in tag:gmatch("([%w:_-]+)%s*=%s*'([^']*)'") do
    attrs[name:lower()] = val
  end
  -- 无引号：允许 #hex 等
  for name, val in tag:gmatch("([%w:_-]+)%s*=%s*([^%s>\"']+)") do
    if not attrs[name:lower()] then
      attrs[name:lower()] = val
    end
  end
  -- boolean attrs
  if tag:lower():find("%sopen[%s>]") or tag:lower():find("%sopen$") then
    attrs.open = "open"
  end
  return attrs
end

---规范化颜色为 #rrggbb（供 nvim_set_hl）
---@param s string|nil
---@return string|nil
function M.normalize_color(s)
  if not s or s == "" then
    return nil
  end
  s = trim(s):gsub("^['\"]", ""):gsub("['\"]$", "")
  -- #rgb / #rrggbb / #rrggbbaa
  if s:match("^#%x%x%x$") then
    local r, g, b = s:match("^#(%x)(%x)(%x)$")
    if r then
      return string.format("#%s%s%s%s%s%s", r, r, g, g, b, b):lower()
    end
  end
  if s:match("^#%x%x%x%x%x%x$") then
    return s:lower()
  end
  if s:match("^#%x%x%x%x%x%x%x%x$") then
    return s:sub(1, 7):lower()
  end
  local r, g, b = s:match("^[Rr][Gg][Bb]%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
  if r then
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if r and g and b and r <= 255 and g <= 255 and b <= 255 then
      return string.format("#%02x%02x%02x", r, g, b)
    end
  end
  return nil
end

---解析 style="a:b; c:d"
---@param style string|nil
---@return table<string, string>
function M.parse_style(style)
  local out = {}
  if not style or style == "" then
    return out
  end
  for part in (style .. ";"):gmatch("([^;]+);") do
    local k, v = part:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
    if k and v then
      out[k:lower()] = v
    end
  end
  return out
end

---font-weight 是否视为粗体
---@param v string|nil
---@return boolean
local function is_bold_weight(v)
  if not v or v == "" then
    return false
  end
  v = trim(v):lower()
  if v == "bold" or v == "bolder" then
    return true
  end
  local n = tonumber(v)
  return n ~= nil and n >= 600
end

---font-style 是否视为斜体
---@param v string|nil
---@return boolean
local function is_italic_style(v)
  if not v or v == "" then
    return false
  end
  v = trim(v):lower()
  return v == "italic" or v == "oblique"
end

---从 font 属性取颜色与字重/字形
---@param attrs table<string, string>
---@return string|nil fg, string|nil bg, boolean bold, boolean italic
function M.font_colors_from_attrs(attrs)
  attrs = attrs or {}
  local fg = M.normalize_color(attrs.color)
  local bg = M.normalize_color(attrs.bgcolor)
  local bold = false
  local italic = false
  local st = M.parse_style(attrs.style)
  if st.color then
    fg = M.normalize_color(st.color) or fg
  end
  local bg_s = st["background-color"] or st.background or st.bg
  if bg_s then
    bg = M.normalize_color(bg_s) or bg
  end
  if is_bold_weight(st["font-weight"] or st.weight or st.fontweight) then
    bold = true
  end
  if is_italic_style(st["font-style"] or st.fontstyle) then
    italic = true
  end
  return fg, bg, bold, italic
end

---结构化样式（颜色 + bold/italic）
---@param attrs table<string, string>
---@return { fg: string|nil, bg: string|nil, bold: boolean, italic: boolean }
function M.font_style_from_attrs(attrs)
  local fg, bg, bold, italic = M.font_colors_from_attrs(attrs)
  return { fg = fg, bg = bg, bold = bold == true, italic = italic == true }
end

---在 text 的 pos（1-based）处是否为 <font ...>
---@param text string
---@param pos integer
---@return boolean
function M.is_font_open_at(text, pos)
  if not text or not pos or pos < 1 then
    return false
  end
  local head = text:sub(pos, pos + 4):lower()
  if head ~= "<font" then
    return false
  end
  local nextc = text:sub(pos + 5, pos + 5)
  return nextc == "" or nextc:match("[%s/>]")
end

---解析 text 中从 pos 起的 <font...>inner</font>
---@param text string
---@param pos integer 1-based
---@return integer|nil end_pos 结束后下一字符 1-based, table|nil span
function M.parse_font_at(text, pos)
  if not M.is_font_open_at(text, pos) then
    return nil, nil
  end
  local gt = text:find(">", pos + 5, true)
  if not gt then
    return nil, nil
  end
  local close_s, close_e = text:find("</[Ff][Oo][Nn][Tt]>", gt + 1)
  if not close_s then
    return nil, nil
  end
  local attr_str = text:sub(pos + 5, gt - 1) -- after "<font"
  local attrs = M.parse_attrs(attr_str)
  local inner = text:sub(gt + 1, close_s - 1)
  local sty = M.font_style_from_attrs(attrs)
  return close_e + 1, {
    type = "font",
    text = inner,
    fg = sty.fg,
    bg = sty.bg,
    bold = sty.bold,
    italic = sty.italic,
    -- 源码区间（1-based inclusive）供编辑区使用时可再算
    open_end = gt,
    close_start = close_s,
    close_end = close_e,
  }
end

---@param line string
---@return {src:string, alt:string}|nil
function M.parse_img_tag(line)
  local lower = line:lower()
  if not lower:find("<img", 1, true) then
    return nil
  end
  local tag = line:match("<[Ii][Mm][Gg](.-)/?>") or line:match("<[Ii][Mm][Gg](.-)>")
  if not tag then
    return nil
  end
  local attrs = M.parse_attrs(tag)
  local src = attrs.src
  if not src or src == "" then
    return nil
  end
  -- 拒绝危险 scheme
  local scheme = src:match("^(%w+):")
  if scheme and scheme:lower() ~= "file" then
    local s = scheme:lower()
    if s == "http" or s == "https" or s == "javascript" or s == "data" then
      return { src = src, alt = attrs.alt or "", blocked = true }
    end
  end
  return { src = src, alt = attrs.alt or "" }
end

---从 lines[start_idx] 起提取 details 块
---@param lines string[]
---@param start_idx number 1-based
---@param cfg table|nil
---@return table|nil
function M.extract_details(lines, start_idx, cfg)
  local first = lines[start_idx]
  if not first then
    return nil
  end
  if not first:lower():find("<details", 1, true) then
    return nil
  end

  local attrs = M.parse_attrs(first:match("<[Dd][Ee][Tt][Aa][Ii][Ll][Ss]([^>]*)>") or "")
  -- 有 open 属性 → 展开；否则跟随 html.details_default_open（默认 false）
  local is_open
  if attrs.open then
    is_open = true
  else
    is_open = (cfg and cfg.html and cfg.html.details_default_open) or false
  end

  local depth = 0
  local end_idx = nil
  local buf = {}
  for i = start_idx, #lines do
    local line = lines[i]
    local lower = line:lower()
    -- 计数嵌套
    local pos = 1
    while true do
      local a = lower:find("<details", pos, true)
      local b = lower:find("</details>", pos, true)
      if not a and not b then
        break
      end
      if a and (not b or a < b) then
        depth = depth + 1
        pos = a + 8
      else
        depth = depth - 1
        pos = b + 10
        if depth == 0 then
          end_idx = i
          break
        end
      end
    end
    buf[#buf + 1] = line
    if end_idx then
      break
    end
  end
  if not end_idx then
    return nil
  end

  local blob = table.concat(buf, "\n")
  -- 去掉外层 details 标签
  local inner = blob:gsub("^.-<[Dd][Ee][Tt][Aa][Ii][Ll][Ss][^>]*>", "", 1)
  inner = inner:gsub("</[Dd][Ee][Tt][Aa][Ii][Ll][Ss]>%s*$", "", 1)

  local summary = "Details"
  local summary_m = inner:match("<[Ss][Uu][Mm][Mm][Aa][Rr][Yy][^>]*>(.-)</[Ss][Uu][Mm][Mm][Aa][Rr][Yy]>")
  if summary_m then
    summary = trim(summary_m:gsub("\n", " "))
    inner = inner:gsub("<[Ss][Uu][Mm][Mm][Aa][Rr][Yy][^>]*>.-</[Ss][Uu][Mm][Mm][Aa][Rr][Yy]>", "", 1)
  end

  -- inner → 行列表，并计算 body 在源中的大致行偏移
  inner = inner:gsub("^\n+", ""):gsub("\n+$", "")
  local body_lines = {}
  if inner ~= "" then
    for ln in (inner .. "\n"):gmatch("(.-)\n") do
      body_lines[#body_lines + 1] = ln
    end
  end

  -- body 起始行：start 后找 summary 结束
  local body_line_offset = start_idx
  for i = start_idx, end_idx do
    if lines[i]:lower():find("</summary>", 1, true) then
      body_line_offset = i + 1
      break
    end
  end

  return {
    end_idx = end_idx,
    open = is_open,
    summary = summary,
    body_lines = body_lines,
    body_line_offset = body_line_offset,
  }
end

return M

