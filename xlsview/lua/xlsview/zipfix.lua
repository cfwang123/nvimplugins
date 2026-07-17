---@mod xlsview.zipfix
--- 阻止 zip 插件把 .xlsx 当压缩包浏览
local M = {}

--- 与 pdfview 对齐：Word + Excel 均不走 zip 浏览
local SKIP = {
  xlsx = true,
  xlsm = true,
  xltx = true,
  xltm = true,
  xlsb = true,
  xls = true,
  docx = true,
  docm = true,
  dotx = true,
  dotm = true,
  doc = true,
}

local DEFAULT_NO_XLS = table.concat({
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
  "*.xpi",
  "*.zip",
}, ",")

function M.filter_ext(ext_list)
  if not ext_list or ext_list == "" then
    return DEFAULT_NO_XLS
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
  return #parts > 0 and table.concat(parts, ",") or DEFAULT_NO_XLS
end

function M.preempt()
  if vim.g.xlsview_zip_preempted then
    return
  end
  local cur = vim.g.zipPlugin_ext
  if type(cur) == "string" and cur ~= "" then
    vim.g.zipPlugin_ext = M.filter_ext(cur)
  else
    vim.g.zipPlugin_ext = DEFAULT_NO_XLS
  end
  vim.g.xlsview_zip_preempted = true
end

function M.rebind()
  local filtered = M.filter_ext(vim.g.zipPlugin_ext)
  vim.g.zipPlugin_ext = filtered
  local has_read = vim.fn.exists("*zip#Read") == 1
  local has_browse = vim.fn.exists("*zip#Browse") == 1
  pcall(vim.cmd, "silent! autocmd! zip")
  if has_read then
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
  if has_browse and filtered ~= "" then
    pcall(function()
      vim.cmd("augroup zip")
      vim.cmd("exe 'autocmd BufReadCmd ' . g:zipPlugin_ext . ' call zip#Browse(expand(\"<amatch>\"))'")
      vim.cmd("augroup END")
    end)
  end
end

local installed = false

function M.install()
  M.preempt()
  pcall(M.rebind)
  if installed then
    return
  end
  installed = true
  local aug = vim.api.nvim_create_augroup("XlsViewZipFix", { clear = true })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = aug,
    once = true,
    callback = function()
      pcall(M.rebind)
    end,
  })
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
