---@mod ntemoji NERDTree emoji icons (no Nerd Font / vim-devicons)
local M = {}

---@class NtemojiConfig
---@field enabled boolean
---@field folder_closed string
---@field folder_open string
---@field folder_symlink string
---@field default_file string
---@field before string 图标前空格
---@field after string 图标后空格
---@field exact table<string,string> 精确文件名（小写）
---@field extension table<string,string> 扩展名（小写，无点）
---@field open_close boolean 目录开合用不同图标（需 path.isOpen，尽力而为）
---@field conceal_brackets boolean 隐藏 NERDTree 包在图标外的 []（默认 true）

local default_config = {
  enabled = true,
  folder_closed = "📁",
  folder_open = "📂",
  folder_symlink = "📁",
  default_file = "📄",
  before = " ",
  after = " ",
  open_close = true,
  --- NERDTree 会把 flag 渲染成 [📁 ]，用 syntax conceal 藏掉 []
  conceal_brackets = true,
  exact = {
    ["node_modules"] = "📦",
    [".gitignore"] = "🙈",
    [".git"] = "📦",
    ["dockerfile"] = "🐳",
    ["makefile"] = "🔧",
    ["license"] = "📜",
    ["readme"] = "📝",
    ["readme.md"] = "📝",
  },
  extension = {
    txt = "📄",
    xml = "📄",
    js = "📄",
    ts = "📄",
    jsx = "📄",
    tsx = "📄",
    json = "📋",
    md = "📝",
    markdown = "📝",
    tutor = "📘",
    css = "📝",
    scss = "📝",
    less = "📝",
    html = "📝",
    htm = "📝",
    py = "📄",
    lua = "📄",
    c = "📄",
    cc = "📄",
    cpp = "📄",
    cxx = "📄",
    h = "📄",
    hpp = "📄",
    cs = "📄",
    java = "📄",
    go = "📄",
    rs = "📄",
    rb = "📄",
    php = "📄",
    sh = "📄",
    bash = "📄",
    zsh = "📄",
    ps1 = "📄",
    bat = "📄",
    cmd = "📄",
    vim = "📄",
    yml = "📄",
    yaml = "📄",
    toml = "📄",
    ini = "📄",
    conf = "⚙️",
    cfg = "⚙️",
    sql = "📄",
    db = "🗃️",
    sqlite = "🗃️",
    svg = "🖼️",
    png = "🖼️",
    jpg = "🖼️",
    jpeg = "🖼️",
    gif = "🖼️",
    ico = "🖼️",
    webp = "🖼️",
    bmp = "🖼️",
    zip = "📦",
    tar = "📦",
    gz = "📦",
    tgz = "📦",
    rar = "📦",
    ["7z"] = "📦",
    exe = "▶️",
    dll = "🔩",
    so = "🔩",
    pdf = "📕",
    lock = "🔒",
    log = "📄",
    csv = "📊",
    xls = "📊",
    xlsx = "📊",
    doc = "📘",
    docx = "📘",
    ppt = "📙",
    pptx = "📙",
    mp3 = "🎵",
    wav = "🎵",
    flac = "🎵",
    mid = "🎵",
    midi = "🎵",
    mp4 = "🎬",
    mkv = "🎬",
    avi = "🎬",
    webm = "🎬",
  },
}

local config = vim.deepcopy(default_config)
local setup_done = false
local listeners_ok = false

local function basename(path)
  path = path:gsub("[/\\]+$", "")
  return path:match("([^/\\]+)$") or path
end

local function extension(path)
  local name = basename(path)
  local ext = name:match("%.([^.]+)$")
  if not ext then
    return ""
  end
  return ext:lower()
end

---文件图标
---@param path string
---@return string
function M.file_icon(path)
  if not path or path == "" then
    return config.default_file
  end
  local name = basename(path):lower()
  if config.exact[name] then
    return config.exact[name]
  end
  -- readme.md 等已在 exact；再试无扩展 stem
  local stem = name:match("^([^%.]+)") or name
  if config.exact[stem] then
    return config.exact[stem]
  end
  local ext = extension(path)
  if ext ~= "" and config.extension[ext] then
    return config.extension[ext]
  end
  return config.default_file
