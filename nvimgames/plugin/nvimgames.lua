if vim.g.loaded_nvimgames then
  return
end
vim.g.loaded_nvimgames = true

local function ensure_setup()
  local ok, ng = pcall(require, "nvimgames")
  if not ok then
    vim.notify("nvimgames: " .. tostring(ng), vim.log.levels.ERROR)
    return nil
  end
  if not vim.g.nvimgames_setup_done then
    ng.setup()
  end
  return ng
end

vim.api.nvim_create_user_command("Mine", function(opts)
  if not ensure_setup() then
    return
  end
  local mine = require("nvimgames.mine")
  mine.open({ difficulty = mine.resolve_difficulty(opts.args) })
end, {
  nargs = "?",
  complete = function()
    return { "beginner", "intermediate", "expert", "初级", "中级", "高级" }
  end,
  desc = "打开扫雷（beginner/intermediate/expert）",
})

vim.api.nvim_create_user_command("Sokoban", function(opts)
  if not ensure_setup() then
    return
  end
  local n = tonumber(opts.args)
  if n then
    require("nvimgames.sokoban").open({ level = n })
  else
    require("nvimgames.sokoban").open({})
  end
end, {
  nargs = "?",
  desc = "打开推箱子（无参=上次关卡，有参=指定关卡号）",
})

vim.api.nvim_create_user_command("Game24", function()
  if not ensure_setup() then
    return
  end
  require("nvimgames.twentyfour").open({})
end, {
  desc = "打开 24 点小游戏",
})

vim.api.nvim_create_user_command("Tetris", function(opts)
  if not ensure_setup() then
    return
  end
  local arg = vim.trim(opts.args or ""):lower()
  local versus = arg == "vs"
    or arg == "versus"
    or arg == "pve"
    or arg == "ai"
    or arg == "对战"
    or arg == "人机"
  require("nvimgames.tetris").open({ mode = versus and "versus" or "solo" })
end, {
  nargs = "?",
  complete = function()
    return { "vs", "versus", "solo", "对战", "人机" }
  end,
  desc = "打开俄罗斯方块（:Tetris vs = 人机对战）",
})

vim.api.nvim_create_user_command("NvimGames", function(opts)
  if not ensure_setup() then
    return
  end
  local arg = vim.trim(opts.args or "")
  local lower = arg:lower()
  local menu = require("nvimgames.menu")

  if arg == "" then
    menu.open()
    return
  end

  if lower == "mine" or arg == "扫雷" or arg == "1" then
    menu.open_by_id("mine")
  elseif lower == "sokoban" or arg == "推箱子" or arg == "2" then
    menu.open_by_id("sokoban")
  elseif lower == "game24" or lower == "twentyfour" or lower == "24" or arg == "24点" or arg == "3" then
    menu.open_by_id("twentyfour")
  elseif lower == "tetris" or arg == "俄罗斯方块" or arg == "方块" or arg == "4" then
    menu.open_by_id("tetris")
  else
    vim.notify("nvimgames: 未知 '" .. arg .. "'（1–4 / mine / sokoban / game24 / tetris）", vim.log.levels.WARN)
  end
end, {
  nargs = "?",
  complete = function()
    return {
      "mine",
      "sokoban",
      "game24",
      "tetris",
      "扫雷",
      "推箱子",
      "24点",
      "俄罗斯方块",
      "1",
      "2",
      "3",
      "4",
    }
  end,
  desc = "打开 nvimgames 选单（float；数字选择 / Esc 退出）",
})
