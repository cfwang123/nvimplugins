if vim.g.loaded_tablemode then
  return
end
vim.g.loaded_tablemode = true

local function get_mod()
  local ok, m = pcall(require, "tablemode")
  if not ok then
    vim.notify("tablemode: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

-- 进入 rtp 时自动 setup（注册默认快捷键）
get_mod()

vim.api.nvim_create_user_command("TableModeToggle", function()
  local m = get_mod()
  if m then
    m.toggle()
  end
end, { desc = "tablemode: toggle table mode" })

vim.api.nvim_create_user_command("TableModeEnable", function()
  local m = get_mod()
  if m then
    m.enable()
  end
end, { desc = "tablemode: enable table mode" })

vim.api.nvim_create_user_command("TableModeDisable", function()
  local m = get_mod()
  if m then
    m.disable()
  end
end, { desc = "tablemode: disable table mode" })

vim.api.nvim_create_user_command("TableModeRealign", function()
  local m = get_mod()
  if m then
    m.realign()
  end
end, { desc = "tablemode: realign table under cursor" })

vim.api.nvim_create_user_command("Tableize", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local delim = nil
  local args = vim.trim(opts.args or "")
  -- 支持 :Tableize/;  或 :Tableize ,
  if args ~= "" then
    if args:sub(1, 1) == "/" then
      delim = args:sub(2)
    else
      delim = args
    end
  end
  local l1 = opts.line1
  local l2 = opts.line2
  if delim then
    m.tableize(l1, l2, delim)
  else
    m.tableize(l1, l2)
  end
end, {
  nargs = "?",
  range = true,
  desc = "tablemode: convert lines to table (optional delimiter)",
})
