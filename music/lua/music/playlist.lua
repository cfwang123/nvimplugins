---@mod music.playlist Sibling file list panel (同目录曲目列表)
local M = {}

---@class PlaylistState
---@field files string[]
---@field cursor integer 1-based selection
---@field playing_path string|nil
---@field buf integer|nil
---@field win integer|nil
---@field on_play fun(path: string)|nil
---@field on_close fun()|nil

local state = {
  files = {},
  cursor = 1,
  playing_path = nil,
  buf = nil,
  win = nil,
  on_play = nil,
  on_close = nil,
}

local ns = vim.api.nvim_create_namespace("music_playlist")
local hl_ready = false

local function ensure_hl()
  if hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  -- white / gray UI，与播放器一致
  vim.api.nvim_set_hl(0, "MusicListNormal", { fg = "#4a4a4a", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "MusicListHeader", { fg = "#1a1a1a", bg = "#f0f0f0", bold = true })
  vim.api.nvim_set_hl(0, "MusicListMeta", { fg = "#9a9a9a", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "MusicListItem", { fg = "#3a3a3a", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "MusicListCursor", { fg = "#1a1a1a", bg = "#e0e0e0", bold = true })
  vim.api.nvim_set_hl(0, "MusicListPlaying", { fg = "#c45c12", bg = "#ffffff", bold = true })
  vim.api.nvim_set_hl(0, "MusicListPlayingCur", { fg = "#c45c12", bg = "#e0e0e0", bold = true })
  hl_ready = true
end

local function norm_path(p)
  if not p or p == "" then
    return ""
  end
  return vim.fn.fnamemodify(p, ":p"):gsub("\\", "/"):lower()
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---@return integer|nil
function M.get_win()
  if M.is_open() then
    return state.win
  end
  return nil
end

---@return integer|nil
function M.get_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  return nil
end

---@param cb fun(path: string)|nil
function M.set_on_play(cb)
  state.on_play = cb
end

---@param cb fun()|nil
function M.set_on_close(cb)
  state.on_close = cb
end

---Sync file list + highlight current playing track.
---@param files string[]
---@param playing_path string|nil
---@param prefer_cursor integer|nil 1-based
function M.set_files(files, playing_path, prefer_cursor)
  state.files = files or {}
  state.playing_path = playing_path
  local n = #state.files
  if n == 0 then
    state.cursor = 1
  else
    if prefer_cursor and prefer_cursor >= 1 and prefer_cursor <= n then
      state.cursor = prefer_cursor
    else
      -- keep cursor if still valid path in list; else snap to playing
      local cur_path = state.files[state.cursor]
      local keep = cur_path and true
      if keep and playing_path then
        -- if list rebuilt, try match playing
      end
      local found = nil
      if playing_path and playing_path ~= "" then
        local want = norm_path(playing_path)
        for i, f in ipairs(state.files) do
          if norm_path(f) == want then
            found = i
            break
          end
        end
      end
      if found then
        state.cursor = found
      elseif state.cursor < 1 or state.cursor > n then
        state.cursor = 1
      end
    end
  end
  if M.is_open() then
    M.render()
  end
end

local function line_for(i, path, cols)
  local name = vim.fn.fnamemodify(path, ":t")
  local mark = "  "
  if state.playing_path and norm_path(path) == norm_path(state.playing_path) then
    mark = "> "
  end
  local text = string.format("%s%3d  %s", mark, i, name)
  local w = vim.fn.strwidth(text)
  if w < cols then
    text = text .. string.rep(" ", cols - w)
  end
  return text
end

function M.render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  ensure_hl()
  local cols = 40
  if M.is_open() then
    cols = math.max(20, vim.api.nvim_win_get_width(state.win))
  end

  local lines = {}
  local n = #state.files
  local header = string.format(" 列表  %d 首  ↑↓/Pg 选  Space播  f关  Tab切换", n)
  local hw = vim.fn.strwidth(header)
  if hw < cols then
    header = header .. string.rep(" ", cols - hw)
  end
  table.insert(lines, header)

  if n == 0 then
    table.insert(lines, "  (无音频文件)")
  else
    for i, path in ipairs(state.files) do
      table.insert(lines, line_for(i, path, cols))
    end
  end

  local bo = vim.bo[state.buf]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  bo.modifiable = false
  bo.modified = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, "MusicListHeader", 0, 0, -1)

  for i, path in ipairs(state.files) do
    local row = i -- 0-based: header is row 0, items start at 1
    local is_cur = i == state.cursor
    local is_play = state.playing_path and norm_path(path) == norm_path(state.playing_path)
    local hl = "MusicListItem"
    if is_cur and is_play then
      hl = "MusicListPlayingCur"
    elseif is_cur then
      hl = "MusicListCursor"
    elseif is_play then
      hl = "MusicListPlaying"
    end
    pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, hl, row, 0, -1)
  end

  if M.is_open() and n > 0 then
    local row = math.max(1, math.min(state.cursor + 1, #lines)) -- 1-based with header
    pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
    pcall(function()
      vim.api.nvim_win_call(state.win, function()
        vim.cmd("normal! zz")
      end)
    end)
  end
end

---@param delta integer
function M.move(delta)
  local n = #state.files
  if n == 0 then
    return
  end
  local c = state.cursor + delta
  if c < 1 then
    c = 1
  elseif c > n then
    c = n
  end
  if c ~= state.cursor then
    state.cursor = c
    M.render()
  end
end

---@param pages integer positive or negative page steps
function M.page(pages)
  local win_h = 10
  if M.is_open() then
    win_h = math.max(3, vim.api.nvim_win_get_height(state.win) - 1)
  end
  M.move(pages * win_h)
end

function M.play_cursor()
  local path = state.files[state.cursor]
  if not path or path == "" then
    return
  end
  state.playing_path = path
  if state.on_play then
    state.on_play(path)
  end
  -- Space/回车选歌后关闭列表
  M.close_panel()
end

local function bind_list_keys()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  if vim.b[state.buf].music_list_keys then
    return
  end
  vim.b[state.buf].music_list_keys = true

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = state.buf, silent = true, nowait = true, desc = desc })
  end

  map("<Up>", function()
    M.move(-1)
  end, "music list: up")
  map("k", function()
    M.move(-1)
  end, "music list: up")
  map("<Down>", function()
    M.move(1)
  end, "music list: down")
  map("j", function()
    M.move(1)
  end, "music list: down")
  map("<PageUp>", function()
    M.page(-1)
  end, "music list: page up")
  map("<PageDown>", function()
    M.page(1)
  end, "music list: page down")
  map("<C-u>", function()
    M.page(-1)
  end, "music list: page up")
  map("<C-d>", function()
    M.page(1)
  end, "music list: page down")
  map("<Space>", function()
    M.play_cursor()
  end, "music list: play")
  map("<CR>", function()
    M.play_cursor()
  end, "music list: play")
  map("f", function()
    M.close_panel()
  end, "music list: close")
  map("q", function()
    M.close_panel()
  end, "music list: close")
  -- Tab: focus player — set by init.lua via set_tab_handler
  map("gg", function()
    state.cursor = 1
    M.render()
  end, "music list: top")
  map("G", function()
    state.cursor = math.max(1, #state.files)
    M.render()
  end, "music list: bottom")

  -- click to select / double-ish: left mouse sets cursor, second click or CR plays
  map("<LeftMouse>", function()
    local m = vim.fn.getmousepos()
    if not M.is_open() or m.winid ~= state.win then
      return
    end
    local line = m.line or 1
    if line <= 1 then
      return
    end
    local idx = line - 1
    if idx >= 1 and idx <= #state.files then
      state.cursor = idx
      M.render()
    end
  end, "music list: click select")
  map("<2-LeftMouse>", function()
    local m = vim.fn.getmousepos()
    if not M.is_open() or m.winid ~= state.win then
      return
    end
    local line = m.line or 1
    if line <= 1 then
      return
    end
    local idx = line - 1
    if idx >= 1 and idx <= #state.files then
      state.cursor = idx
      M.play_cursor()
    end
  end, "music list: double-click play")
end

---@param handler fun()|nil
function M.set_tab_handler(handler)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  vim.keymap.set("n", "<Tab>", function()
    if handler then
      handler()
    end
  end, { buffer = state.buf, silent = true, nowait = true, desc = "music list: focus player" })
end

---@param music_win integer|nil
---@param height? integer
---@return integer|nil win
function M.open_panel(music_win, height)
  ensure_hl()
  height = math.max(5, math.min(height or 12, vim.o.lines - 6))

  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = vim.api.nvim_create_buf(false, true)
    local bo = vim.bo[state.buf]
    bo.buftype = "nofile"
    bo.bufhidden = "hide"
    bo.buflisted = false
    bo.swapfile = false
    bo.modifiable = false
    bo.filetype = "music_playlist"
    pcall(vim.api.nvim_buf_set_name, state.buf, "music://playlist")
    vim.b[state.buf].music_playlist = true
    bind_list_keys()
  end

  if M.is_open() then
    M.render()
    pcall(vim.api.nvim_set_current_win, state.win)
    return state.win
  end

  if music_win and vim.api.nvim_win_is_valid(music_win) then
    pcall(vim.api.nvim_set_current_win, music_win)
  end
  vim.cmd("aboveleft " .. tostring(height) .. "split")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  local wo = vim.wo[state.win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.cursorline = false
  wo.list = false
  wo.scrolloff = 2
  pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = state.win })
  pcall(vim.api.nvim_win_set_height, state.win, height)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function()
      if state.win and not vim.api.nvim_win_is_valid(state.win) then
        state.win = nil
      end
    end,
  })

  M.render()
  return state.win
end

function M.close_panel()
  local was_open = state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
  if was_open then
    local tab_wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(state.win))
    if #tab_wins <= 1 then
      local empty = vim.api.nvim_create_buf(true, true)
      pcall(vim.api.nvim_win_set_buf, state.win, empty)
    else
      pcall(vim.api.nvim_win_close, state.win, true)
    end
  end
  state.win = nil
  if was_open and state.on_close then
    -- 布局刚变，下一 tick 立刻收回播放器高度
    vim.schedule(function()
      if state.on_close then
        state.on_close()
      end
    end)
  end
end

---@param music_win integer|nil
---@param files string[]
---@param playing_path string|nil
---@param cursor integer|nil
---@return boolean open
function M.toggle(music_win, files, playing_path, cursor)
  if M.is_open() then
    M.close_panel()
    return false
  end
  M.set_files(files or {}, playing_path, cursor)
  M.open_panel(music_win, 12)
  return true
end

function M.reset()
  local cb = state.on_close
  state.on_close = nil -- avoid refit during full reset
  M.close_panel()
  state.on_close = cb
  state.files = {}
  state.cursor = 1
  state.playing_path = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.on_play = nil
end

return M
