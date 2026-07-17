if vim.g.loaded_httpbuf then
  return
end
vim.g.loaded_httpbuf = true

local function get_mod()
  local ok, m = pcall(require, "httpbuf")
  if not ok then
    vim.notify("httpbuf: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

get_mod()

vim.api.nvim_create_user_command("HttpBuf", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local arg = vim.trim(opts.args or "")
  if arg ~= "" then
    m.open({ text = arg })
  else
    m.open({})
  end
end, {
  nargs = "*",
  desc = "httpbuf: open HTTP request editor",
})

vim.api.nvim_create_user_command("Http", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local arg = vim.trim(opts.args or "")
  if arg ~= "" then
    m.open({ text = arg })
  else
    m.open({})
  end
end, {
  nargs = "*",
  desc = "httpbuf: alias of HttpBuf",
})

vim.api.nvim_create_user_command("HttpSend", function()
  local m = get_mod()
  if m then
    m.send_current_buf()
  end
end, { desc = "httpbuf: send current request buffer" })
