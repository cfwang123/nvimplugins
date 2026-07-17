if vim.g.loaded_mixer then
  return
end
vim.g.loaded_mixer = true

local function get_mod()
  local ok, mixer = pcall(require, "mixer")
  if not ok then
    vim.notify("mixer: " .. tostring(mixer), vim.log.levels.ERROR)
    return nil
  end
  mixer.ensure_setup()
  return mixer
end

get_mod()

vim.api.nvim_create_user_command("Mixer", function(opts)
  local mixer = get_mod()
  if not mixer then
    return
  end
  local arg = vim.trim(opts.args or "")
  if arg == "" then
    mixer.open({ play = false })
    return
  end
  -- preset id or file path
  if vim.fn.filereadable(arg) == 1 then
    mixer.play_file(vim.fn.fnamemodify(arg, ":p"))
  else
    mixer.play_preset(arg)
  end
end, {
  nargs = "?",
  complete = function(arglead)
    local list = {
      "twinkle",
      "ode",
      "scales",
      "groove",
      "sakura",
    }
    local out = {}
    for _, s in ipairs(list) do
      if s:find(arglead, 1, true) == 1 then
        out[#out + 1] = s
      end
    end
    return out
  end,
  desc = "打开 MIDI 播放器；参数为预设名或 .mid 路径",
})

vim.api.nvim_create_user_command("MixerStop", function()
  local mixer = get_mod()
  if mixer then
    require("mixer.player").stop()
  end
end, { desc = "停止混音器播放" })

-- 启动时检测 pip 依赖并提示安装
do
  local _dep_plugin = "mixer"
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
