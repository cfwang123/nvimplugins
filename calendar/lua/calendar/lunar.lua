---@mod calendar.lunar 公历↔农历、节气、传统节日
---农历数据范围：1900-01-31 ~ 2100-12-31
local M = {}

-- ── bit 兼容（LuaJIT bit / bit32 / 纯 Lua）──────────────────
local bit = rawget(_G, "bit") or rawget(_G, "bit32")
if not bit then
  bit = {}
  function bit.band(a, b)
    local r, p = 0, 1
    a = a % 0x100000000
    b = b % 0x100000000
    for _ = 1, 32 do
      if (a % 2 == 1) and (b % 2 == 1) then
        r = r + p
      end
      a = math.floor(a / 2)
      b = math.floor(b / 2)
      p = p * 2
    end
    return r
  end
  function bit.rshift(a, n)
    return math.floor((a % 0x100000000) / (2 ^ n))
  end
end

-- 1900–2100 每年农历信息（经典 lunarInfo bit 表）
local LUNAR_INFO = {
  0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,
  0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,
  0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,
  0x06566, 0x0d4a0, 0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
  0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,
  0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,
  0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,
  0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6,
  0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,
  0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0,
  0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,
  0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
  0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,
  0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,
  0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,
  0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0,
  0x0a2e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4,
  0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0,
  0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160,
  0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,
  0x0d520,
}

local LUNAR_MONTH_ZH = { "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊" }
local LUNAR_DAY_ZH = {
  "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
  "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
  "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
}
local LUNAR_MONTH_EN = {
  "1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th", "10th", "11th", "12th",
}

local SOLAR_FEST = {
  ["01-01"] = { zh = "元旦", en = "New Year" },
  ["02-14"] = { zh = "情人节", en = "Valentine" },
  ["03-08"] = { zh = "妇女节", en = "Women's Day" },
  ["03-12"] = { zh = "植树节", en = "Arbor Day" },
  ["04-01"] = { zh = "愚人节", en = "April Fools" },
  ["05-01"] = { zh = "劳动节", en = "Labor Day" },
  ["05-04"] = { zh = "青年节", en = "Youth Day" },
  ["06-01"] = { zh = "儿童节", en = "Children's Day" },
  ["07-01"] = { zh = "建党节", en = "CPC Day" },
  ["08-01"] = { zh = "建军节", en = "Army Day" },
  ["09-10"] = { zh = "教师节", en = "Teachers' Day" },
  ["10-01"] = { zh = "国庆节", en = "National Day" },
  ["12-24"] = { zh = "平安夜", en = "Christmas Eve" },
  ["12-25"] = { zh = "圣诞节", en = "Christmas" },
}

local LUNAR_FEST = {
  ["1-1"] = { zh = "春节", en = "Spring Festival" },
  ["1-15"] = { zh = "元宵节", en = "Lantern Festival" },
  ["2-2"] = { zh = "龙抬头", en = "Longtaitou" },
  ["5-5"] = { zh = "端午节", en = "Dragon Boat" },
  ["7-7"] = { zh = "七夕", en = "Qixi" },
  ["7-15"] = { zh = "中元节", en = "Ghost Festival" },
  ["8-15"] = { zh = "中秋节", en = "Mid-Autumn" },
  ["9-9"] = { zh = "重阳节", en = "Double Ninth" },
  ["12-8"] = { zh = "腊八", en = "Laba" },
  ["12-23"] = { zh = "小年", en = "Little New Year" },
}

local TERM_NAMES_ZH = {
  "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
  "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
  "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
}
local TERM_NAMES_EN = {
  "Slight Cold", "Great Cold", "Start of Spring", "Rain Water", "Awakening", "Spring Equinox",
  "Pure Brightness", "Grain Rain", "Start of Summer", "Grain Buds", "Grain in Ear", "Summer Solstice",
  "Slight Heat", "Great Heat", "Start of Autumn", "End of Heat", "White Dew", "Autumnal Equinox",
  "Cold Dew", "Frost's Descent", "Start of Winter", "Slight Snow", "Great Snow", "Winter Solstice",
}

