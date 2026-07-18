---@mod music Buffer-based audio player (colorful clickable UI)
local M = {}

local player = require("music.player")
local midi = require("music.midi")
local lyrics = require("music.lyrics")
local playlist = require("music.playlist")

---@class MusicConfig
---@field backend "python"|"auto"
---@field volume number
---@field loop boolean
---@field auto_next boolean
---@field auto_play boolean
---@field auto_open boolean
---@field extensions string[]
---@field poll_ms number
---@field bar_width number|nil
---@field fit_height boolean 上下分屏时按内容自动高度
---@field toggle_key string 显示/隐藏播放器 UI（后台继续播）
---@field statusline_when_hidden boolean 隐藏 UI 时状态栏显示 歌名.mp3[1:22/3:33, 1/299]
---@field statusline_always boolean 播放中始终写 statusline（UI 打开也显示）
---@field python string Python 可执行文件（默认 python）
---@field keys_midi string|false 打开 MIDI 播放器 / 预设（Windows）

local default_config = {
  backend = "python",
  volume = 70,
  loop = false,
  auto_next = true,
  auto_play = true,
  auto_open = true,
  extensions = {
    "mp3",
    "flac",
    "wav",
    "ogg",
    "oga",
    "m4a",
    "aac",
    "opus",
    "wma",
    "aiff",
    "ape",
    "wv",
    "mid",
    "midi",
  },
  poll_ms = 100, -- 10 frames/s：进度条与歌词跟进
  bar_width = nil,
  fit_height = true,
  toggle_key = "<M-m>", -- Alt+M
  --- 隐藏播放器 UI（Alt+M）时 statusline 显示：歌名.mp3[1:22/3:33, 1/299]
  statusline_when_hidden = false,
  --- true：只要在播/暂停就写 statusline（不要求隐藏 UI）
  statusline_always = false,
  python = "python",
  --- 界面语言："auto" | "zh" | "en"；Y 切换（L 为单曲循环）
  ui_lang = "auto",
  --- Windows：打开 MIDI 模式播放器（预设 / .mid）
  keys_midi = "<leader>mx",
}

---内置 MIDI 预设 id（与 scripts/midi_synth.py 一致）
local MIDI_PRESET_IDS = { "twinkle", "ode", "scales", "groove", "sakura" }

local ns_preset_float = vim.api.nvim_create_namespace("music_midi_presets")
local preset_float = { win = nil, buf = nil }

local config = vim.deepcopy(default_config)
local EXT = {}

---@class MusicHit
---@field action string
---@field row integer 1-based
---@field d0 integer 1-based display col start
---@field d1 integer 1-based display col end inclusive
---@field bar_d0 integer|nil for seek: bar display start
---@field bar_w integer|nil

---@class MusicSeg
---@field text string
---@field hl string
---@field b0 integer 0-based byte start
---@field b1 integer 0-based byte end exclusive

---@class MusicBufState
---@field path string
---@field siblings string[]
---@field index integer
---@field hits MusicHit[]
---@field segs table<integer, MusicSeg[]> 0-based row -> segs
---@field dragging boolean
---@field drag_action string|nil
---@field paint_lines string[]|nil last painted lines (dirty refresh)
---@field paint_cols integer|nil last paint width
---@field paint_segs table<integer, MusicSeg[]>|nil last segs for dirty hl
---@field mode "audio"|"midi"
---@field preset string|nil 内置 MIDI 预设 id

---@type table<integer, MusicBufState>
local state_by_buf = {}
---@type integer|nil
local active_buf = nil
---@type uv.uv_timer_t|nil
local poll_timer = nil
local ns = vim.api.nvim_create_namespace("music")
local hl_ready = false

local function rebuild_ext()
  EXT = {}
  for _, e in ipairs(config.extensions) do
    EXT[e:lower()] = true
  end
end

local function is_audio(path)
  if not path or path == "" then
    return false
  end
  local ext = path:match("%.([%w]+)$")
  return ext and EXT[ext:lower()] == true
end

local function is_midi_path(path)
  if not path or path == "" then
    return false
  end
  local ext = path:match("%.([%w]+)$")
  if not ext then
    return false
  end
  ext = ext:lower()
  return ext == "mid" or ext == "midi"
end

local function is_midi_preset(name)
  if not name or name == "" then
    return false
  end
  local key = tostring(name):lower():gsub("%s+", "")
  for _, id in ipairs(MIDI_PRESET_IDS) do
    if id == key then
      return true
    end
  end
  return false
end

---@param st MusicBufState|nil
local function is_midi_mode(st)
  return st and st.mode == "midi"
end

---当前 buffer 对应的播放引擎（audio player / midi）
---@param st MusicBufState|nil
local function engine(st)
  if is_midi_mode(st) then
    return midi
  end
  return player
end

local function stop_other_engine(mode)
  if mode == "midi" then
    pcall(function()
      player.stop()
    end)
  else
    pcall(function()
      midi.stop()
    end)
  end
end

local function stop_all_engines()
  pcall(function()
    player.stop()
  end)
  pcall(function()
    midi.stop()
  end)
end

local function close_preset_float()
  if preset_float.win and vim.api.nvim_win_is_valid(preset_float.win) then
    pcall(vim.api.nvim_win_close, preset_float.win, true)
  end
  if preset_float.buf and vim.api.nvim_buf_is_valid(preset_float.buf) then
    pcall(vim.api.nvim_buf_delete, preset_float.buf, { force = true })
  end
  preset_float.win, preset_float.buf = nil, nil
end

local function midi_preset_list()
  local st = midi.get_state()
  local list = st.presets or {}
  if #list == 0 then
    return {
      { id = "twinkle", title = "小星星 / Twinkle" },
      { id = "ode", title = "欢乐颂 / Ode to Joy" },
      { id = "scales", title = "乐器巡演 / Scales" },
      { id = "groove", title = "迷你律动 / Groove" },
      { id = "sakura", title = "五声音韵 / Pentatonic" },
    }
  end
  return list
end

local function fmt_time(sec)
  if sec == nil or sec < 0 or sec ~= sec then
    return "--:--"
  end
  sec = math.floor(sec + 0.5)
  local m = math.floor(sec / 60)
  local s = sec % 60
  if m >= 60 then
    local h = math.floor(m / 60)
    m = m % 60
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

---statusline 专用：分钟不补前导 0，秒仍两位 → 0:07／4:38（不是 00:07／04:38）
local function fmt_time_stl(sec)
  if sec == nil or sec < 0 or sec ~= sec then
    return "--:--"
  end
  sec = math.floor(sec + 0.5)
  if sec >= 3600 then
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    return string.format("%d:%d:%02d", h, m, s)
  end
  local m = math.floor(sec / 60)
  local s = sec % 60
  return string.format("%d:%02d", m, s)
end

local function list_siblings(path)
  path = vim.fn.fnamemodify(path, ":p")
  local dir = vim.fn.fnamemodify(path, ":h")
  local files = vim.fn.glob(dir .. "/*", false, true)
  local want_midi = is_midi_path(path)
  local audio = {}
  for _, f in ipairs(files) do
    if vim.fn.isdirectory(f) == 0 and is_audio(f) then
      local fmidi = is_midi_path(f)
      -- MIDI 与普通音频分目录列表，互不混排
      if fmidi == want_midi then
        table.insert(audio, vim.fn.fnamemodify(f, ":p"))
      end
    end
  end
  table.sort(audio, function(a, b)
    return vim.fn.fnamemodify(a, ":t"):lower() < vim.fn.fnamemodify(b, ":t"):lower()
  end)
  local idx = 1
  local norm = path:gsub("\\", "/"):lower()
  for i, f in ipairs(audio) do
    if f:gsub("\\", "/"):lower() == norm then
      idx = i
      break
    end
  end
  if #audio == 0 then
    audio = { path }
    idx = 1
  end
  return audio, idx
end

local function win_width(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return vim.api.nvim_win_get_width(win)
    end
  end
  return vim.o.columns
end

---Sidebar / file-tree windows must never host the player.
local SIDEBAR_FILETYPES = {
  nerdtree = true,
  NerdTree = true,
  NvimTree = true,
  ["neo-tree"] = true,
  CHADTree = true,
  aerial = true,
  ultratree = true,
  Outline = true,
}

local function is_sidebar_win(win)
  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local b = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[b].filetype or ""
  if SIDEBAR_FILETYPES[ft] then
    return true
  end
  local name = vim.api.nvim_buf_get_name(b)
  if name:match("NERD_tree_") or name:match("NvimTree_") or name:match("neo%-tree") then
    return true
  end
  return false
end

local function is_usable_content_win(win)
  return win and win ~= 0 and vim.api.nvim_win_is_valid(win) and not is_sidebar_win(win)
end

---Existing music player window + buffer (search current tab first, then all tabs).
---@return integer|nil win
---@return integer|nil buf
local function find_music_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].music_player then
      return win, b
    end
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local b = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(b) and vim.b[b].music_player then
        return win, b
      end
    end
  end
  if active_buf and vim.api.nvim_buf_is_valid(active_buf) and vim.b[active_buf].music_player then
    return nil, active_buf
  end
  return nil, nil
end

