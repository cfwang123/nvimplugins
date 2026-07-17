---@mod imgbuf.i18n zh/en UI
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    scale_fill = "拉伸",
    scale_fit = "等比",
    mode_block = "方块",
    mode_half = "半块",
    mode_braille = "点阵",
    hint_hd = " 关闭(q)  刷新(r)  切换[%s](s)  系统打开(o)  中英(L)  │ HD · %s ",
    hint_cell = " 关闭(q)  刷新(r)  方块(1)  半块(2)  点阵(3)  切换[%s](s)  系统打开(o)  中英(L)  │ %s · %s ",
    no_path = "imgbuf: 无图片路径",
    not_found = "imgbuf: 文件不存在: ",
    open_fail = "imgbuf: 打开失败: ",
    readonly = "imgbuf: 预览为只读，不会写入原图片",
    need_path = "imgbuf: 请指定图片路径",
    bad_mode = "imgbuf: mode 须为 block|half|braille",
    bad_scale = "imgbuf: scale 为 fit | fill | toggle",
    anim_arg = "imgbuf: ImgbufAnimTest 参数为 fps 数字，例如 :ImgbufAnimTest 10",
    lang_to_en = "imgbuf: UI → English",
    lang_to_zh = "imgbuf: UI → 中文",
  },
  en = {
    scale_fill = "fill",
    scale_fit = "fit",
    mode_block = "block",
    mode_half = "half",
    mode_braille = "braille",
    hint_hd = " Close(q)  Refresh(r)  Scale[%s](s)  Open(o)  Lang(L)  │ HD · %s ",
    hint_cell = " Close(q)  Refresh(r)  Block(1)  Half(2)  Braille(3)  Scale[%s](s)  Open(o)  Lang(L)  │ %s · %s ",
    no_path = "imgbuf: no image path",
    not_found = "imgbuf: file not found: ",
    open_fail = "imgbuf: open failed: ",
    readonly = "imgbuf: preview is read-only; will not write the image file",
    need_path = "imgbuf: provide an image path",
    bad_mode = "imgbuf: mode must be block|half|braille",
    bad_scale = "imgbuf: scale is fit | fill | toggle",
    anim_arg = "imgbuf: ImgbufAnimTest arg is fps number, e.g. :ImgbufAnimTest 10",
    lang_to_en = "imgbuf: UI → English",
    lang_to_zh = "imgbuf: UI → 中文",
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
  return pack[key] or STR.zh[key] or STR.en[key] or key
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/imgbuf-nvim-prefs.json"
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
