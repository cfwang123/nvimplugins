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

-- 启动时检测推荐 pip 依赖（Pillow）并提示安装
do
  local _dep_plugin = "mdview"
  local _dep_src = debug.getinfo(1, "S").source
  vim.defer_fn(function()
    if vim.g.nvimplugins_skip_deps or vim.g.nvimplugins_deps_bundle_done then
      return
    end
    local ok, dc = pcall(require, "nvimplugins.depcheck")
    if not ok or type(dc) ~= "table" then
      local src = _dep_src
      if type(src) == "string" and src:sub(1, 1) == "@" then
        src = src:sub(2)
      end
      local dir = vim.fn.fnamemodify(src, ":p:h")
      for _ = 1, 8 do
        local f = dir .. "/lua/nvimplugins/depcheck.lua"
        if vim.fn.filereadable(f) == 1 then
          local chunk = loadfile(f)
          if chunk then
            dc = chunk()
            package.loaded["nvimplugins.depcheck"] = dc
            ok = true
          end
          break
        end
        local parent = vim.fn.fnamemodify(dir, ":h")
        if parent == dir then
          break
        end
        dir = parent
      end
    end
    if ok and dc and dc.schedule then
      dc.schedule(_dep_plugin, 0, _dep_src)
    end
  end, 550)
end
