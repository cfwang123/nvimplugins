if vim.g.loaded_pdfview then
  return
end
vim.g.loaded_pdfview = true

-- 尽早从 zip 浏览列表去掉 .docx，避免 BufReadCmd 走 zip#Browse（无 unzip 时 E15/E117）
pcall(function()
  require("pdfview.zipfix").preempt()
end)

local function get_mod()
  local ok, pdfview = pcall(require, "pdfview")
  if not ok then
    vim.notify("pdfview: " .. tostring(pdfview), vim.log.levels.ERROR)
    return nil
  end
  pdfview.ensure_setup()
  return pdfview
end

-- 进入 rtp 即用默认配置（auto_open）
get_mod()

vim.api.nvim_create_user_command("PdfView", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local path = opts.args
  if path == nil or path == "" then
    path = vim.fn.expand("%:p")
  else
    path = vim.fn.fnamemodify(path, ":p")
  end
  m.open(path)
end, {
  nargs = "?",
  complete = "file",
  desc = "pdfview: open PDF/Word preview",
})

-- 别名
vim.api.nvim_create_user_command("DocView", function(opts)
  vim.cmd("PdfView " .. (opts.args or ""))
end, {
  nargs = "?",
  complete = "file",
  desc = "pdfview: open PDF/Word preview (alias)",
})

vim.api.nvim_create_user_command("PdfViewRefresh", function()
  local m = get_mod()
  if m then
    m.refresh(nil, true)
  end
end, { desc = "pdfview: force re-extract and render" })

vim.api.nvim_create_user_command("PdfViewClose", function()
  local m = get_mod()
  if m then
    m.close()
  end
end, { desc = "pdfview: close preview" })

-- 启动时检测 pip 依赖并提示安装
do
  local _dep_plugin = "pdfview"
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
