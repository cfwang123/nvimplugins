---@mod bookmarks 文件/文件夹收藏夹
---右侧 split 列表；与 vimplugins 的 bookmarks.txt 格式兼容。

local M = {}

local default_config = {
  ---数据文件；默认与 Vim 版共用 stdpath("data")/vimplugins/bookmarks.txt
  file = nil,
  ---右侧窗口宽度
  width = 36,
  ---默认全局快捷键；false 关闭对应映射
  ---A/D 仅在收藏夹窗口内绑定（见 setup_buffer），不占用编辑窗口
  keys_open = "<leader>bo",
  keys_add_file = false,
  keys_add_dir = false,
  ---设为 true 时不注册任何默认全局映射
  no_mappings = false,
  ---默认是否短名称显示（true=仅名称，重名去公共前缀；S 可切换）
  name_only = true,
}

local config = vim.deepcopy(default_config)
local setup_done = false
---@type string[]
local keys_applied = {}

---@class BookmarkItem
---@field type "f"|"d"
---@field path string

local state = {
  buf = -1,
  win = -1,
  ---@type BookmarkItem[]
  list = {},
  loaded_once = false,
  name_only = true, -- 默认短名称；S 切换完整路径
  prev_buf = 0,
}

local HEADER_LINES = 2 -- 标题 + 空行

-- ---------------------------------------------------------------------------
-- 路径与存储
-- ---------------------------------------------------------------------------

local function data_file()
  if config.file and config.file ~= "" then
    return vim.fn.expand(config.file)
  end
  local dir = vim.fn.stdpath("data") .. "/vimplugins"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir .. "/bookmarks.txt"
end

---@param path string
---@return string
local function normalize_path(path)
  local p = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  p = p:gsub("\\", "/")
  if p:match("[/\\]$") and not p:match("^([A-Za-z]:)?/$") then
    p = p:gsub("[/\\]+$", "")
  end
  return p
end

---@param path string
---@return string
local function display_path(path)
  local home = vim.fn.expand("~"):gsub("\\", "/")
  if path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

---@param path string
---@return string
local function base_name(path)
  local name = vim.fn.fnamemodify(path, ":t")
  if name == "" then
    return path
  end
  return name
end

---@param path string
---@return string[]
local function path_parts(path)
  local p = path:gsub("\\", "/")
  local parts = {}
  for part in p:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

