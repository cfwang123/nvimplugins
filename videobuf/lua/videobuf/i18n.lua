---@mod videobuf.i18n zh/en UI strings + system language detect
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    play = " 播放Space ",
    pause = " 暂停Space ",
    stop = " 停止x ",
    replay = " 重播r ",
    loop_on = " 循环:开L ",
    loop_off = " 循环:关L ",
    lyrics = " 字幕g ",
    fps_down = " fps-[ ",
    fps_up = " ]+ ",
    mode_solid = " 1整 ",
    mode_half = " 2半 ",
    mode_block = " 3方 ",
    mute = " 静音m ",
    unmute = " 取消静音m ",
    close = " 关闭q ",
    lang = " 中文/EN ",
    status_play = "▶播放",
    status_pause = "⏸暂停",
    status_stop = "■停止",
    frames = "帧",
    no_subtitle = " （无字幕）",
    waiting_frame = "等待画面…",
    lang_switched = "界面语言: 中文",
    scale_fill = "缩放: 铺满",
    scale_fit = "缩放: 等比",
    mode_solid_info = "模式: 整格",
    mode_half_info = "模式: 半块",
    mode_block_info = "模式: 方块",
  },
  en = {
    play = " Play Space ",
    pause = " Pause Space ",
    stop = " Stop x ",
    replay = " Replay r ",
    loop_on = " Loop:On L ",
    loop_off = " Loop:Off L ",
    lyrics = " Subs g ",
    fps_down = " fps-[ ",
    fps_up = " ]+ ",
    mode_solid = " 1Full ",
    mode_half = " 2Half ",
    mode_block = " 3Blk ",
    mute = " Mute m ",
    unmute = " Unmute m ",
    close = " Close q ",
    lang = " EN/中文 ",
    status_play = "▶Play",
    status_pause = "⏸Pause",
    status_stop = "■Stop",
    frames = "frm",
    no_subtitle = " (no subs)",
    waiting_frame = "waiting for frame…",
    lang_switched = "UI language: English",
    scale_fill = "scale: fill",
    scale_fit = "scale: fit",
    mode_solid_info = "mode: solid",
    mode_half_info = "mode: half",
    mode_block_info = "mode: block",
  },
}

---Detect system / nvim UI language → "zh" | "en"
---@return "zh"|"en"
function M.detect()
  local cands = {
    vim.v.lang,
    vim.env.LC_ALL,
    vim.env.LC_MESSAGES,
    vim.env.LANG,
    vim.o.langmenu,
  }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" and c ~= "C" and c ~= "POSIX" then
      local low = c:lower()
      if low:match("^zh")
        or low:find("chinese", 1, true)
        or low:find("china", 1, true)
        or low:find("taiwan", 1, true)
        or low:find("hong_kong", 1, true)
        or low:find("hong-kong", 1, true)
      then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  -- Windows UI culture
  if vim.fn.has("win32") == 1 then
    local ok, out = pcall(function()
      return vim.fn.system({
        "powershell",
        "-NoProfile",
        "-Command",
        "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
      })
    end)
    if ok and type(out) == "string" then
      local low = out:lower():gsub("%s+", "")
      if low:match("^zh") then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  return "en"
end

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.detect()
  end
  return lang
end

---@return "zh"|"en"
function M.get()
  return lang
end

---@param l "zh"|"en"|nil
function M.set(l)
  if l == "zh" or l == "en" then
    lang = l
  end
  return lang
end

---Toggle zh ↔ en
---@return "zh"|"en"
function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  return lang
end

---@param key string
---@return string
function M.t(key)
  local pack = STR[lang] or STR.en
  return pack[key] or (STR.en[key] or key)
end

return M
