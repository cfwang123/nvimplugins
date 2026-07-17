---@mod pdfview.i18n zh/en UI
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    meta_word = "  Word · 帮助(?) · Enter/点击 图float · 高清(gh) · 图(gi) · 中英(L)",
    meta_pdf = "  %d 页 · 帮助(?) · Enter/点击 图 · 高清(gh) · 图(gi) · 翻页(n/p) · 中英(L)",
    page_sep = "── 第 %d / %d 页 ",
    not_supported = "pdfview: 不支持的文件 (pdf/docx/doc): ",
    not_found = "pdfview: 文件不存在: ",
    extracting = "pdfview: 正在提取 %s…",
    err = "pdfview: ",
    refreshed = "pdfview: 已刷新",
    open_echo_pages = "pdfview: %s · %d 页",
    open_echo_sections = "pdfview: %s · %d 节",
    no_image = "pdfview: 光标处无图片",
    no_preview = "pdfview: 无预览 buffer",
    gfx_fail = "pdfview: 无法加载 graphics",
    page_hd_off = "pdfview: 已关闭页内高清",
    page_hd_unsupported = "pdfview: 终端不支持高清叠层（需 WezTerm/Kitty/Ghostty）",
    page_hd_none = "pdfview: 当前页没有可叠高清的图片",
    page_hd_on = "pdfview: 页内高清已开 · 滚动/失焦或再按 gh 关闭",
    float_hint = "q/Esc 关闭 · o 系统打开 · L 中英",
    float_fail = "pdfview: 打开图片 float 失败",
    img_no_path = "pdfview: 无图片路径",
    img_not_found = "pdfview: 图片不存在: ",
    help_title = " pdfview 帮助 ",
    lang_to_en = "pdfview: UI → English",
    lang_to_zh = "pdfview: UI → 中文",
    help_lines = {
      "pdfview 快捷键（PDF / Word）",
      "",
      "  q / Esc     关闭预览",
      "  r           强制重新提取并渲染",
      "  n / ]       下一页（PDF）",
      "  p / [       上一页（PDF）",
      "  Enter/点击  光标处图片 → float 大图（支持则高清）",
      "  gi          同上（图片 float）",
      "  gh          临时显示当前页高清图（滚动/失焦清除）",
      "  o           系统打开文档，或光标在图上时打开该图",
      "  L           切换中/英文界面",
      "  ?           本帮助",
      "",
      "文本：颜色 / 粗体 / 斜体（PDF span · Word run）",
      "图片：默认 chafa；Enter/点击 float + 高清叠层",
      "表格：Unicode 边框（PDF find_tables · Word tbl）",
      "",
      "依赖：",
      "  PDF  — Python3 + PyMuPDF",
      "  DOCX — 仅标准库（zip+xml）",
      "  DOC  — 需 LibreOffice soffice 转 docx",
      "  图片 — chafa 或 Pillow；高清 WezTerm/Kitty/Ghostty",
    },
  },
  en = {
    meta_word = "  Word · Help(?) · Enter/click image float · HD(gh) · Img(gi) · Lang(L)",
    meta_pdf = "  %d pages · Help(?) · Enter/click image · HD(gh) · Img(gi) · Page(n/p) · Lang(L)",
    page_sep = "── Page %d / %d ",
    not_supported = "pdfview: not a supported file (pdf/docx/doc): ",
    not_found = "pdfview: file not found: ",
    extracting = "pdfview: extracting %s…",
    err = "pdfview: ",
    refreshed = "pdfview: refreshed",
    open_echo_pages = "pdfview: %s · %d pages",
    open_echo_sections = "pdfview: %s · %d section(s)",
    no_image = "pdfview: no image under cursor",
    no_preview = "pdfview: no preview buffer",
    gfx_fail = "pdfview: graphics load failed",
    page_hd_off = "pdfview: page HD off",
    page_hd_unsupported = "pdfview: terminal has no HD graphics (WezTerm/Kitty/Ghostty)",
    page_hd_none = "pdfview: no HD images on this page",
    page_hd_on = "pdfview: page HD on · scroll/blur or gh again to clear",
    float_hint = "q/Esc close · o system open · L lang",
    float_fail = "pdfview: failed to open image float",
    img_no_path = "pdfview: no image path",
    img_not_found = "pdfview: image not found: ",
    help_title = " pdfview help ",
    lang_to_en = "pdfview: UI → English",
    lang_to_zh = "pdfview: UI → 中文",
    help_lines = {
      "pdfview keys (PDF / Word)",
      "",
      "  q / Esc     Close preview",
      "  r           Force re-extract and render",
      "  n / ]       Next page (PDF)",
      "  p / [       Previous page (PDF)",
      "  Enter/click Image under cursor → float (HD if supported)",
      "  gi          Same (image float)",
      "  gh          Temporary page HD (cleared on scroll/blur)",
      "  o           System-open document, or image under cursor",
      "  L           Toggle Chinese / English UI",
      "  ?           This help",
      "",
      "Text: color / bold / italic (PDF span · Word run)",
      "Images: chafa by default; Enter/click float + HD overlay",
      "Tables: Unicode borders (PDF find_tables · Word tbl)",
      "",
      "Deps:",
      "  PDF  — Python3 + PyMuPDF",
      "  DOCX — stdlib only (zip+xml)",
      "  DOC  — LibreOffice soffice → docx",
      "  Img  — chafa or Pillow; HD WezTerm/Kitty/Ghostty",
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
  return vim.fn.stdpath("data") .. "/pdfview-nvim-prefs.json"
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
