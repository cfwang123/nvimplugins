---@mod colorpicker HSV 取色浮窗 → 插入 CSS 颜色
local i18n = require("colorpicker.i18n")

local M = {}

---@class ColorpickerConfig
---@field ui_lang "auto"|"zh"|"en"
---@field border string
---@field keys_open string|false
---@field default_format "hex"|"rgb"|"rgba"|"hsl"|"hsla"|"hex_alpha"
---@field default_h number
---@field default_s number
---@field default_v number
---@field default_a number 透明度 0–1，默认 1（100%）
---@field plane_w integer SV 平面列数
---@field plane_h integer SV 平面行数
---@field bar_w integer 滑条宽度
---@field step_h number 已废弃：细调按 H 条格数；保留兼容
---@field step_sv number 已废弃：细调按滑条/平面格数；保留兼容
---@field step_h_coarse number 色相粗调：格数（默认 5 格）
---@field step_sv_coarse number 饱和/明度/透明粗调：格数（默认 5 格）
---@field parse_under_cursor boolean 打开时尝试解析光标处颜色
---@field replace_under_cursor boolean 光标在颜色代码上时完成则替换（非插入）
---@field yank_also boolean Enter 插入时同时写入剪贴板
---@field preview boolean 在 buffer 中给色码铺该色底（对比字色）
---@field preview_auto boolean 自动为普通 buffer 启用预览
---@field preview_max_lines integer 超过此行数仅扫描可见区域
---@field preview_filetypes string[]|nil 限制文件类型；nil 表示不限（排除特殊 buftype）

local default_config = {
  ui_lang = "auto",
  border = "rounded",
  keys_open = "<leader>co",
  default_format = "hex",
  default_h = 210,
  default_s = 0.75,
  default_v = 0.9,
  default_a = 1, -- 100% 不透明
  plane_w = 28,
  plane_h = 10,
  bar_w = 36,
  step_h = 1, -- 兼容旧配置，细调已改为 1 格
  step_sv = 0.01, -- 兼容旧配置，细调已改为 1 格
  step_h_coarse = 5, -- 粗调 = 5 格
  step_sv_coarse = 5, -- 粗调 = 5 格
  parse_under_cursor = true,
  replace_under_cursor = true,
  yank_also = false,
  preview = true,
  preview_auto = true,
  preview_max_lines = 4000,
  preview_filetypes = nil,
}

local FORMATS = { "hex", "rgb", "rgba", "hsl", "hsla", "hex_alpha" }

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}

local NS = vim.api.nvim_create_namespace("colorpicker")
local hlpool = require("colorpicker.hlpool")
-- 浮窗色块：每帧最多约 plane*height+bars+preview 种色，512 足够；固定组名避免 E849
local cell_pool = hlpool.create("ColorpickerC", 512)

---@class ColorpickerState
---@field buf integer|nil
---@field win integer|nil
---@field h number 0–360
---@field s number 0–1
---@field v number 0–1
---@field a number 0–1 alpha
---@field focus "plane"|"h"|"s"|"v"|"a"
---@field format string
---@field origin_win integer|nil
---@field origin_buf integer|nil
---@field origin_row integer
---@field origin_col integer 0-based byte col
---@field replace_from integer|nil 替换区间起点（字节，含）
---@field replace_to integer|nil 替换区间终点（字节，开区间，同 nvim_buf_set_text）
---@field replace_token string|nil 将被替换的原始 token（调试/通知）
---@field lines string[]
---@field plane_row integer 0-based 内容行：SV 平面起始
---@field plane_col integer 平面起始列（显示列）
---@field bar_h_row integer
---@field bar_s_row integer
---@field bar_v_row integer
---@field bar_a_row integer
---@field bar_col integer 滑条标签前缀显示宽度（兼容）
---@field bar_prefix_chars integer 滑条标签前缀字符数（点击命中用）
---@field plane_chars integer SV 平面字符列数
---@field preview_row integer
---@field preview_col integer
---@field preview_w integer
---@field preview_h integer
---@field preview_chars integer 预览块起始字符下标

local state = {
  buf = nil,
  win = nil,
  h = 210,
  s = 0.75,
  v = 0.9,
  a = 1,
  focus = "plane",
  format = "hex",
  origin_win = nil,
  origin_buf = nil,
  origin_row = 1,
  origin_col = 0,
  replace_from = nil,
  replace_to = nil,
  replace_token = nil,
  lines = {},
  plane_row = 0,
  plane_col = 0,
  bar_h_row = 0,
  bar_s_row = 0,
  bar_v_row = 0,
  bar_a_row = 0,
  bar_col = 0,
  bar_prefix_chars = 4,
  plane_chars = 28,
  preview_row = 0,
  preview_col = 0,
  preview_w = 8,
  preview_h = 4,
  preview_chars = 0,
}
local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

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

local function ensure_ui_hl()
  set_hl("ColorpickerNormal", { fg = "#111111", bg = "#ffffff", ctermfg = 233, ctermbg = 15 })
  set_hl("ColorpickerTitle", { fg = "#003366", bg = "#ffffff", bold = true, ctermfg = 24, ctermbg = 15 })
  set_hl("ColorpickerHelp", { fg = "#666666", bg = "#ffffff", ctermfg = 242, ctermbg = 15 })
  set_hl("ColorpickerBorder", { fg = "#4488aa", bg = "#ffffff", ctermfg = 67, ctermbg = 15 })
  set_hl("ColorpickerLabel", { fg = "#003366", bg = "#ffffff", bold = true, ctermfg = 24, ctermbg = 15 })
  set_hl("ColorpickerFocus", { fg = "#ffffff", bg = "#1565c0", bold = true, ctermfg = 15, ctermbg = 25 })
  set_hl("ColorpickerValue", { fg = "#111111", bg = "#f5f5f5", ctermfg = 233, ctermbg = 255 })
  set_hl("ColorpickerCss", { fg = "#006600", bg = "#ffffff", bold = true, ctermfg = 22, ctermbg = 15 })
  set_hl("ColorpickerMarker", { fg = "#ffffff", bg = "#000000", bold = true, ctermfg = 15, ctermbg = 0 })
end

---@param r integer
---@param g integer
---@param b integer
---@return string
local function cell_hl(r, g, b)
  return hlpool.solid(cell_pool, r, g, b)
end

---HSV → RGB (0–255)
---@param h number 0–360
---@param s number 0–1
---@param v number 0–1
---@return integer r
---@return integer g
---@return integer b
local function hsv_to_rgb(h, s, v)
  h = h % 360
  if h < 0 then
    h = h + 360
  end
  s = clamp(s, 0, 1)
  v = clamp(v, 0, 1)
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local rp, gp, bp = 0, 0, 0
  if h < 60 then
    rp, gp, bp = c, x, 0
  elseif h < 120 then
    rp, gp, bp = x, c, 0
  elseif h < 180 then
    rp, gp, bp = 0, c, x
  elseif h < 240 then
    rp, gp, bp = 0, x, c
  elseif h < 300 then
    rp, gp, bp = x, 0, c
  else
    rp, gp, bp = c, 0, x
  end
  return clamp(math.floor((rp + m) * 255 + 0.5), 0, 255),
    clamp(math.floor((gp + m) * 255 + 0.5), 0, 255),
    clamp(math.floor((bp + m) * 255 + 0.5), 0, 255)