-- 节气 C 系数（20 世纪 / 21 世纪）
local TERM_C_20 = {
  6.11, 20.84, 4.6295, 19.4599, 6.3826, 21.4155, 5.59, 20.888,
  6.318, 21.86, 6.5, 22.2, 7.928, 23.65, 8.35, 23.95,
  8.44, 23.822, 9.098, 24.218, 8.218, 23.08, 7.9, 22.6,
}
local TERM_C_21 = {
  5.4055, 20.12, 3.87, 18.73, 5.63, 20.646, 4.81, 20.1,
  5.52, 21.04, 5.678, 21.37, 7.108, 22.83, 7.5, 23.13,
  7.646, 23.042, 8.318, 23.438, 7.438, 22.36, 7.18, 21.94,
}

-- lunarInfo 编码（与常见 JS 农历表一致）：
--   bit0–3  : 闰月月份（0=无闰）
--   bit4–15 : 12 个农历月大小（1=30 天）
--   bit16   : 闰月天数（1=30，0=29）

---@param y integer
---@return integer
local function leap_month(y)
  local info = LUNAR_INFO[y - 1899]
  if not info then
    return 0
  end
  return bit.band(info, 0xf)
end

---@param y integer
---@return integer
local function leap_days(y)
  if leap_month(y) == 0 then
    return 0
  end
  local info = LUNAR_INFO[y - 1899]
  if bit.band(info, 0x10000) ~= 0 then
    return 30
  end
  return 29
end

---@param y integer
---@param m integer 1-12
---@return integer
local function month_days(y, m)
  local info = LUNAR_INFO[y - 1899]
  if not info then
    return 30
  end
  if bit.band(info, bit.rshift(0x10000, m)) ~= 0 then
    return 30
  end
  return 29
end

---@param y integer
---@return integer
local function year_days(y)
  local sum = 348 -- 12*29
  local info = LUNAR_INFO[y - 1899]
  if not info then
    return 354
  end
  -- bit15..bit4 → 正月..腊月
  local mask = 0x8000
  while mask > 0x8 do
    if bit.band(info, mask) ~= 0 then
      sum = sum + 1
    end
    mask = bit.rshift(mask, 1)
  end
  return sum + leap_days(y)
end

---儒略日（整数日）
---@param y integer
---@param m integer
---@param d integer
---@return integer
local function julian_day(y, m, d)
  local a = math.floor((14 - m) / 12)
  local yy = y + 4800 - a
  local mm = m + 12 * a - 3
  return d
    + math.floor((153 * mm + 2) / 5)
    + 365 * yy
    + math.floor(yy / 4)
    - math.floor(yy / 100)
    + math.floor(yy / 400)
    - 32045
end

local BASE_JD = julian_day(1900, 1, 31)

---@param y integer
---@param m integer
---@param d integer
---@return integer
local function days_from_base(y, m, d)
  return julian_day(y, m, d) - BASE_JD
end

---@class LunarDate
---@field year integer
---@field month integer
---@field day integer
---@field is_leap boolean
---@field full_zh string
---@field full_en string
---@field short_zh string
---@field short_en string

