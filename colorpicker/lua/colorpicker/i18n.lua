---@mod colorpicker.i18n
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    title = " 取色器 ",
    help = " ,./[]调H  hl调SV  5调A  单击选  双击完成  Tab格式  Enter插入/替换  y复制  q关 L中英 ",
    focus_h = "色相 H",
    focus_s = "饱和 S",
    focus_v = "明度 V",
    focus_a = "透明 A",
    focus_plane = "SV 平面",
    format = "格式",
    preview = "预览",
    alpha = "透明度",
    inserted = "colorpicker: 已插入 ",
    replaced = "colorpicker: 已替换 ",
    yanked = "colorpicker: 已复制 ",
    cancelled = "colorpicker: 已取消",
    lang_to_en = "colorpicker: UI → English",
    lang_to_zh = "colorpicker: UI → 中文",
    parse_ok = "colorpicker: 已从光标颜色载入（完成时替换）",
    parse_fail = "colorpicker: 光标处未识别到颜色",
  },
  en = {
    title = " Color Picker ",
    help = " ,./[] hue  hl S/V  5 alpha  click pick  double-click done  Tab  Enter  y  q/L ",
    focus_h = "Hue H",
    focus_s = "Sat S",
    focus_v = "Val V",
    focus_a = "Alpha A",
    focus_plane = "SV plane",
    format = "Format",
    preview = "Preview",
    alpha = "Opacity",
    inserted = "colorpicker: inserted ",
    replaced = "colorpicker: replaced ",
    yanked = "colorpicker: yanked ",
    cancelled = "colorpicker: cancelled",
    lang_to_en = "colorpicker: UI → English",
    lang_to_zh = "colorpicker: UI → 中文",
    parse_ok = "colorpicker: loaded under-cursor color (will replace)",
    parse_fail = "colorpicker: no color under cursor",
  },
}

function M.detect()
  local cands = {
    vim.v.lang,
    vim.v.ctype,
    vim.env.LC_ALL,
    vim.env.LC_MESSAGES,
    vim.env.LANG,
    vim.o.langmenu,
  }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" and c ~= "C" and c ~= "POSIX" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 then
    local ok, out = pcall(vim.fn.system, {
      "powershell",
      "-NoProfile",
      "-Command",
      "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
    })
    if ok and type(out) == "string" then
      local low = vim.trim(out):lower()
      if low:match("^zh") then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  return "zh"
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/colorpicker-nvim-prefs.json"
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

return M
