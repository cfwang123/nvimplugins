---@mod tts.split 分段（保留原文偏移）+ 语言检测
local M = {}

local function is_cjk(cp)
  return (cp >= 0x4E00 and cp <= 0x9FFF)
    or (cp >= 0x3400 and cp <= 0x4DBF)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0x3000 and cp <= 0x303F)
    or (cp >= 0xFF00 and cp <= 0xFFEF)
end

---@param text string
---@return string
function M.detect_lang(text)
  text = text or ""
  local cjk, latin = 0, 0
  for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
    local code = vim.fn.char2nr(ch)
    if is_cjk(code) then
      cjk = cjk + 1
    elseif (code >= 65 and code <= 90) or (code >= 97 and code <= 122) then
      latin = latin + 1
    end
  end
  if cjk == 0 and latin == 0 then
    return "en"
  end
  if cjk >= latin then
    return "zh"
  end
  return "en"
end

local function is_sentence_end(ch)
  return ch == "。"
    or ch == "！"
    or ch == "？"
    or ch == "；"
    or ch == "."
    or ch == "!"
    or ch == "?"
    or ch == ";"
    or ch == "\n"
end

local function is_blank(s)
  return not s or s:match("^%s*$") ~= nil
end

local function utf_len_at(text, i)
  local b = text:byte(i)
  if not b then
    return 1
  end
  if b >= 0xF0 then
    return 4
  end
  if b >= 0xE0 then
    return 3
  end
  if b >= 0xC0 then
    return 2
  end
  return 1
end

---@class TtsSeg
---@field text string
---@field start_byte integer 0-based inclusive
---@field end_byte integer 0-based exclusive

