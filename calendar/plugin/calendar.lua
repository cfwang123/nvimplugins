if vim.g.loaded_calendar then
  return
end
vim.g.loaded_calendar = true

local function get_mod()
  local ok, m = pcall(require, "calendar")
  if not ok then
    vim.notify("calendar: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

-- 自动 setup：注册默认快捷键
get_mod()

vim.api.nvim_create_user_command("Calendar", function()
  local m = get_mod()
  if m then
    m.open()
  end
end, { desc = "calendar: open month float" })

vim.api.nvim_create_user_command("CalendarClose", function()
  local m = get_mod()
  if m then
    m.close()
  end
end, { desc = "calendar: close float" })
