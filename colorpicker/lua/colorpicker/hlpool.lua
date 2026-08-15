---@mod colorpicker.hlpool 固定数量高亮组，动态改色（避免 E849 Too many highlight groups）
local M = {}

---@class HlPool
---@field prefix string
---@field size integer
---@field next integer 本帧已分配数量
---@field cache table<string, string> hex -> group name（本帧内）
---@field inited boolean

local function set_hl(name, val)
  local o = {}
  for k, v in pairs(val) do
    o[k] = v
  end
  if vim.fn.has("nvim-0.10") == 1 then
    o.force = true
  end
  pcall(vim.api.nvim_set_hl, 0, name, o)
end

---@param r number
---@param g number
---@param b number
---@return integer
---@return integer
---@return integer
local function clamp_rgb(r, g, b)
  r = math.max(0, math.min(255, math.floor(r + 0.5)))
  g = math.max(0, math.min(255, math.floor(g + 0.5)))
  b = math.max(0, math.min(255, math.floor(b + 0.5)))
  return r, g, b
end

---颜色量化：超出池容量时减少唯一色数量
---@param r integer
---@param g integer
---@param b integer
---@param step integer
---@return integer
---@return integer
---@return integer
local function quantize(r, g, b, step)
  step = math.max(1, step or 16)
  return math.floor(r / step) * step, math.floor(g / step) * step, math.floor(b / step) * step
end

---创建固定池。组名 prefix1 .. prefix{size}，全局只注册一次。
---@param prefix string 如 "ColorpickerC"
---@param size integer 如 512
---@return HlPool
function M.create(prefix, size)
  size = math.max(16, math.floor(size or 256))
  ---@type HlPool
  local pool = {
    prefix = prefix,
    size = size,
    next = 0,
    cache = {},
    inited = false,
  }
  return pool
end

---@param pool HlPool
function M.ensure_inited(pool)
  if pool.inited then
    return
  end
  for i = 1, pool.size do
    local name = pool.prefix .. i
    set_hl(name, { fg = "#000000", bg = "#000000" })
  end
  pool.inited = true
end

---每帧/每次 refresh 开始时调用：清空本帧缓存，从槽位 1 重分配
---@param pool HlPool
function M.reset(pool)
  M.ensure_inited(pool)
  pool.next = 0
  pool.cache = {}
end

---为 RGB 取一个组名，并 set_hl 为该颜色（fg=bg）
---用于浮窗色块格子；文件内预览请用 contrast（色码需可读）
---@param pool HlPool
---@param r number
---@param g number
---@param b number
---@return string hl_group
function M.solid(pool, r, g, b)
  M.ensure_inited(pool)
  r, g, b = clamp_rgb(r, g, b)

  -- 本帧唯一色过多时量化，避免槽位不够互相覆盖导致花屏
  if pool.next >= pool.size then
    r, g, b = quantize(r, g, b, 16)
  end
  if pool.next >= pool.size then
    r, g, b = quantize(r, g, b, 32)
  end

  local hex = string.format("%02x%02x%02x", r, g, b)
  local cached = pool.cache[hex]
  if cached then
    return cached
  end

  local idx
  if pool.next < pool.size then
    pool.next = pool.next + 1
    idx = pool.next
  else
    -- 仍溢出：按颜色哈希固定到槽位（同色稳定；异色可能共享槽）
    idx = (r * 73856093 + g * 19349663 + b * 83492791) % pool.size
    if idx < 0 then
      idx = -idx
    end
    idx = idx + 1
  end

  local name = pool.prefix .. idx
  set_hl(name, { fg = "#" .. hex, bg = "#" .. hex })
  pool.cache[hex] = name
  return name
end

---文件内预览：底色=该色，字色按亮度黑/白，色码保持可读
---@param pool HlPool
---@param r number
---@param g number
---@param b number
---@return string hl_group
function M.contrast(pool, r, g, b)
  M.ensure_inited(pool)
  r, g, b = clamp_rgb(r, g, b)

  if pool.next >= pool.size then
    r, g, b = quantize(r, g, b, 16)
  end
  if pool.next >= pool.size then
    r, g, b = quantize(r, g, b, 32)
  end

  local hex = string.format("%02x%02x%02x", r, g, b)
  local key = hex .. "_c"
  local cached = pool.cache[key]
  if cached then
    return cached
  end

  local idx
  if pool.next < pool.size then
    pool.next = pool.next + 1
    idx = pool.next
  else
    idx = (r * 73856093 + g * 19349663 + b * 83492791) % pool.size
    if idx < 0 then
      idx = -idx
    end
    idx = idx + 1
  end

  local lum = 0.299 * r + 0.587 * g + 0.114 * b
  local fg = lum > 160 and "000000" or "ffffff"
  local name = pool.prefix .. idx
  set_hl(name, { fg = "#" .. fg, bg = "#" .. hex })
  pool.cache[key] = name
  return name
end

return M
