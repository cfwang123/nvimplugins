if vim.g.loaded_taskmgr then
  return
end
vim.g.loaded_taskmgr = true

local function get_mod()
  local ok, m = pcall(require, "taskmgr")
  if not ok then
    vim.notify("taskmgr: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

-- 自动 setup（注册 <leader>ta）
get_mod()

vim.api.nvim_create_user_command("Taskmgr", function()
  local m = get_mod()
  if m then
    m.open()
  end
end, { desc = "taskmgr: open process manager float" })

vim.api.nvim_create_user_command("TaskmgrRefresh", function()
  local m = get_mod()
  if m then
    m.refresh()
  end
end, { desc = "taskmgr: refresh process list" })

vim.api.nvim_create_user_command("TaskmgrClose", function()
  local m = get_mod()
  if m then
    m.close()
  end
end, { desc = "taskmgr: close process manager" })
