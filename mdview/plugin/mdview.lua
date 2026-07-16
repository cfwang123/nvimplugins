if vim.g.loaded_mdview then
  return
end
vim.g.loaded_mdview = true

local function get_mod()
  local ok, mdview = pcall(require, "mdview")
  if not ok then
    vim.notify("mdview: " .. tostring(mdview), vim.log.levels.ERROR)
    return nil
  end
  mdview.ensure_setup()
  return mdview
end

-- 进入 rtp 即用默认配置
get_mod()

vim.api.nvim_create_user_command("MdView", function()
  local m = get_mod()
  if m then
    m.toggle_view()
  end
end, { desc = "mdview: single-window source ⇄ preview" })

vim.api.nvim_create_user_command("MdSideView", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local sub = (opts.args or ""):lower()
  if sub == "open" then
    m.side_open()
  elseif sub == "close" then
    m.side_close()
  else
    m.toggle_side()
  end
end, {
  nargs = "?",
  complete = function()
    return { "open", "close" }
  end,
  desc = "mdview: side preview toggle / open / close",
})

vim.api.nvim_create_user_command("MdViewRefresh", function()
  local m = get_mod()
  if m then
    m.refresh()
  end
end, { desc = "mdview: force re-render preview" })

vim.api.nvim_create_user_command("MdViewSync", function()
  local m = get_mod()
  if m then
    m.sync_now()
  end
end, { desc = "mdview: sync side preview to source cursor" })
