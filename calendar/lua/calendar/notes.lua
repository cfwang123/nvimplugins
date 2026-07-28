---@mod calendar.notes 日期备注与颜色标记持久化
local M = {}

---颜色循环顺序
M.COLOR_ORDER = { "red", "orange", "yellow", "green", "blue", "purple", "pink" }

---@type table<string, { note?: string, color?: string }>
local cache = nil

local function store_path()
  return vim.fn.stdpath("data") .. "/calendar-nvim-notes.json"
end

local function ensure_loaded()
  if cache then
    return
  end
  cache = {}
  local f = store_path()
  if vim.fn.filereadable(f) ~= 1 then
    return
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" then
    for k, v in pairs(data) do
      if type(k) == "string" and type(v) == "table" then
        cache[k] = {
          note = type(v.note) == "string" and v.note or nil,
          color = type(v.color) == "string" and v.color or nil,
        }
      end
    end
  end
end

local function save()
  ensure_loaded()
  pcall(function()
    local f = store_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    -- 去掉空条目
    local out = {}
    for k, v in pairs(cache or {}) do
      if v and ((v.note and v.note ~= "") or (v.color and v.color ~= "")) then
        out[k] = {
          note = (v.note and v.note ~= "") and v.note or nil,
          color = (v.color and v.color ~= "") and v.color or nil,
        }
      end
    end
    vim.fn.writefile({ vim.json.encode(out) }, f)
  end)
end

---@param y integer
---@param m integer
---@param d integer
---@return string
function M.key(y, m, d)
  return string.format("%04d-%02d-%02d", y, m, d)
end

---@param y integer
---@param m integer
---@param d integer
---@return { note?: string, color?: string }
function M.get(y, m, d)
  ensure_loaded()
  local e = cache[M.key(y, m, d)]
  if not e then
    return {}
  end
  return { note = e.note, color = e.color }
end

---@param y integer
---@param m integer
---@param d integer
---@param note? string|nil  nil 表示不改；"" 表示清空
---@param color? string|nil nil 表示不改；"" 表示清空
function M.set(y, m, d, note, color)
  ensure_loaded()
  local k = M.key(y, m, d)
  local e = cache[k] or {}
  if note ~= nil then
    e.note = (note ~= "" and note) or nil
  end
  if color ~= nil then
    e.color = (color ~= "" and color) or nil
  end
  if (not e.note or e.note == "") and (not e.color or e.color == "") then
    cache[k] = nil
  else
    cache[k] = e
  end
  save()
end

---@param y integer
---@param m integer
---@param d integer
function M.clear(y, m, d)
  ensure_loaded()
  cache[M.key(y, m, d)] = nil
  save()
end

---循环到下一颜色；当前无颜色则取第一个
---@param current? string
---@return string
function M.next_color(current)
  local order = M.COLOR_ORDER
  if not current or current == "" then
    return order[1]
  end
  for i, c in ipairs(order) do
    if c == current then
      return order[(i % #order) + 1]
    end
  end
  return order[1]
end

function M.reload()
  cache = nil
  ensure_loaded()
end

return M
