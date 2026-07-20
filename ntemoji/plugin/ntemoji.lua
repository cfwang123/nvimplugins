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

-- 默认尝试启用；若检测到 vim-devicons 会自动关闭
local mod = get_mod()
if mod and not mod.is_enabled() then
  -- 已装 devicons：不挂后续 autocmd
  return
end

-- NERDTree / 其它插件可能更晚加载，VimEnter 再检测一次
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("NtemojiBoot", { clear = true }),
  callback = function()
    local m = get_mod()
    if not m then
      return
    end
    if m.devicons_present() then
      -- 后加载的 devicons：确保不启用
      vim.g.ntemoji_enabled = 0
      return
    end
    m.ensure_listeners()
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = "nerdtree",
  group = vim.api.nvim_create_augroup("NtemojiFT", { clear = true }),
  callback = function()
    local m = get_mod()
    if m and m.is_enabled() then
      m.ensure_listeners()
      -- 每次进入树都重挂 [] conceal（syntax/matchadd 可能被 NERDTree 冲掉）
      pcall(vim.fn["ntemoji#apply_conceal"])
    end
  end,
})
