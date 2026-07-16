if vim.g.loaded_drawbuf then
  return
end
vim.g.loaded_drawbuf = true

local function get_mod()
  local ok, drawbuf = pcall(require, "drawbuf")
  if not ok then
    vim.notify("drawbuf: " .. tostring(drawbuf), vim.log.levels.ERROR)
    return nil
  end
  -- 插件加载即用默认配置；用户可之后 setup({...}) 覆盖
  drawbuf.ensure_setup()
  return drawbuf
end

-- 进入 rtp 时自动初始化，无需手写 setup()
get_mod()

vim.api.nvim_create_user_command("Draw", function(opts)
  local drawbuf = get_mod()
  if not drawbuf then
    return
  end
  if opts.args and opts.args ~= "" then
    local a = opts.args
    if vim.fn.filereadable(a) == 1 then
      drawbuf.open_file(a)
    else
      local w, h = a:match("^(%d+)x(%d+)$")
      if w then
        drawbuf.open({ width = tonumber(w), height = tonumber(h) })
      else
        drawbuf.open_file(a)
      end
    end
  else
    drawbuf.open({})
  end
end, {
  nargs = "?",
  complete = "file",
  desc = "打开绘图画布（默认适应窗口并留白边）",
})
