---@mod calendar.i18n
local M = {}
---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    title = " 日历 ",
    help = " hl日 jk周 []月 {}年 t今天 n备注 c颜色 x清除 q关 L中英 ",
    weekdays = { "日", "一", "二", "三", "四", "五", "六" },
    months = {
      "1月",
      "2月",
      "3月",
      "4月",
      "5月",
      "6月",
      "7月",
      "8月",
      "9月",
      "10月",
      "11月",
      "12月",
    },
    selected = "选中",
    today = "今天",
    lunar = "农历",
    holiday = "节日",
    term = "节气",
    note = "备注",
    mark = "标记",
    no_note = "（无备注）",
    no_mark = "（无）",
    no_holiday = "—",
    note_prompt = "日期备注: ",
    note_saved = "calendar: 备注已保存",
    note_cleared = "calendar: 备注/标记已清除",
    color_set = "calendar: 标记 → ",
    lang_to_en = "calendar: UI → English",
    lang_to_zh = "calendar: UI → 中文",
    colors = {
      red = "红",
      orange = "橙",
      yellow = "黄",
      green = "绿",
      blue = "蓝",
      purple = "紫",
      pink = "粉",
    },
  },
  en = {
    title = " Calendar ",
    help = " hl day  jk week  [] mon  {} year  t today  n note  c color  x clear  q/L ",
    weekdays = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" },
    months = {
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    },
    selected = "Selected",
    today = "Today",
    lunar = "Lunar",
    holiday = "Holiday",
    term = "Term",
    note = "Note",
    mark = "Mark",
    no_note = "(no note)",
    no_mark = "(none)",
    no_holiday = "—",
    note_prompt = "Note for day: ",
    note_saved = "calendar: note saved",
    note_cleared = "calendar: note/mark cleared",
    color_set = "calendar: mark → ",
    lang_to_en = "calendar: UI → English",
    lang_to_zh = "calendar: UI → 中文",
    colors = {
      red = "Red",
      orange = "Orange",
      yellow = "Yellow",
      green = "Green",
      blue = "Blue",
      purple = "Purple",
      pink = "Pink",
    },
  },
}

function M.detect()
  local cands = { vim.v.lang, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  return "zh"
end

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.load_prefs() or M.detect()
  end
  return lang
end

function M.get()
  return lang
end

function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  M.save_prefs()
  return lang
end

function M.t(key)
  local pack = STR[lang] or STR.zh
  return pack[key] or STR.zh[key] or key
end

---@param key string
---@return string[]
function M.list(key)
  local pack = STR[lang] or STR.zh
  local v = pack[key] or STR.zh[key]
  return type(v) == "table" and v or {}
end

---@param color_id string
---@return string
function M.color_name(color_id)
  local pack = STR[lang] or STR.zh
  local colors = pack.colors or STR.zh.colors
  return colors[color_id] or color_id
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/calendar-nvim-prefs.json"
end

function M.load_prefs()
  local f = prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" and (data.ui_lang == "zh" or data.ui_lang == "en") then
    return data.ui_lang
  end
  return nil
end

function M.save_prefs()
  pcall(function()
    local f = prefs_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({ vim.json.encode({ ui_lang = lang }) }, f)
  end)
end

return M
