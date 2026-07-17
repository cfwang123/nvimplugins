if vim.g.loaded_imgbuf then
  return
end
vim.g.loaded_imgbuf = true

local function get_mod()
  local ok, imgbuf = pcall(require, "imgbuf")
  if not ok then
    vim.notify("imgbuf: " .. tostring(imgbuf), vim.log.levels.ERROR)
    return nil
  end
  -- 插件加载即用默认配置；用户可之后 setup({...}) 覆盖
  imgbuf.ensure_setup()
  return imgbuf
end

-- 进入 rtp 时自动初始化（auto_open 等），无需手写 setup()
get_mod()

vim.api.nvim_create_user_command("Imgbuf", function(opts)
  local imgbuf = get_mod()
  if not imgbuf then
    return
  end
  local path = opts.args
  if path == nil or path == "" then
    path = vim.fn.expand("%:p")
  end
  imgbuf.open(path)
end, {
  nargs = "?",
  complete = "file",
  desc = "Open image with chafa-style buffer renderer",
})

vim.api.nvim_create_user_command("ImgbufClipboard", function()
  local imgbuf = get_mod()
  if not imgbuf then
    return
  end
  imgbuf.open_clipboard()
end, {
  desc = "Preview image from system clipboard",
})

vim.api.nvim_create_user_command("ImgbufAnimTest", function(opts)
  local imgbuf = get_mod()
  if not imgbuf then
    return
  end
  local fps = tonumber(opts.args)
  if opts.args ~= nil and opts.args ~= "" and not fps then
    vim.notify("imgbuf: ImgbufAnimTest 参数为 fps 数字，例如 :ImgbufAnimTest 10", vim.log.levels.ERROR)
    return
  end
  require("imgbuf.animtest").start({ fps = fps or 10 })
end, {
  nargs = "?",
  desc = "全刷屏动画测试（默认 10fps；q 退出 Space 暂停）",
})
