---@mod es.i18n 中英文界面
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    size_on = "大小:开",
    size_off = "大小:关",
    focus_list = "列表",
    focus_prompt = "输入",
    searching = "搜索中…",
    hint_idle = "输入  ←→光标  ↑↓选  F2大小  L中英  Ctrl-g填pwd  Esc关",
    no_results = "无结果",
    f2_size = "F2切换大小列",
    status_hits = "%d/%d  显%d-%d  %s  [%s]  Enter编辑  ^O系统 ^P复制 ^R资源管理器  F2大小  L中英",
    empty_hint = "（直接输入，支持中文 IME；Ctrl-g 填目录；F2 大小列；L 中英）",
    searching_dots = "  …",
    no_match = "（无匹配）",
    win_only = "es: 仅支持 Windows（依赖 Everything / es.exe）",
    es_not_found = "未找到 es.exe（Everything CLI）。请安装并加入 PATH，或 setup({ es_cmd = '...' })",
    es_exit = "es 退出码 %d（确认 Everything 已运行）",
    es_timeout = "es 超时（%dms）",
    es_start_fail = "无法启动 es.exe",
    system_open = "es: 系统打开 ",
    system_open_fail = "es: vim.ui.open 失败 ",
    system_open_fail2 = "es: 无法系统打开",
    system_open_win_only = "es: 系统打开仅完善支持 Windows",
    copied = "es: 已复制 ",
    explorer_win_only = "es: 资源管理器定位仅支持 Windows",
    explorer_show = "es: 资源管理器 ",
    lang_to_en = "es: 界面 → English",
    lang_to_zh = "es: 界面 → 中文",
  },
  en = {
    size_on = "Size:on",
    size_off = "Size:off",
    focus_list = "List",
    focus_prompt = "Input",
    searching = "Searching…",
    hint_idle = "Type  ←→cursor  ↑↓sel  F2 size  L lang  Ctrl-g cwd  Esc quit",
    no_results = "No results",
    f2_size = "F2 toggle size",
    status_hits = "%d/%d  show %d-%d  %s  [%s]  Enter edit  ^O open ^P copy ^R explorer  F2 size  L lang",
    empty_hint = "(Type to search, IME OK; Ctrl-g cwd; F2 size; L language)",
    searching_dots = "  …",
    no_match = "(no matches)",
    win_only = "es: Windows only (needs Everything / es.exe)",
    es_not_found = "es.exe not found. Install Everything CLI or setup({ es_cmd = '...' })",
    es_exit = "es exit code %d (is Everything running?)",
    es_timeout = "es timeout (%dms)",
    es_start_fail = "failed to start es.exe",
    system_open = "es: system open ",
    system_open_fail = "es: vim.ui.open failed ",
    system_open_fail2 = "es: cannot system-open",
    system_open_win_only = "es: system open is Windows-oriented",
    copied = "es: copied ",
    explorer_win_only = "es: reveal in Explorer is Windows only",
    explorer_show = "es: Explorer ",
    lang_to_en = "es: UI → English",
    lang_to_zh = "es: UI → 中文",
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

---@param user_lang? string "zh"|"en"|"auto"|nil
function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    local remembered = M.load_prefs()
    if remembered then
      lang = remembered
    else
      lang = M.detect()
    end
  end
  return lang
end

function M.get()
  return lang
end

function M.set(l, opts)
  opts = opts or {}
  if l == "zh" or l == "en" then
    lang = l
    if opts.persist ~= false then
      M.save_prefs()
    end
  end
  return lang
end

function M.toggle(opts)
  lang = (lang == "zh") and "en" or "zh"
  if not opts or opts.persist ~= false then
    M.save_prefs()
  end
  return lang
end

---@param key string
---@param ... any format args
function M.t(key, ...)
  local pack = STR[lang] or STR.zh
  local s = pack[key] or STR.zh[key] or key
  if select("#", ...) > 0 then
    return string.format(s, ...)
  end
  return s
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/es-nvim-prefs.json"
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