---Global singleton: only one music window. Detach buffer from other tabs/windows.
---@param keep_win integer|nil window that should keep showing music
---@param buf integer music buffer
local function ensure_singleton_window(keep_win, buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if win ~= keep_win and vim.api.nvim_win_get_buf(win) == buf then
        local n = #vim.api.nvim_tabpage_list_wins(tab)
        if n <= 1 then
          -- last window on that tab: leave an empty scratch so tab stays
          local empty = vim.api.nvim_create_buf(true, true)
          pcall(function()
            vim.bo[empty].buftype = "nofile"
            vim.bo[empty].bufhidden = "wipe"
            vim.bo[empty].swapfile = false
          end)
          pcall(vim.api.nvim_win_set_buf, win, empty)
        else
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
end

---True if `win` sits in a vertical stack (horizontal split / :split), not alone in column.
---winlayout: "col" = stacked (top-bottom), "row" = side-by-side (vsplit).
local function win_is_vertically_split(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local function walk(node, parent_col_multi)
    if type(node) ~= "table" then
      return false
    end
    if node[1] == "leaf" then
      return node[2] == win and parent_col_multi
    end
    local kind = node[1] -- "row" | "col"
    local children = node[2] or {}
    local multi = #children > 1
    -- stacked siblings only when parent is "col" with multiple children
    local stacked_here = kind == "col" and multi
    for _, ch in ipairs(children) do
      if walk(ch, stacked_here) then
        return true
      end
    end
    return false
  end
  return walk(vim.fn.winlayout(), false)
end

---Estimate UI line count for initial split height (before paint).
local function estimate_ui_lines()
  -- title + status + bar + lyrics + actions
  return 5
end

---Resize only when music window shares a vertical stack (上下分屏).
---If the column is only music (vsplit 右侧整列 / 唯一窗口), do NOT change height.
local function fit_music_height(buf, nlines)
  if not config.fit_height then
    return
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  nlines = math.max(3, math.min(nlines or 3, vim.o.lines - 3))
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf and win_is_vertically_split(win) then
      pcall(vim.api.nvim_win_set_height, win, nlines)
      -- Neovim 0.12+: winfixheight is boolean
      pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
    end
  end
end

---打开 f 列表前保存的播放器高度；关闭后原样恢复，避免把底栏顶飞。
local list_saved_player_h = nil

local function save_player_height_for_list()
  list_saved_player_h = nil
  local buf = active_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_win_is_valid(win) then
      list_saved_player_h = vim.api.nvim_win_get_height(win)
      return
    end
  end
end

---列表关闭后：恢复打开前高度（若可），且仅在上下分屏时改高度。
---注意：播放器独占整列（右侧 vsplit 全高）时禁止 set_height，否则会把 nvim 底栏上推。
local function refit_player_after_list()
  local buf = active_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    list_saved_player_h = nil
    return
  end
  local nlines = list_saved_player_h
  list_saved_player_h = nil
  if not nlines or nlines < 3 then
    local st = state_by_buf[buf]
    nlines = estimate_ui_lines()
    if st and st.paint_lines and #st.paint_lines > 0 then
      nlines = #st.paint_lines
    end
  end
  nlines = math.max(3, math.min(nlines, vim.o.lines - 3))
  local music_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      music_win = music_win or win
      -- 与 fit_music_height 一致：仅上下分屏时改高度
      if config.fit_height ~= false and win_is_vertically_split(win) then
        pcall(vim.api.nvim_win_set_height, win, nlines)
        pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
      end
    end
  end
  -- 关闭列表后焦点回到播放器（q / f / Space 选歌等）
  if music_win and vim.api.nvim_win_is_valid(music_win) then
    pcall(vim.api.nvim_set_current_win, music_win)
  end
end

---True if window hosts music player / lyrics / playlist panel.
local function is_music_ui_win(win)
  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local b = vim.api.nvim_win_get_buf(win)
  return vim.b[b].music_player == true
    or vim.b[b].music_lyrics == true
    or vim.b[b].music_playlist == true
end

---Return focus to a code/editor window (not music / lyrics / sidebar).
---@param preferred integer|nil
---@return integer|nil
local function focus_editor_win(preferred)
  local function ok(win)
    return is_usable_content_win(win) and not is_music_ui_win(win)
  end
  if ok(preferred) then
    pcall(vim.api.nvim_set_current_win, preferred)
    return preferred
  end
  local alt = vim.fn.win_getid(vim.fn.winnr("#"))
  if ok(alt) then
    pcall(vim.api.nvim_set_current_win, alt)
    return alt
  end
  local best, best_area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if ok(win) then
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if area > best_area then
        best_area, best = area, win
      end
    end
  end
  if best then
    pcall(vim.api.nvim_set_current_win, best)
  end
  return best
end

---Open music buffer in a bottom horizontal split under the current editor pane.
---(底部分屏；Vim 术语为 :split / belowright，不是左右 vsplit)
---Does not steal focus: after open, returns to the previous editor window.
---@param buf integer
---@param height? integer
---@return integer win
local function open_bottom_split(buf, height)
  height = math.max(3, math.min(height or estimate_ui_lines(), vim.o.lines - 5))

  local prev = vim.api.nvim_get_current_win()
  if is_sidebar_win(prev) or is_music_ui_win(prev) then
    prev = nil
  end

  -- already visible in current tab → fit only, keep / restore editor focus
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      if win_is_vertically_split(win) then
        pcall(vim.api.nvim_win_set_height, win, height)
        pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
      end
      focus_editor_win(prev)
      return win
    end
  end

  -- anchor: current content window (not NERDTree / music)
  local anchor = vim.api.nvim_get_current_win()
  if is_sidebar_win(anchor) or is_music_ui_win(anchor) then
    anchor = find_content_win(nil)
    if anchor and is_music_ui_win(anchor) then
      anchor = focus_editor_win(nil) or anchor
    end
  end
  if anchor and vim.api.nvim_win_is_valid(anchor) then
    pcall(vim.api.nvim_set_current_win, anchor)
    if not prev and not is_music_ui_win(anchor) and not is_sidebar_win(anchor) then
      prev = anchor
    end
  end

  -- bottom horizontal split under current window
  vim.cmd("belowright " .. tostring(height) .. "split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_win_set_height, win, height)
  pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
  -- 少抢焦：分屏后回到代码窗
  focus_editor_win(prev or anchor)
  return win
end

local function session_path()
  return vim.fn.stdpath("data") .. "/music-nvim-session.json"
end

---@return table|nil
local function load_session()
  local f = session_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(f)
  if not lines or #lines == 0 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok and type(data) == "table" and (data.path or data.preset) then
    return data
  end
  return nil
end

---Persist last dir / file / position / volume (for Alt+M restore).
local function save_session()
  local st = active_buf and state_by_buf[active_buf]
  local eng = engine(st)
  eng.poll()
  local pst = eng.get_state()
  local path = pst.path
  if (not path or path == "") and st then
    path = st.path
  end
  -- 预设 MIDI：无真实文件则跳过会话（或记 preset）
  if (not path or path == "") and st and st.preset then
    local data = {
      mode = "midi",
      preset = st.preset,
      position = tonumber(pst.position) or 0,
      volume = tonumber(pst.volume) or config.volume,
    }
    pcall(function()
      vim.fn.mkdir(vim.fn.fnamemodify(session_path(), ":h"), "p")
      vim.fn.writefile({ vim.json.encode(data) }, session_path())
    end)
    return
  end
  if not path or path == "" then
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  local data = {
    path = path,
    dir = vim.fn.fnamemodify(path, ":h"),
    position = tonumber(pst.position) or 0,
    volume = tonumber(pst.volume) or config.volume,
    loop = not not pst.loop,
    mode = is_midi_path(path) and "midi" or "audio",
  }
  pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(session_path(), ":h"), "p")
    vim.fn.writefile({ vim.json.encode(data) }, session_path())
  end)
end

---Never open inside NERDTree; prefer: preferred → music win → previous (#) → current → largest.
local function find_content_win(preferred)
  if is_usable_content_win(preferred) then
    return preferred
  end
  local mwin = find_music_win()
  if is_usable_content_win(mwin) then
    return mwin
  end
  -- NERDTree `o` targets previous window
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if is_usable_content_win(prev) then
    return prev
  end
  local cur = vim.api.nvim_get_current_win()
  if is_usable_content_win(cur) then
    return cur
  end
  local best, best_area = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_usable_content_win(win) then
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if area > best_area then
        best_area, best = area, win
      end
    end
  end
  return best or cur
end

local function close_orphan_split(orphan_win, keep_win)
  if not orphan_win or orphan_win == keep_win then
    return
  end
  if not vim.api.nvim_win_is_valid(orphan_win) or is_sidebar_win(orphan_win) then
    return
  end
  local other = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= orphan_win and is_usable_content_win(win) then
      other = other + 1
    end
  end
  if other < 1 then
    return
  end
  pcall(vim.api.nvim_win_close, orphan_win, true)
end

local function ensure_hl()
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  -- Minimal: white paper + black/gray ink (no colorful chrome)
  local bg = "#ffffff"
  local fg = "#1a1a1a"
  local muted = "#6b6b6b"
  local faint = "#9a9a9a"
  local bar_bg = "#e8e8e8"
  local bar_fg = "#404040"
  vim.api.nvim_set_hl(0, "MusicNormal", { fg = fg, bg = bg })
  vim.api.nvim_set_hl(0, "MusicHeader", { fg = muted, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, "MusicTitle", { fg = fg, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, "MusicPath", { fg = faint, bg = bg })
  vim.api.nvim_set_hl(0, "MusicMeta", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicTime", { fg = fg, bg = bg })
  vim.api.nvim_set_hl(0, "MusicStatusPlay", { fg = fg, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, "MusicStatusPause", { fg = muted, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, "MusicStatusStop", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBarFill", { fg = bar_fg, bg = bar_bg })
  vim.api.nvim_set_hl(0, "MusicBarEmpty", { fg = "#c0c0c0", bg = bar_bg })
  vim.api.nvim_set_hl(0, "MusicBarThumb", { fg = fg, bg = bar_bg, bold = true })
  vim.api.nvim_set_hl(0, "MusicBarBracket", { fg = muted, bg = bg })
  -- Buttons: plain gray text, no solid color blocks
  vim.api.nvim_set_hl(0, "MusicBtn", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBtnPlay", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBtnPause", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBtnWarn", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBtnDanger", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBtnMute", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBtnLoopOn", { fg = fg, bg = bg })
  vim.api.nvim_set_hl(0, "MusicBtnLoopOff", { fg = muted, bg = bg })
  vim.api.nvim_set_hl(0, "MusicHint", { fg = faint, bg = bg })
  vim.api.nvim_set_hl(0, "MusicSep", { fg = "#d0d0d0", bg = bg })
  -- inline current lyrics (karaoke: sung prefix deep orange)
  vim.api.nvim_set_hl(0, "MusicLyricSung", { fg = "#c45c12", bg = bg, bold = true })
  vim.api.nvim_set_hl(0, "MusicLyricRest", { fg = "#8a8a8a", bg = bg })
  -- 播放器窗口内隐藏光标（与白底同色 + blend）
  vim.api.nvim_set_hl(0, "MusicHiddenCursor", { fg = bg, bg = bg, blend = 100 })
  hl_ready = true
end

---Hide caret while focus is on music player (guicursor is global → enter/leave swap).
local saved_guicursor = nil
local player_cursor_hidden = false

local function hide_player_cursor()
  if player_cursor_hidden then
    return
  end
  ensure_hl()
  saved_guicursor = vim.o.guicursor
  -- a: all modes use invisible cursor group
  vim.o.guicursor = "a:MusicHiddenCursor"
  player_cursor_hidden = true
end

local function restore_player_cursor()
  if not player_cursor_hidden then
    return
  end
  if saved_guicursor and saved_guicursor ~= "" then
    vim.o.guicursor = saved_guicursor
  else
    pcall(function()
      vim.cmd("set guicursor&")
    end)
  end
  saved_guicursor = nil
  player_cursor_hidden = false
end

---Line builder: tracks display cols (1-based) and byte ranges for highlights.
local function new_line()
  local self = {
    parts = {}, ---@type string[]
    segs = {}, ---@type MusicSeg[]
    hits = {}, ---@type {action:string,d0:integer,d1:integer,bar_d0?:integer,bar_w?:integer}[]
    bytes = 0,
    disp = 0, -- last used display col (0 = none yet; next char at disp+1)
  }

  function self:add(text, hl, action, extra)
    if not text or text == "" then
      return self
    end
    local w = vim.fn.strwidth(text)
    local b0 = self.bytes
    local b1 = b0 + #text
    local d0 = self.disp + 1
    local d1 = self.disp + w
    table.insert(self.parts, text)
    table.insert(self.segs, { text = text, hl = hl or "MusicNormal", b0 = b0, b1 = b1 })
    if action then
      local hit = { action = action, d0 = d0, d1 = d1 }
      if extra then
        for k, v in pairs(extra) do
          hit[k] = v
        end
      end
      table.insert(self.hits, hit)
    end
    self.bytes = b1
    self.disp = d1
    return self
  end

  function self:gap(n, hl)
    return self:add(string.rep(" ", n or 1), hl or "MusicNormal", nil)
  end

  ---@param label string button text
  ---@param key string|nil shortcut appended, e.g. 上一首PgUp / 播放Space
  function self:btn(label, key, hl, action)
    local text = label
    if key and key ~= "" then
      text = label .. key
    end
    return self:add(text, hl or "MusicBtn", action)
  end

  ---Non-clickable separator between actions
  function self:sep(text)
    return self:add(text or ", ", "MusicMeta", nil)
  end

  function self:text()
    return table.concat(self.parts)
  end

  return self
end

---Return fill / thumb / empty cell counts that always sum to `width`.
local function progress_segments(pos, dur, width)
  width = math.max(8, width)
  local filled = 0
  if dur and dur > 0 then
    pos = math.max(0, math.min(dur, pos or 0))
    filled = math.floor(pos / dur * width + 0.5)
    filled = math.max(0, math.min(width, filled))
  end
  if filled <= 0 then
    return 0, true, width - 1 -- empty almost all + thumb
  end
  if filled >= width then
    return width - 1, true, 0
  end
  return filled, true, width - filled - 1
end

local function status_label(status)
  local i18n = require("music.i18n")
  if status == "playing" then
    return i18n.t("playing"), "MusicStatusPlay"
  elseif status == "paused" then
    return i18n.t("paused"), "MusicStatusPause"
  elseif status == "stopped" then
    return i18n.t("stopped"), "MusicStatusStop"
  end
  return i18n.t("idle"), "MusicMeta"
end

local function norm_path(p)
  if not p or p == "" then
    return ""
  end
  return vim.fn.fnamemodify(p, ":p"):gsub("\\", "/"):lower()
end

local function track_status(st, pst)
  local status = pst.status or "idle"
  local pos = pst.position or 0
  if is_midi_mode(st) then
    -- MIDI：允许 path 尚未回写（预设）
    return status, pos, pst.duration
  end
  if pst.path and st.path and st.path ~= "" and norm_path(pst.path) ~= norm_path(st.path) then
    -- different track still loading in daemon
    status = "idle"
    pos = 0
  end
  return status, pos, pst.duration
end

---@return string[] lines
---@return table<integer, MusicSeg[]> segs_by_row 0-based
---@return MusicHit[] hits
local function build_ui(buf, st)
  ensure_hl()
  local pst = engine(st).get_state()
  local w = win_width(buf)
  local content_w = math.max(28, w - 4)
  local bar_w = config.bar_width or math.min(content_w - 4, math.max(24, w - 10))
  local midi_mode = is_midi_mode(st)

  local title
  if midi_mode then
    title = pst.title
    if not title or title == "" then
      if st.preset and st.preset ~= "" then
        title = st.preset
      elseif st.path and st.path ~= "" then
        title = vim.fn.fnamemodify(st.path, ":t")
      else
        title = require("music.i18n").t("midi_badge")
      end
    end
  else
    title = vim.fn.fnamemodify(st.path, ":t")
  end
  local status, pos, dur = track_status(st, pst)
  if status == "loading" then
    local i18n = require("music.i18n")
    -- reuse idle highlight for loading
  end
  local playing = status == "playing"
  local slabel, shl = status_label(status)
  if status == "loading" then
    slabel = require("music.i18n").t("loading")
    shl = "MusicMeta"
  end

  local lines = {}
  local segs_by_row = {}
  local all_hits = {}

  local function push(line_obj)
    local row1 = #lines + 1
    table.insert(lines, line_obj:text())
    segs_by_row[row1 - 1] = line_obj.segs
    for _, h in ipairs(line_obj.hits) do
      table.insert(all_hits, {
        action = h.action,
        row = row1,
        d0 = h.d0,
        d1 = h.d1,
        bar_d0 = h.bar_d0,
        bar_w = h.bar_w,
      })
    end
  end

  local function push_progress()
    local L = new_line()
    L:gap(1):add("|", "MusicBarBracket")
    local fill_n, has_thumb, empty_n = progress_segments(pos, dur, bar_w)
    local bar_d0 = L.disp + 1
    -- MIDI 暂不支持 seek：进度条仅展示
    local seek_action = midi_mode and nil or "seek"
    if fill_n > 0 then
      L:add(string.rep("#", fill_n), "MusicBarFill", seek_action, seek_action and { bar_d0 = bar_d0, bar_w = bar_w } or nil)
    end
    if has_thumb then
      L:add("|", "MusicBarThumb", seek_action, seek_action and { bar_d0 = bar_d0, bar_w = bar_w } or nil)
    end
    if empty_n > 0 then
      L:add(string.rep("-", empty_n), "MusicBarEmpty", seek_action, seek_action and { bar_d0 = bar_d0, bar_w = bar_w } or nil)
    end
    L:add("|", "MusicBarBracket")
    push(L)
  end

  ---Current lyric line(s) with karaoke progress (CN+EN same timestamp → 2 lines).
  local function push_current_lyrics()
    local i18n = require("music.i18n")
    if midi_mode then
      -- MIDI：不显示歌词行，省高度
      return
    end
    local texts, progress = lyrics.get_current_display(pos)
    if not texts or #texts == 0 then
      local L = new_line()
      L:gap(1):add(i18n.t("no_lyrics"), "MusicLyricRest")
      push(L)
      return
    end
    for _, text in ipairs(texts) do
      local sung, rest = lyrics.split_progress(text, progress)
      local L = new_line()
      L:gap(1)
      if sung ~= "" then
        L:add(sung, "MusicLyricSung")
      end
      if rest ~= "" then
        L:add(rest, "MusicLyricRest")
      end
      if sung == "" and rest == "" then
        L:add(" ", "MusicLyricRest")
      end
      push(L)
    end
  end

  -- 操作行：上一首PgUp, 暂停Space, ... 列表f, q关闭（无方括号，逗号分隔，可点击）
  local function push_primary_btns()
    local i18n = require("music.i18n")
    local L = new_line()
    L:gap(1)
    L:btn(i18n.t("prev"), "PgUp", "MusicBtn", "prev")
    L:sep(", ")
    if playing then
      L:btn(i18n.t("pause"), "Space", "MusicBtn", "toggle")
    else
      L:btn(i18n.t("play"), "Space", "MusicBtn", "toggle")
    end
    L:sep(", ")
    L:btn(i18n.t("next"), "PgDn", "MusicBtn", "next")
    L:sep(", ")
    L:btn(i18n.t("stop"), "x", "MusicBtn", "stop")
    L:sep(", ")
    if not midi_mode then
      if pst.loop then
        L:btn(i18n.t("loop_on"), "L", "MusicBtnLoopOn", "loop")
      else
        L:btn(i18n.t("loop_off"), "L", "MusicBtnLoopOff", "loop")
      end
      L:sep(", ")
      L:btn(i18n.t("restart"), "r", "MusicBtn", "restart")
      L:sep(", ")
      L:btn(i18n.t("lyrics"), "g", "MusicBtn", "lyrics")
      L:sep(", ")
      L:btn(i18n.t("list"), "f", "MusicBtn", "playlist")
    else
      L:btn(i18n.t("restart"), "r", "MusicBtn", "restart")
      L:sep(", ")
      -- MIDI：同目录 mid 列表 + 内置预设
      if st.path and st.path ~= "" and #st.siblings > 0 then
        L:btn(i18n.t("list"), "f", "MusicBtn", "playlist")
        L:sep(", ")
      end
      L:btn(i18n.t("presets"), "m", "MusicBtn", "presets")
    end
    L:sep(", ")
    L:btn(i18n.t("lang"), "Y", "MusicBtn", "lang")
    L:sep(", ")
    L:btn(i18n.t("close"), "q", "MusicBtn", "close")
    push(L)
  end

  -- 唯一布局：标题 + 状态时间 + 进度条 + 歌词 + 操作行
  do
    local L = new_line()
    local badge = midi_mode and require("music.i18n").t("midi_badge") or "MUSIC"
    L:gap(1):add(badge, "MusicHeader"):gap(2):add(title, "MusicTitle")
    push(L)
  end
  do
    local L = new_line()
    L:gap(1)
      :add(slabel, shl)
      :gap(2)
      :add(fmt_time(pos), "MusicTime")
      :add("/", "MusicMeta")
      :add(fmt_time(dur), "MusicTime")
      :gap(2)
      :add(string.format("%s%d%%", require("music.i18n").t("volume"), pst.volume or config.volume), "MusicMeta")
    if not midi_mode or (st.siblings and #st.siblings > 0 and st.path and st.path ~= "") then
      L:gap(2):add(string.format("%d/%d", st.index or 1, math.max(1, #(st.siblings or {}))), "MusicMeta")
    end
    push(L)
  end
  push_progress()
  push_current_lyrics()
  push_primary_btns()

  st.hits = all_hits
  st.segs = segs_by_row
  return lines, segs_by_row, all_hits
end

---Pad line to display width with spaces (for full-line bg via highlight, no winhl).
local function pad_display(line, cols)
  cols = math.max(1, cols or 1)
  local w = vim.fn.strwidth(line)
  if w < cols then
    return line .. string.rep(" ", cols - w)
  end
  return line
end

local function segs_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
    return false
  end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if not x or not y or x.hl ~= y.hl or x.b0 ~= y.b0 or x.b1 ~= y.b1 then
      return false
    end
  end
  return true
end

local function apply_row_highlights(buf, row0, segs)
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, row0, row0 + 1)
  pcall(vim.api.nvim_buf_add_highlight, buf, ns, "MusicNormal", row0, 0, -1)
  if not segs then
    return
  end
  for _, seg in ipairs(segs) do
    if seg.hl and seg.b1 > seg.b0 then
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, seg.hl, row0, seg.b0, seg.b1)
    end
  end
end

local function lock_music_view(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_set_option_value, "winhl", "", { win = win })
      pcall(function()
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview({
            lnum = 1,
            col = 0,
            topline = 1,
            leftcol = 0,
            curswant = 0,
          })
        end)
      end)
    end
  end
end

---Statusline helpers (M.statusline assigned after any_music_displayed exists).
local refresh_statusline_var
local ensure_statusline_hook

---Redraw UI only (no IPC). Dirty: only rewrite changed rows / re-hl.
---Background via buffer namespace highlights only — never winhl.
---@param buf integer
---@param opts? { force?: boolean }
local function paint(buf, opts)
  local st = state_by_buf[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  opts = opts or {}
  local force = opts.force == true

  local cols = win_width(buf)
  local lines, segs_by_row = build_ui(buf, st)
  for i, ln in ipairs(lines) do
    lines[i] = pad_display(ln, cols)
  end

  local old_lines = st.paint_lines
  local old_segs = st.paint_segs
  local n = #lines
  local full = force
    or not old_lines
    or not old_segs
    or #old_lines ~= n
    or st.paint_cols ~= cols

  local bo = vim.bo[buf]
  bo.readonly = false
  bo.modifiable = true

  if full then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    bo.modifiable = false
    bo.modified = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for row0 = 0, n - 1 do
      apply_row_highlights(buf, row0, segs_by_row[row0])
    end
    fit_music_height(buf, n)
    lock_music_view(buf)
  else
    for i = 1, n do
      local row0 = i - 1
      local text_changed = old_lines[i] ~= lines[i]
      local hl_changed = not segs_equal(old_segs[row0], segs_by_row[row0])
      if text_changed then
        vim.api.nvim_buf_set_lines(buf, row0, row0 + 1, false, { lines[i] })
        apply_row_highlights(buf, row0, segs_by_row[row0])
      elseif hl_changed then
        apply_row_highlights(buf, row0, segs_by_row[row0])
      end
    end
    bo.modifiable = false
    bo.modified = false
  end

  st.paint_lines = lines
  st.paint_cols = cols
  st.paint_segs = segs_by_row
end

local function render(buf)
  local st = state_by_buf[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  engine(st).poll()
  paint(buf, { force = true })
end

local function stop_poll()
  if poll_timer then
    pcall(function()
      poll_timer:stop()
      poll_timer:close()
    end)
    poll_timer = nil
  end
end

---Need background timer when UI visible or statusline-when-hidden is on.
---(is_buf_displayed / any_music_displayed defined later; start_poll assigned after them.)
local should_poll
local start_poll

local function hit_at(st, row, col)
  -- row 1-based, col 1-based **display** column (strwidth-based)
  if not st.hits then
    return nil
  end
  for _, h in ipairs(st.hits) do
    if h.row == row and col >= h.d0 and col <= h.d1 then
      return h
    end
  end
  return nil
end

---Mouse → (line, display_col). Correct for sign/number gutter (same as drawbuf).
---@param buf integer
---@return integer|nil row 1-based
---@return integer|nil vcol 1-based display col in buffer text
local function mouse_display_pos(buf)
  local mouse = vim.fn.getmousepos()
  local win = vim.fn.bufwinid(buf)
  if win == -1 or mouse.winid == 0 or mouse.winid ~= win then
    return nil, nil
  end
  local info = vim.fn.getwininfo(win)[1] or {}
  local textoff = info.textoff or 0
  local leftcol = info.leftcol or 0
  local wpos = vim.api.nvim_win_get_position(win)
  -- screencol is 1-based screen cell; subtract win left + gutter
  local vcol = mouse.screencol - wpos[2] - textoff + leftcol
  if vcol < 1 then
    vcol = mouse.wincol - textoff + leftcol
  end
  if vcol < 1 then
    vcol = mouse.column
  end
  return mouse.line, vcol
end

local play_path_in_buf ---@type fun(buf: integer, path: string, opts?: table)
local play_preset_in_buf ---@type fun(buf: integer, name: string, opts?: table)
local open_preset_float ---@type fun()

local function do_toggle(buf, st)
  local eng = engine(st)
  local pst = eng.get_state()
  if is_midi_mode(st) then
    if pst.status == "idle" or pst.status == "stopped" then
      if st.preset and st.preset ~= "" then
        midi.load_preset(st.preset, true)
      elseif st.path and st.path ~= "" then
        midi.load_path(st.path, true)
      else
        open_preset_float()
        return
      end
    else
      midi.toggle()
    end
  else
    if pst.status == "idle" or pst.status == "stopped" or not pst.path then
      player.play(st.path, pst.position or 0)
    else
      player.toggle()
    end
  end
  render(buf)
end

local function goto_sibling(buf, delta)
  local st = state_by_buf[buf]
  if not st then
    return
  end
  -- 预设模式：循环内置曲目
  if is_midi_mode(st) and st.preset and (not st.path or st.path == "") then
    local presets = midi_preset_list()
    if #presets == 0 then
      return
    end
    local idx = st.index or 1
    idx = idx + delta
    if idx < 1 then
      idx = #presets
    elseif idx > #presets then
      idx = 1
    end
    local p = presets[idx]
    play_preset_in_buf(buf, p.id or p.name, { auto_play = true })
    return
  end
  if not st.siblings or #st.siblings == 0 then
    return
  end
  local idx = st.index + delta
  if idx < 1 then
    idx = #st.siblings
  elseif idx > #st.siblings then
    idx = 1
  end
  play_path_in_buf(buf, st.siblings[idx], { auto_play = true })
end

local function seek_from_hit(buf, st, hit, col)
  if is_midi_mode(st) then
    return
  end
  local pst = player.get_state()
  local dur = pst.duration
  if not dur or dur <= 0 then
    vim.notify(require("music.i18n").t("no_duration"), vim.log.levels.WARN)
    return
  end
  local bar_d0 = hit.bar_d0 or hit.d0
  local bar_w = hit.bar_w or math.max(1, hit.d1 - hit.d0 + 1)
  local rel = col - bar_d0
  if rel < 0 then
    rel = 0
  end
  if rel >= bar_w then
    rel = bar_w - 1
  end
  local ratio = bar_w <= 1 and 0 or (rel / (bar_w - 1))
  player.seek_abs(ratio * dur)
  render(buf)
end

local function run_action(buf, st, action, hit, col)
  local eng = engine(st)
  if action == "toggle" then
    do_toggle(buf, st)
  elseif action == "prev" then
    goto_sibling(buf, -1)
  elseif action == "next" then
    goto_sibling(buf, 1)
  elseif action == "stop" then
    eng.stop()
    render(buf)
  elseif action == "seek_back" then
    if not is_midi_mode(st) then
      player.seek(-5)
      render(buf)
    end
  elseif action == "seek_fwd" then
    if not is_midi_mode(st) then
      player.seek(5)
      render(buf)
    end
  elseif action == "vol_up" then
    eng.volume_up(5)
    render(buf)
  elseif action == "vol_down" then
    eng.volume_down(5)
    render(buf)
  elseif action == "loop" then
    if is_midi_mode(st) then
      return
    end
    local on = player.set_loop()
    local i18n = require("music.i18n")
    vim.notify(on and i18n.t("loop_notify_on") or i18n.t("loop_notify_off"), vim.log.levels.INFO)
    render(buf)
  elseif action == "restart" then
    if is_midi_mode(st) then
      if st.preset and st.preset ~= "" then
        midi.load_preset(st.preset, true)
      elseif st.path and st.path ~= "" then
        midi.load_path(st.path, true)
      end
    else
      player.play(st.path, 0)
    end
    render(buf)
  elseif action == "close" then
    M.close(buf)
  elseif action == "lyrics" then
    if not is_midi_mode(st) then
      M.toggle_lyrics()
    end
  elseif action == "playlist" then
    M.toggle_playlist()
  elseif action == "presets" then
    open_preset_float()
  elseif action == "lang" then
    M.toggle_ui_lang(buf)
  elseif action == "seek" then
    seek_from_hit(buf, st, hit, col)
  end
end

---Music player window for current buffer (if any).
local function music_win_of(buf)
  buf = buf or active_buf
  if not buf then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

function M.toggle_lyrics()
  M.ensure_setup()
  local prev = vim.api.nvim_get_current_win()
  if is_music_ui_win(prev) or is_sidebar_win(prev) then
    prev = nil
  end
  local buf = active_buf
  local st = buf and state_by_buf[buf]
  if is_midi_mode(st) then
    return
  end
  local path = st and st.path or (player.get_state().path)
  local mwin = music_win_of(buf)
  lyrics.toggle(mwin, path)
  -- after opening lyrics above, re-fit music height if needed
  if buf and vim.api.nvim_buf_is_valid(buf) then
    paint(buf, { force = true })
  end
  -- 少抢焦：歌词窗打开后回到代码窗
  focus_editor_win(prev)
end

---Sync playlist panel with current player state (files / playing / cursor).
local function sync_playlist(st)
  if not st then
    return
  end
  playlist.set_files(st.siblings or {}, st.path, st.index)
end

---Tab: cycle focus player ↔ list (only when list is open).
local function focus_tab_cycle()
  local mwin = music_win_of(active_buf)
  local lwin = playlist.get_win()
  if not lwin or not mwin then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  if cur == lwin then
    pcall(vim.api.nvim_set_current_win, mwin)
  else
    pcall(vim.api.nvim_set_current_win, lwin)
  end
end

---Show / hide sibling file list. Opening focuses the list for navigation.
function M.toggle_playlist()
  M.ensure_setup()
  local buf = active_buf
  local st = buf and state_by_buf[buf]
  if not st then
    vim.notify(require("music.i18n").t("no_playing"), vim.log.levels.INFO)
    return
  end
  -- 纯预设 MIDI：列表改为内置曲目
  if is_midi_mode(st) and (not st.path or st.path == "" or not st.siblings or #st.siblings == 0) then
    open_preset_float()
    return
  end
  local mwin = music_win_of(buf)
  if playlist.is_open() then
    playlist.close_panel() -- on_close → 恢复打开前高度
    if mwin and vim.api.nvim_win_is_valid(mwin) then
      pcall(vim.api.nvim_set_current_win, mwin)
    end
    return
  end
  -- 打开前记下高度，关闭时原样恢复（避免强制改高把底栏顶上去）
  save_player_height_for_list()
  playlist.set_on_play(function(path)
    local b = active_buf
    if b and vim.api.nvim_buf_is_valid(b) then
      play_path_in_buf(b, path, { auto_play = true })
    end
  end)
  playlist.set_on_close(refit_player_after_list)
  playlist.toggle(mwin, st.siblings, st.path, st.index)
  playlist.set_tab_handler(focus_tab_cycle)
  -- 打开列表后焦点在列表，便于立刻 ↑↓ 选择
  local lwin = playlist.get_win()
  if lwin then
    pcall(vim.api.nvim_set_current_win, lwin)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    paint(buf, { force = true })
  end
end

local function mouse_handle(buf, mode)
  local st = state_by_buf[buf]
  if not st then
    return
  end
  local row, col = mouse_display_pos(buf)
  if not row or not col then
    if mode == "release" then
      st.dragging = false
      st.drag_action = nil
    end
    return
  end
  local hit = hit_at(st, row, col)
  if not hit then
    if mode == "release" then
      st.dragging = false
      st.drag_action = nil
    end
    return
  end

  if mode == "down" then
    if hit.action == "seek" then
      st.dragging = true
      st.drag_action = "seek"
      seek_from_hit(buf, st, hit, col)
    else
      st.dragging = false
      st.drag_action = nil
      run_action(buf, st, hit.action, hit, col)
    end
  elseif mode == "drag" then
    if st.dragging and st.drag_action == "seek" then
      local h = hit
      if not h or h.action ~= "seek" then
        for _, x in ipairs(st.hits or {}) do
          if x.row == row and x.action == "seek" then
            h = x
            break
          end
        end
      end
      if h and h.action == "seek" then
        seek_from_hit(buf, st, h, col)
      end
    end
  elseif mode == "release" then
    if st.dragging and st.drag_action == "seek" then
      for _, x in ipairs(st.hits or {}) do
        if x.row == row and x.action == "seek" then
          seek_from_hit(buf, st, x, col)
          break
        end
      end
    end
    st.dragging = false
    st.drag_action = nil
  end
end

play_path_in_buf = function(buf, path, opts)
  opts = opts or {}
  path = vim.fn.fnamemodify(path, ":p")
  local midi_file = is_midi_path(path)
  local mode = midi_file and "midi" or "audio"
  stop_other_engine(mode)

  local siblings, index = list_siblings(path)
  local st = state_by_buf[buf]
  if not st then
    st = {
      path = path,
      siblings = siblings,
      index = index,
      hits = {},
      segs = {},
      dragging = false,
      drag_action = nil,
      mode = mode,
      preset = nil,
    }
    state_by_buf[buf] = st
  else
    st.path = path
    st.siblings = siblings
    st.index = index
    st.mode = mode
    st.preset = nil
  end

  -- track/layout change → next paint is full
  st.paint_lines = nil
  st.paint_segs = nil
  st.paint_cols = nil

  pcall(vim.api.nvim_buf_set_name, buf, path)
  vim.b[buf].music_player = true
  active_buf = buf
  ensure_hl()
  render(buf)
  start_poll()

  local start_pos = tonumber(opts.start_pos) or 0
  local want_play = opts.auto_play ~= false and config.auto_play
  if midi_file then
    lyrics.close_panel()
    midi.load_path(path, want_play)
    if not want_play then
      -- load only
    end
  else
    if want_play then
      local ok, err = player.play(path, start_pos)
      if not ok then
        vim.notify("music: " .. tostring(err), vim.log.levels.ERROR)
      end
    elseif start_pos > 0 and opts.seek_only then
      player.play(path, start_pos)
      player.pause()
    end
    -- reload lyrics for new track (keep panel if open)
    lyrics.on_track(path, start_pos)
  end
  sync_playlist(st)
  render(buf)
  save_session()
end

play_preset_in_buf = function(buf, name, opts)
  opts = opts or {}
  name = tostring(name or ""):lower()
  stop_other_engine("midi")
  midi.ensure()

  local presets = midi_preset_list()
  local index = 1
  for i, p in ipairs(presets) do
    if (p.id or p.name) == name then
      index = i
      break
    end
  end

  local st = state_by_buf[buf]
  if not st then
    st = {
      path = "",
      siblings = {},
      index = index,
      hits = {},
      segs = {},
      dragging = false,
      drag_action = nil,
      mode = "midi",
      preset = name,
    }
    state_by_buf[buf] = st
  else
    st.path = ""
    st.siblings = {}
    st.index = index
    st.mode = "midi"
    st.preset = name
  end
  st.paint_lines = nil
  st.paint_segs = nil
  st.paint_cols = nil

  pcall(vim.api.nvim_buf_set_name, buf, "music://midi/" .. name)
  vim.b[buf].music_player = true
  active_buf = buf
  ensure_hl()
  lyrics.close_panel()
  playlist.close_panel()

  local want_play = opts.auto_play ~= false and config.auto_play
  midi.load_preset(name, want_play)
  start_poll()
  render(buf)
  save_session()
end

open_preset_float = function()
  close_preset_float()
  M.ensure_setup()
  midi.ensure()
  midi.list_presets()
  vim.wait(300, function()
    local s = midi.get_state()
    return s.presets and #s.presets > 0
  end, 30)

  local i18n = require("music.i18n")
  local presets = midi_preset_list()
  local cur_idx = 1
  local st = active_buf and state_by_buf[active_buf]
  if st and st.preset then
    for i, p in ipairs(presets) do
      if (p.id or p.name) == st.preset then
        cur_idx = i
        break
      end
    end
  end

  local lines = { " " .. i18n.t("presets_title") .. " ", "" }
  for i, p in ipairs(presets) do
    local mark = (i == cur_idx) and "● " or "○ "
    lines[#lines + 1] = mark .. (p.title or p.name or p.id or ("#" .. i))
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden = "wipe"
  vim.b[fbuf].music_midi_presets = true

  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 4)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.7))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  local fwin = vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. i18n.t("presets") .. " ",
    title_pos = "center",
    zindex = 80,
  })
  pcall(function()
    vim.wo[fwin].cursorline = true
    vim.wo[fwin].number = false
    vim.wo[fwin].wrap = false
  end)
  preset_float.win = fwin
  preset_float.buf = fbuf
  pcall(vim.api.nvim_buf_set_extmark, fbuf, ns_preset_float, cur_idx + 1, 0, {
    end_row = cur_idx + 1,
    line_hl_group = "MusicBtnLoopOn",
  })
  pcall(vim.api.nvim_win_set_cursor, fwin, { cur_idx + 2, 0 })

  local function pick_line(lnum)
    local i = lnum - 2
    if i < 1 or i > #presets then
      return
    end
    local p = presets[i]
    local id = p.id or p.name
    close_preset_float()
    local b = active_buf
    if not b or not vim.api.nvim_buf_is_valid(b) then
      -- 无播放器 buffer：走 open_midi 创建
      M.open_midi({ preset = id, play = true })
      return
    end
    play_preset_in_buf(b, id, { auto_play = true })
    vim.notify(i18n.t("midi_loaded") .. tostring(p.title or id), vim.log.levels.INFO)
  end

  local o = { buffer = fbuf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_preset_float, o)
  vim.keymap.set("n", "<Esc>", close_preset_float, o)
  vim.keymap.set("n", "<CR>", function()
    pick_line(vim.api.nvim_win_get_cursor(0)[1])
  end, o)
  vim.keymap.set("n", "<LeftRelease>", function()
    vim.schedule(function()
      if preset_float.buf and vim.api.nvim_get_current_buf() == preset_float.buf then
        pick_line(vim.api.nvim_win_get_cursor(0)[1])
      end
    end)
  end, o)
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv" }) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", o)
  end
  for i = 1, math.min(9, #presets) do
    vim.keymap.set("n", tostring(i), function()
      pick_line(i + 2)
    end, o)
  end
end

---True if buffer is shown in any window (current tab).
local function is_buf_displayed(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

---Any music player buffer currently visible in current tab?
local function any_music_displayed()
  for buf, _ in pairs(state_by_buf) do
    if is_buf_displayed(buf) then
      return true
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].music_player and is_buf_displayed(buf) then
      return true
    end
  end
  return false
end

---是否需要维护 statusline 文本
local function statusline_enabled()
  return config.statusline_always == true or config.statusline_when_hidden == true
end

---Statusline 文本：`歌名.mp3[1:22/3:33, 1/299]`；无会话时为空。
---statusline_when_hidden：仅 UI 隐藏时返回；statusline_always：播放中始终返回。
---@return string
function M.statusline()
  if not statusline_enabled() then
    return ""
  end
  if not config.statusline_always and any_music_displayed() then
    return ""
  end
  local st = active_buf and state_by_buf[active_buf]
  local pst = engine(st).get_state()
  -- 仅在播放中显示；暂停 / 停止时清空 statusline
  if (pst.status or "") ~= "playing" then
    return ""
  end
  local path = pst.path
  if (not path or path == "") and st then
    path = st.path
  end
  local name
  if path and path ~= "" then
    -- 保留扩展名：歌名.mp3
    name = vim.fn.fnamemodify(path, ":t")
    if name == "" then
      name = path
    end
  elseif st and st.preset then
    name = st.preset
  elseif pst.title and pst.title ~= "" then
    name = pst.title
  else
    return ""
  end
  -- pst.position 已是 player 实时推算进度
  local pos_sec = tonumber(pst.position) or 0
  local dur_sec = tonumber(pst.duration)
  -- 展示层再夹一次，避免异常大进度
  if dur_sec and dur_sec > 0 and pos_sec > dur_sec then
    pos_sec = dur_sec
  end
  local pos = fmt_time_stl(pos_sec)
  local dur = fmt_time_stl(dur_sec)
  local total = 0
  local idx = 0
  if st then
    total = #(st.siblings or {})
    idx = tonumber(st.index) or 0
    if total > 0 then
      if idx < 1 then
        idx = 1
      elseif idx > total then
        idx = total
      end
    end
  end
  -- 进度/总长用全角斜杠 ／（宽 2），避免半角 / 与数字粘连成 02:122/
  -- 也不用 |（airline/lualine 分区符）
  if total > 0 then
    -- Fantasy.mp3[00:24／04:31 6/58]
    return string.format("%s[%s／%s %d/%d]", name, pos, dur, idx, total)
  end
  return string.format("%s[%s／%s]", name, pos, dur)
end

refresh_statusline_var = function()
  if not statusline_enabled() then
    if vim.g.music_statusline and vim.g.music_statusline ~= "" then
      vim.g.music_statusline = ""
      pcall(vim.cmd, "redrawstatus!")
    end
    return
  end
  local text = M.statusline()
  local prev = vim.g.music_statusline
  if prev ~= text then
    vim.g.music_statusline = text
  end
  -- 播放中每 tick 刷 statusline，进度才会推进
  if text ~= "" or (prev and prev ~= "") then
    pcall(vim.cmd, "redrawstatus!")
  end
end

ensure_statusline_hook = function()
  if not statusline_enabled() then
    return
  end
  vim.g.music_statusline = vim.g.music_statusline or ""
  -- 注意：必须用 %{...}（结果当普通文字），不能用 %{%...%}（会再当格式串解析，
  -- 把 "2:32/3:50" 弄成 "2:326/ 3:50" 一类乱码）。
  -- 用 g: 变量：由 refresh_statusline_var 每 tick 写入实时进度。
  local seg = "%{get(g:,'music_statusline','')}"
  local stl = vim.o.statusline or ""
  -- 去掉旧版错误的 %{%v:lua...%} / 重复片段
  stl = stl:gsub("%%{%%v:lua%.require%('music'%)%.statusline%(%)%%}", "")
  stl = stl:gsub("%%{%%v:lua%.require%(\"music\"%)%.statusline%(%)%%}", "")
  stl = stl:gsub("%s*%%{get%(g:,'music_statusline',''%)}", "")
  stl = stl:gsub("%s*%%{g:music_statusline}", "")
  stl = vim.trim(stl)
  if stl == "" then
    vim.o.statusline = "%<%f %h%m%r%=" .. seg .. " %-14.(%l,%c%V%) %P"
  else
    vim.o.statusline = stl .. " " .. seg
  end
  vim.g.music_statusline_hooked = true
end

should_poll = function()
  if config.poll_ms <= 0 then
    return false
  end
  if active_buf and vim.api.nvim_buf_is_valid(active_buf) and is_buf_displayed(active_buf) then
    return true
  end
  if statusline_enabled() then
    local st = active_buf and state_by_buf[active_buf]
    local pst = engine(st).get_state()
    if (pst.path or (st and st.preset)) and (pst.status == "playing" or pst.status == "paused" or pst.status == "stopped") then
      return true
    end
    if active_buf and vim.api.nvim_buf_is_valid(active_buf) and state_by_buf[active_buf] then
      return true
    end
  end
  return false
end

start_poll = function()
  stop_poll()
  if not should_poll() then
    return
  end
  poll_timer = vim.uv.new_timer()
  if not poll_timer then
    return
  end
  poll_timer:start(
    config.poll_ms,
    config.poll_ms,
    vim.schedule_wrap(function()
      if not should_poll() then
        stop_poll()
        refresh_statusline_var()
        return
      end
      local st = active_buf and state_by_buf[active_buf]
      local eng = engine(st)
      eng.poll()
      local ui_visible = active_buf
        and vim.api.nvim_buf_is_valid(active_buf)
        and is_buf_displayed(active_buf)
      if ui_visible then
        paint(active_buf) -- dirty refresh
        if not is_midi_mode(st) then
          local pst = player.get_state()
          if pst.path then
            lyrics.on_track(pst.path, pst.position or 0)
          else
            lyrics.follow(pst.position or 0)
          end
        end
      end
      refresh_statusline_var()
    end)
  )
end

---UI hidden: keep playing in background (do NOT stop audio).
local function on_ui_hidden()
  if any_music_displayed() then
    return
  end
  save_session()
  if statusline_enabled() then
    -- keep timer for statusline position updates
    start_poll()
    refresh_statusline_var()
  else
    stop_poll()
    refresh_statusline_var()
  end
end

local function on_ended()
  local buf = active_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- buffer 已不在窗口里：不要自动下一首（避免后台又开进程）
  if not is_buf_displayed(buf) then
    return
  end
  local st = state_by_buf[buf]
  if not st then
    return
  end
  if is_midi_mode(st) then
    local mst = midi.get_state()
    if mst.loop then
      if st.preset and st.preset ~= "" then
        midi.load_preset(st.preset, true)
      elseif st.path and st.path ~= "" then
        midi.load_path(st.path, true)
      end
      render(buf)
      return
    end
    if config.auto_next then
      if st.preset and (not st.path or st.path == "") then
        goto_sibling(buf, 1)
      elseif st.siblings and #st.siblings > 1 then
        goto_sibling(buf, 1)
      else
        render(buf)
      end
    else
      render(buf)
    end
    save_session()
    return
  end
  local pst = player.get_state()
  if pst.loop then
    player.play(st.path, 0)
    render(buf)
    return
  end
  if config.auto_next and #st.siblings > 1 then
    goto_sibling(buf, 1)
  else
    render(buf)
  end
  save_session()
end

local function map_no_scroll(buf)
  local nop_keys = {
    "j",
    "k",
    "h",
    "l",
    -- Up/Down rebound for volume after nops
    "<C-d>",
    "<C-u>",
    "<C-f>",
    "<C-b>",
    "<C-e>",
    "<C-y>",
    "<PageUp>",
    "<PageDown>",
    "gg",
    "G",
    "0",
    "$",
    "w",
    "b",
    "e",
    "zt",
    "zz",
    "zb",
    "H",
    "M",
    "L",
    "+",
    "-",
    "<CR>",
  }
  for _, lhs in ipairs(nop_keys) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "music: no scroll",
    })
  end
  pcall(vim.keymap.set, "n", "<ScrollWheelLeft>", "<Nop>", { buffer = buf, silent = true, nowait = true })
  pcall(vim.keymap.set, "n", "<ScrollWheelRight>", "<Nop>", { buffer = buf, silent = true, nowait = true })
  pcall(vim.keymap.set, "n", "i", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "a", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "I", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "A", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "o", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "O", "<Nop>", { buffer = buf, silent = true })
  -- 禁止 Visual 模式（v / V / 块选 / 重选）
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv", "<C-q>" }) do
    pcall(vim.keymap.set, "n", lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "music: no visual",
    })
  end
end

local function bind(buf)
  map_no_scroll(buf)

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  local function with_st(fn)
    return function()
      local st = state_by_buf[buf]
      if st then
        fn(st)
      end
    end
  end

  map("q", function()
    M.close(buf)
  end, "music: close")
  map("<Esc>", function()
    M.close(buf)
  end, "music: close")
  map("<Space>", with_st(function(st)
    do_toggle(buf, st)
  end), "music: toggle")
  map("p", with_st(function(st)
    do_toggle(buf, st)
  end), "music: toggle")
  map("<PageUp>", function()
    goto_sibling(buf, -1)
  end, "music: prev")
  map("<PageDown>", function()
    goto_sibling(buf, 1)
  end, "music: next")
  map("x", with_st(function(st)
    engine(st).stop()
    paint(buf)
  end), "music: stop")
  -- rebind after Nop
  map("l", with_st(function(st)
    if not is_midi_mode(st) then
      player.seek(5)
      paint(buf)
    end
  end), "music: +5s")
  map("h", with_st(function(st)
    if not is_midi_mode(st) then
      player.seek(-5)
      paint(buf)
    end
  end), "music: -5s")
  map("<Right>", with_st(function(st)
    if not is_midi_mode(st) then
      player.seek(5)
      paint(buf)
    end
  end), "music: +5s")
  map("<Left>", with_st(function(st)
    if not is_midi_mode(st) then
      player.seek(-5)
      paint(buf)
    end
  end), "music: -5s")
  map("+", with_st(function(st)
    engine(st).volume_up(5)
    paint(buf)
  end), "music: vol+")
  map("=", with_st(function(st)
    engine(st).volume_up(5)
    paint(buf)
  end), "music: vol+")
  map("-", with_st(function(st)
    engine(st).volume_down(5)
    paint(buf)
  end), "music: vol-")
  -- Up/Down arrows → volume
  map("<Up>", with_st(function(st)
    engine(st).volume_up(5)
    paint(buf)
  end), "music: vol+")
  map("<Down>", with_st(function(st)
    engine(st).volume_down(5)
    paint(buf)
  end), "music: vol-")
  map("r", with_st(function(st)
    run_action(buf, st, "restart", nil, 0)
  end), "music: restart")
  map("L", with_st(function(st)
    if is_midi_mode(st) then
      return
    end
    local on = player.set_loop()
    local i18n = require("music.i18n")
    vim.notify(on and i18n.t("loop_notify_on") or i18n.t("loop_notify_off"), vim.log.levels.INFO)
    paint(buf)
  end), "music: loop")
  map("Y", function()
    M.toggle_ui_lang(buf)
  end, "music: toggle UI language")
  map("g", function()
    M.toggle_lyrics()
  end, "music: toggle lyrics")
  map("f", function()
    M.toggle_playlist()
  end, "music: toggle playlist")
  map("m", with_st(function(st)
    if is_midi_mode(st) then
      open_preset_float()
    end
  end), "music: midi presets")
  map("<Tab>", function()
    if playlist.is_open() then
      focus_tab_cycle()
    end
  end, "music: focus list/player")

  -- mouse wheel → volume
  local function wheel_vol(delta)
    return function()
      local st = state_by_buf[buf]
      local eng = engine(st)
      if delta > 0 then
        eng.volume_up(5)
      else
        eng.volume_down(5)
      end
      paint(buf)
    end
  end
  ---Only handle mouse when click/scroll is ON this music window.
  ---Otherwise focus/click other windows would be swallowed (buffer-local <LeftMouse>).
  local function mouse_on_self()
    local m = vim.fn.getmousepos()
    local mywin = vim.fn.bufwinid(buf)
    return mywin ~= -1 and m.winid ~= 0 and m.winid == mywin
  end

  local function focus_clicked_win()
    local m = vim.fn.getmousepos()
    if m.winid ~= 0 and vim.api.nvim_win_is_valid(m.winid) then
      pcall(vim.api.nvim_set_current_win, m.winid)
      local col = math.max(0, (m.column or 1) - 1)
      local line = math.max(1, m.line or 1)
      pcall(vim.api.nvim_win_set_cursor, m.winid, { line, col })
    end
  end

  map("<ScrollWheelUp>", function()
    if not mouse_on_self() then
      focus_clicked_win()
      return
    end
    wheel_vol(1)()
  end, "music: vol+")
  map("<ScrollWheelDown>", function()
    if not mouse_on_self() then
      focus_clicked_win()
      return
    end
    wheel_vol(-1)()
  end, "music: vol-")
  map("<S-ScrollWheelUp>", function()
    if mouse_on_self() then
      wheel_vol(1)()
    else
      focus_clicked_win()
    end
  end, "music: vol+")
  map("<S-ScrollWheelDown>", function()
    if mouse_on_self() then
      wheel_vol(-1)()
    else
      focus_clicked_win()
    end
  end, "music: vol-")

  map("<LeftMouse>", function()
    if not mouse_on_self() then
      -- click another window (e.g. NERDTree / code): switch focus, don't eat event
      focus_clicked_win()
      return
    end
    mouse_handle(buf, "down")
  end, "music: click")
  map("<LeftDrag>", function()
    if not mouse_on_self() then
      return
    end
    mouse_handle(buf, "drag")
  end, "music: drag")
  map("<LeftRelease>", function()
    if not mouse_on_self() then
      return
    end
    mouse_handle(buf, "release")
  end, "music: release")

  -- 右键禁止选中文字（默认 mouse 会进入 Visual）
  local function map_right_nop(lhs)
    vim.keymap.set({ "n", "v", "x", "s", "i" }, lhs, function()
      if not mouse_on_self() then
        focus_clicked_win()
        return
      end
      -- 吞掉右键；若已在 Visual 则退出
      local mode = vim.fn.mode()
      if mode == "v" or mode == "V" or mode == "\22" then
        local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
        vim.api.nvim_feedkeys(esc, "n", false)
      end
    end, { buffer = buf, silent = true, nowait = true, desc = "music: no right-select" })
  end
  map_right_nop("<RightMouse>")
  map_right_nop("<RightDrag>")
  map_right_nop("<RightRelease>")
  map_right_nop("<2-RightMouse>")
end

local function apply_buf_opts(buf)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  -- hide (not wipe): Alt+M can hide UI while buffer + audio keep running
  bo.bufhidden = "hide"
  bo.buflisted = false
  bo.swapfile = false
  bo.modifiable = false
  bo.readonly = false
  bo.filetype = "music"
  bo.textwidth = 0
  vim.b[buf].music_player = true

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local wo = vim.wo[win]
      wo.number = false
      wo.relativenumber = false
      wo.signcolumn = "no"
      wo.foldcolumn = "0"
      wo.cursorline = false
      wo.cursorcolumn = false
      wo.wrap = false
      wo.list = false
      wo.foldenable = false
      wo.scrolloff = 0
      wo.sidescrolloff = 0
      wo.scrollbind = false
      wo.statuscolumn = ""
      -- never set winhl (leaks dark bg to other buffers in same window)
      pcall(vim.api.nvim_set_option_value, "winhl", "", { win = win })
      if vim.o.mouse == "" then
        vim.o.mouse = "a"
      end
    end
  end
end

---Attach once-per-buffer autocmds for player lifecycle.
local function attach_player_autocmds(buf)
  if vim.b[buf].music_autocmds then
    return
  end
  vim.b[buf].music_autocmds = true

  -- 焦点在播放器时隐藏光标，离开后恢复
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    buffer = buf,
    callback = function()
      hide_player_cursor()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    callback = function()
      restore_player_cursor()
    end,
  })
  -- 若仍进入 Visual（鼠标等），立即退回 Normal
  vim.api.nvim_create_autocmd("ModeChanged", {
    buffer = buf,
    callback = function()
      local mode = vim.fn.mode()
      if mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" then
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() ~= buf then
            return
          end
          local m = vim.fn.mode()
          if m == "v" or m == "V" or m == "\22" or m == "s" or m == "S" then
            local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
            vim.api.nvim_feedkeys(esc, "n", false)
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      restore_player_cursor()
      close_preset_float()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          pcall(vim.api.nvim_set_option_value, "winhl", "", { win = win })
        end
      end
      save_session()
      local st = state_by_buf[buf]
      state_by_buf[buf] = nil
      if active_buf == buf then
        active_buf = nil
        stop_poll()
        stop_all_engines()
      elseif st then
        engine(st).stop()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufHidden" }, {
    buffer = buf,
    callback = function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(win)
        if not (vim.api.nvim_buf_is_valid(b) and vim.b[b].music_player) then
          local wh = ""
          pcall(function()
            wh = vim.api.nvim_get_option_value("winhl", { win = win }) or ""
          end)
          if wh:find("MusicNormal", 1, true) then
            pcall(vim.api.nvim_set_option_value, "winhl", "", { win = win })
          end
        end
      end
      -- hide UI only — keep audio
      vim.schedule(on_ui_hidden)
    end,
  })

  vim.api.nvim_create_autocmd({ "VimResized", "ColorScheme" }, {
    buffer = buf,
    callback = function()
      hl_ready = false
      ensure_hl()
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end,
  })
end

---确保有播放器 buffer（复用或新建底栏）
---@param opts? { win?: integer, replace_buf?: integer, close_win?: integer, bottom_split?: boolean }
---@return integer|nil buf
local function ensure_player_buf(opts)
  opts = opts or {}
  local existing_win, existing_buf = find_music_win()
  local close_win = opts.close_win
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local bottom = opts.bottom_split == true

  if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) and vim.b[existing_buf].music_player then
    local win
    if bottom then
      ensure_singleton_window(nil, existing_buf)
      win = open_bottom_split(existing_buf, estimate_ui_lines())
      ensure_singleton_window(win, existing_buf)
    else
      win = find_content_win(opts.win or existing_win)
      if not is_usable_content_win(existing_win) or (existing_win and vim.api.nvim_win_get_tabpage(existing_win) ~= cur_tab) then
        win = find_content_win(opts.win)
      elseif is_usable_content_win(existing_win) then
        win = existing_win
      end
      ensure_singleton_window(win, existing_buf)
      vim.api.nvim_win_set_buf(win, existing_buf)
    end
    apply_buf_opts(existing_buf)
    local ph = opts.replace_buf
    if ph and ph ~= existing_buf and vim.api.nvim_buf_is_valid(ph) then
      local ph_win = vim.fn.bufwinid(ph)
      if ph_win ~= -1 and ph_win ~= win then
        close_win = close_win or ph_win
      end
      pcall(vim.api.nvim_buf_delete, ph, { force = true })
    end
    if close_win then
      close_orphan_split(close_win, win)
    end
    if not bottom then
      pcall(vim.api.nvim_set_current_win, win)
    end
    return existing_buf
  end

  local buf = opts.replace_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].music_player then
    buf = vim.api.nvim_create_buf(true, true)
  end

  local win
  if bottom then
    ensure_singleton_window(nil, buf)
    win = open_bottom_split(buf, estimate_ui_lines())
    ensure_singleton_window(win, buf)
  else
    win = find_content_win(opts.win or existing_win)
    ensure_singleton_window(win, buf)
    vim.api.nvim_win_set_buf(win, buf)
  end

  ensure_hl()
  apply_buf_opts(buf)
  bind(buf)
  attach_player_autocmds(buf)

  if close_win then
    close_orphan_split(close_win, win)
  end
  if not bottom then
    pcall(vim.api.nvim_set_current_win, win)
  end
  return buf
end

---@param path string
---@param opts? { win?: integer, replace_buf?: integer, auto_play?: boolean, close_win?: integer, bottom_split?: boolean, start_pos?: number }
---@return integer|nil buf
function M.open(path, opts)
  M.ensure_setup()
  opts = opts or {}
  -- 允许预设名：:Music twinkle
  local raw = vim.trim(path or "")
  if is_midi_preset(raw) and vim.fn.filereadable(raw) ~= 1 then
    return M.open_midi({ preset = raw:lower(), play = opts.auto_play ~= false })
  end
  path = vim.fn.expand(path or "")
  path = vim.fn.fnamemodify(path, ":p")
  if path == "" or vim.fn.filereadable(path) ~= 1 then
    vim.notify(require("music.i18n").t("not_found") .. tostring(path), vim.log.levels.ERROR)
    return nil
  end
  if not is_audio(path) then
    vim.notify(require("music.i18n").t("not_audio") .. path, vim.log.levels.WARN)
  end

  local buf = ensure_player_buf(opts)
  if not buf then
    return nil
  end
  play_path_in_buf(buf, path, {
    auto_play = opts.auto_play,
    start_pos = opts.start_pos,
  })
  return buf
end

---打开 MIDI 模式：预设名 / .mid 路径 / 空闲（可按 m 选预设）
---@param opts? { path?: string, preset?: string, play?: boolean, win?: integer, replace_buf?: integer, bottom_split?: boolean }
---@return integer|nil buf
function M.open_midi(opts)
  M.ensure_setup()
  opts = opts or {}
  if vim.fn.has("win32") ~= 1 and vim.fn.has("win64") ~= 1 then
    vim.notify(require("music.i18n").t("midi_need_win"), vim.log.levels.ERROR)
    return nil
  end
  local play = opts.play
  if play == nil then
    play = config.auto_play ~= false
  end
  local buf = ensure_player_buf({
    win = opts.win,
    replace_buf = opts.replace_buf,
    bottom_split = opts.bottom_split ~= false, -- 默认底栏
  })
  if not buf then
    return nil
  end
  if opts.path and opts.path ~= "" then
    play_path_in_buf(buf, opts.path, { auto_play = play })
  elseif opts.preset and opts.preset ~= "" then
    play_preset_in_buf(buf, opts.preset, { auto_play = play })
  else
    -- 空闲 MIDI UI
    stop_other_engine("midi")
    local st = state_by_buf[buf]
    if not st then
      st = {
        path = "",
        siblings = {},
        index = 1,
        hits = {},
        segs = {},
        dragging = false,
        drag_action = nil,
        mode = "midi",
        preset = nil,
      }
      state_by_buf[buf] = st
    else
      st.path = ""
      st.siblings = {}
      st.mode = "midi"
      st.preset = nil
      st.paint_lines = nil
    end
    pcall(vim.api.nvim_buf_set_name, buf, "music://midi")
    vim.b[buf].music_player = true
    active_buf = buf
    midi.ensure()
    start_poll()
    render(buf)
  end
  return buf
end

function M.close(buf)
  buf = buf or active_buf
  save_session()
  close_preset_float()
  lyrics.close_panel()
  playlist.close_panel()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    stop_all_engines()
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_set_option_value, "winhl", "", { win = win })
    end
  end
  stop_all_engines()
  state_by_buf[buf] = nil
  if active_buf == buf then
    active_buf = nil
    stop_poll()
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---Hide player windows; audio keeps playing in background.
function M.hide_ui()
  M.ensure_setup()
  save_session()
  close_preset_float()
  lyrics.close_panel()
  playlist.close_panel()
  local buf = active_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- close every window showing music (all tabs)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        local n = #vim.api.nvim_tabpage_list_wins(tab)
        if n <= 1 then
          local empty = vim.api.nvim_create_buf(true, true)
          pcall(function()
            vim.bo[empty].buftype = "nofile"
            vim.bo[empty].bufhidden = "wipe"
            vim.bo[empty].swapfile = false
          end)
          pcall(vim.api.nvim_win_set_buf, win, empty)
        else
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
  -- buffer kept (bufhidden=hide); player keeps running
  if statusline_enabled() then
    start_poll()
    refresh_statusline_var()
  else
    stop_poll()
    refresh_statusline_var()
  end