---@param paths string[]
---@return string
local function common_dir_prefix(paths)
  if #paths == 0 then
    return ""
  end
  local all = {}
  for _, p in ipairs(paths) do
    all[#all + 1] = path_parts(p)
  end
  local n = #all[1]
  for i = 2, #all do
    if #all[i] < n then
      n = #all[i]
    end
  end
  local common = {}
  for i = 1, n do
    local part = all[1][i]
    local same = true
    for j = 2, #all do
      if all[j][i] ~= part then
        same = false
        break
      end
    end
    if not same then
      break
    end
    common[#common + 1] = part
  end
  if #common == 0 then
    return ""
  end
  local minlen = n
  for _, parts in ipairs(all) do
    if #parts < minlen then
      minlen = #parts
    end
  end
  if #common >= minlen and #common > 0 then
    table.remove(common)
  end
  if #common == 0 then
    return ""
  end
  if common[1]:match("^[A-Za-z]:$") then
    return table.concat(common, "/") .. "/"
  end
  if paths[1]:match("^/") then
    return "/" .. table.concat(common, "/") .. "/"
  end
  return table.concat(common, "/") .. "/"
end

---@param path string
---@param prefix string
---@return string
local function strip_prefix(path, prefix)
  if prefix == "" then
    return path
  end
  local p = path:gsub("\\", "/")
  if p:sub(1, #prefix) == prefix then
    local rest = p:sub(#prefix + 1)
    if rest == "" then
      return base_name(path)
    end
    return rest
  end
  return base_name(path)
end

---@return string[]
local function item_labels()
  local labels = {}
  if not state.name_only then
    for _, item in ipairs(state.list) do
      labels[#labels + 1] = display_path(item.path)
    end
    return labels
  end

  ---@type table<string, integer[]>
  local groups = {}
  for i, item in ipairs(state.list) do
    local base = base_name(item.path)
    groups[base] = groups[base] or {}
    groups[base][#groups[base] + 1] = i
  end

  ---@type table<string, string>
  local prefix_of = {}
  for base, idxs in pairs(groups) do
    if #idxs > 1 then
      local paths = {}
      for _, idx in ipairs(idxs) do
        paths[#paths + 1] = state.list[idx].path
      end
      prefix_of[base] = common_dir_prefix(paths)
    end
  end

  for _, item in ipairs(state.list) do
    local base = base_name(item.path)
    if prefix_of[base] then
      labels[#labels + 1] = strip_prefix(item.path, prefix_of[base])
    else
      labels[#labels + 1] = base
    end
  end
  return labels
end

function M.load()
  state.list = {}
  local file = data_file()
  if vim.fn.filereadable(file) == 0 then
    return
  end
  local lines = vim.fn.readfile(file)
  for _, line in ipairs(lines) do
    line = vim.trim(line)
    if line ~= "" and not line:match("^#") then
      local typ, path
      if line:match("^[fd]|") then
        typ = line:sub(1, 1)
        path = line:sub(3)
      else
        path = line
        typ = (vim.fn.isdirectory(vim.fn.expand(path)) == 1) and "d" or "f"
      end
      path = normalize_path(path)
      if path ~= "" then
        state.list[#state.list + 1] = { type = typ, path = path }
      end
    end
  end
end

function M.save()
  local lines = { "# vimplugins bookmarks: f=file d=directory" }
  for _, item in ipairs(state.list) do
    lines[#lines + 1] = item.type .. "|" .. item.path
  end
  local file = data_file()
  local dir = vim.fn.fnamemodify(file, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile(lines, file)
end

local function ensure_loaded()
  if not state.loaded_once then
    M.load()
    state.loaded_once = true
  end
end

---@param path string
---@return integer
local function find_index(path)
  path = normalize_path(path)
  for i, item in ipairs(state.list) do
    if item.path == path then
      return i
    end
  end
  return -1
end

-- ---------------------------------------------------------------------------
-- 窗口
-- ---------------------------------------------------------------------------

local function is_open()
  return state.win > 0 and vim.api.nvim_win_is_valid(state.win)
end

local function close_win()
  if is_open() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = -1
  if state.buf > 0 and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = -1
end

---@param lnum integer 1-based 窗口行号
---@return integer list 下标（1-based），无效为 -1
local function line_to_index(lnum)
  local list_idx = lnum - HEADER_LINES -- 第 3 行 → 1
  if list_idx < 1 or list_idx > #state.list then
    return -1
  end
  return list_idx
end

---@return BookmarkItem|nil
local function item_under_cursor()
  if not is_open() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  local idx = line_to_index(lnum)
  if idx < 0 then
    return nil
  end
  return state.list[idx]
end

local render

local function refresh_if_open()
  if is_open() then
    render(false)
  end
end

---@param keep_cursor boolean|nil
render = function(keep_cursor)
  if not is_open() then
    return
  end
  local keep_idx = -1
  if keep_cursor and vim.api.nvim_get_current_win() == state.win then
    keep_idx = line_to_index(vim.api.nvim_win_get_cursor(state.win)[1])
  end

  local mode = state.name_only and "短名" or "路径"
  local lines = {
    string.format("  收藏夹[%s]  <o>打开 <t>标签 <S>切换显示 <dd>删 <q>关", mode),
    "",
  }
  if #state.list == 0 then
    lines[#lines + 1] = "  (空)  用 A 收藏文件，D 收藏目录"
  else
    local labels = item_labels()
    for i, item in ipairs(state.list) do
      local mark = item.type == "d" and "[D]" or "[F]"
      local exists
      if item.type == "d" then
        exists = vim.fn.isdirectory(item.path) == 1
      else
        exists = vim.fn.filereadable(item.path) == 1
      end
      local flag = exists and " " or "!"
      lines[#lines + 1] = string.format(" %s%s %s", mark, flag, labels[i])
    end
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].modified = false

  local target
  if keep_idx >= 1 and keep_idx <= #state.list then
    target = keep_idx + HEADER_LINES
  elseif #state.list > 0 then
    target = HEADER_LINES + 1
  else
    target = 1
  end
  pcall(vim.api.nvim_win_set_cursor, state.win, { target, 0 })
end

-- ---------------------------------------------------------------------------
-- 添加 / 删除
-- ---------------------------------------------------------------------------

---@param path? string
function M.add_file(path)
  ensure_loaded()
  if not path or path == "" then
    path = vim.fn.expand("%:p")
  end
  if path == "" then
    vim.notify("bookmarks: 当前没有可收藏的文件", vim.log.levels.WARN)
    return
  end
  if vim.fn.isdirectory(path) == 1 then
    vim.notify("bookmarks: 当前路径是目录，请用 D 添加目录", vim.log.levels.WARN)
    return
  end
  path = normalize_path(path)
  if find_index(path) >= 0 then
    vim.notify("bookmarks: 已在收藏夹中: " .. display_path(path), vim.log.levels.INFO)
    return
  end
  state.list[#state.list + 1] = { type = "f", path = path }
  M.save()
  refresh_if_open()
  vim.notify("bookmarks: 已收藏文件 " .. display_path(path), vim.log.levels.INFO)
end

---@param path? string
function M.add_dir(path)
  ensure_loaded()
  if not path or path == "" then
    path = vim.fn.expand("%:p:h")
    if path == "" or path == "." then
      path = vim.fn.getcwd()
    end
  end
  if path == "" then
    vim.notify("bookmarks: 无法确定当前目录", vim.log.levels.WARN)
    return
  end
  if vim.fn.isdirectory(vim.fn.expand(path)) == 0 then
    if vim.fn.filereadable(vim.fn.expand(path)) == 1 then
      path = vim.fn.fnamemodify(vim.fn.expand(path), ":p:h")
    else
      vim.notify("bookmarks: 不是有效目录: " .. path, vim.log.levels.WARN)
      return
    end
  end
  path = normalize_path(path)
  if find_index(path) >= 0 then
    vim.notify("bookmarks: 已在收藏夹中: " .. display_path(path), vim.log.levels.INFO)
    return
  end
  state.list[#state.list + 1] = { type = "d", path = path }
  M.save()
  refresh_if_open()
  vim.notify("bookmarks: 已收藏目录 " .. display_path(path), vim.log.levels.INFO)
end

function M.add_file_from_prev()
  local prev = state.prev_buf
  if prev > 0 and vim.api.nvim_buf_is_valid(prev) then
    local path = vim.fn.expand("#" .. prev .. ":p")
    M.add_file(path)
  else
    M.add_file()
  end
end

function M.add_dir_from_prev()
  local prev = state.prev_buf
  if prev > 0 and vim.api.nvim_buf_is_valid(prev) then
    local path = vim.fn.expand("#" .. prev .. ":p:h")
    M.add_dir(path)
  else
    M.add_dir()
  end
end

function M.remove_under_cursor()
  ensure_loaded()
  if not is_open() then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  local idx = line_to_index(lnum)
  if idx < 0 then
    return
  end
  local item = state.list[idx]
  table.remove(state.list, idx)
  M.save()
  render(false)
  vim.notify("bookmarks: 已移除 " .. display_path(item.path), vim.log.levels.INFO)
end

function M.toggle_short_name()
  state.name_only = not state.name_only
  render(true)
  if state.name_only then
    vim.notify("bookmarks: 仅显示名称（重名去掉公共前缀）", vim.log.levels.INFO)
  else
    vim.notify("bookmarks: 显示完整路径", vim.log.levels.INFO)
  end
end

function M.refresh()
  M.load()
  state.loaded_once = true
  render(false)
  vim.notify("bookmarks: 已刷新", vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- 打开条目
-- ---------------------------------------------------------------------------

local function find_alt_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= state.win then
      local b = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[b].buftype
      if bt == "" or bt == "help" then
        return win
      end
    end
  end
  return nil
end

local function goto_alt_or_split()
  local wid = find_alt_window()
  if wid then
    vim.api.nvim_set_current_win(wid)
  else
    if is_open() then
      vim.api.nvim_set_current_win(state.win)
    end
    vim.cmd("leftabove vnew")
  end
end

---@param path string
---@param newtab boolean
local function open_dir(path, newtab)
  if newtab then
    vim.cmd("tabnew")
  else
    goto_alt_or_split()
  end
  if vim.fn.exists(":NERDTree") == 2 then
    vim.cmd("NERDTree " .. vim.fn.fnameescape(path))
    vim.cmd("cd " .. vim.fn.fnameescape(path))
    return
  end
  -- neo-tree 可选
  if vim.fn.exists(":Neotree") == 2 then
    vim.cmd("Neotree dir=" .. vim.fn.fnameescape(path))
    vim.cmd("cd " .. vim.fn.fnameescape(path))
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  vim.cmd("cd " .. vim.fn.fnameescape(path))
end

---@param path string
---@param newtab boolean
local function open_file(path, newtab)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("bookmarks: 文件不存在: " .. display_path(path), vim.log.levels.WARN)
  end
  if newtab then
    vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  else
    goto_alt_or_split()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

---@param newtab boolean
function M.open_item(newtab)
  local item = item_under_cursor()
  if not item then
    return
  end
  local path = item.path
  local is_dir = item.type == "d" or vim.fn.isdirectory(path) == 1
  if is_dir then
    if vim.fn.isdirectory(path) == 0 then
      vim.notify("bookmarks: 目录不存在: " .. display_path(path), vim.log.levels.ERROR)
      return
    end
    open_dir(path, newtab)
  else
    open_file(path, newtab)
  end
end

-- ---------------------------------------------------------------------------
-- buffer 映射与打开窗口
-- ---------------------------------------------------------------------------

local function setup_buffer(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "bookmarks"
  vim.bo[buf].textwidth = 0

  local wo = vim.wo[state.win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.list = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.colorcolumn = ""
  wo.cursorline = true
  -- winfix 仅较新 Neovim 支持；旧版会 E5108
  pcall(function()
    wo.winfix = "bookmarks"
  end)
  wo.statusline = " Bookmarks"

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "bookmarks: " .. desc,
    })
  end

  map("q", function()
    M.close()
  end, "close")
  map("<Esc>", function()
    M.close()
  end, "close")
  map("o", function()
    M.open_item(false)
  end, "open")
  map("<CR>", function()
    M.open_item(false)
  end, "open")
  map("t", function()
    M.open_item(true)
  end, "tab open")
  map("dd", function()
    M.remove_under_cursor()
  end, "delete")
  map("r", function()
    M.refresh()
  end, "refresh")
  map("S", function()
    M.toggle_short_name()
  end, "toggle short name")
  map("A", function()
    M.add_file_from_prev()
  end, "add file from prev")
  map("D", function()
    M.add_dir_from_prev()
  end, "add dir from prev")
end

function M.open()
  ensure_loaded()
  if vim.bo.filetype ~= "bookmarks" then
    state.prev_buf = vim.api.nvim_get_current_buf()
  end

  if is_open() then
    vim.api.nvim_set_current_win(state.win)
    render(false)
    return
  end

  local width = config.width or 36
  vim.cmd("botright vertical " .. width .. "new")
  state.win = vim.api.nvim_get_current_win()
  state.buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_set_name, state.buf, "[Bookmarks]")
  setup_buffer(state.buf)
  render(false)
end

function M.close()
  close_win()
end

function M.toggle()
  if is_open() then
    close_win()
  else
    M.open()
  end
end

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

local function clear_keys()
  for _, lhs in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", lhs)
  end
  keys_applied = {}
end

local function apply_keys()
  clear_keys()
  if config.no_mappings then
    return
  end
  local function set_key(lhs, fn, desc)
    if not lhs or lhs == false or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, fn, { silent = true, desc = "bookmarks: " .. desc })
    keys_applied[#keys_applied + 1] = lhs
  end
  set_key(config.keys_open, function()
    M.open()
  end, "open")
  set_key(config.keys_add_file, function()
    M.add_file()
  end, "add file")
  set_key(config.keys_add_dir, function()
    M.add_dir()
  end, "add dir")
end

---@param opts? table
function M.setup(opts)
  if opts then
    config = vim.tbl_deep_extend("force", config, opts)
  end
  if config.name_only ~= nil then
    state.name_only = not not config.name_only
  end
  apply_keys()
  setup_done = true
end

function M.ensure_setup()
  if not setup_done then
    M.setup()
  end
end

function M.get_config()
  return config
end

return M
