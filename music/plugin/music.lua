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

-- 加载即用默认配置（含 auto_open / MIDI）；命令在 setup() 内注册
get_mod()

-- 启动时检测 pip 依赖并提示安装
do
  local _dep_plugin = "music"
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
