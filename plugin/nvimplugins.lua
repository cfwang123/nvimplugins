-- 整仓安装入口：Plug 'cfwang123/nvimplugins'（或本地根目录）时把各子插件加入 rtp 并加载。
-- 分目录安装时不会用到本文件（各子目录自带 plugin/）。
if vim.g.loaded_nvimplugins_bundle then
  return
end
vim.g.loaded_nvimplugins_bundle = true

local this = debug.getinfo(1, "S").source:sub(2)
local bundle_root = vim.fn.fnamemodify(this, ":h:h")

-- 默认全部启用；可在插件加载前设置：
--   vim.g.nvimplugins_enable = { "imgbuf", "mdview" }
local default_plugins = {
  "mdview",
  "music",
  "imgbuf",
  "nvimgames",
  "drawbuf",
}

local enable = vim.g.nvimplugins_enable
if type(enable) ~= "table" or #enable == 0 then
  enable = default_plugins
end

local enabled = {}
for _, name in ipairs(enable) do
  enabled[name] = true
end

local function source_plugin_dir(dir)
  local files = vim.fn.glob(dir .. "/plugin/*.{lua,vim}", false, true)
  for _, f in ipairs(files) do
    if f:match("%.lua$") then
      dofile(f)
    else
      vim.cmd.source(vim.fn.fnameescape(f))
    end
  end
end

for _, name in ipairs(default_plugins) do
  if enabled[name] then
    local dir = vim.fs.normalize(bundle_root .. "/" .. name)
    if vim.fn.isdirectory(dir) == 0 then
      vim.notify("nvimplugins: 缺少子插件目录 " .. name, vim.log.levels.WARN)
    else
      -- prepend：保证 require 优先命中本仓；已单独 Plug 时重复无害，loaded_* 防双重加载
      vim.opt.runtimepath:prepend(dir)
      source_plugin_dir(dir)
    end
  end
end

-- Neovim 0.9+ loader 会缓存「未找到」；rtp 变更后需重置，否则紧接着的 require 仍失败
if vim.loader and type(vim.loader.reset) == "function" then
  pcall(vim.loader.reset)
end
