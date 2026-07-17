---@mod pdfview.zipfix
--- 阻止 Neovim 自带 zip 插件把 .docx 当压缩包浏览（缺 unzip 时会 E15/E117）
local M = {}

---zipPlugin 默认扩展（与 runtime/plugin/zipPlugin.vim 对齐），去掉 Word OOXML
local DEFAULT_ZIP_EXT_NO_WORD = table.concat({
  "*.aar",
  "*.apk",
  "*.celzip",
  "*.crtx",
  "*.ear",
  "*.epub",
  "*.gcsx",
  "*.glox",
  "*.gqsx",
  "*.ja",
  "*.jar",
  "*.kmz",
  "*.odb",
  "*.odc",
  "*.odf",
  "*.odg",
  "*.odi",
  "*.odm",
  "*.odp",
  "*.ods",
  "*.odt",
  "*.otc",
  "*.otf",
  "*.otg",
  "*.oth",
  "*.oti",
  "*.otp",
  "*.ots",
  "*.ott",
  "*.oxt",
  "*.pkpass",
  "*.potm",
  "*.potx",
  "*.ppam",
  "*.ppsm",
  "*.ppsx",
  "*.pptm",
  "*.pptx",
  "*.sldx",
  "*.thmx",
  "*.vdw",
  "*.war",
  "*.whl",
  "*.wsz",
  "*.xap",
  "*.xlam",
  -- 无 xlsx/xlsm：由 xlsview 预览
  "*.xpi",
  "*.zip",
}, ",")

---要从 zip 浏览中剔除的扩展（小写）
--- 含 Excel：与 xlsview 共存时互不抢回
local SKIP = {
  docx = true,
  docm = true,
  dotx = true,
  dotm = true,
  doc = true,
  xlsx = true,
  xlsm = true,
  xltx = true,
  xltm = true,
  xlsb = true,
}

---@param ext_list string|nil
---@return string
function M.filter_ext(ext_list)
  if not ext_list or ext_list == "" then
    return DEFAULT_ZIP_EXT_NO_WORD
  end
  local parts = {}
  for part in ext_list:gmatch("[^,]+") do
    part = vim.trim(part)
    if part ~= "" then
      local e = part:match("%.([%w]+)$")
      if not (e and SKIP[e:lower()]) then
        parts[#parts + 1] = part
      end
    end
  end
  if #parts == 0 then
    return DEFAULT_ZIP_EXT_NO_WORD
  end
  return table.concat(parts, ",")
end

---尽量在 zipPlugin 加载前改掉扩展列表
function M.preempt()
  if vim.g.pdfview_zip_preempted then
    return
  end
  local cur = vim.g.zipPlugin_ext
  if type(cur) == "string" and cur ~= "" then
    vim.g.zipPlugin_ext = M.filter_ext(cur)
  else
    -- zip 尚未设默认：直接提供无 Word 的列表
    vim.g.zipPlugin_ext = DEFAULT_ZIP_EXT_NO_WORD
  end
  vim.g.pdfview_zip_preempted = true
end

---zip 已加载后：重写 augroup zip（保留 zipfile: 协议，Browse 不含 docx）
function M.rebind()
  local filtered = M.filter_ext(vim.g.zipPlugin_ext)
  vim.g.zipPlugin_ext = filtered

  local has_zip_read = vim.fn.exists("*zip#Read") == 1
  local has_zip_browse = vim.fn.exists("*zip#Browse") == 1

  pcall(vim.cmd, "silent! autocmd! zip")

  if has_zip_read then
    pcall(vim.cmd, [[
      augroup zip
        autocmd!
        autocmd BufReadCmd  zipfile:*  call zip#Read(expand("<amatch>"), 1)
        autocmd FileReadCmd zipfile:*  call zip#Read(expand("<amatch>"), 0)
        autocmd BufWriteCmd zipfile:*  call zip#Write(expand("<amatch>"))
        autocmd FileWriteCmd zipfile:* call zip#Write(expand("<amatch>"))
      augroup END
    ]])
    if vim.fn.has("unix") == 1 then
      pcall(vim.cmd, [[
        augroup zip
          autocmd BufReadCmd  zipfile:*/*  call zip#Read(expand("<amatch>"), 1)
          autocmd FileReadCmd zipfile:*/*  call zip#Read(expand("<amatch>"), 0)
          autocmd BufWriteCmd zipfile:*/*  call zip#Write(expand("<amatch>"))
          autocmd FileWriteCmd zipfile:*/* call zip#Write(expand("<amatch>"))
        augroup END
      ]])
    end
  end

  if has_zip_browse and filtered ~= "" then
    -- 与 zipPlugin 相同：exe 拼接扩展列表
    pcall(function()
      vim.cmd("augroup zip")
      vim.cmd("exe 'autocmd BufReadCmd ' . g:zipPlugin_ext . ' call zip#Browse(expand(\"<amatch>\"))'")
      vim.cmd("augroup END")
    end)
  end

  return true
end

local installed = false

function M.install()
  M.preempt()
  pcall(M.rebind)
  if installed then
    return
  end
  installed = true

  local aug = vim.api.nvim_create_augroup("PdfViewZipFix", { clear = true })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = aug,
    once = true,
    callback = function()
      pcall(M.rebind)
    end,
  })
  -- lazy.nvim 等晚加载后再绑
  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = { "LazyDone", "LazyLoad" },
    callback = function()
      pcall(M.rebind)
    end,
  })
  vim.defer_fn(function()
    pcall(M.rebind)
  end, 300)
end

return M
