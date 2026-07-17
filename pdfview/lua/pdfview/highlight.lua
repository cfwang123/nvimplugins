---@mod pdfview.highlight
local M = {}

local defined = false

local links = {
  PdfViewTitle = "Title",
  PdfViewPage = "Title",
  PdfViewPageSep = "Comment",
  PdfViewMeta = "Comment",
  PdfViewTableBorder = "Comment",
  PdfViewTableHeader = "",
  PdfViewImageBorder = "Comment",
  PdfViewImage = "Directory",
  PdfViewHint = "Comment",
  PdfViewHelp = "",
  PdfViewBold = "",
  PdfViewItalic = "",
  PdfViewMono = "String",
}

local function copy_fg(from_name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = from_name, link = false })
  if ok and hl and hl.fg then
    return hl.fg
  end
  return nil
end

local function style_attrs(kind)
  local out = { default = false }
  if kind == "bold" then
    out.bold = true
  elseif kind == "italic" then
    out.italic = true
  elseif kind == "bold_italic" then
    out.bold = true
    out.italic = true
  end
  local candidates = {
    bold = { "@markup.strong", "markdownBold", "Bold", "Normal" },
    italic = { "@markup.italic", "markdownItalic", "Italic", "Normal" },
    bold_italic = { "@markup.strong", "Bold", "Normal" },
  }
  for _, name in ipairs(candidates[kind] or {}) do
    local fg = copy_fg(name)
    if fg then
      out.fg = fg
      break
    end
  end
  return out
end

---真彩色 span 缓存 hex6 -> group
local tc_cache = {}

---@param hex6 string rrggbb 或 #rrggbb
---@param bold boolean|nil
---@param italic boolean|nil
---@return string hl_group
function M.truecolor(hex6, bold, italic)
  hex6 = (hex6 or "000000"):lower():gsub("^#", "")
  if not hex6:match("^%x%x%x%x%x%x$") then
    hex6 = "000000"
  end
  local key = hex6
  if bold then
    key = key .. "b"
  end
  if italic then
    key = key .. "i"
  end
  local name = "PdfViewTC_" .. key
  if not tc_cache[key] then
    local opts = { fg = "#" .. hex6, default = false }
    if bold then
      opts.bold = true
    end
    if italic then
      opts.italic = true
    end
    pcall(vim.api.nvim_set_hl, 0, name, opts)
    tc_cache[key] = name
  else
    -- 主题切换后可能被清；重设
    local opts = { fg = "#" .. hex6, default = false }
    if bold then
      opts.bold = true
    end
    if italic then
      opts.italic = true
    end
    pcall(vim.api.nvim_set_hl, 0, name, opts)
  end
  return name
end

function M.setup(user_hls)
  for name, link in pairs(links) do
    if name == "PdfViewBold" or name == "PdfViewItalic" or name == "PdfViewTableHeader" or name == "PdfViewHelp" then
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

  local function set_style(name, kind)
    local override = user_hls and user_hls[name]
    if type(override) == "string" then
      vim.api.nvim_set_hl(0, name, { link = override, default = false })
    elseif type(override) == "table" then
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = false }, override))
    else
      vim.api.nvim_set_hl(0, name, style_attrs(kind))
    end
  end
  set_style("PdfViewBold", "bold")
  set_style("PdfViewItalic", "italic")

  local th = user_hls and user_hls.PdfViewTableHeader
  if type(th) == "table" then
    vim.api.nvim_set_hl(0, "PdfViewTableHeader", vim.tbl_extend("force", { bold = true, default = false }, th))
  elseif type(th) == "string" then
    vim.api.nvim_set_hl(0, "PdfViewTableHeader", { link = th, default = false })
  else
    vim.api.nvim_set_hl(0, "PdfViewTableHeader", { bold = true, default = false })
  end

  -- Help float 白底
  vim.api.nvim_set_hl(0, "PdfViewHelpFloat", { bg = "#ffffff", fg = "#000000", default = false })
  vim.api.nvim_set_hl(0, "PdfViewHelpFloatBorder", { bg = "#ffffff", fg = "#888888", default = false })
  vim.api.nvim_set_hl(0, "PdfViewHelpFloatTitle", { bg = "#ffffff", fg = "#000000", bold = true, default = false })
  vim.api.nvim_set_hl(0, "PdfViewHelp", { link = "PdfViewHelpFloatTitle", default = false })

  defined = true
end

function M.ensure()
  if not defined then
    M.setup(nil)
  end
end

return M
