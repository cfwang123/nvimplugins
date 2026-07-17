if vim.g.loaded_ntemoji then
  return
end
vim.g.loaded_ntemoji = true

local function get_mod()
  local ok, m = pcall(require, "ntemoji")
  if not ok then
    vim.notify("ntemoji: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

-- 默认启用；NERDTree 加载 nerdtree_plugin 时也会 ensure
get_mod()

-- NERDTree 晚于本插件加载时再注册
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("NtemojiBoot", { clear = true }),
  callback = function()
    local m = get_mod()
    if m then
      m.ensure_listeners()
    end
  end,
})

-- 打开 NERDTree 时再试一次（PathNotifier 通常已存在）
vim.api.nvim_create_autocmd("FileType", {
  pattern = "nerdtree",
  group = vim.api.nvim_create_augroup("NtemojiFT", { clear = true }),
  callback = function()
    local m = get_mod()
    if m then
      m.ensure_listeners()
    end
  end,
})
