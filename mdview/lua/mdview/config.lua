---@mod mdview.config
local M = {}

---@class MdViewImageConfig
---@field mode "thumb"|"placeholder"|"off"
---@field max_height number
---@field max_width number|nil
---@field max_images number
---@field backend "auto"|"chafa"|"python"|"none"
---@field palette_size number
---@field open_with "float"|"edit"|"none"
---@field python string
---@field hd "never" 预览内不叠高清（固定 never）
---@field float_hd "always"|"never" float 内高清，默认 always
---@field float_scale "fill"|"fit"
---@field hd_tmux boolean
---@field hd_ssh boolean
---@field graphics_tmux boolean
---@field graphics_ssh boolean

---@class MdViewHtmlConfig
---@field img boolean
---@field details boolean
---@field details_default_open boolean
---@field details_max_depth number
---@field unknown "raw"|"hide"|"comment"

---@class MdViewConfig
---@field split_direction "left"|"right"
---@field width number
---@field winopts table
---@field debounce_ms number
---@field heading_conceal boolean
---@field list_bullets string[]
---@field table_style "unicode"|"ascii"|"minimal"
---@field strikethrough boolean
---@field mark_highlight boolean
---@field toc boolean
---@field toc_min_level number
---@field toc_max_level number
---@field toc_position "top"|"none"
---@field code_border boolean
---@field code_lang_position string
---@field code_line_numbers boolean
---@field code_fold_lines number
---@field code_highlight "auto"|"treesitter"|"syntax"|"none"
---@field sync_scroll boolean
---@field sync_cursor_block boolean
---@field sync_reverse boolean
---@field image MdViewImageConfig
---@field html MdViewHtmlConfig
---@field highlights table|nil
---@field auto_side_open boolean
---@field keys { view?: string|false, side?: string|false, toc?: string|false } 全局快捷键；false 关闭该项

local defaults = {
  split_direction = "right",
  width = 0.45,
  -- 全局快捷键（setup 时注册）；设为 false 可关闭
  keys = {
    view = "<leader>mv", -- :MdView 单窗预览
    side = "<leader>ms", -- :MdSideView 侧边预览
    toc = "<leader>toc", -- 编辑窗 / 任意处：弹出 TOC float
  },
  winopts = {
    number = false,
    relativenumber = false,
    wrap = false, -- 内容已按窗口宽软折行；变宽时 WinResized 重排
    cursorline = false,
    signcolumn = "no",
    foldcolumn = "0",
    list = false,
    sidescrolloff = 0,
    sidescroll = 1,
  },
  debounce_ms = 150,
  --- 磁盘上 md 被外部程序修改时自动 reload 源 buffer 并重绘预览
  watch_external = true,
  show_help = true, -- ? 打开帮助 float
  show_key_hint = true, -- 预览顶部灰色快捷键提示行
  --- 界面语言："auto"（跟随系统）| "zh" | "en"；L 可切换并记住
  ui_lang = "auto",
  heading_conceal = true,
  list_bullets = { "●", "○" }, -- 第1层 ●，第2层及以后 ○
  table_style = "unicode",
  strikethrough = true,
  mark_highlight = true,
  toc = true,
  toc_min_level = 1,
  toc_max_level = 3,
  toc_position = "top",
  code_border = true,
  code_lang_position = "top_right",
  code_line_numbers = true,
  code_fold_lines = 10,
  code_highlight = "auto",
  sync_scroll = true,
  sync_cursor_block = true,
  sync_reverse = true,
  image = {
    mode = "thumb",
    -- 0 = 高度完全按宽 100% 比例；>0 时高度不超过该值（宽仍 100%）
    max_height = 0,
    max_width = nil, -- nil = 预览宽 100%
    max_images = 20,
    backend = "auto",
    palette_size = 64,
    thumb_scale = "width_full", -- width_full=宽100%高自适应；stretch=拉满
    -- 终端单元格 宽/高（约 0.5）。修正把字符格当正方形导致的图像比例失真
    cell_aspect = 0.5,
    open_with = "float",
    float_scale = "fill", -- float 内高清/█：fill 拉伸 | fit 等比
    python = "python",
    -- 预览内不做高清叠层（仅 █）
    hd = "never",
    -- float 高清：always=终端支持则叠像素图（默认开）
    float_hd = "always",
    hd_tmux = false,
    hd_ssh = false,
    graphics_tmux = false,
    graphics_ssh = false,
  },
  html = {
    img = true,
    details = true,
    details_default_open = false,
    details_max_depth = 8,
    unknown = "raw",
  },
  highlights = nil,
  auto_side_open = false,
}

local config = vim.deepcopy(defaults)
local setup_done = false

function M.defaults()
  return vim.deepcopy(defaults)
end

function M.get()
  return config
end

function M.is_setup()
  return setup_done
end

---@param user table|nil
function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user or {})
  local i18n = require("mdview.i18n")
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
  setup_done = true
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

return M
