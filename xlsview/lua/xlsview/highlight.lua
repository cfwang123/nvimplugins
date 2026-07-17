---@mod xlsview.highlight
local M = {}

local defined = false
local tc = {}

local links = {
  XlsViewTitle = "Title",
  XlsViewMeta = "Comment",
  XlsViewSheet = "Title",
  XlsViewSheetActive = "",
  XlsViewSheetInactive = "Comment",
  XlsViewBorder = "Comment",
  XlsViewHeader = "",
  XlsViewHint = "Comment",
  XlsViewHelp = "",
  XlsViewRowNr = "LineNr",
  XlsViewBold = "",
  XlsViewItalic = "",
}

function M.truecolor(fg_hex, bold, italic, bg_hex)
  -- JSON null → vim.NIL（userdata），必须先规范化
  if type(fg_hex) ~= "string" or fg_hex == "" then
    fg_hex = "000000"
  end
  fg_hex = fg_hex:lower():gsub("^#", "")
  if not fg_hex:match("^%x%x%x%x%x%x$") then
    fg_hex = "000000"
  end
  local bg = nil
  if type(bg_hex) == "string" and bg_hex ~= "" then
    bg = bg_hex:lower():gsub("^#", "")
    if not bg:match("^%x%x%x%x%x%x$") then
      bg = nil
    end
  end
  local key = fg_hex .. (bold and "b" or "") .. (italic and "i" or "") .. (bg and ("_" .. bg) or "")
  local name = "XlsViewTC_" .. key
  if not tc[key] then
    local opts = { fg = "#" .. fg_hex, default = false }
    if bold then
      opts.bold = true
    end
    if italic then
      opts.italic = true
    end
    if bg then
      opts.bg = "#" .. bg
    end
    pcall(vim.api.nvim_set_hl, 0, name, opts)
    tc[key] = name
  else
    local opts = { fg = "#" .. fg_hex, default = false }
    if bold then
      opts.bold = true
    end
    if italic then
      opts.italic = true
    end
    if bg then
      opts.bg = "#" .. bg
    end
    pcall(vim.api.nvim_set_hl, 0, name, opts)
  end
  return name
end

function M.setup(user_hls)
  for name, link in pairs(links) do
    if name == "XlsViewBold" or name == "XlsViewItalic" or name == "XlsViewHeader" or name == "XlsViewSheetActive" then
      goto continue
    end
    local override = user_hls and user_hls[name]
    if type(override) == "string" then
      vim.api.nvim_set_hl(0, name, { link = override, default = true })
    elseif type(override) == "table" then
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, override))
    elseif link and link ~= "" then
      vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
    ::continue::
  end
  vim.api.nvim_set_hl(0, "XlsViewBold", { bold = true, default = false })
  vim.api.nvim_set_hl(0, "XlsViewItalic", { italic = true, default = false })
  vim.api.nvim_set_hl(0, "XlsViewHeader", { bold = true, default = false })
  vim.api.nvim_set_hl(0, "XlsViewSheetActive", { bold = true, underline = true, default = false })
  vim.api.nvim_set_hl(0, "XlsViewHelpFloat", { bg = "#ffffff", fg = "#000000", default = false })
  vim.api.nvim_set_hl(0, "XlsViewHelpFloatBorder", { bg = "#ffffff", fg = "#888888", default = false })
  defined = true
end

function M.ensure()
  if not defined then
    M.setup(nil)
  end
end

return M
