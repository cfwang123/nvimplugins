---@mod pdfview.config
local M = {}

---@class PdfViewImageConfig
---@field mode "thumb"|"placeholder"|"off"
---@field backend "auto"|"chafa"|"python"|"none"
---@field max_height number
---@field max_width number|nil
---@field max_images number
---@field cell_aspect number
---@field python string
---@field open_with "float"|"none"
---@field float_scale "fill"|"fit"
---@field float_hd "always"|"never"
---@field hd_tmux boolean
---@field hd_ssh boolean

---@class PdfViewConfig
---@field auto_open boolean
---@field python string
---@field max_pages number 0=全部
---@field table_style "unicode"|"ascii"|"minimal"
---@field page_sep boolean
---@field show_help boolean
---@field wrap boolean
---@field winopts table
---@field image PdfViewImageConfig
---@field keys table|false|nil
---@field highlights table|nil

local defaults = {
  auto_open = true,
  python = "python",
  max_pages = 0, -- 0 = 全部页
  table_style = "unicode",
  page_sep = true,
  show_help = true,
  wrap = true,
  --- 界面语言："auto" | "zh" | "en"；L 切换
  ui_lang = "auto",
  winopts = {
    number = false,
    relativenumber = false,
    wrap = false,
    cursorline = false,
    signcolumn = "no",
    foldcolumn = "0",
    list = false,
    sidescrolloff = 0,
    sidescroll = 1,
  },
  image = {
    mode = "thumb",
    -- 默认 chafa；无 chafa 时回退 python+Pillow
    backend = "chafa",
    max_height = 0, -- 0 = 按宽比例
    max_width = nil, -- nil = 窗口宽
    max_images = 30,
    cell_aspect = 0.5,
    python = "python",
    open_with = "float", -- Enter/点击/gi → float 大图
    float_scale = "fill", -- fill 拉伸 | fit 等比
    -- float 内高清：终端支持则 always（与 mdview 一致）
    float_hd = "always",
    hd_tmux = false,
    hd_ssh = false,
  },
  keys = {
    open = false, -- 无默认全局键；用 :PdfView / 自动打开
  },
  highlights = nil,
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
  local i18n = require("pdfview.i18n")
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