---按句切分；text 为已规范化（\n）的原文，区间相对该 text
---@param text string
---@return TtsSeg[]
function M.segments_detailed(text)
  text = text or ""
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local n = #text
  if n == 0 or is_blank(text) then
    return {}
  end

  ---@type TtsSeg[]
  local parts = {}
  local seg_start = 0 -- 0-based
  local i = 1 -- 1-based

  while i <= n do
    local ulen = utf_len_at(text, i)
    local ch = text:sub(i, i + ulen - 1)
    local next_i = i + ulen
    if is_sentence_end(ch) then
      local end_excl = next_i - 1 -- 1-based inclusive last byte -> exclusive = next_i - 1? 
      -- bytes: i..i+ulen-1 inclusive → exclusive end 0-based = i+ulen-1
      end_excl = i + ulen - 1 -- 0-based exclusive = (i-1)+ulen = i+ulen-1
      local piece = text:sub(seg_start + 1, end_excl)
      if not is_blank(piece) then
        parts[#parts + 1] = {
          text = piece,
          start_byte = seg_start,
          end_byte = end_excl,
        }
      end
      -- 下一段从句末之后开始
      seg_start = end_excl
      i = next_i
      -- 跳过紧跟的多余换行（不把它们并进下一段朗读，但偏移仍连续）
      while i <= n and text:sub(i, i) == "\n" do
        seg_start = i -- 0-based exclusive end of newline = i
        i = i + 1
      end
    else
      i = next_i
    end
  end

  if seg_start < n then
    local piece = text:sub(seg_start + 1, n)
    if not is_blank(piece) then
      parts[#parts + 1] = {
        text = piece,
        start_byte = seg_start,
        end_byte = n,
      }
    end
  end

  if #parts == 0 then
    return { { text = text, start_byte = 0, end_byte = n } }
  end

  -- 合并过短段：并到下一段（改区间）
  local out = {}
  local k = 1
  while k <= #parts do
    local cur_s = parts[k].start_byte
    local cur_e = parts[k].end_byte
    local cur_t = parts[k].text
    while vim.fn.strchars(cur_t) < 2 and k < #parts do
      k = k + 1
      cur_e = parts[k].end_byte
      cur_t = text:sub(cur_s + 1, cur_e)
    end
    if vim.fn.strchars(cur_t) < 2 and #out > 0 then
      out[#out].end_byte = cur_e
      out[#out].text = text:sub(out[#out].start_byte + 1, cur_e)
    else
      out[#out + 1] = { text = cur_t, start_byte = cur_s, end_byte = cur_e }
    end
    k = k + 1
  end
  return out
end

---@param text string
---@return string[]
function M.segments(text)
  local t = {}
  for _, s in ipairs(M.segments_detailed(text)) do
    t[#t + 1] = s.text
  end
  return t
end

---@param lines string[]
---@param byte0 integer
---@return integer, integer
function M.byte_to_linecol(lines, byte0)
  local pos = 0
  byte0 = math.max(0, byte0 or 0)
  for i, line in ipairs(lines) do
    local len = #line
    if byte0 <= pos + len then
      return i, byte0 - pos
    end
    pos = pos + len + 1
  end
  if #lines == 0 then
    return 1, 0
  end
  return #lines, #lines[#lines]
end

---@param lines string[]
---@param line integer
---@param col integer
---@return integer
function M.linecol_to_byte(lines, line, col)
  local pos = 0
  line = math.max(1, line or 1)
  col = math.max(0, col or 0)
  for i = 1, math.min(line - 1, #lines) do
    pos = pos + #lines[i] + 1
  end
  local L = lines[line] or ""
  return pos + math.min(col, #L)
end

---根据原文内字节偏移找所属段（0-based index）。落在段间空白时取下一段。
---@param detailed TtsSeg[]
---@param byte0 integer 相对 detailed 所用 text 的 0-based 偏移
---@return integer
function M.segment_index_at(detailed, byte0)
  detailed = detailed or {}
  if #detailed == 0 then
    return 0
  end
  byte0 = math.max(0, byte0 or 0)
  for i, s in ipairs(detailed) do
    local a = s.start_byte or 0
    local b = s.end_byte or a
    -- 落在本段内，或落在本段之前的间隙 → 从本段开始
    if byte0 < b then
      return i - 1
    end
  end
  return #detailed - 1
end

---@param lines string[]
---@param detailed TtsSeg[]
---@param base_byte integer
---@return table[]
function M.ranges_for_buf(lines, detailed, base_byte)
  base_byte = base_byte or 0
  local ranges = {}
  for _, s in ipairs(detailed or {}) do
    local a = base_byte + (s.start_byte or 0)
    local b = base_byte + (s.end_byte or a)
    if b < a then
      b = a
    end
    local l1, c1 = M.byte_to_linecol(lines, a)
    local l2, c2
    if b <= a then
      l2, c2 = l1, c1
    else
      l2, c2 = M.byte_to_linecol(lines, b - 1)
      c2 = c2 + 1
    end
    ranges[#ranges + 1] = {
      line = l1,
      col = c1,
      end_line = l2,
      end_col = c2,
    }
  end
  return ranges
end

---@param buf integer
---@return string
function M.buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---@param buf integer
---@param s table
---@param e table
---@return string
---@return {line:integer, col:integer}
function M.extract_range(buf, s, e)
  if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
    s, e = e, s
  end
  local lines = vim.api.nvim_buf_get_lines(buf, s[2] - 1, e[2], false)
  if #lines == 0 then
    return "", { line = s[2], col = 0 }
  end
  local c0 = math.max(0, s[3] - 1)
  local c1 = math.max(0, e[3] - 1)
  if #lines == 1 then
    local line = lines[1]
    local ch_end = c1
    if c1 < #line then
      local ci = vim.fn.charidx(line, c1)
      if ci >= 0 then
        local nb = vim.fn.byteidx(line, ci + 1)
        if nb > 0 then
          ch_end = nb - 1
        end
      end
    end
    return line:sub(c0 + 1, ch_end + 1), { line = s[2], col = c0 }
  end
  lines[1] = lines[1]:sub(c0 + 1)
  local lastline = lines[#lines]
  local ch_end = c1
  if c1 < #lastline then
    local ci = vim.fn.charidx(lastline, c1)
    if ci >= 0 then
      local nb = vim.fn.byteidx(lastline, ci + 1)
      if nb > 0 then
        ch_end = nb - 1
      end
    end
  end
  lines[#lines] = lastline:sub(1, ch_end + 1)
  return table.concat(lines, "\n"), { line = s[2], col = c0 }
end

return M
