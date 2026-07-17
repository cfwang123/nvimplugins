---@mod qrbuf.i18n
local M = {}
---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    title = " QR 二维码 ",
    empty = "（无文本可编码）",
    gen_fail = "qrbuf: 生成失败 — ",
    need_python = "qrbuf: 需要 Python3",
    script_missing = "qrbuf: 缺少脚本 ",
    copied = "qrbuf: 已复制原文",
    closed = "qrbuf: 已关闭",
    help = " q 关闭  y 复制原文  L 中英  +/- 缩放 ",
    lang_to_en = "qrbuf: UI → English",
    lang_to_zh = "qrbuf: UI → 中文",
    win_title = "二维码",
  },
  en = {
    title = " QR Code ",
    empty = "(no text to encode)",
    gen_fail = "qrbuf: generate failed — ",
    need_python = "qrbuf: needs Python3",
    script_missing = "qrbuf: missing script ",
    copied = "qrbuf: text copied",
    closed = "qrbuf: closed",
    help = " q close  y copy text  L lang  +/- zoom ",
    lang_to_en = "qrbuf: UI → English",
    lang_to_zh = "qrbuf: UI → 中文",
    win_title = "QR Code",
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
  if vim.fn.has("win32") == 1 then
    local ok, out = pcall(vim.fn.system, {
      "powershell",
      "-NoProfile",
      "-Command",
      "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
    })
    if ok and type(out) == "string" and vim.trim(out):lower():match("^zh") then
      return "zh"
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

local function prefs_path()
  return vim.fn.stdpath("data") .. "/qrbuf-nvim-prefs.json"
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
