---@mod nvimplugins.depcheck 子插件启动时安全调用依赖检查
---可从 monorepo 根或子目录 plugin/*.lua 调用；找不到模块则静默跳过。
local M = {}

local function loadfile_deps_from(start_dir)
  local dir = start_dir
  for _ = 1, 8 do
    local candidate = dir .. "/lua/nvimplugins/deps.lua"
    if vim.fn.filereadable(candidate) == 1 then
      local chunk, err = loadfile(candidate)
      if not chunk then
        vim.notify("nvimplugins.deps: " .. tostring(err), vim.log.levels.WARN)
        return nil
      end
      local mod = chunk()
      if type(mod) == "table" and mod.ensure then
        package.loaded["nvimplugins.deps"] = mod
        return mod
      end
      return nil
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir or parent == "" then
      break
    end
    dir = parent
  end
  return nil
end

---尝试加载 deps 模块（require 或沿路径找 monorepo 文件）
---@param hint_src? string  调用方源文件路径（@ 前缀可有可无）
---@return table|nil
function M.load_deps(hint_src)
  local ok, deps = pcall(require, "nvimplugins.deps")
  if ok and type(deps) == "table" and deps.ensure then
    return deps
  end

  local src = hint_src
  if not src then
    local info = debug.getinfo(2, "S")
    src = info and info.source or ""
  end
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  if type(src) == "string" and src ~= "" and not src:match("^%[") then
    local dir = vim.fn.fnamemodify(src, ":p:h")
    local mod = loadfile_deps_from(dir)
    if mod then
      return mod
    end
  end

  -- runtimepath 上找 monorepo 根
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local candidate = rtp .. "/lua/nvimplugins/deps.lua"
    if vim.fn.filereadable(candidate) == 1 then
      local chunk = loadfile(candidate)
      if chunk then
        local mod = chunk()
        if type(mod) == "table" and mod.ensure then
          package.loaded["nvimplugins.deps"] = mod
          return mod
        end
      end
    end
    -- 子插件目录在 rtp 时：其父级可能是 monorepo
    local parent = vim.fn.fnamemodify(rtp, ":h")
    local cand2 = parent .. "/lua/nvimplugins/deps.lua"
    if vim.fn.filereadable(cand2) == 1 then
      local chunk = loadfile(cand2)
      if chunk then
        local mod = chunk()
        if type(mod) == "table" and mod.ensure then
          package.loaded["nvimplugins.deps"] = mod
          return mod
        end
      end
    end
  end
  return nil
end

---延迟检查单个（或多个）插件依赖
---@param plugin_name string|string[]
---@param delay_ms? integer
---@param hint_src? string
function M.schedule(plugin_name, delay_ms, hint_src)
  if vim.g.nvimplugins_skip_deps then
    return
  end
  delay_ms = delay_ms or 500
  vim.defer_fn(function()
    if vim.g.nvimplugins_skip_deps then
      return
    end
    -- 合集已统一检查则跳过（避免重复）
    if vim.g.nvimplugins_deps_bundle_done then
      return
    end
    local deps = M.load_deps(hint_src)
    if not deps then
      return
    end
    deps.ensure(plugin_name, { silent_ok = true })
  end, delay_ms)
end

return M
