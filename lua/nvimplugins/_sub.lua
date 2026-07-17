---Load a monorepo subplugin module (e.g. "imgbuf") from <root>/<name>/lua/...
---Used by root lua/<name>/init.lua proxies so require() works right after plug#end
---(vim-plug only puts the repo root on rtp during vim_starting; plugin/* runs later).
local M = {}

local function bundle_root()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  -- this file: <root>/lua/nvimplugins/_sub.lua → :h:h:h = root
  return vim.fn.fnamemodify(src, ":p:h:h:h")
end

---@param name string subfolder / module name
---@return any
function M.load(name)
  local root = bundle_root()
  local plugin_root = root .. "/" .. name
  if vim.fn.isdirectory(plugin_root) == 0 then
    error("nvimplugins: missing subplugin " .. name .. " at " .. plugin_root, 0)
  end
  vim.opt.runtimepath:prepend(plugin_root)
  if vim.loader and type(vim.loader.reset) == "function" then
    pcall(vim.loader.reset)
  end
  local real = plugin_root .. "/lua/" .. name .. "/init.lua"
  if vim.fn.filereadable(real) == 0 then
    error("nvimplugins: missing " .. real, 0)
  end
  local chunk, err = loadfile(real)
  if not chunk then
    error(err, 0)
  end
  return chunk()
end

return M
