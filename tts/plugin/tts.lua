if vim.g.loaded_tts then
  return
end
vim.g.loaded_tts = true

local function get_mod()
  local ok, tts = pcall(require, "tts")
  if not ok then
    vim.notify("tts: " .. tostring(tts), vim.log.levels.ERROR)
    return nil
  end
  tts.ensure_setup()
  return tts
end

get_mod()

vim.api.nvim_create_user_command("TTS", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local text = opts.args
  if text == nil or text == "" then
    text = vim.api.nvim_get_current_line()
  end
  m.cmd_speak(text)
end, {
  nargs = "*",
  desc = "tts: speak text via Windows SAPI",
})

vim.api.nvim_create_user_command("TTSStop", function()
  local m = get_mod()
  if m then
    m.stop_all()
  end
end, { desc = "tts: stop speech and close preview" })

vim.api.nvim_create_user_command("TTSVoices", function()
  local m = get_mod()
  if not m then
    return
  end
  local engine = require("tts.engine")
  engine.ensure()
  engine.list_voices()
  vim.defer_fn(function()
    local st = engine.get_state()
    local lines = { "SAPI voices:" }
    for _, v in ipairs(st.voices or {}) do
      lines[#lines + 1] = string.format("  [%d] %s", v.index or 0, v.name or "?")
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, 300)
end, { desc = "tts: list SAPI voices" })

-- 启动时检测 pip 依赖并提示安装（仅 Windows）
do
  local _dep_plugin = "tts"
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
