if vim.g.loaded_xlsview then
  return
end
vim.g.loaded_xlsview = true

pcall(function()
  require("xlsview.zipfix").preempt()
end)

local function get_mod()
  local ok, m = pcall(require, "xlsview")
  if not ok then
    vim.notify("xlsview: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

get_mod()

vim.api.nvim_create_user_command("XlsView", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local path = opts.args
  if path == nil or path == "" then
    path = vim.fn.expand("%:p")
  else
    path = vim.fn.fnamemodify(path, ":p")
  end
  m.open(path)
end, {
  nargs = "?",
  complete = "file",
  desc = "xlsview: open Excel (.xlsx) preview",
})

vim.api.nvim_create_user_command("XlsViewRefresh", function()
  local m = get_mod()
  if m then
    m.refresh(nil, true)
  end
end, { desc = "xlsview: re-extract and render" })

vim.api.nvim_create_user_command("XlsViewClose", function()
  local m = get_mod()
  if m then
    m.close()
  end
end, { desc = "xlsview: close preview" })
