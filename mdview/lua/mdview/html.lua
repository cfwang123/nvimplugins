---@mod mdview.html
--- HTML 白名单：img / details / summary
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
  for name, val in tag:gmatch("([%w:_-]+)%s*=%s*([%w%./%_%-]+)") do
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
