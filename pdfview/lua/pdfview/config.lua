---@mod pdfview.config
local M = {}

---@class PdfViewImageConfig
---@field mode "thumb"|"placeholder"|"off"
---@field backend "python"|"none" 字符画仅 Python+Pillow（auto/chafa 兼容映射为 python）
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
---@field lazy_render boolean 大文档只渲染视口附近页
---@field lazy_threshold number 页数 ≥ 此值才启用懒渲染（默认 12）
---@field viewport_buffer number 可见页上下各多渲染几页（默认 2）
---@field extract_chunk number PDF 打开时先同步提取的页数（默认 8）
---@field stub_page_lines number 未提取页占位行数（默认 36，使滚动比例接近真实页序）
---@field toc boolean 有大纲时默认打开左侧 TOC（默认 true）
---@field toc_width number TOC 窗宽度（列，默认 32）
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
  max_pages = 0, -- 0 = 全部页（提取上限；0 不限制）
  -- 大 PDF：按页懒提取 + 视口懒渲染；远处页占位，滚近再展开
  lazy_render = true,
  lazy_threshold = 12,
  viewport_buffer = 2,
  extract_chunk = 8, -- 打开时先抽前 N 页（同步，避免卡死上千页）
  stub_page_lines = 36, -- 未加载页等高占位，滚动约 50% ≈ 中间页
  toc = true, -- 有 PDF 大纲时默认开左侧 TOC
  toc_width = 32,
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
    -- 字符画：Python+Pillow（thumb.py）；none 关闭
    backend = "python",
    max_height = 0, -- 0 = 按宽比例
    max_width = nil, -- nil = 窗口宽
    max_images = 30,
    cell_aspect = 0.5,
    python = "python",
    open_with = "float", -- Enter/点击/gi → float 大图
    float_scale = "fit", -- fit 等比 | fill 拉伸
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
