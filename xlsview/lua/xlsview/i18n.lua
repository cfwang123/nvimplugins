---@mod xlsview.i18n zh/en UI
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    meta = "  %d 个工作表 · 最大 %dx%d · 帮助(?) · 换表(n/p) · 跳转[1-%d] · 中英(L)",
    hint = "  跳格(↑↓←→/Tab)  格块选(Ctrl-v，方向扩展)  y复制  换表(n/p)  关闭(q)",
    scroll_hint = "  Ctrl-v 选中当前整格；方向键按格扩展；y 复制单元格文本",
    sheet_echo = "xlsview: 工作表 %d/%d · %s",
    open_echo = "xlsview: %s · %d 个工作表",
    not_xlsx = "xlsview: 不是 xlsx: ",
    not_found = "xlsview: 文件不存在: ",
    extracting = "xlsview: 正在提取…",
    refreshed = "xlsview: 已刷新",
    err = "xlsview: ",
    help_title = " xlsview 帮助 ",
    lang_to_en = "xlsview: UI → English",
    lang_to_zh = "xlsview: UI → 中文",
    help_lines = {
      "xlsview 快捷键",
      "",
      "  q / Esc     关闭预览",
      "  r           强制重新提取并渲染",
      "  n / ] / gt  下一工作表",
      "  p / [ / gT  上一工作表",
      "  1-9         跳到第 N 个工作表",
      "  点击标签    切换工作表",
      "  ↑↓←→/hjkl  跳到邻近单元格（Excel 风格）",
      "  Tab/S-Tab  下一格 / 上一格（行末换行）",
      "  0 / $      本行首格 / 末格",
      "  Ctrl-v      单元格块选（进入时选中当前整格）",
      "  块选中↑↓←→  一次扩展一行/一列单元格",
      "  y / Ctrl-c  复制选中单元格文本（忽略 │，Excel 风格）",
      "  v / V       普通字符/行选择",
      "  zh / zl     视口横向滚动（不跳格）",
      "  L           切换中/英文界面",
      "  ?           本帮助",
      "",
      "复制：按数据格导出，空单元格保留列位；两边选到 │ 会忽略",
      "显示：单元格颜色 / 粗体 / 斜体 / 表头 / 底色",
      "列宽：默认按内容，可横向滚动（fit_to_window=false）",
      "依赖：Python3 + openpyxl",
      "格式：.xlsx .xlsm .xltx .xltm",
    },
  },
  en = {
    meta = "  %d sheet(s) · max %dx%d · Help(?) · Sheet(n/p) · Jump[1-%d] · Lang(L)",
    hint = "  Cells(↑↓←→/Tab)  Cell-block(Ctrl-v)  y yank  Sheet(n/p)  Close(q)",
    scroll_hint = "  Ctrl-v selects whole cell; arrows grow by cell; y yanks cells",
    sheet_echo = "xlsview: sheet %d/%d · %s",
    open_echo = "xlsview: %s · %d sheet(s)",
    not_xlsx = "xlsview: not xlsx: ",
    not_found = "xlsview: not found: ",
    extracting = "xlsview: extracting…",
    refreshed = "xlsview: refreshed",
    err = "xlsview: ",
    help_title = " xlsview help ",
    lang_to_en = "xlsview: UI → English",
    lang_to_zh = "xlsview: UI → 中文",
    help_lines = {
      "xlsview keys",
      "",
      "  q / Esc     Close preview",
      "  r           Force re-extract and render",
      "  n / ] / gt  Next sheet",
      "  p / [ / gT  Previous sheet",
      "  1-9         Jump to sheet N",
      "  click tab   Switch sheet",
      "  ↑↓←→/hjkl  Move to adjacent cell (Excel-like)",
      "  Tab/S-Tab  Next / prev cell (wrap row)",
      "  0 / $      First / last cell in row",
      "  Ctrl-v      Cell block select (starts with full current cell)",
      "  In block ↑↓←→  Extend by one cell row/column",
      "  y / Ctrl-c  Yank selected cells (ignore │, Excel-like)",
      "  v / V       Normal char / line visual",
      "  zh / zl     Pan view horizontally (no cell jump)",
      "  L           Toggle Chinese / English UI",
      "  ?           This help",
      "",
      "Yank: export by cell grid; empty cells keep columns; border │ ignored",
      "Display: cell colors / bold / italic / header / fill",
      "Columns: natural width + h-scroll (fit_to_window=false)",
      "Deps: Python3 + openpyxl",
      "Formats: .xlsx .xlsm .xltx .xltm",
    },
  },
}

function M.detect()
  local cands = { vim.v.lang, vim.v.ctype, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" and c ~= "C" and c ~= "POSIX" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) or low:match("zh[_%-]") then
        return "zh"
      end
      if low:match("^en") or low:match("en[_%-]") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
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

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.detect()
  end
  return lang
end

function M.get()
  return lang
end

function M.set(l)
  if l == "zh" or l == "en" then
    lang = l
  end
  return lang
end

function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  return lang
end

function M.t(key)
  local pack = STR[lang] or STR.zh
  local v = pack[key]
  if v ~= nil then
    return v
  end
  return STR.zh[key] or STR.en[key] or key
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/xlsview-nvim-prefs.json"
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
