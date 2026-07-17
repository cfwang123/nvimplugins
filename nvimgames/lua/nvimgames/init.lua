---@mod nvimgames Neovim 小游戏合集
local M = {}

local default_config = {
  lang = "auto", ---@type "zh"|"en"|"auto"
  mine = {},
  sokoban = {},
  twentyfour = {},
  tetris = {},
}

local config = vim.deepcopy(default_config)

---@param user? { lang?: "zh"|"en"|"auto", mine?: table, sokoban?: table, twentyfour?: table, tetris?: table }
function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  local i18n = require("nvimgames.i18n")
  if config.lang == "zh" or config.lang == "en" then
    i18n.setup(config.lang)
  else
    i18n.setup(nil)
  end
  require("nvimgames.mine").setup(config.mine)
  require("nvimgames.sokoban").setup(config.sokoban)
  require("nvimgames.twentyfour").setup(config.twentyfour)
  require("nvimgames.tetris").setup(config.tetris)
  vim.g.nvimgames_setup_done = true
end

function M.open_mine(opts)
  return require("nvimgames.mine").open(opts)
end

function M.open_sokoban(opts)
  return require("nvimgames.sokoban").open(opts)
end

function M.open_twentyfour(opts)
  return require("nvimgames.twentyfour").open(opts)
end

function M.open_tetris(opts)
  return require("nvimgames.tetris").open(opts)
end

function M.open_menu()
  return require("nvimgames.menu").open()
end

function M.config()
  return config
end

function M.toggle_lang()
  local i18n = require("nvimgames.i18n")
  i18n.toggle()
  return i18n.get()
end

return M
