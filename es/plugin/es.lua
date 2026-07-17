if vim.g.loaded_es then
  return
end
vim.g.loaded_es = true

local function get_mod()
  local ok, es = pcall(require, "es")
  if not ok then
    vim.notify("es: " .. tostring(es), vim.log.levels.ERROR)
    return nil
  end
  es.ensure_setup()
  return es
end

-- 进入 rtp 时自动初始化（默认快捷键 <leader>es）
get_mod()

vim.api.nvim_create_user_command("ES", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local q = vim.trim(opts.args or "")
  if q == "" then
    m.open({})
  else
    m.open({ query = q })
  end
end, {
  nargs = "*",
  desc = "es: search files via Everything (es.exe)",
})

vim.api.nvim_create_user_command("Es", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local q = vim.trim(opts.args or "")
  if q == "" then
    m.open({})
  else
    m.open({ query = q })
  end
end, {
  nargs = "*",
  desc = "es: search files via Everything (es.exe)",
})
