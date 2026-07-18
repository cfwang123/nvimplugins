---nvimplugins 合集元模块（可选）
---整仓安装时由 plugin/nvimplugins.lua 自动挂载子插件；
---本模块提供列表查询与依赖检查入口。
local M = {}

---合集内子插件名（与目录名一致）
M.plugins = {
  "mdview",
  "music",
  "imgbuf",
  "videobuf",
  "nvimgames",
  "drawbuf",
  "pdfview",
  "xlsview",
  "tts",
  "es",
  "qrbuf",
  "httpbuf",
  "weather",
  "taskmgr",
  "ntemoji",
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

---检查 pip 依赖并提示安装（见 nvimplugins.deps）
---@param plugins? string|string[]
---@param opts? table
function M.check_deps(plugins, opts)
  return require("nvimplugins.deps").ensure(plugins, opts)
end

---打开合集帮助浮窗（命令 / 快捷键 / 点击运行）
function M.help()
  return require("nvimplugins.help").open()
end

return M