end

---Show player UI in a bottom split under current buffer; restore session if needed.
function M.show_ui()
  M.ensure_setup()
  local buf = active_buf
  if buf and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].music_player then
    -- close other tabs' music windows, then bottom-split here
    ensure_singleton_window(nil, buf)
    local win = open_bottom_split(buf, estimate_ui_lines())
    apply_buf_opts(buf)
    ensure_singleton_window(win, buf)
    -- open_bottom_split 已回焦代码窗，不抢焦点
    start_poll()
    paint(buf, { force = true })
    refresh_statusline_var()
    return buf
  end

  -- no live buffer: restore from session into bottom split
  local sess = load_session()
  if sess then
    if type(sess.volume) == "number" then
      if sess.mode == "midi" or (sess.path and is_midi_path(sess.path)) then
        midi.set_volume(sess.volume)
      else
        player.set_volume(sess.volume)
      end
    end
    if sess.preset and (not sess.path or sess.path == "") then
      return M.open_midi({
        preset = sess.preset,
        play = true,
        bottom_split = true,
      })
    end
    if sess.path and vim.fn.filereadable(sess.path) == 1 then
      if sess.loop ~= nil and not is_midi_path(sess.path) then
        player.set_loop(sess.loop)
      end
      return M.open(sess.path, {
        auto_play = true,
        start_pos = tonumber(sess.position) or 0,
        bottom_split = true,
      })
    end
  end

  vim.notify(require("music.i18n").t("no_session"), vim.log.levels.INFO)
  return nil
