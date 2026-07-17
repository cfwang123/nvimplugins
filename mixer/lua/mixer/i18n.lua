---@mod mixer.i18n
local M = {}
---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    title = "混音器",
    idle = "就绪",
    loading = "加载中…",
    playing = "播放中",
    paused = "已暂停",
    stopped = "已停止",
    play = "播放",
    pause = "暂停",
    stop = "停止",
    presets = "曲目",
    presets_title = "选择预设 MIDI（Enter/点击 · q 取消）",
    volume = "音量",
    lang = "中英",
    close = "关闭",
    no_song = "mixer: 未加载曲目",
    loaded = "mixer: 已加载 ",
    need_file = "mixer: 请指定 MIDI 或预设名",
    py_missing = "mixer: 未找到 python",
    script_missing = "mixer: 缺少脚本 ",
    daemon_fail = "mixer: 无法启动播放引擎 (需 Windows + winmm.dll)",
    lang_to_en = "mixer: UI → English",
    lang_to_zh = "mixer: UI → 中文",
  },
  en = {
    title = "Mixer",
    idle = "Ready",
    loading = "Loading…",
    playing = "Playing",
    paused = "Paused",
    stopped = "Stopped",
    play = "Play",
    pause = "Pause",
    stop = "Stop",
    presets = "Songs",
    presets_title = "Pick preset MIDI (Enter/click · q cancel)",
    volume = "Vol",
    lang = "EN/中",
    close = "Close",
    no_song = "mixer: no song loaded",
    loaded = "mixer: loaded ",
    need_file = "mixer: need MIDI path or preset name",
    py_missing = "mixer: python not found",
    script_missing = "mixer: missing script ",
    daemon_fail = "mixer: cannot start player (need Windows + winmm.dll)",
    lang_to_en = "mixer: UI → English",
    lang_to_zh = "mixer: UI → 中文",
  },
}

function M.detect()
  local cands = { vim.v.lang, vim.v.ctype, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
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
  return pack[key] or STR.zh[key] or key
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/mixer-nvim-prefs.json"
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
