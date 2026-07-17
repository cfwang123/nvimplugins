---@mod mdview.anchor
--- 标题 slug / 页内锚点（GFM 风格近似）
local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---URL 解码 %20 等
---@param s string
---@return string
function M.url_decode(s)
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return s
end

---生成与常见 Markdown 预览兼容的 slug
---`[Quote](#Quote)` / `[Quote](#quote)` 均可匹配标题 `## Quote`
---@param text string
---@return string
function M.slugify(text)
  text = trim(text or "")
  text = text:gsub("[%*%_`]+", "")
  text = text:gsub("%[(.-)%]%b()", "%1")
  text = vim.fn.tolower(text)
  text = text:gsub("%s+", "-")
  -- 去掉 ASCII 标点，保留 - _ 与非 ASCII（中文等）
  -- 不用 vim.fn.substitute 字符类：易解析失败变成空 pattern → E33
  text = text:gsub(".", function(ch)
    local b = ch:byte()
    if not b then
      return ""
    end
    if ch == "-" or ch == "_" then
      return ch
    end
    -- 0-9 a-z（tolower 后）
    if (b >= 48 and b <= 57) or (b >= 97 and b <= 122) then
      return ch
    end
    -- 非 ASCII：保留 UTF-8 字节（中文标题）
    if b >= 128 then
      return ch
    end
    return ""
  end)
  text = text:gsub("%-+", "-")
  text = text:gsub("^%-", ""):gsub("%-$", "")
  return text
end

---@param anchor string 含或不含 #
---@return string
function M.normalize_anchor(anchor)
  anchor = trim(anchor or "")
  anchor = anchor:gsub("^#", "")
  anchor = M.url_decode(anchor)
  return anchor
end

---去掉锚点/标题前的手写序号：`6. ` / `1.1. ` / `1.1 `
---（手写扫描，避免 Lua pattern 对捕获组量词的限制）
---@param s string
---@return string
local function strip_num_prefix(s)
  s = trim(s or "")
  local i = 1
  local len = #s
  if i > len or s:byte(i) < 48 or s:byte(i) > 57 then
    return s
  end
  while i <= len and s:byte(i) >= 48 and s:byte(i) <= 57 do
    i = i + 1
  end
  if i > len or s:sub(i, i) ~= "." then
    return s
  end
  i = i + 1
  while i <= len do
    local k = i
    while k <= len and s:byte(k) >= 48 and s:byte(k) <= 57 do
      k = k + 1
    end
    if k == i then
      break
    end
    i = k
    if i <= len and s:sub(i, i) == "." then
      i = i + 1
    else
      break
    end
  end
  if i <= len and (s:byte(i) == 32 or s:byte(i) == 9) then
    while i <= len and (s:byte(i) == 32 or s:byte(i) == 9) do
      i = i + 1
    end
    return s:sub(i)
  end
  return s
end

---标题完整显示文本（自动序号 + 正文）
---@param h table
---@return string
local function heading_display_text(h)
  local num = h.auto_number or ""
  local text = h.text or ""
  if num ~= "" then
    return num .. text
  end
  return text
end

---在标题列表中查找
---支持 `[跳到表格](#6. 表格)`：带序号的锚点
---@param headings table[] { text, slug, source_start, preview_line?, auto_number? }
---@param anchor string
---@return table|nil
function M.find_heading(headings, anchor)
  local raw = M.normalize_anchor(anchor)
  if raw == "" then
    return nil
  end
  local want_slug = M.slugify(raw)
  local want_lower = vim.fn.tolower(raw)
  local raw_stripped = strip_num_prefix(raw)
  local want_stripped_lower = vim.fn.tolower(raw_stripped)
  local want_stripped_slug = M.slugify(raw_stripped)

  for _, h in ipairs(headings or {}) do
    if h.slug == want_slug then
      return h
    end
  end
  for _, h in ipairs(headings or {}) do
    if vim.fn.tolower(h.text or "") == want_lower then
      return h
    end
  end
  -- 完整显示名：`6. 表格`（auto_number + text 或正文已含序号）
  for _, h in ipairs(headings or {}) do
    local disp = heading_display_text(h)
    if vim.fn.tolower(disp) == want_lower or M.slugify(disp) == want_slug then
      return h
    end
  end
  -- 锚点带序号、标题正文不带：`#6. 表格` → 文本 `表格`
  if raw_stripped ~= raw then
    for _, h in ipairs(headings or {}) do
      if vim.fn.tolower(h.text or "") == want_stripped_lower then
        return h
      end
      if (h.slug or "") == want_stripped_slug then
        return h
      end
      -- 正文本身也带序号时 strip 后再比
      if vim.fn.tolower(strip_num_prefix(h.text or "")) == want_stripped_lower then
        return h
      end
    end
  end
  local compact = want_slug:gsub("%-", "")
  for _, h in ipairs(headings or {}) do
    if (h.slug or ""):gsub("%-", "") == compact then
      return h
    end
  end
  local compact2 = want_stripped_slug:gsub("%-", "")
  if compact2 ~= "" and compact2 ~= compact then
    for _, h in ipairs(headings or {}) do
      if (h.slug or ""):gsub("%-", "") == compact2 then
        return h
      end
    end
  end
  return nil
end

---从 AST 收集标题
---@param blocks table[]
---@param rev_map table|nil source_line -> preview_line
---@return table[]
function M.collect_headings(blocks, rev_map)
  local out = {}
  local function walk(bs)
    for _, b in ipairs(bs or {}) do
      if b.type == "heading" then
        out[#out + 1] = {
          level = b.level or 1,
          text = b.text or "",
          slug = M.slugify(b.text or ""),
          source_start = b.source_start,
          source_end = b.source_end or b.source_start,
          preview_line = rev_map and rev_map[b.source_start] or nil,
          auto_number = b.auto_number,
        }
      elseif b.children then
        walk(b.children)
      end
    end
  end
  walk(blocks)
  return out
end

return M
