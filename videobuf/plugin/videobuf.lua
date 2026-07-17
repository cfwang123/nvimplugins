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

-- 启动时检测 pip 依赖并提示安装
do
  local _dep_plugin = "videobuf"
  local _dep_src = debug.getinfo(1, "S").source
  vim.defer_fn(function()
    if vim.g.nvimplugins_skip_deps or vim.g.nvimplugins_deps_bundle_done then
      return
    end
    local ok, dc = pcall(require, "nvimplugins.depcheck")
    if not ok or type(dc) ~= "table" then
      local src = _dep_src
      if type(src) == "string" and src:sub(1, 1) == "@" then
        src = src:sub(2)
      end
      local dir = vim.fn.fnamemodify(src, ":p:h")
      for _ = 1, 8 do
        local f = dir .. "/lua/nvimplugins/depcheck.lua"
        if vim.fn.filereadable(f) == 1 then
          local chunk = loadfile(f)
          if chunk then
            dc = chunk()
            package.loaded["nvimplugins.depcheck"] = dc
            ok = true
          end
          break
        end
        local parent = vim.fn.fnamemodify(dir, ":h")
        if parent == dir then
          break
        end
        dir = parent
      end
    end
    if ok and dc and dc.schedule then
      dc.schedule(_dep_plugin, 0, _dep_src)
    end
  end, 550)
end
