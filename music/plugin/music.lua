if vim.g.loaded_music then
  return
end
vim.g.loaded_music = true

local function get_mod()
  local ok, music = pcall(require, "music")
  if not ok then
    vim.notify("music: " .. tostring(music), vim.log.levels.ERROR)
    return nil
  end
  music.ensure_setup()
  return music
end

-- 加载即用默认配置（含 auto_open），无需手写 setup()
get_mod()

vim.api.nvim_create_user_command("Music", function(opts)
  local music = get_mod()
  if not music then
    return
  end
  local path = opts.args
  if path == nil or path == "" then
    path = vim.fn.expand("%:p")
  end
  if path == nil or path == "" then
    vim.notify(require("music.i18n").t("need_file"), vim.log.levels.ERROR)
    return
  end
  music.open(path)
end, {
  nargs = "?",
  complete = "file",
  desc = "在 buffer 中打开音频播放器",
})

vim.api.nvim_create_user_command("MusicToggle", function()
  local music = get_mod()
  if music then
    music.toggle()
  end
end, { desc = "播放/暂停" })

vim.api.nvim_create_user_command("MusicNext", function()
  local music = get_mod()
  if music then
    music.next()
  end
end, { desc = "同目录下一首" })

vim.api.nvim_create_user_command("MusicPrev", function()
  local music = get_mod()
  if music then
    music.prev()
  end
end, { desc = "同目录上一首" })

vim.api.nvim_create_user_command("MusicStop", function()
  local music = get_mod()
  if music then
    music.stop()
  end
end, { desc = "停止播放" })