end

---RGB → HSV
---@param r number 0–255
---@param g number 0–255
---@param b number 0–255
---@return number h
---@return number s
---@return number v
local function rgb_to_hsv(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local d = maxc - minc
  local h = 0
  if d > 1e-9 then
    if maxc == r then
      h = 60 * (((g - b) / d) % 6)
    elseif maxc == g then
      h = 60 * (((b - r) / d) + 2)
    else
      h = 60 * (((r - g) / d) + 4)
    end
  end
  if h < 0 then
    h = h + 360
  end
  local s = (maxc <= 1e-9) and 0 or (d / maxc)
  return h, s, maxc
end

---RGB → HSL (CSS)
---@param r number 0–255
---@param g number 0–255
---@param b number 0–255
---@return number h 0–360
---@return number s 0–1
---@return number l 0–1
local function rgb_to_hsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local l = (maxc + minc) / 2
  local d = maxc - minc
  local h, s = 0, 0
  if d > 1e-9 then
    s = d / (1 - math.abs(2 * l - 1))
    if maxc == r then
      h = 60 * (((g - b) / d) % 6)
    elseif maxc == g then
      h = 60 * (((b - r) / d) + 2)
    else
      h = 60 * (((r - g) / d) + 4)
    end
  end
  if h < 0 then
    h = h + 360
  end
  return h, s, l
end

---@param n integer
---@return string
local function hex2(n)
  return string.format("%02x", clamp(n, 0, 255))
end

---@return integer r
---@return integer g
---@return integer b
local function current_rgb()
  return hsv_to_rgb(state.h, state.s, state.v)
end

---@param a number
---@return string
local function fmt_alpha(a)
  a = clamp(a, 0, 1)
  if math.abs(a - 1) < 1e-6 then
    return "1"
  end
  if math.abs(a) < 1e-6 then
    return "0"
  end
  return (string.format("%.2f", a):gsub("0+$", ""):gsub("%.$", ""))
end

---无 alpha 通道的格式在 a<1 时自动升级，避免透明度丢失
---@param fmt string
---@param a number
---@return string
local function effective_format(fmt, a)
  if a >= 1 - 1e-6 then
    return fmt
  end
  if fmt == "hex" then
    return "hex_alpha"
  end
  if fmt == "rgb" then
    return "rgba"
  end
  if fmt == "hsl" then
    return "hsla"
  end
  return fmt
end

---当前颜色的 CSS 字符串
---@param fmt? string
---@return string
function M.format_css(fmt)
  fmt = effective_format(fmt or state.format or "hex", state.a)
  local r, g, b = current_rgb()
  local a = clamp(state.a, 0, 1)
  if fmt == "hex" then
    return "#" .. hex2(r) .. hex2(g) .. hex2(b)
  elseif fmt == "hex_alpha" then
    local aa = clamp(math.floor(a * 255 + 0.5), 0, 255)
    return "#" .. hex2(r) .. hex2(g) .. hex2(b) .. hex2(aa)
  elseif fmt == "rgb" then
    return string.format("rgb(%d, %d, %d)", r, g, b)
  elseif fmt == "rgba" then
    return string.format("rgba(%d, %d, %d, %s)", r, g, b, fmt_alpha(a))
  elseif fmt == "hsl" or fmt == "hsla" then
    local hh, ss, ll = rgb_to_hsl(r, g, b)
    local hs = string.format("%d", math.floor(hh + 0.5) % 360)
    local sps = string.format("%d%%", math.floor(ss * 100 + 0.5))
    local lps = string.format("%d%%", math.floor(ll * 100 + 0.5))
    if fmt == "hsl" then
      return string.format("hsl(%s, %s, %s)", hs, sps, lps)
    end
    return string.format("hsla(%s, %s, %s, %s)", hs, sps, lps, fmt_alpha(a))
  end
  return "#" .. hex2(r) .. hex2(g) .. hex2(b)
end

---@param s string
---@param w integer
---@return string
local function pad_dw(s, w)
  s = tostring(s or "")
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then
    return s
  end
  return s .. string.rep(" ", w - dw)
end

---解析 CSS 颜色 → h,s,v,a 或 nil
---@param text string
---@return number|nil h
---@return number|nil s
---@return number|nil v
---@return number|nil a
local function parse_css_color(text)
  if not text or text == "" then
    return nil
  end
  text = vim.trim(text)

  -- #rgb #rrggbb #rrggbbaa
  local hex = text:match("^#([%x]+)$")
  if hex then
    local n = #hex
    local r, g, b, a = 0, 0, 0, 1
    if n == 3 or n == 4 then
      r = tonumber(hex:sub(1, 1) .. hex:sub(1, 1), 16)
      g = tonumber(hex:sub(2, 2) .. hex:sub(2, 2), 16)
      b = tonumber(hex:sub(3, 3) .. hex:sub(3, 3), 16)
      if n == 4 then
        a = tonumber(hex:sub(4, 4) .. hex:sub(4, 4), 16) / 255
      end
    elseif n == 6 or n == 8 then
      r = tonumber(hex:sub(1, 2), 16)
      g = tonumber(hex:sub(3, 4), 16)
      b = tonumber(hex:sub(5, 6), 16)
      if n == 8 then
        a = tonumber(hex:sub(7, 8), 16) / 255
      end
    else
      return nil
    end
    local hh, ss, vv = rgb_to_hsv(r, g, b)
    return hh, ss, vv, a
  end

  -- rgb/rgba
  local rf, gf, bf, af = text:match("^[Rr][Gg][Bb][Aa]?%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,?%s*([%d%.]*)%s*%)$")
  if rf then
    local r = tonumber(rf)
    local g = tonumber(gf)
    local b = tonumber(bf)
    local a = (af and af ~= "") and tonumber(af) or 1
    if not r or not g or not b then
      return nil
    end
    -- 0–1 小数形式
    if r <= 1 and g <= 1 and b <= 1 and (r + g + b) <= 3 and (tostring(rf):find("%.") or r < 1) then
      r, g, b = r * 255, g * 255, b * 255
    end
    local hh, ss, vv = rgb_to_hsv(r, g, b)
    return hh, ss, vv, a or 1
  end

  -- hsl/hsla
  local hf, sf, lf, haf = text:match(
    "^[Hh][Ss][Ll][Aa]?%(%s*([%d%.]+)[dD]?[eE]?[gG]?%s*,%s*([%d%.]+)%%?%s*,%s*([%d%.]+)%%?%s*,?%s*([%d%.]*)%s*%)$"
  )
  if hf then
    local h = tonumber(hf) or 0
    local s = tonumber(sf) or 0
    local l = tonumber(lf) or 0
    local a = (haf and haf ~= "") and tonumber(haf) or 1
    if s > 1 then
      s = s / 100
    end
    if l > 1 then
      l = l / 100
    end
    -- HSL → RGB → HSV
    local c = (1 - math.abs(2 * l - 1)) * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = l - c / 2
    local rp, gp, bp = 0, 0, 0
    local hh = h % 360
    if hh < 0 then
      hh = hh + 360
    end
    if hh < 60 then
      rp, gp, bp = c, x, 0
    elseif hh < 120 then
      rp, gp, bp = x, c, 0
    elseif hh < 180 then
      rp, gp, bp = 0, c, x
    elseif hh < 240 then
      rp, gp, bp = 0, x, c
    elseif hh < 300 then
      rp, gp, bp = x, 0, c
    else
      rp, gp, bp = c, 0, x
    end
    local r = (rp + m) * 255
    local g = (gp + m) * 255
    local b = (bp + m) * 255
    local H, S, V = rgb_to_hsv(r, g, b)
    return H, S, V, a or 1
  end

  return nil
end

---校验 hex 体长度是否为合法 CSS 颜色
---@param hexbody string
---@return boolean
local function valid_hex_body(hexbody)
  local n = #hexbody
  return n == 3 or n == 4 or n == 6 or n == 8
end

---在行文本中找光标处/紧邻的颜色 token
---返回 from/to 为 0-based 字节区间 [from, to)（to 与 nvim_buf_set_text 一致）
---@param line string
---@param col0 integer 0-based byte
---@return string|nil token
---@return integer|nil from
---@return integer|nil to
local function find_color_near(line, col0)
  if not line or line == "" then
    return nil
  end
  col0 = clamp(col0, 0, #line)

  -- %b() 匹配平衡括号，兼容 rgb(...) / rgba(...)
  local patterns = {
    "#[%x]+",
    "[Rr][Gg][Bb][Aa]?%b()",
    "[Hh][Ss][Ll][Aa]?%b()",
  }

  ---@type {tok:string, from:integer, to:integer, len:integer, dist:integer}[]
  local cands = {}

  for _, pat in ipairs(patterns) do
    local init = 1
    while true do
      local s, e = line:find(pat, init)
      if not s then
        break
      end
      local tok = line:sub(s, e)
      local ok = false
      if tok:sub(1, 1) == "#" then
        ok = valid_hex_body(tok:sub(2)) and parse_css_color(tok) ~= nil
      else
        ok = parse_css_color(tok) ~= nil
      end
      if ok then
        local from = s - 1 -- 0-based inclusive
        local to = e -- 0-based exclusive (= 1-based inclusive end)
        -- 光标在 token 内，或紧贴左右边界（含 to：光标在色码末尾之后一格）
        local inside = col0 >= from and col0 < to
        local on_edge = col0 == from or col0 == to or col0 == to - 1
        local dist = math.huge
        if inside then
          dist = 0
        elseif on_edge then
          dist = 0
        else
          -- 允许紧邻 1 字节（如 color:|#ff 的冒号后空格再点 hex）
          local d = math.min(math.abs(col0 - from), math.abs(col0 - to))
          if d <= 1 then
            dist = d
          end
        end
        if dist < math.huge then
          cands[#cands + 1] = {
            tok = tok,
            from = from,
            to = to,
            len = to - from,
            dist = dist,
          }
        end
      end
      init = s + 1
    end
  end

  if #cands == 0 then
    return nil
  end

  -- 优先：距离最近 → 更长 token（#rrggbb 优于误匹配短片段）
  table.sort(cands, function(a, b)
    if a.dist ~= b.dist then
      return a.dist < b.dist
    end
    return a.len > b.len
  end)

  local best = cands[1]
  return best.tok, best.from, best.to
end

---扫描一行内全部合法 CSS 颜色（供预览 / 批量）
---@param line string
---@return { tok: string, from: integer, to: integer }[]
local function find_all_colors_in_line(line)
  ---@type { tok: string, from: integer, to: integer }[]
  local out = {}
  if not line or line == "" then
    return out
  end
  local patterns = {
    "#[%x]+",
    "[Rr][Gg][Bb][Aa]?%b()",
    "[Hh][Ss][Ll][Aa]?%b()",
  }
  ---@type table<string, boolean>
  local seen = {}
  for _, pat in ipairs(patterns) do
    local init = 1
    while true do
      local s, e = line:find(pat, init)
      if not s then
        break
      end
      local tok = line:sub(s, e)
      local ok = false
      if tok:sub(1, 1) == "#" then
        ok = valid_hex_body(tok:sub(2)) and parse_css_color(tok) ~= nil
      else
        ok = parse_css_color(tok) ~= nil
      end
      if ok then
        local key = s .. ":" .. e
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = { tok = tok, from = s - 1, to = e }
        end
      end
      init = s + 1
    end
  end
  table.sort(out, function(a, b)
    return a.from < b.from
  end)
  return out
end

local function close_popup()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf = nil, nil
  state.lines = {}
end

---@param focus string
---@return string
local function focus_label(focus)
  if focus == "h" then
    return i18n.t("focus_h")
  elseif focus == "s" then
    return i18n.t("focus_s")
  elseif focus == "v" then
    return i18n.t("focus_v")
  elseif focus == "a" then
    return i18n.t("focus_a")
  end
  return i18n.t("focus_plane")
end

local function cycle_focus(dir)
  local order = { "plane", "h", "s", "v", "a" }
  local idx = 1
  for i, f in ipairs(order) do
    if f == state.focus then
      idx = i
      break
    end
  end
  idx = ((idx - 1 + dir) % #order) + 1
  state.focus = order[idx]
end

local function cycle_format(dir)
  local idx = 1
  for i, f in ipairs(FORMATS) do
    if f == state.format then
      idx = i
      break
    end
  end
  idx = ((idx - 1 + (dir or 1)) % #FORMATS) + 1
  state.format = FORMATS[idx]
end

---@param dh number
---@param ds number
---@param dv number
local function adjust(dh, ds, dv)
  state.h = (state.h + dh) % 360
  if state.h < 0 then
    state.h = state.h + 360
  end
  state.s = clamp(state.s + ds, 0, 1)
  state.v = clamp(state.v + dv, 0, 1)
end

---UI 格数：平面 / 滑条（与绘制一致）
---@return integer pw
---@return integer ph
---@return integer bw
local function grid_dims()
  local pw = math.max(8, tonumber(config.plane_w) or 28)
  local ph = math.max(4, tonumber(config.plane_h) or 10)
  local bw = math.max(12, tonumber(config.bar_w) or 36)
  return pw, ph, bw
end

---0–1 通道：按格移动（细调 1 格，粗调 N 格），对齐到格点
---@param value number 0–1
---@param cells integer 格数（列数）
---@param delta_cells integer 移动格数（可负）
---@return number
local function step_unit_by_cells(value, cells, delta_cells)
  cells = math.max(2, cells)
  local idx = math.floor(clamp(value, 0, 1) * (cells - 1) + 0.5)
  idx = clamp(idx + delta_cells, 0, cells - 1)
  return idx / (cells - 1)
end

---色相 → 滑条格下标；h=360 表示最右格（与 0° 同色但位置不同）
---@param h number
---@param cells integer
---@return integer
local function hue_to_cell(h, cells)
  cells = math.max(2, cells)
  if h >= 360 - 1e-9 then
    return cells - 1
  end
  h = h % 360
  if h < 0 then
    h = h + 360
  end
  return clamp(math.floor((h / 360) * (cells - 1) + 0.5), 0, cells - 1)
end

---色相 0–360：按 H 条格移动并贴格；在 0 与最右格之间环绕
---最右格存 h=360，避免 %360 后与最左 0 混淆
---@param h number
---@param cells integer
---@param delta_cells integer
---@return number
local function step_hue_by_cells(h, cells, delta_cells)
  cells = math.max(2, cells)
  local idx = hue_to_cell(h, cells) + delta_cells
  idx = idx % cells
  if idx < 0 then
    idx = idx + cells
  end
  if idx == 0 then
    return 0
  end
  if idx == cells - 1 then
    return 360 -- 最右格：与 0° 同色，标记位置在最右
  end
  return (idx / (cells - 1)) * 360
end

---@param coarse boolean|nil
---@return integer
local function cells_delta(coarse)
  if not coarse then
    return 1
  end
  local n = tonumber(config.step_sv_coarse) or 5
  -- 兼容旧配置 0.05 表示比例：当作 5 格
  if n > 0 and n < 1 then
    n = 5
  end
  return math.max(1, math.floor(n + 0.5))
end

---@param coarse boolean|nil
---@return integer
local function hue_cells_delta(coarse)
  if not coarse then
    return 1
  end
  local n = tonumber(config.step_h_coarse) or 5
  if n > 0 and n < 1 then
    n = 5
  end
  -- 旧配置 10 表示 10°，换算成大约 10 格量级时仍按格数用
  if n > 20 then
    n = 5
  end
  return math.max(1, math.floor(n + 0.5))
end

---h/l 等：当前焦点通道移动 delta 格
local function adjust_focus(delta, coarse)
  local pw, ph, bw = grid_dims()
  local d = cells_delta(coarse) * delta
  if state.focus == "h" then
    state.h = step_hue_by_cells(state.h, bw, cells_delta(coarse) * delta)
  elseif state.focus == "s" then
    state.s = step_unit_by_cells(state.s, bw, d)
  elseif state.focus == "v" then
    state.v = step_unit_by_cells(state.v, bw, d)
  elseif state.focus == "a" then
    state.a = step_unit_by_cells(state.a, bw, d)
  else
    -- plane：水平 = S，按平面列数
    state.s = step_unit_by_cells(state.s, pw, d)
  end
end

---j/k：平面上按行移动 V；其它焦点切换通道
local function adjust_plane_v(delta, coarse)
  if state.focus == "plane" then
    local _, ph = grid_dims()
    local d = cells_delta(coarse) * delta
    state.v = step_unit_by_cells(state.v, ph, d)
  else
    cycle_focus(delta > 0 and 1 or -1)
  end
end

---色相专用键 [] , . ：始终按 H 条 1 格（粗调 N 格）
local function hue_step_cells(dir, coarse)
  local _, _, bw = grid_dims()
  state.h = step_hue_by_cells(state.h, bw, hue_cells_delta(coarse) * dir)
end

---构建 UI 并绘制
function M._render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  ensure_ui_hl()
  -- 每帧重置色块槽位并动态 set_hl（固定组数量，防 E849）
  hlpool.reset(cell_pool)

  local pw = math.max(8, tonumber(config.plane_w) or 28)
  local ph = math.max(4, tonumber(config.plane_h) or 10)
  local bw = math.max(12, tonumber(config.bar_w) or 36)
  local prev_w = 8
  local prev_h = math.min(4, ph)

  local marks = {} ---@type {line:integer, col:integer, end_col:integer, hl:string}[]
  local lines = {}

  -- 标题 / 帮助
  local title = i18n.t("title"):gsub("^%s+", ""):gsub("%s+$", "")
  local help = i18n.t("help")
  lines[#lines + 1] = title
  lines[#lines + 1] = help
  marks[#marks + 1] = { line = 0, col = 0, end_col = #title, hl = "ColorpickerTitle" }
  marks[#marks + 1] = { line = 1, col = 0, end_col = #help, hl = "ColorpickerHelp" }
  lines[#lines + 1] = ""

  -- SV 平面 + 预览 并排
  local h_lab = math.floor(state.h + 0.5)
  if h_lab >= 360 then
    h_lab = 0
  end
  local plane_label = (state.focus == "plane" and "▸ " or "  ") .. "S→ V↓  H=" .. string.format("%d°", h_lab)
  local preview_label = i18n.t("preview")
  local gap = "   "
  local plane_start_col = 0 -- 字符列（全块字符）
  local preview_start_col = pw + vim.fn.strdisplaywidth(gap)
  -- 预览区起始字符下标（plane 每格 1 字符 + gap 字符）
  local preview_start_chars = pw + vim.fn.strchars(gap)

  lines[#lines + 1] = pad_dw(plane_label, pw) .. gap .. preview_label
  local lab_row = #lines - 1
  marks[#marks + 1] = {
    line = lab_row,
    col = 0,
    end_col = #lines[#lines],
    hl = state.focus == "plane" and "ColorpickerFocus" or "ColorpickerLabel",
  }

  state.plane_row = #lines -- 下一行开始是平面
  state.plane_col = plane_start_col
  state.plane_chars = pw
  state.preview_row = state.plane_row
  state.preview_col = preview_start_col
  state.preview_chars = preview_start_chars
  state.preview_w = prev_w
  state.preview_h = prev_h

  local cur_r, cur_g, cur_b = current_rgb()
  local sel_sx = clamp(math.floor(state.s * (pw - 1) + 0.5), 0, pw - 1)
  local sel_sy = clamp(math.floor((1 - state.v) * (ph - 1) + 0.5), 0, ph - 1)

  for y = 0, ph - 1 do
    local row_parts = {}
    local row_marks = {}
    local vv = 1 - (y / math.max(ph - 1, 1))
    for x = 0, pw - 1 do
      local ss = x / math.max(pw - 1, 1)
      local rr, gg, bb = hsv_to_rgb(state.h, ss, vv)
      local ch = "█"
      if x == sel_sx and y == sel_sy then
        -- 选中点：用对比色十字感
        local lum = 0.299 * rr + 0.587 * gg + 0.114 * bb
        ch = lum > 140 and "◆" or "◇"
        row_parts[#row_parts + 1] = ch
        local col0 = x -- 平面起始 col=0，但 ◆ 可能多字节
        -- 稍后按累积字节处理
      else
        row_parts[#row_parts + 1] = ch
      end
      row_marks[#row_marks + 1] = { r = rr, g = gg, b = bb, is_sel = (x == sel_sx and y == sel_sy) }
    end

    -- 预览列（叠透明度：棋盘底 + 当前色 * a）
    local prev_parts = {}
    local in_prev = y < prev_h
    if in_prev then
      for _ = 1, prev_w do
        prev_parts[#prev_parts + 1] = "█"
      end
    else
      for _ = 1, prev_w do
        prev_parts[#prev_parts + 1] = " "
      end
    end

    local plane_str = table.concat(row_parts)
    local line = plane_str .. gap .. table.concat(prev_parts)
    lines[#lines + 1] = line
    local lnum = #lines - 1

    -- 平面高亮（按字符逐个，块字符多为 3 字节 UTF-8）
    local byte_col = 0
    for i, mk in ipairs(row_marks) do
      local ch = row_parts[i]
      local blen = #ch
      local hl
      if mk.is_sel then
        hl = "ColorpickerMarker"
      else
        hl = cell_hl(mk.r, mk.g, mk.b)
      end
      marks[#marks + 1] = { line = lnum, col = byte_col, end_col = byte_col + blen, hl = hl }
      byte_col = byte_col + blen
    end
    -- gap 无高亮
    byte_col = byte_col + #gap
    if in_prev then
      local aa = clamp(state.a, 0, 1)
      for px = 0, prev_w - 1 do
        local stripe = ((px + y) % 2 == 0) and 220 or 160
        local pr = math.floor(cur_r * aa + stripe * (1 - aa) + 0.5)
        local pg = math.floor(cur_g * aa + stripe * (1 - aa) + 0.5)
        local pb = math.floor(cur_b * aa + stripe * (1 - aa) + 0.5)
        local phl = cell_hl(pr, pg, pb)
        local blen = #"█"
        marks[#marks + 1] = { line = lnum, col = byte_col, end_col = byte_col + blen, hl = phl }
        byte_col = byte_col + blen
      end
    end
  end

  lines[#lines + 1] = ""

  -- 滑条
  local function bar_line(label, focused, fill_fn, marker_pos, value_text)
    local prefix = (focused and "▸ " or "  ") .. label .. " "
    local bar_chars = {}
    local bar_cols = {} ---@type {r:integer,g:integer,b:integer}[]
    for i = 0, bw - 1 do
      local t = i / math.max(bw - 1, 1)
      local rr, gg, bb = fill_fn(t)
      bar_cols[#bar_cols + 1] = { r = rr, g = gg, b = bb }
      if i == marker_pos then
        bar_chars[#bar_chars + 1] = "┃"
      else
        bar_chars[#bar_chars + 1] = "█"
      end
    end
    local bar_str = table.concat(bar_chars)
    local line = prefix .. bar_str .. "  " .. value_text
    lines[#lines + 1] = line
    local lnum = #lines - 1
    local pre_bytes = #prefix
    -- 点击命中：优先用「字符下标」（每个 █ 一格），避免 wincol/字节混用偏差
    local pre_disp = vim.fn.strdisplaywidth(prefix)
    local pre_chars = vim.fn.strchars(prefix)
    marks[#marks + 1] = {
      line = lnum,
      col = 0,
      end_col = pre_bytes,
      hl = focused and "ColorpickerFocus" or "ColorpickerLabel",
    }
    local byte_col = pre_bytes
    for i, ch in ipairs(bar_chars) do
      local blen = #ch
      local c = bar_cols[i]
      local hl = (i - 1 == marker_pos) and "ColorpickerMarker" or cell_hl(c.r, c.g, c.b)
      marks[#marks + 1] = { line = lnum, col = byte_col, end_col = byte_col + blen, hl = hl }
      byte_col = byte_col + blen
    end
    local val_start = byte_col + 2
    marks[#marks + 1] = {
      line = lnum,
      col = val_start,
      end_col = #line,
      hl = "ColorpickerValue",
    }
    return lnum, pre_disp, pre_chars
  end

  local h_pos = hue_to_cell(state.h, bw)
  local s_pos = clamp(math.floor(state.s * (bw - 1) + 0.5), 0, bw - 1)
  local v_pos = clamp(math.floor(state.v * (bw - 1) + 0.5), 0, bw - 1)
  local a_pos = clamp(math.floor(state.a * (bw - 1) + 0.5), 0, bw - 1)

  -- 显示角度：360 与 0 同色，UI 显示 0° 但滑块在最右；其它正常
  local h_deg_show = math.floor(state.h + 0.5)
  if h_deg_show >= 360 then
    h_deg_show = 0
  elseif h_deg_show < 0 then
    h_deg_show = h_deg_show % 360
  end
  local h_row, h_disp, h_pchars = bar_line("H", state.focus == "h", function(t)
    return hsv_to_rgb(t * 360, 1, 1)
  end, h_pos, string.format("%3d°", h_deg_show))
  state.bar_h_row = h_row
  state.bar_col = h_disp
  state.bar_prefix_chars = h_pchars or 4

  local s_row = bar_line("S", state.focus == "s", function(t)
    return hsv_to_rgb(state.h, t, state.v)
  end, s_pos, string.format("%3d%%", math.floor(state.s * 100 + 0.5)))
  state.bar_s_row = s_row

  local v_row = bar_line("V", state.focus == "v", function(t)
    return hsv_to_rgb(state.h, state.s, t)
  end, v_pos, string.format("%3d%%", math.floor(state.v * 100 + 0.5)))
  state.bar_v_row = v_row

  -- 透明度：当前色叠在灰白棋盘底上（示意半透明）
  local cr, cg, cb = current_rgb()
  local a_row = select(1, bar_line("A", state.focus == "a", function(t)
    -- t = alpha；棋盘用 i 在 bar_line 内不可见，用 t 相位近似条纹
    local stripe = (math.floor(t * (bw - 1) + 0.01) % 2 == 0) and 220 or 170
    local rr = math.floor(cr * t + stripe * (1 - t) + 0.5)
    local gg = math.floor(cg * t + stripe * (1 - t) + 0.5)
    local bb = math.floor(cb * t + stripe * (1 - t) + 0.5)
    return rr, gg, bb
  end, a_pos, string.format("%3d%%", math.floor(state.a * 100 + 0.5))))
  state.bar_a_row = a_row
  state.plane_chars = pw

  lines[#lines + 1] = ""

  -- CSS 输出
  local css = M.format_css(state.format)
  local alt_hex = M.format_css("hex")
  local alt_rgb = M.format_css("rgb")
  local alt_hsl = M.format_css("hsl")
  local focus_s = focus_label(state.focus)
  local info1 = string.format(
    "%s: %s    %s: %s",
    i18n.t("format"),
    state.format,
    "focus",
    focus_s
  )
  local info2 = css
  local info3 = alt_hex .. "   " .. alt_rgb .. "   " .. alt_hsl
  lines[#lines + 1] = info1
  lines[#lines + 1] = info2
  lines[#lines + 1] = info3
  marks[#marks + 1] = { line = #lines - 3, col = 0, end_col = #info1, hl = "ColorpickerLabel" }
  marks[#marks + 1] = { line = #lines - 2, col = 0, end_col = #info2, hl = "ColorpickerCss" }
  marks[#marks + 1] = { line = #lines - 1, col = 0, end_col = #info3, hl = "ColorpickerHelp" }

  state.lines = lines

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for _, mk in ipairs(marks) do
    local line = lines[mk.line + 1] or ""
    local ec = math.min(mk.end_col, #line)
    local sc = math.min(mk.col, ec)
    if ec > sc then
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, mk.line, sc, {
        end_col = ec,
        hl_group = mk.hl,
      })
    end
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local w = 0
    for _, l in ipairs(lines) do
      w = math.max(w, vim.fn.strdisplaywidth(l))
    end
    w = math.min(math.max(w + 2, 48), vim.o.columns - 4)
    local h = math.min(#lines + 2, vim.o.lines - 4)
    pcall(vim.api.nvim_win_set_config, state.win, {
      relative = "editor",
      width = w,
      height = h,
      row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - w) / 2)),
      title = i18n.t("title"),
      title_pos = "center",
    })
    -- 光标放到选中点附近
    local crow = state.plane_row + sel_sy + 1
    local ccol = 0
    -- 估算字节：选中前 sel_sx 个字符
    local pline = lines[crow] or ""
    -- 平面字符多为 █/◆/◇，逐字累加
    local idx = 0
    local b = 0
    while idx < sel_sx and b < #pline do
      local ch = vim.fn.strcharpart(pline, idx, 1)
      if ch == "" then
        break
      end
      b = b + #ch
      idx = idx + 1
    end
    pcall(vim.api.nvim_win_set_cursor, state.win, { crow, b })
  end
end

---确认前再解析一次光标处颜色区间（避免打开后状态丢失 / 解析遗漏）
---@return boolean replaced 是否将走替换
local function resolve_replace_range()
  if config.replace_under_cursor == false then
    return false
  end
  local buf = state.origin_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return state.replace_from ~= nil and state.replace_to ~= nil
  end
  local row = state.origin_row
  local col = state.origin_col
  local lines = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)
  local line = lines[1] or ""
  local tok, from, to = find_color_near(line, col)
  if tok and from and to and to > from then
    state.replace_from, state.replace_to = from, to
    state.replace_token = tok
    return true
  end
  -- 保留打开时已记录的区间
  if state.replace_from and state.replace_to and state.replace_to > state.replace_from then
    return true
  end
  state.replace_from, state.replace_to, state.replace_token = nil, nil, nil
  return false
end

---@param css string
---@return boolean did_replace
local function apply_insert(css)
  local buf = state.origin_buf
  local row = state.origin_row
  local col = state.origin_col
  local from = state.replace_from
  local to = state.replace_to

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_put({ css }, "c", true, true)
    return false
  end

  -- 再次校验行上区间，防止 buffer 已被改
  if from and to and from >= 0 and to > from then
    local lines = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)
    local line = lines[1] or ""
    if to > #line then
      to = #line
    end
    if from < to then
      local ok = pcall(vim.api.nvim_buf_set_text, buf, row - 1, from, row - 1, to, { css })
      if ok then
        if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
          pcall(vim.api.nvim_set_current_win, state.origin_win)
          pcall(vim.api.nvim_win_set_cursor, state.origin_win, { row, from + #css })
        end
        return true
      end
    end
  end

  pcall(vim.api.nvim_buf_set_text, buf, row - 1, col, row - 1, col, { css })
  if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    pcall(vim.api.nvim_set_current_win, state.origin_win)
    pcall(vim.api.nvim_win_set_cursor, state.origin_win, { row, col + #css })
  end
  return false
end

-- 前向声明：on_double_click / map 在赋值前引用
local confirm_insert

confirm_insert = function()
  local will_replace = resolve_replace_range()
  local css = M.format_css(state.format)
  local origin_win = state.origin_win
  close_popup()
  local did_replace = apply_insert(css)
  if config.yank_also then
    pcall(vim.fn.setreg, "+", css)
    pcall(vim.fn.setreg, '"', css)
  end
  local prefix = (will_replace or did_replace) and i18n.t("replaced") or i18n.t("inserted")
  vim.notify(prefix .. css, vim.log.levels.INFO)
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    pcall(vim.api.nvim_set_current_win, origin_win)
  end
  -- 替换后刷新 buffer 色块预览
  vim.schedule(function()
    pcall(function()
      require("colorpicker.preview").refresh(origin_win and vim.api.nvim_win_get_buf(origin_win) or nil)
    end)
  end)
end

---确认并插入 CSS（浮窗内 Enter 调用；亦可脚本触发）
function M.confirm()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end
  confirm_insert()
  return true
end

local function yank_css()
  local css = M.format_css(state.format)
  pcall(vim.fn.setreg, "+", css)
  pcall(vim.fn.setreg, '"', css)
  vim.notify(i18n.t("yanked") .. css, vim.log.levels.INFO)
end

local function cancel()
  close_popup()
  if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    pcall(vim.api.nvim_set_current_win, state.origin_win)
  end
end

---鼠标 → 行内 0-based **字符**下标（每个 █/┃/▸ 计 1）
---优先用 column 字节下标换算，避免 wincol 在浮窗/最右缘的偏差
---@param mouse table
---@return integer char_idx
local function mouse_char_index(mouse)
  local line = state.lines[mouse.line or 0] or ""
  if line == "" then
    return 0
  end
  local nchars = vim.fn.strchars(line)
  local bcol = math.max(0, (mouse.column or 1) - 1)

  -- 字节落在某个 UTF-8 字符上 → 返回该字符下标
  local bi, ci = 0, 0
  while ci < nchars do
    local ch = vim.fn.strcharpart(line, ci, 1)
    local blen = #ch
    if blen <= 0 then
      break
    end
    if bcol < bi + blen then
      return ci
    end
    bi = bi + blen
    ci = ci + 1
  end

  -- column 指向行尾之后：用 wincol 显示列兜底（部分终端最右缘 column 会偏大）
  if type(mouse.wincol) == "number" and mouse.wincol > 0 then
    local dcol = mouse.wincol - 1
    local acc, cci = 0, 0
    while cci < nchars do
      local ch = vim.fn.strcharpart(line, cci, 1)
      local dw = vim.fn.strdisplaywidth(ch)
      if dcol < acc + dw then
        return cci
      end
      acc = acc + dw
      cci = cci + 1
    end
  end

  -- 夹到最后一个字符（含最右侧色块）
  return math.max(0, nchars - 1)
end

---将滑条格下标映射到 0–1（最左=0，最右=1）
---@param cell integer 0-based
---@param n integer 格数
---@return number
local function cell_to_t(cell, n)
  if n <= 1 then
    return 0
  end
  cell = clamp(cell, 0, n - 1)
  return cell / (n - 1)
end

---鼠标点击：平面 / 滑条 / 预览
---@return boolean hit 是否点中可调区域
local function on_click()
  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid ~= state.win then
    return false
  end
  local r = mouse.line -- buffer 行号（1-based）
  local ci = mouse_char_index(mouse)
  local pw = math.max(8, tonumber(config.plane_w) or 28)
  local ph = math.max(4, tonumber(config.plane_h) or 10)
  local bw = math.max(12, tonumber(config.bar_w) or 36)
  local pchars = state.bar_prefix_chars or 4

  -- SV plane + 右侧预览
  if r >= state.plane_row + 1 and r < state.plane_row + 1 + ph then
    local y = r - (state.plane_row + 1)
    if ci >= 0 and ci < pw then
      -- V 轴：y=0 在上 = v 最大
      state.s = cell_to_t(ci, pw)
      state.v = 1 - cell_to_t(y, ph)
      state.focus = "plane"
      M._render()
      return true
    end
    local p0 = state.preview_chars or (pw + 3)
    if ci >= p0 and ci < p0 + (state.preview_w or 8) and y < (state.preview_h or 4) then
      -- 点预览块：视为命中（双击可确认）
      return true
    end
  end

  -- bars：字符下标 = 前缀字符数 + 格下标
  local function bar_hit(row0)
    if r ~= row0 + 1 then
      return nil
    end
    local cell = ci - pchars
    if cell >= 0 and cell < bw then
      return cell_to_t(cell, bw)
    end
    -- 最右缘：column 偶发落到 value 区前一字节，若紧贴条末端仍算最后一格
    if cell == bw then
      return 1
    end
    return nil
  end

  local th = bar_hit(state.bar_h_row)
  if th then
    state.h = th * 360
    state.focus = "h"
    M._render()
    return true
  end
  local ts = bar_hit(state.bar_s_row)
  if ts then
    state.s = ts
    state.focus = "s"
    M._render()
    return true
  end
  local tv = bar_hit(state.bar_v_row)
  if tv then
    state.v = tv
    state.focus = "v"
    M._render()
    return true
  end
  local ta = bar_hit(state.bar_a_row)
  if ta then
    state.a = ta
    state.focus = "a"
    M._render()
    return true
  end
  return false
end

---双击颜色区域：更新后直接完成选色
local function on_double_click()
  local hit = on_click()
  if hit then
    confirm_insert()
  end
end

local function bind_keys(buf)
  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", o, { desc = desc }))
  end

  -- 禁止 visual / select 选中浮窗文字
  -- 注：keymap 模式短名只有 n/v/x/s/...，没有单独的 "V" / CTRL-V 模式名
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv", "gh", "gH", "g<C-h>" }) do
    vim.keymap.set("n", lhs, "<Nop>", vim.tbl_extend("force", o, { desc = "colorpicker: no visual" }))
  end
  local function leave_visual()
    pcall(vim.cmd, "normal! \27")
  end
  -- x = visual（含行/块选），s = select
  for _, mode in ipairs({ "x", "s" }) do
    vim.keymap.set(mode, "<Esc>", leave_visual, vim.tbl_extend("force", o, { desc = "colorpicker: leave visual" }))
    for _, lhs in ipairs({
      "h",
      "j",
      "l",
      "k",
      "w",
      "b",
      "e",
      "0",
      "$",
      "G",
      "gg",
      "<Left>",
      "<Right>",
      "<Up>",
      "<Down>",
    }) do
      vim.keymap.set(mode, lhs, leave_visual, o)
    end
  end
  pcall(vim.api.nvim_create_autocmd, "ModeChanged", {
    buffer = buf,
    callback = function()
      local mode = vim.fn.mode()
      if mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19" then
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == buf then
            leave_visual()
          end
        end)
      end
    end,
  })
  -- 禁止鼠标拖出选区；单击取色；双击完成
  map("<LeftDrag>", function() end, "colorpicker: no drag select")
  map("<2-LeftMouse>", on_double_click, "colorpicker: double-click confirm")
  map("<3-LeftMouse>", on_double_click, "colorpicker: triple-click confirm")

  map("q", cancel, "colorpicker: close")
  map("<Esc>", cancel, "colorpicker: close")
  map("<CR>", confirm_insert, "colorpicker: insert/replace CSS")
  map("y", yank_css, "colorpicker: yank CSS")
  map("Y", yank_css, "colorpicker: yank CSS")

  map("h", function()
    adjust_focus(-1, false)
    M._render()
  end, "colorpicker: decrease")
  map("l", function()
    adjust_focus(1, false)
    M._render()
  end, "colorpicker: increase")
  map("<Left>", function()
    adjust_focus(-1, false)
    M._render()
  end, "colorpicker: decrease")
  map("<Right>", function()
    adjust_focus(1, false)
    M._render()
  end, "colorpicker: increase")
  map("H", function()
    adjust_focus(-1, true)
    M._render()
  end, "colorpicker: coarse decrease")
  map("<S-Left>", function()
    adjust_focus(-1, true)
    M._render()
  end, "colorpicker: coarse decrease")
  map("<S-Right>", function()
    adjust_focus(1, true)
    M._render()
  end, "colorpicker: coarse increase")

  -- 色相：任意焦点下可用；按 H 条「一格」步进（非 1°）
  map(",", function()
    hue_step_cells(-1, false)
    M._render()
  end, "colorpicker: hue -1 cell")
  map(".", function()
    hue_step_cells(1, false)
    M._render()
  end, "colorpicker: hue +1 cell")
  map("[", function()
    hue_step_cells(-1, false)
    M._render()
  end, "colorpicker: hue -1 cell")
  map("]", function()
    hue_step_cells(1, false)
    M._render()
  end, "colorpicker: hue +1 cell")
  map("<", function()
    hue_step_cells(-1, true)
    M._render()
  end, "colorpicker: hue coarse")
  map(">", function()
    hue_step_cells(1, true)
    M._render()
  end, "colorpicker: hue coarse")
  map("{", function()
    hue_step_cells(-1, true)
    M._render()
  end, "colorpicker: hue coarse")
  map("}", function()
    hue_step_cells(1, true)
    M._render()
  end, "colorpicker: hue coarse")

  map("j", function()
    adjust_plane_v(-1, false)
    M._render()
  end, "colorpicker: down / next focus")
  map("k", function()
    adjust_plane_v(1, false)
    M._render()
  end, "colorpicker: up / prev focus")
  map("<Down>", function()
    adjust_plane_v(-1, false)
    M._render()
  end, "colorpicker: down")
  map("<Up>", function()
    adjust_plane_v(1, false)
    M._render()
  end, "colorpicker: up")

  -- j/k on non-plane cycles focus; also explicit Tab-like
  map("<Tab>", function()
    cycle_format(1)
    M._render()
  end, "colorpicker: next format")
  map("<S-Tab>", function()
    cycle_format(-1)
    M._render()
  end, "colorpicker: prev format")
  map("f", function()
    cycle_format(1)
    M._render()
  end, "colorpicker: next format")

  map("1", function()
    state.focus = "h"
    M._render()
  end, "colorpicker: focus H")
  map("2", function()
    state.focus = "s"
    M._render()
  end, "colorpicker: focus S")
  map("3", function()
    state.focus = "v"
    M._render()
  end, "colorpicker: focus V")
  map("4", function()
    state.focus = "plane"
    M._render()
  end, "colorpicker: focus plane")
  map("5", function()
    state.focus = "a"
    M._render()
  end, "colorpicker: focus alpha")
  -- a：聚焦透明度（浮窗内不使用 append）
  map("a", function()
    state.focus = "a"
    M._render()
  end, "colorpicker: focus alpha")
  map("<Space>", function()
    cycle_focus(1)
    M._render()
  end, "colorpicker: cycle focus")

  -- 粗调 +/-
  map("+", function()
    adjust_focus(1, true)
    M._render()
  end, "colorpicker: coarse +")
  map("-", function()
    adjust_focus(-1, true)
    M._render()
  end, "colorpicker: coarse -")
  map("=", function()
    adjust_focus(1, true)
    M._render()
  end, "colorpicker: coarse +")

  map("w", function()
    state.s = 0
    state.v = 1
    M._render()
  end, "colorpicker: white")
  map("b", function()
    state.v = 0
    M._render()
  end, "colorpicker: black")
  map("r", function()
    state.h = config.default_h or 210
    state.s = config.default_s or 0.75
    state.v = config.default_v or 0.9
    state.a = config.default_a ~= nil and config.default_a or 1
    M._render()
  end, "colorpicker: reset")

  map("L", function()
    local lang = i18n.toggle()
    vim.notify(lang == "en" and i18n.t("lang_to_en") or i18n.t("lang_to_zh"), vim.log.levels.INFO)
    M._render()
  end, "colorpicker: language")

  map("<LeftMouse>", on_click, "colorpicker: click")
end

---从 origin 缓冲解析光标颜色，并记下替换区间
local function try_parse_under_cursor()
  local buf = state.origin_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local row = state.origin_row
  local col = state.origin_col
  local lines = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)
  local line = lines[1] or ""
  local tok, from, to = find_color_near(line, col)
  if not tok or not from or not to then
    return false
  end
  local hh, ss, vv, aa = parse_css_color(tok)
  if not hh then
    return false
  end
  state.h, state.s, state.v = hh, ss, vv
  state.a = aa ~= nil and aa or 1
  state.replace_from, state.replace_to = from, to
  state.replace_token = tok
  -- 根据 token 猜格式，替换时尽量保持同类写法
  if tok:match("^#") then
    local hexbody = tok:gsub("^#", "")
    if #hexbody == 8 or #hexbody == 4 then
      state.format = "hex_alpha"
    else
      state.format = "hex"
    end
  elseif tok:lower():match("^rgba") then
    state.format = "rgba"
  elseif tok:lower():match("^rgb") then
    state.format = "rgb"
  elseif tok:lower():match("^hsla") then
    state.format = "hsla"
  elseif tok:lower():match("^hsl") then
    state.format = "hsl"
  end
  return true
end

---@param opts? { format?: string, h?: number, s?: number, v?: number, a?: number }
function M.open(opts)
  M.ensure_setup()
  opts = opts or {}

  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    close_popup()
  end

  -- 记录插入目标
  state.origin_win = vim.api.nvim_get_current_win()
  state.origin_buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(state.origin_win)
  state.origin_row = cur[1]
  state.origin_col = cur[2]
  state.replace_from, state.replace_to, state.replace_token = nil, nil, nil

  state.h = opts.h or config.default_h or 210
  state.s = opts.s or config.default_s or 0.75
  state.v = opts.v or config.default_v or 0.9
  if opts.a ~= nil then
    state.a = opts.a
  elseif config.default_a ~= nil then
    state.a = config.default_a
  else
    state.a = 1
  end
  state.a = clamp(state.a, 0, 1)
  state.focus = "plane"
  state.format = opts.format or config.default_format or "hex"
  -- 校验 format
  local ok_fmt = false
  for _, f in ipairs(FORMATS) do
    if f == state.format then
      ok_fmt = true
      break
    end
  end
  if not ok_fmt then
    state.format = "hex"
  end

  -- 光标在 #rgb/#rrggbb/rgb()/rgba() 等上：载入颜色并标记替换区间
  if config.parse_under_cursor ~= false and opts.h == nil then
    local loaded = try_parse_under_cursor()
    if loaded then
      -- 安静载入；需要提示可看状态栏 format 行
    end
  end

  ensure_ui_hl()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "colorpicker"
  pcall(function()
    vim.bo[buf].undolevels = -1
  end)
  pcall(vim.api.nvim_buf_set_name, buf, "colorpicker://picker")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 56,
    height = 24,
    row = 2,
    col = 4,
    style = "minimal",
    border = config.border or "rounded",
    title = i18n.t("title"),
    title_pos = "center",
    zindex = 60,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
    vim.wo[win].cursorcolumn = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].winhighlight =
      "Normal:ColorpickerNormal,NormalFloat:ColorpickerNormal,FloatBorder:ColorpickerBorder,FloatTitle:ColorpickerTitle"
  end)

  state.buf = buf
  state.win = win
  bind_keys(buf)
  M._render()

  vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
    buffer = buf,
    once = true,
    callback = function()
      state.win, state.buf = nil, nil
    end,
  })
end

function M.close()
  cancel()
end

function M.get_config()
  return config
end

local function apply_keys()
  for _, lhs in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", lhs)
    pcall(vim.keymap.del, "x", lhs)
  end
  keys_applied = {}
  local lhs = config.keys_open
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, function()
      M.open()
    end, { silent = true, desc = "colorpicker: open HSV picker" })
    -- 可视模式：先回 normal 再打开（便于解析光标/选区附近颜色）
    vim.keymap.set("x", lhs, function()
      local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
      vim.api.nvim_feedkeys(esc, "nx", false)
      vim.schedule(function()
        M.open()
      end)
    end, { silent = true, desc = "colorpicker: open HSV picker" })
    keys_applied[#keys_applied + 1] = lhs
  end
end

---@param user? ColorpickerConfig
function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  local lang = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang = user.ui_lang
  end
  if lang == "zh" or lang == "en" then
    i18n.setup(lang)
  else
    i18n.setup("auto")
  end
  apply_keys()
  -- buffer 内色码铺色
  pcall(function()
    require("colorpicker.preview").setup(config)
  end)
  setup_done = true
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
end

---供 preview 模块调用：按位置打开并替换
---@param opts { buf: integer, row: integer, col: integer, from?: integer, to?: integer, tok?: string }
function M.open_at(opts)
  opts = opts or {}
  if opts.buf and vim.api.nvim_buf_is_valid(opts.buf) then
    local wins = vim.fn.win_findbuf(opts.buf)
    if wins and wins[1] then
      pcall(vim.api.nvim_set_current_win, wins[1])
    end
    pcall(vim.api.nvim_set_current_buf, opts.buf)
    if opts.row and opts.col then
      pcall(vim.api.nvim_win_set_cursor, 0, { opts.row, opts.col })
    end
  end
  M.open({})
  -- open 会再 parse；若给了区间则强制覆盖
  if opts.from and opts.to and opts.tok then
    local hh, ss, vv, aa = parse_css_color(opts.tok)
    if hh then
      state.h, state.s, state.v = hh, ss, vv
      state.a = aa ~= nil and aa or 1
      state.replace_from, state.replace_to = opts.from, opts.to
      state.replace_token = opts.tok
      if opts.tok:match("^#") then
        local hexbody = opts.tok:gsub("^#", "")
        state.format = (#hexbody == 8 or #hexbody == 4) and "hex_alpha" or "hex"
      elseif opts.tok:lower():match("^rgba") then
        state.format = "rgba"
      elseif opts.tok:lower():match("^rgb") then
        state.format = "rgb"
      elseif opts.tok:lower():match("^hsla") then
        state.format = "hsla"
      elseif opts.tok:lower():match("^hsl") then
        state.format = "hsl"
      end
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        M._render()
      end
    end
  end
end

-- 测试 / 子模块导出
M._hsv_to_rgb = hsv_to_rgb
M._rgb_to_hsv = rgb_to_hsv
M._parse_css_color = parse_css_color
M.find_all_colors_in_line = find_all_colors_in_line
M.parse_css_color = parse_css_color

return M
