if vim.g.loaded_colorpicker then
  return
end
vim.g.loaded_colorpicker = true

local function get_mod()
  local ok, m = pcall(require, "colorpicker")
  if not ok then
    vim.notify("colorpicker: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

-- 自动 setup：注册默认快捷键
get_mod()

vim.api.nvim_create_user_command("ColorPicker", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local arg = vim.trim(opts.args or "")
  if arg ~= "" then
    m.open({ format = arg })
  else
    m.open()
  end
end, {
  nargs = "?",
  complete = function()
    return { "hex", "rgb", "rgba", "hsl", "hsla", "hex_alpha" }
  end,
  desc = "colorpicker: open HSV color picker (optional format)",
})

vim.api.nvim_create_user_command("Colorpicker", function(opts)
  vim.cmd("ColorPicker " .. (opts.args or ""))
end, {
  nargs = "?",
  complete = function()
    return { "hex", "rgb", "rgba", "hsl", "hsla", "hex_alpha" }
  end,
  desc = "colorpicker: alias of ColorPicker",
})

vim.api.nvim_create_user_command("ColorPickerClose", function()
  local m = get_mod()
  if m then
    m.close()
  end
end, { desc = "colorpicker: close float" })

vim.api.nvim_create_user_command("ColorPickerPreview", function()
  local m = get_mod()
  if not m then
    return
  end
  local ok, prev = pcall(require, "colorpicker.preview")
  if ok and prev then
    prev.refresh(0)
    vim.notify("colorpicker: preview refreshed", vim.log.levels.INFO)
  end
end, { desc = "colorpicker: refresh in-buffer color highlights" })