end

---Alt+M: show / hide player UI (hide = background play).
function M.toggle_ui()
  M.ensure_setup()
  if any_music_displayed() then
    M.hide_ui()
  else
    M.show_ui()
  end
end

function M.toggle()
  M.ensure_setup()
  if active_buf and state_by_buf[active_buf] then
    do_toggle(active_buf, state_by_buf[active_buf])
  else
    player.toggle()
  end
end

function M.next()
  if active_buf and state_by_buf[active_buf] then
    goto_sibling(active_buf, 1)
  end
end

function M.prev()
  if active_buf and state_by_buf[active_buf] then
    goto_sibling(active_buf, -1)
  end
end

function M.stop()
  local st = active_buf and state_by_buf[active_buf]
  if st then
    engine(st).stop()
  else
    stop_all_engines()
  end
  if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
    render(active_buf)
  end
end

---NERDTree `o` / :e audio → content pane (reuse existing player if any).
local function resolve_auto_open_wins(placeholder_buf)
  local hint = -1
  if placeholder_buf and vim.api.nvim_buf_is_valid(placeholder_buf) then
    hint = vim.fn.bufwinid(placeholder_buf)
  end
  local existing_win = find_music_win()
  local target = find_content_win(existing_win)
  local close_win = nil
  if hint ~= -1 and hint ~= target and is_usable_content_win(hint) then
    -- opened as extra split; put player on main pane and drop the split
    close_win = hint
  elseif is_usable_content_win(hint) and not existing_win then
    target = hint
  end
  return target, close_win
