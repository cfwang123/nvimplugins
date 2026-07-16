---@mod mdview.highlight
local M = {}

local defined = false

local links = {
  MdViewH1 = "Title",
  MdViewH2 = "Title",
  MdViewH3 = "Title",
  MdViewH4 = "Statement",
  MdViewH5 = "Statement",
  MdViewH6 = "Statement",
  -- Bold/Italic/Strike 不用 link：很多主题没有 Italic 组，Strike 链 Comment 会丢删除线
  MdViewBold = "",
  MdViewItalic = "",
  MdViewStrike = "",
  MdViewMark = "", -- 黄色底，见 setup
  MdViewInlineCode = "String",
  MdViewCodeBlock = "Comment",
  MdViewCodeBorder = "Comment",
  MdViewCodeBg = "", -- 单独设置灰底，见 setup
  MdViewCodeLang = "Type",
  MdViewCodeCopy = "", -- 代码块 [Copy] 按钮
  MdViewCodeLinenr = "LineNr",
  MdViewCodeFold = "Comment",
  MdViewListBullet = "Special",
  MdViewTableBorder = "Comment",
  MdViewQuote = "Comment",
  MdViewLink = "Underlined",
  MdViewImage = "Directory",
  MdViewImageBorder = "Comment",
  MdViewDetailsMarker = "Special",
  MdViewDetailsSummary = "Title",
  MdViewCursor = "CursorLine",
  MdViewCursorLine = "", -- 源光标对应预览行（更醒目），见 setup
  MdViewCursorMark = "", -- 预览内光标位置标记
  MdViewHr = "Comment",
  MdViewTocTitle = "Title",
  MdViewTocItem = "", -- float 内 bold，见 setup
  MdViewTocSep = "Comment",
  MdViewTocFloat = "", -- 纯白底
  MdViewHelp = "",
}

local function code_bg_color()
  local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  local bg = ok and normal and normal.bg or nil
  if type(bg) == "number" then
    -- 相对 Normal 略提亮/压暗灰底
    local r = math.floor(bg / 65536) % 256
    local g = math.floor(bg / 256) % 256
    local b = bg % 256
    local lum = 0.299 * r + 0.587 * g + 0.114 * b
    local delta = lum > 128 and -28 or 28
    r = math.max(0, math.min(255, r + delta))
    g = math.max(0, math.min(255, g + delta))
    b = math.max(0, math.min(255, b + delta))
    return string.format("#%02x%02x%02x", r, g, b)
  end
  return "#2e2e2e"
end

local function copy_fg(from_name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = from_name, link = false })
  if not ok or not hl then
    return nil
  end
  if hl.fg then
    return hl.fg
  end
  return nil
end

local function style_attrs(kind)
  -- 尽量贴近 markdown 源窗口样式；始终带上 bold/italic/strikethrough 标志
  local candidates = {
    bold = { "@markup.strong", "markdownBold", "Bold", "Normal" },
    italic = { "@markup.italic", "markdownItalic", "Italic", "Normal" },
    strike = { "@markup.strikethrough", "markdownStrike", "Comment", "Normal" },
  }
  local out = { default = false }
  if kind == "bold" then
    out.bold = true
  elseif kind == "italic" then
    out.italic = true
  elseif kind == "strike" then
    out.strikethrough = true
  end
  for _, name in ipairs(candidates[kind] or {}) do
    local fg = copy_fg(name)
    if fg then
      out.fg = fg
      break
    end
  end
  return out
end

