---nvimplugins 合集元模块（可选）
---整仓安装时由 plugin/nvimplugins.lua 自动挂载子插件；
---本模块仅提供列表查询，无需强制 require。
local M = {}

---合集内子插件名（与目录名一致）
M.plugins = {
  "mdview",
  "music",
  "imgbuf",
  "nvimgames",
  "drawbuf",
}

---返回当前已加载的子插件名列表（依据 vim.g.loaded_*）
function M.loaded()
  local out = {}
  for _, name in ipairs(M.plugins) do
    if vim.g["loaded_" .. name] then
      table.insert(out, name)
    end
  end
  return out
end

return M