end

local function setup_auto_open()
  local pat = {}
  for _, ext in ipairs(config.extensions) do
    table.insert(pat, "*." .. ext)
    table.insert(pat, "*." .. ext:upper())
  end

  local aug = vim.api.nvim_create_augroup("MusicAutoOpen", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = pat,
    callback = function(ev)
      local path = ev.file
      if path == nil or path == "" then
        path = vim.api.nvim_buf_get_name(ev.buf)
      end
      vim.bo[ev.buf].buftype = "nofile"
      vim.bo[ev.buf].bufhidden = "wipe"
      vim.bo[ev.buf].swapfile = false
      vim.b[ev.buf].music_placeholder = true
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then
          return
        end
        local target, close_win = resolve_auto_open_wins(ev.buf)
        M.open(path, {
          replace_buf = ev.buf,
          win = target,
          close_win = close_win,
          auto_play = true,
        })
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = aug,
    pattern = pat,
    callback = function(ev)
      if vim.b[ev.buf].music_player or vim.b[ev.buf].music_placeholder then
        return
      end
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if not is_audio(path) then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) or vim.b[ev.buf].music_player then
          return
        end
        local target, close_win = resolve_auto_open_wins(ev.buf)
        M.open(path, {
          replace_buf = ev.buf,
          win = target,
          close_win = close_win,
          auto_play = true,
        })
      end)
    end,
  })
