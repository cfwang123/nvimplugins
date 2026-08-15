if vim.g.loaded_bookmarks then
  return
end
vim.g.loaded_bookmarks = true

local function get_mod()
  local ok, m = pcall(require, "bookmarks")
  if not ok then
    vim.notify("bookmarks: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

-- 进入 rtp 时自动 setup（默认全局仅 <leader>bo；A/D 仅收藏夹窗口内）
get_mod()

vim.api.nvim_create_user_command("BookmarksOpen", function()
  local m = get_mod()
  if m then
    m.open()
  end
end, { desc = "bookmarks: open sidebar" })

vim.api.nvim_create_user_command("BookmarksToggle", function()
  local m = get_mod()
  if m then
    m.toggle()
  end
end, { desc = "bookmarks: toggle sidebar" })

vim.api.nvim_create_user_command("BookmarksClose", function()
  local m = get_mod()
  if m then
    m.close()
  end
end, { desc = "bookmarks: close sidebar" })

vim.api.nvim_create_user_command("BookmarksAddFile", function()
  local m = get_mod()
  if m then
    m.add_file()
  end
end, { desc = "bookmarks: add current file" })

vim.api.nvim_create_user_command("BookmarksAddDir", function()
  local m = get_mod()
  if m then
    m.add_dir()
  end
end, { desc = "bookmarks: add current directory" })

vim.api.nvim_create_user_command("BookmarksRefresh", function()
  local m = get_mod()
  if m then
    m.refresh()
  end
end, { desc = "bookmarks: reload from disk" })