function M.setup(user_hls)
  for name, link in pairs(links) do
    if name == "MdViewCodeBg" or name == "MdViewBold" or name == "MdViewItalic" or name == "MdViewStrike" then
      goto continue
    end
    local override = user_hls and user_hls[name]
    if override then
      if type(override) == "string" then
        vim.api.nvim_set_hl(0, name, { link = override, default = true })
      else
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, override))
      end
    elseif link and link ~= "" then
      vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
    ::continue::
  end

  -- 强制正确的 bold / italic / strikethrough（不链到可能无效的组）
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
  set_style("MdViewBold", "bold")
  set_style("MdViewItalic", "italic")
  set_style("MdViewStrike", "strike")

  -- 代码块 Copy 按钮
  vim.api.nvim_set_hl(0, "MdViewCodeCopy", {
    fg = "#00aaff",
    bold = true,
    underline = true,
    default = false,
  })
  vim.api.nvim_set_hl(0, "MdViewCodeCopied", {
    fg = "#22aa44",
    bold = true,
    default = false,
  })

  -- ==marked== 黄底黑字
  local mark_ov = user_hls and user_hls.MdViewMark
  if type(mark_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewMark", vim.tbl_extend("force", { default = false }, mark_ov))
  elseif type(mark_ov) == "string" then
    vim.api.nvim_set_hl(0, "MdViewMark", { link = mark_ov, default = false })
  else
    vim.api.nvim_set_hl(0, "MdViewMark", {
      bg = "#ffcc00",
      fg = "#000000",
      default = false,
    })
  end

  -- 标题层级：保留链到 Title 的同时强制 bold
  for i = 1, 6 do
    local name = "MdViewH" .. i
    local override = user_hls and user_hls[name]
    if type(override) == "table" then
      local o = vim.tbl_extend("force", { bold = true, default = false }, override)
      vim.api.nvim_set_hl(0, name, o)
    elseif type(override) == "string" then
      vim.api.nvim_set_hl(0, name, { link = override, default = false })
      -- link 无法保证 bold，再叠一层（nvim 以最后设置为准时用显式属性）
      local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = override, link = false })
      if ok and base then
        base.bold = true
        base.default = false
        vim.api.nvim_set_hl(0, name, base)
      else
        vim.api.nvim_set_hl(0, name, { bold = true, default = false })
      end
    else
      local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = "Title", link = false })
      if ok and base then
        base.bold = true
        base.default = false
        vim.api.nvim_set_hl(0, name, base)
      else
        vim.api.nvim_set_hl(0, name, { bold = true, default = false })
      end
    end
  end

  -- 源→预览光标位置：块浅底 + 当前行更深 + 标记色
  local cur_ov = user_hls and user_hls.MdViewCursor
  if type(cur_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewCursor", vim.tbl_extend("force", { default = false }, cur_ov))
  elseif type(cur_ov) == "string" and cur_ov ~= "" then
    vim.api.nvim_set_hl(0, "MdViewCursor", { link = cur_ov, default = false })
  else
    -- 略深于 CursorLine，保证非焦点窗 extmark 也看得出
    local ok_cl, cl = pcall(vim.api.nvim_get_hl, 0, { name = "CursorLine", link = false })
    if ok_cl and cl and cl.bg then
      vim.api.nvim_set_hl(0, "MdViewCursor", { bg = cl.bg, default = false })
    else
      vim.api.nvim_set_hl(0, "MdViewCursor", { bg = "#2a2a3a", default = false })
    end
  end
  local cur_line_ov = user_hls and user_hls.MdViewCursorLine
  if type(cur_line_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewCursorLine", vim.tbl_extend("force", { default = false }, cur_line_ov))
  else
    local ok_v, vis = pcall(vim.api.nvim_get_hl, 0, { name = "Visual", link = false })
    if ok_v and vis and vis.bg then
      vim.api.nvim_set_hl(0, "MdViewCursorLine", { bg = vis.bg, bold = true, default = false })
    else
      vim.api.nvim_set_hl(0, "MdViewCursorLine", { bg = "#3d4f6f", bold = true, default = false })
    end
  end
  local mark_ov = user_hls and user_hls.MdViewCursorMark
  if type(mark_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewCursorMark", vim.tbl_extend("force", { default = false }, mark_ov))
  else
    vim.api.nvim_set_hl(0, "MdViewCursorMark", { fg = "#89b4fa", bold = true, default = false })
  end

  -- 代码块整行灰底
  local code_bg_override = user_hls and user_hls.MdViewCodeBg
  if type(code_bg_override) == "table" then
    vim.api.nvim_set_hl(0, "MdViewCodeBg", vim.tbl_extend("force", { default = true }, code_bg_override))
  elseif type(code_bg_override) == "string" then
    vim.api.nvim_set_hl(0, "MdViewCodeBg", { link = code_bg_override, default = true })
  else
    vim.api.nvim_set_hl(0, "MdViewCodeBg", { bg = code_bg_color(), default = true })
  end
  pcall(function()
    vim.api.nvim_set_hl(0, "MdViewLink", { underline = true, default = true })
  end)

  -- TOC / Help float：强制纯白底（不 default，覆盖 colorscheme）
  local function set_white_float(name, opts)
    local o = vim.tbl_extend("force", {
      bg = "#ffffff",
      fg = "#000000",
      default = false,
    }, opts or {})
    vim.api.nvim_set_hl(0, name, o)
  end
  set_white_float("MdViewTocFloat")
  set_white_float("MdViewTocFloatBorder", { fg = "#888888" })
  set_white_float("MdViewTocFloatTitle", { bold = true })
  set_white_float("MdViewTocFloatHint", { fg = "#666666" })
  set_white_float("MdViewTocFloatCursor", { bg = "#ddeeff", bold = true })
  local toc_item_ov = user_hls and user_hls.MdViewTocItem
  if type(toc_item_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewTocItem", vim.tbl_extend("force", {
      bg = "#ffffff",
      fg = "#000000",
      bold = true,
      default = false,
    }, toc_item_ov))
  else
    set_white_float("MdViewTocItem", { bold = true })
  end

  set_white_float("MdViewHelpFloat")
  set_white_float("MdViewHelpFloatBorder", { fg = "#888888" })
  set_white_float("MdViewHelpFloatTitle", { bold = true })
  vim.api.nvim_set_hl(0, "MdViewHelp", { link = "MdViewHelpFloatTitle", default = false })

  defined = true
end

function M.ensure()
  if not defined then
    M.setup(nil)
  end
end

---有限调色板，避免 E849
---@param n number
function M.ensure_image_palette(n)
  n = math.max(1, math.min(n or 32, 64))
  for i = 0, n - 1 do
    local name = "MdViewImg" .. i
    if vim.fn.hlexists(name) == 0 then
      -- 灰阶梯度，真彩色终端下可读
      local g = math.floor(40 + (i / math.max(n - 1, 1)) * 200)
      vim.api.nvim_set_hl(0, name, {
        fg = string.format("#%02x%02x%02x", g, g, g),
        default = true,
      })
    end
  end
end

return M