end

---目录图标
---@param path string
---@param is_open? boolean
---@param is_symlink? boolean
---@return string
function M.folder_icon(path, is_open, is_symlink)
  if is_symlink then
    return config.folder_symlink
  end
  if config.open_close and is_open then
    return config.folder_open
  end
  local name = basename(path or ""):lower()
  if config.exact[name] then
    return config.exact[name]
  end
  return config.folder_closed
end

---供 Vim 回调：根据 NERDTree path 对象属性生成 glyph
---args: path_str, is_directory (0/1), is_open (0/1/-1), is_symlink (0/1)
---@return string
function M.glyph(path_str, is_directory, is_open, is_symlink)
  path_str = tostring(path_str or "")
  local dir = tonumber(is_directory) == 1 or is_directory == true
  local open = tonumber(is_open) == 1 or is_open == true
  local link = tonumber(is_symlink) == 1 or is_symlink == true
  if dir then
    return M.folder_icon(path_str, open, link)
  end
  return M.file_icon(path_str)
end

---在 path.flagSet 上写入图标（由 Vimscript 调用，需 path 为 Vim 对象）
---此函数仅返回完整 flag 字符串
function M.flag_string(path_str, is_directory, is_open, is_symlink)
  local g = M.glyph(path_str, is_directory, is_open, is_symlink)
  return (config.before or " ") .. g .. (config.after or " ")
end

function M.get_config()
  return config
end

---是否检测到 vim-devicons（已加载或在 runtimepath 上）
---@return boolean
function M.devicons_present()
  if vim.g.ntemoji_force == 1 then
    return false
  end
  local ok, present = pcall(vim.fn["ntemoji#devicons_present"])
  if ok then
    return present == 1 or present == true
  end
  -- 无 autoload 时的兜底
  if vim.g.loaded_webdevicons == 1 then
    return true
  end
  if vim.fn.exists("*WebDevIconsGetFileTypeSymbol") == 1 then
    return true
  end
  local files = vim.api.nvim_get_runtime_file("plugin/webdevicons.vim", true)
  if files and #files > 0 then
    return true
  end
  files = vim.api.nvim_get_runtime_file("nerdtree_plugin/webdevicons.vim", true)
  return files and #files > 0
end

---@param user? NtemojiConfig
function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  setup_done = true
  -- 已装 devicons → 整插件关闭
  if config.enabled and M.devicons_present() then
    config.enabled = false
    vim.g.ntemoji_enabled = 0
    if not vim.g.ntemoji_skipped_devicons then
      vim.g.ntemoji_skipped_devicons = 1
      -- 安静跳过：不刷屏；需要提示可设 g:ntemoji_notify_skip = 1
      if vim.g.ntemoji_notify_skip == 1 then
        vim.schedule(function()
          vim.notify("ntemoji: vim-devicons detected, disabled", vim.log.levels.INFO)
        end)
      end
    end
  else
    vim.g.ntemoji_enabled = config.enabled and 1 or 0
  end
  vim.g.ntemoji_before = config.before
  vim.g.ntemoji_after = config.after
  vim.g.ntemoji_conceal_brackets = config.conceal_brackets and 1 or 0
  if config.enabled then
    M.ensure_listeners()
  end
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
end

---注册 NERDTree 监听（可重复调用）
function M.ensure_listeners()
  if not setup_done then
    M.ensure_setup()
  end
  if not config.enabled or vim.g.ntemoji_enabled == 0 then
    return false
  end
  -- 再次检测（devicons 可能后于 ntemoji 加载）
  if M.devicons_present() then
    config.enabled = false
    vim.g.ntemoji_enabled = 0
    listeners_ok = false
    return false
  end
  if listeners_ok then
    return true
  end
  if vim.g.NERDTreePathNotifier == nil then
    return false
  end
  local ok, ret = pcall(function()
    return vim.fn["ntemoji#register"]()
  end)
  if ok and (ret == 1 or ret == true) then
    listeners_ok = true
    return true
  end
  return false
end

function M.is_enabled()
  return config.enabled and vim.g.ntemoji_enabled ~= 0 and not M.devicons_present()
end

return M
