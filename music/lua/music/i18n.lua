---@mod music.i18n zh/en UI
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    playing = "播放中",
    paused = "已暂停",
    stopped = "已停止",
    idle = "就绪",
    prev = "上一首",
    pause = "暂停",
    play = "播放",
    next = "下一首",
    stop = "停止",
    loop_on = "循环:开",
    loop_off = "循环:关",
    restart = "重播",
    lyrics = "歌词",
    list = "列表",
    close = "关闭",
    lang = "中英",
    no_lyrics = "(无歌词)",
    volume = "音量",
    loop_notify_on = "music: 单曲循环 开",
    loop_notify_off = "music: 单曲循环 关",
    no_duration = "music: 未知时长，无法跳转",
    no_playing = "music: 没有播放中的曲目",
    not_found = "music: 文件不存在: ",
    not_audio = "music: 不是支持的音频: ",
    no_session = "music: 没有可恢复的播放记录（先打开音频文件）",
    need_file = "music: 请指定音频文件",
    outline_title = "◆ 播放列表",
    outline_hint = "  Enter 选歌 · q 关闭",
    lang_to_en = "music: UI → English",
    lang_to_zh = "music: UI → 中文",
  },
  en = {
    playing = "Playing",
    paused = "Paused",
    stopped = "Stopped",
    idle = "Ready",
    prev = "Prev",
    pause = "Pause",
    play = "Play",
    next = "Next",
    stop = "Stop",
    loop_on = "Loop:On",
    loop_off = "Loop:Off",
    restart = "Replay",
    lyrics = "Lyrics",
    list = "List",
    close = "Close",
    lang = "EN/中",
    no_lyrics = "(no lyrics)",
    volume = "Vol",
    loop_notify_on = "music: loop ON",
    loop_notify_off = "music: loop OFF",
    no_duration = "music: unknown duration, cannot seek",
    no_playing = "music: nothing playing",
    not_found = "music: file not found: ",
    not_audio = "music: not a supported audio: ",
    no_session = "music: no session to restore (open an audio file first)",
    need_file = "music: specify an audio file",
    outline_title = "◆ Playlist",
    outline_hint = "  Enter pick · q close",
    lang_to_en = "music: UI → English",
    lang_to_zh = "music: UI → 中文",
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
  return vim.fn.stdpath("data") .. "/music-nvim-prefs.json"
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