end

---Scrub MusicNormal winhl left by older versions on any window.
local function scrub_all_music_winhl()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local wh = ""
    pcall(function()
      wh = vim.api.nvim_get_option_value("winhl", { win = win }) or ""
    end)
    if wh:find("MusicNormal", 1, true) then
      pcall(vim.api.nvim_set_option_value, "winhl", "", { win = win })
    end
  end
end

---切换中/英文界面
---@param buf? integer
function M.toggle_ui_lang(buf)
  local i18n = require("music.i18n")
  local next_lang = i18n.toggle()
  i18n.save_prefs()
  if next_lang == "en" then
    vim.notify(i18n.t("lang_to_en"), vim.log.levels.INFO)
  else
    vim.notify(i18n.t("lang_to_zh"), vim.log.levels.INFO)
  end
  buf = buf or active_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    paint(buf)
  end
end

---@param user? MusicConfig
function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  local i18n = require("music.i18n")
  local remembered = i18n.load_prefs()
  local lang_opt = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang_opt = user.ui_lang
  elseif remembered then
    lang_opt = remembered
  end
  if lang_opt == "zh" or lang_opt == "en" then
    i18n.setup(lang_opt)
  else
    i18n.setup("auto")
  end
  rebuild_ext()
  player.setup({
    backend = config.backend,
    volume = config.volume,
    loop = config.loop,
    python = config.python,
  })
  midi.setup({
    python = config.python,
    volume = config.volume,
  })
  scrub_all_music_winhl()
  ensure_statusline_hook()
  playlist.set_on_close(refit_player_after_list)
  player.on_ended(on_ended)
  midi.on_ended(on_ended)
  local function on_any_status()
    if active_buf and vim.api.nvim_buf_is_valid(active_buf) and any_music_displayed() then
      paint(active_buf) -- dirty
    end
    refresh_statusline_var()
  end
  player.on_status(on_any_status)
  midi.on_status(on_any_status)

  vim.api.nvim_create_user_command("Music", function(opts)
    local arg = vim.trim(opts.args or "")
    if arg == "" then
      local cur = vim.fn.expand("%:p")
      if cur ~= "" and is_audio(cur) then
        M.open(cur)
        return
      end
      -- no path: toggle / restore session
      M.toggle_ui()
      return
    end
    if is_midi_preset(arg) and vim.fn.filereadable(arg) ~= 1 then
      M.open_midi({ preset = arg:lower(), play = true })
      return
    end
    if vim.fn.filereadable(arg) == 1 or vim.fn.filereadable(vim.fn.expand(arg)) == 1 then
      M.open(arg)
      return
    end
    M.open(arg)
  end, {
    nargs = "?",
    complete = function(arglead)
      local out = {}
      for _, id in ipairs(MIDI_PRESET_IDS) do
        if id:find(arglead, 1, true) == 1 then
          out[#out + 1] = id
        end
      end
      -- 文件补全
      local files = vim.fn.getcompletion(arglead, "file")
      for _, f in ipairs(files) do
        out[#out + 1] = f
      end
      return out
    end,
    desc = "打开音频/MIDI 播放器；预设名或文件路径；无参则显示/隐藏 UI",
  })

  vim.api.nvim_create_user_command("MusicToggle", function()
    M.toggle()
  end, { desc = "播放/暂停" })

  vim.api.nvim_create_user_command("MusicNext", function()
    M.next()
  end, { desc = "同目录下一首" })

  vim.api.nvim_create_user_command("MusicPrev", function()
    M.prev()
  end, { desc = "同目录上一首" })

  vim.api.nvim_create_user_command("MusicStop", function()
    M.stop()
  end, { desc = "停止播放" })

  vim.api.nvim_create_user_command("MusicToggleUI", function()
    M.toggle_ui()
  end, { desc = "显示/隐藏 music 播放器（后台继续播）" })

  vim.api.nvim_create_user_command("MusicMidi", function(opts)
    local arg = vim.trim(opts.args or "")
    if arg == "" then
      M.open_midi({ play = false })
      return
    end
    if is_midi_preset(arg) and vim.fn.filereadable(arg) ~= 1 then
      M.open_midi({ preset = arg:lower(), play = true })
    elseif vim.fn.filereadable(arg) == 1 or vim.fn.filereadable(vim.fn.expand(arg)) == 1 then
      M.open_midi({ path = vim.fn.fnamemodify(vim.fn.expand(arg), ":p"), play = true })
    else
      M.open_midi({ preset = arg:lower(), play = true })
    end
  end, {
    nargs = "?",
    complete = function(arglead)
      local out = {}
      for _, id in ipairs(MIDI_PRESET_IDS) do
        if id:find(arglead, 1, true) == 1 then
          out[#out + 1] = id
        end
      end
      local files = vim.fn.getcompletion(arglead, "file")
      for _, f in ipairs(files) do
        out[#out + 1] = f
      end
      return out
    end,
    desc = "打开 MIDI 播放器；参数为预设名或 .mid 路径",
  })

  if config.auto_open then
    setup_auto_open()
  else
    vim.api.nvim_create_augroup("MusicAutoOpen", { clear = true })
  end

  vim.api.nvim_create_autocmd({ "WinClosed", "TabClosed", "BufWinLeave" }, {
    group = vim.api.nvim_create_augroup("MusicVisibility", { clear = true }),
    callback = function()
      vim.schedule(on_ui_hidden)
    end,
  })

  -- Global Alt+M (configurable)
  local key = config.toggle_key or "<M-m>"
  pcall(vim.keymap.del, "n", key)
  vim.keymap.set({ "n", "i", "v", "t" }, key, function()
    -- leave insert for clean UI switch
    if vim.fn.mode():find("i") then
      vim.cmd("stopinsert")
    end
    M.toggle_ui()
  end, { desc = "music: show/hide player UI", silent = true })

  -- MIDI 快捷键（兼容原 mixer <leader>mx）
  local mk = config.keys_midi
  if mk and mk ~= false and mk ~= "" then
    pcall(vim.keymap.del, "n", mk)
    vim.keymap.set("n", mk, function()
      M.open_midi({ play = false })
    end, { silent = true, desc = "music: open MIDI player" })
  end

  -- leave Neovim: save session + quit python daemons
  local leave_aug = vim.api.nvim_create_augroup("MusicLeave", { clear = true })
  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimLeave" }, {
    group = leave_aug,
    callback = function()
      save_session()
      stop_poll()
      player.shutdown()
      midi.shutdown()
    end,
  })

  -- Windows：后台预热 MIDI 引擎
  midi.warmup()

  ensure_hl()
  vim.g.music_setup_done = true
end

function M.ensure_setup()
  if not vim.g.music_setup_done then
    M.setup()
  end
end

function M.config()
  return config
end

return M
