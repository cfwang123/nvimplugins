if vim.g.loaded_videobuf then
  return
end
vim.g.loaded_videobuf = true

local function get_mod()
  local ok, videobuf = pcall(require, "videobuf")
  if not ok then
    vim.notify("videobuf: " .. tostring(videobuf), vim.log.levels.ERROR)
    return nil
  end
  videobuf.ensure_setup()
  return videobuf
end

get_mod()

vim.api.nvim_create_user_command("Videobuf", function(opts)
  local vb = get_mod()
  if not vb then
    return
  end
  local path = opts.args
  if path == nil or path == "" then
    path = vim.fn.expand("%:p")
  end
  if path == nil or path == "" then
    vim.notify("videobuf: 请指定视频路径", vim.log.levels.ERROR)
    return
  end
  vb.open(path)
end, {
  nargs = "?",
  complete = "file",
  desc = "打开内嵌视频播放器",
})

vim.api.nvim_create_user_command("VideobufToggle", function()
  local vb = get_mod()
  if vb then
    vb.toggle()
  end
end, { desc = "播放/暂停" })

vim.api.nvim_create_user_command("VideobufStop", function()
  local vb = get_mod()
  if vb then
    vb.stop()
  end
end, { desc = "停止" })

vim.api.nvim_create_user_command("VideobufNext", function()
  local vb = get_mod()
  if vb then
    vb.next()
  end
end, { desc = "同目录下一个视频" })

vim.api.nvim_create_user_command("VideobufPrev", function()
  local vb = get_mod()
  if vb then
    vb.prev()
  end
end, { desc = "同目录上一个视频" })

vim.api.nvim_create_user_command("VideobufClose", function()
  local vb = get_mod()
  if vb then
    vb.close()
  end
end, { desc = "关闭 videobuf" })

vim.api.nvim_create_user_command("VideobufFps", function(opts)
  local vb = get_mod()
  if not vb then
    return
  end
  local arg = vim.trim(opts.args or "")
  if arg == "" then
    vb.set_fps(nil)
    return
  end
  vb.set_fps(tonumber(arg))
end, { nargs = "?", desc = "设置/查看目标 FPS" })