---公历 → 农历（经典 offset 算法，与常见 JS 农历表一致）
---@param y integer
---@param m integer
---@param d integer
---@return LunarDate|nil
function M.solar_to_lunar(y, m, d)
  if y < 1900 or y > 2100 then
    return nil
  end
  local offset = days_from_base(y, m, d)
  if offset < 0 then
    return nil
  end

  local lunar_y = 1900
  local dy = 0
  for i = 1900, 2100 do
    dy = year_days(i)
    if offset < dy then
      lunar_y = i
      break
    end
    offset = offset - dy
    if i == 2100 then
      return nil
    end
  end

  -- 展开为「正月…闰X月…腊月」序列再扣天数，逻辑更直观
  local leap = leap_month(lunar_y)
  ---@type {month:integer, is_leap:boolean, days:integer}[]
  local months = {}
  for m = 1, 12 do
    months[#months + 1] = { month = m, is_leap = false, days = month_days(lunar_y, m) }
    if leap > 0 and leap == m then
      months[#months + 1] = { month = m, is_leap = true, days = leap_days(lunar_y) }
    end
  end

  local lunar_m, is_leap, lunar_d = 1, false, 1
  local found = false
  for _, mon in ipairs(months) do
    if offset < mon.days then
      lunar_m = mon.month
      is_leap = mon.is_leap
      lunar_d = offset + 1
      found = true
      break
    end
    offset = offset - mon.days
  end
  if not found then
    return nil
  end

  local mon_zh = (is_leap and "闰" or "") .. (LUNAR_MONTH_ZH[lunar_m] or "?") .. "月"
  local day_zh = LUNAR_DAY_ZH[lunar_d] or tostring(lunar_d)
  local mon_en = (is_leap and "Leap " or "") .. (LUNAR_MONTH_EN[lunar_m] or "?")
  local day_en = "d" .. tostring(lunar_d)
  local short_zh = (lunar_d == 1) and mon_zh or day_zh
  local short_en = (lunar_d == 1) and mon_en or day_en

  return {
    year = lunar_y,
    month = lunar_m,
    day = lunar_d,
    is_leap = is_leap,
    full_zh = mon_zh .. day_zh,
    full_en = mon_en .. " " .. day_en,
    short_zh = short_zh,
    short_en = short_en,
  }
end

---@param y integer
---@param n integer 0-23
---@return integer
local function term_day(y, n)
  local ctab = (y >= 2000) and TERM_C_21 or TERM_C_20
  local c = ctab[n + 1] or 0
  local y2 = y % 100
  local day = math.floor(y2 * 0.2422 + c) - math.floor(y2 / 4)
  return day
end

---@param y integer
---@param m integer
---@param d integer
---@return string|nil zh
---@return string|nil en
function M.solar_term(y, m, d)
  for k = 0, 1 do
    local n = (m - 1) * 2 + k
    if n >= 0 and n <= 23 and term_day(y, n) == d then
      return TERM_NAMES_ZH[n + 1], TERM_NAMES_EN[n + 1]
    end
  end
  return nil, nil
end

---@param y integer
---@param m integer
---@param d integer
---@param lang? "zh"|"en"
---@return string[]
function M.festivals(y, m, d, lang)
  lang = lang or "zh"
  local out = {}
  local sf = SOLAR_FEST[string.format("%02d-%02d", m, d)]
  if sf then
    out[#out + 1] = (lang == "en") and sf.en or sf.zh
  end

  local lunar = M.solar_to_lunar(y, m, d)
  if lunar and not lunar.is_leap then
    local lf = LUNAR_FEST[string.format("%d-%d", lunar.month, lunar.day)]
    if lf then
      out[#out + 1] = (lang == "en") and lf.en or lf.zh
    end
    if lunar.month == 12 and lunar.day == month_days(lunar.year, 12) then
      out[#out + 1] = (lang == "en") and "New Year's Eve" or "除夕"
    end
  end

  local tz, te = M.solar_term(y, m, d)
  if tz then
    out[#out + 1] = (lang == "en") and te or tz
  end
  return out
end

---@param s string
---@param max_w integer
---@return string
local function truncate_dw(s, max_w)
  if vim.fn.strdisplaywidth(s) <= max_w then
    return s
  end
  local chars = vim.fn.split(s, "\\zs")
  local acc, w = {}, 0
  for _, ch in ipairs(chars) do
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > max_w then
      break
    end
    acc[#acc + 1] = ch
    w = w + cw
  end
  return table.concat(acc)
end

---格内短标签：节日/节气优先，否则农历
---@param y integer
---@param m integer
---@param d integer
---@param lang? "zh"|"en"
---@return string label
---@return boolean is_fest
function M.cell_label(y, m, d, lang)
  lang = lang or "zh"
  local fests = M.festivals(y, m, d, lang)
  if #fests > 0 then
    return truncate_dw(fests[1], 6), true
  end
  local lunar = M.solar_to_lunar(y, m, d)
  if not lunar then
    return "", false
  end
  if lang == "en" then
    return lunar.short_en, false
  end
  return lunar.short_zh, false
end

---@param y integer
---@param m integer
---@return integer
function M.days_in_month(y, m)
  local t = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)) then
    return 29
  end
  return t[m] or 30
end

---0=周日 .. 6=周六
---@param y integer
---@param m integer
---@param d integer
---@return integer
function M.weekday(y, m, d)
  -- 儒略日 %7：JD 0 = 周一 → +1 后 0=周日
  return (julian_day(y, m, d) + 1) % 7
end

return M
