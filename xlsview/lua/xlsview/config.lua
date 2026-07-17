---@mod xlsview.config
local M = {}

local defaults = {
  auto_open = true,
  python = "python",
  max_rows = 500, -- 每表最多行
  max_cols = 64, -- 每表最多列
  table_style = "unicode", -- unicode | ascii | minimal
  header_row = true, -- 首行当表头样式
  show_grid = true,
  show_row_numbers = false, -- 左侧 Excel 行号
  freeze_hint = true,
  --- 列宽：默认不按窗口挤压（横向滚动看全表）；true=旧行为压进窗口
  fit_to_window = false,
  --- 单列最小显示宽度（字符格）；fit 时也不会压到更小
  min_col_width = 6,
  --- 单列最大宽度（内容再长也截断到此）
  max_col_width = 28,
  --- 界面语言："auto" | "zh" | "en"；L 切换
  ui_lang = "auto",
  winopts = {
    number = false,
    relativenumber = false,
    wrap = false,
    cursorline = true,
    signcolumn = "no",
    foldcolumn = "0",
    list = false,
    sidescrolloff = 2,
    sidescroll = 1,
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

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user or {})
  local i18n = require("xlsview.i18n")
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
