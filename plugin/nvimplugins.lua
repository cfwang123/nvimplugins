-- 整仓入口：用户只需一行 `Plug 'cfwang123/nvimplugins'`（或本地根路径）。
-- 本文件由 vim-plug / Neovim 自动 source，负责把各子插件加入 rtp 并加载。
-- 分目录安装时不会用到本文件（各子目录自带 plugin/）。

if vim.g.loaded_nvimplugins_bundle then
  return
end

local function resolve_bundle_root()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  if type(src) == "string" and src ~= "" and src ~= ":lua" and not src:match("^%[") then
    local root = vim.fn.fnamemodify(src, ":p:h:h")
    if vim.fn.isdirectory(root) == 1 then
      return root
    end
  end
  -- 兜底：从 runtimepath 上找带 imgbuf 子目录的本仓根
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    if vim.fn.isdirectory(rtp .. "/imgbuf/lua/imgbuf") == 1
      or vim.fn.isdirectory(rtp .. "\\imgbuf\\lua\\imgbuf") == 1
    then
      return rtp
    end
    if vim.fn.filereadable(rtp .. "/plugin/nvimplugins.lua") == 1
      or vim.fn.filereadable(rtp .. "\\plugin\\nvimplugins.lua") == 1
    then
      if vim.fn.isdirectory(rtp .. "/imgbuf") == 1 or vim.fn.isdirectory(rtp .. "\\imgbuf") == 1 then
        return rtp
      end
    end
  end
  return nil
end

local function join(root, name)
  root = tostring(root):gsub("[/\\]+$", "")
  return root .. "/" .. name
end

local function source_plugin_dir(dir)
  local files = vim.fn.glob(dir .. "/plugin/*.lua", false, true)
  for _, f in ipairs(files) do
    dofile(f)
  end
  local vimfiles = vim.fn.glob(dir .. "/plugin/*.vim", false, true)
  for _, f in ipairs(vimfiles) do
    vim.cmd.source(vim.fn.fnameescape(f))
  end
end

local function load_bundle()
  if vim.g.loaded_nvimplugins_bundle then
    return true
  end

  local bundle_root = resolve_bundle_root()
  if not bundle_root then
    return false
  end

  local default_plugins = {
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
    "ntemoji",
  }

  local enable = vim.g.nvimplugins_enable
  if type(enable) ~= "table" or #enable == 0 then
    enable = default_plugins
  end
  local enabled = {}
  for _, name in ipairs(enable) do
    enabled[name] = true
  end

  local loaded_any = false
  for _, name in ipairs(default_plugins) do
    if enabled[name] then
      local dir = join(bundle_root, name)
      if vim.fn.isdirectory(dir) == 1 then
        vim.opt.runtimepath:prepend(dir)
        source_plugin_dir(dir)
        loaded_any = true
      else
        vim.notify("nvimplugins: missing " .. name .. " under " .. bundle_root, vim.log.levels.WARN)
      end
    end
  end

  if not loaded_any then
    return false
  end

  vim.g.loaded_nvimplugins_bundle = true
  if vim.loader and type(vim.loader.reset) == "function" then
    pcall(vim.loader.reset)
  end

  -- 启动后检测已启用子插件的 pip 依赖并提示安装
  vim.defer_fn(function()
    if vim.g.nvimplugins_skip_deps then
      return
    end
    local ok, deps = pcall(require, "nvimplugins.deps")
    if not ok or not deps then
      return
    end
    local names = {}
    for _, name in ipairs(enable) do
      table.insert(names, name)
    end
    deps.ensure(names, { silent_ok = true })
    vim.g.nvimplugins_deps_bundle_done = true
  end, 400)

  return true
end

if not load_bundle() then
  vim.notify(
    "nvimplugins: bundle bootstrap failed (is the repo root on runtimepath?)",
    vim.log.levels.ERROR
  )
end

-- 合集帮助：命令一览 + 当前快捷键，点击/回车运行
pcall(function()
  local help = require("nvimplugins.help")
  help.setup({
    keys_help = vim.g.nvimplugins_keys_help or "<leader>hh",
  })
end)

-- 手动重检 / 强制安装提示（含推荐包）
pcall(function()
  vim.api.nvim_create_user_command("NvimpluginsDeps", function(opts)
    local deps = require("nvimplugins.deps")
    deps.reset()
    local arg = vim.trim(opts.args or "")
    local o = {
      force = true,
      immediate = true,
      silent_ok = false,
      include_recommended = true,
    }
    if arg == "" then
      deps.ensure_loaded(o)
    else
      local names = vim.split(arg, "%s+", { trimempty = true })
      deps.ensure(names, o)
    end
  end, {
    nargs = "*",
    complete = function()
      return {
        "music",
        "videobuf",
        "pdfview",
        "xlsview",
        "tts",
        "mdview",
        "imgbuf",
      }
    end,
    desc = "Check / prompt install nvimplugins Python deps (incl. recommended)",
  })
  vim.api.nvim_create_user_command("NvimpluginsDepsProbe", function()
    require("nvimplugins.deps").debug_probe()
  end, { desc = "Debug: probe Python imports used by nvimplugins" })
end)