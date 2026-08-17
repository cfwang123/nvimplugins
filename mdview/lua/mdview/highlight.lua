---@mod mdview.highlight
local M = {}

local defined = false

-- 标题默认色（层级递减饱和度，强制 bold；不链 Title，避免与正文同色）
local heading_defaults = {
  { fg = "#61afef", bold = true }, -- H1 亮蓝
  { fg = "#56b6c2", bold = true }, -- H2 青
  { fg = "#c678dd", bold = true }, -- H3 紫
  { fg = "#e5c07b", bold = true }, -- H4 金
  { fg = "#98c379", bold = true }, -- H5 绿
  { fg = "#d19a66", bold = true }, -- H6 橙
}

local links = {
  -- MdViewH1..H6 在 setup 中单独设色+bold，不用 link
  MdViewH1 = "",
  MdViewH2 = "",
  MdViewH3 = "",
  MdViewH4 = "",
  MdViewH5 = "",
  MdViewH6 = "",
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
  MdViewLink = "", -- 蓝字+下划线，见 setup
  MdViewImage = "Directory",
  MdViewImageBorder = "Comment",
  MdViewDetailsMarker = "Special",
  MdViewDetailsSummary = "Title",
  MdViewHeadingFold = "Comment", -- 标题 ▸/▼ 折叠标记
  MdViewCursor = "CursorLine",
  MdViewCursorLine = "", -- 源光标对应预览行（更醒目），见 setup
  MdViewCursorMark = "", -- 预览内光标位置标记
  MdViewHr = "Comment",
  MdViewTocTitle = "Title",
  MdViewTocItem = "", -- float 内 bold，见 setup
  MdViewTocSep = "Comment",
  MdViewTocFloat = "", -- 纯白底
  MdViewHelp = "",
  MdViewKeyHint = "Comment", -- 预览顶栏灰色快捷键提示
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

local function is_heading_hl(name)
  return type(name) == "string" and name:match("^MdViewH[1-6]$") ~= nil
end

function M.setup(user_hls)
  for name, link in pairs(links) do
    if
      name == "MdViewCodeBg"
      or name == "MdViewBold"
      or name == "MdViewItalic"
      or name == "MdViewStrike"
      or name == "MdViewLink"
      or is_heading_hl(name)
    then
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

  -- 标题层级：强制 bold + 独立色（不依赖 Title，避免被 MdViewBold 叠层冲掉）
  for i = 1, 6 do
    local name = "MdViewH" .. i
    local override = user_hls and user_hls[name]
    if type(override) == "table" then
      local o = vim.tbl_extend("force", { bold = true, default = false }, override)
      o.bold = true -- 用户可改色，仍保证加粗
      vim.api.nvim_set_hl(0, name, o)
    elseif type(override) == "string" then
      local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = override, link = false })
      if ok and base then
        base.bold = true
        base.default = false
        vim.api.nvim_set_hl(0, name, base)
      else
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = false }, heading_defaults[i]))
      end
    else
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = false }, heading_defaults[i]))
    end
  end

  -- 源→预览光标：块高亮颜色保持原样（CursorLine）；不再叠蓝色当前行
  local cur_ov = user_hls and user_hls.MdViewCursor
  if type(cur_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewCursor", vim.tbl_extend("force", { default = false }, cur_ov))
  elseif type(cur_ov) == "string" and cur_ov ~= "" then
    vim.api.nvim_set_hl(0, "MdViewCursor", { link = cur_ov, default = false })
  else
    -- 与改色前一致：跟 CursorLine，保证非焦点窗 extmark 也看得出
    local ok_cl, cl = pcall(vim.api.nvim_get_hl, 0, { name = "CursorLine", link = false })
    if ok_cl and cl and cl.bg then
      vim.api.nvim_set_hl(0, "MdViewCursor", { bg = cl.bg, default = false })
    else
      vim.api.nvim_set_hl(0, "MdViewCursor", { bg = "#2a2a3a", default = false })
    end
  end
  -- 组名保留兼容；默认链到块高亮（同步逻辑里已不再使用蓝行）
  local cur_line_ov = user_hls and user_hls.MdViewCursorLine
  if type(cur_line_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewCursorLine", vim.tbl_extend("force", { default = false }, cur_line_ov))
  elseif type(cur_line_ov) == "string" and cur_line_ov ~= "" then
    vim.api.nvim_set_hl(0, "MdViewCursorLine", { link = cur_line_ov, default = false })
  else
    vim.api.nvim_set_hl(0, "MdViewCursorLine", { link = "MdViewCursor", default = false })
  end
  local mark_ov = user_hls and user_hls.MdViewCursorMark
  if type(mark_ov) == "table" then
    vim.api.nvim_set_hl(0, "MdViewCursorMark", vim.tbl_extend("force", { default = false }, mark_ov))
  else
    -- 与改色前一致
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
  -- 链接：蓝字 + 蓝色下划线
  -- 必须同时设 fg 与 sp：只设 underline 时 guisp 常跟主题变成红/粉，看起来像源码里的 markdown 链
  local function link_blue()
    -- 仅采用明确偏蓝的 markdown 链接色；不要用 Underlined（常带红/粉 sp）
    for _, name in ipairs({
      "@markup.link",
      "@markup.link.label",
      "@markup.link.url",
      "markdownLinkText",
      "markdownUrl",
      "htmlLink",
    }) do
      local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
      if ok and hl and hl.fg then
        local fg = hl.fg
        if type(fg) == "number" then
          fg = string.format("#%06x", fg)
        end
        if type(fg) == "string" and fg:match("^#%x%x%x%x%x%x$") then
          local n = tonumber(fg:sub(2), 16) or 0
          local r = math.floor(n / 65536) % 256
          local g = math.floor(n / 256) % 256
          local b = n % 256
          local lum = 0.299 * r + 0.587 * g + 0.114 * b
          -- 要求明显偏蓝且亮度适中
          if lum > 40 and lum < 230 and b >= r + 20 and b >= g then
            return fg
          end
        end
      end
    end
    -- 按背景明暗：浅底深链蓝、深底亮链蓝
    local ok_n, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
    local bg = ok_n and normal and normal.bg
    if type(bg) == "number" then
      local r = math.floor(bg / 65536) % 256
      local g = math.floor(bg / 256) % 256
      local b = bg % 256
      local lum = 0.299 * r + 0.587 * g + 0.114 * b
      if lum > 140 then
        return "#0969da" -- 浅色底 GitHub 链接蓝
      end
    end
    return "#58a6ff" -- 深色底
  end
  local link_ov = user_hls and user_hls.MdViewLink
  if type(link_ov) == "table" then
    local blue = link_blue()
    local o = vim.tbl_extend("force", {
      fg = blue,
      sp = blue,
      underline = true,
      default = false,
    }, link_ov)
    if o.fg and (o.sp == nil or o.sp == "") then
      o.sp = o.fg
    end
    o.underline = true
    o.default = false
    vim.api.nvim_set_hl(0, "MdViewLink", o)
  elseif type(link_ov) == "string" and link_ov ~= "" then
    vim.api.nvim_set_hl(0, "MdViewLink", { link = link_ov, default = false })
  else
    local blue = link_blue()
    vim.api.nvim_set_hl(0, "MdViewLink", {
      fg = blue,
      sp = blue,
      underline = true,
      default = false,
    })
  end

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

  -- 预览顶部按键提示：灰色弱化（勿链到 HelpFloat 白底）
  local kh = user_hls and user_hls.MdViewKeyHint
  if type(kh) == "table" then
    vim.api.nvim_set_hl(0, "MdViewKeyHint", vim.tbl_extend("force", { default = false }, kh))
  elseif type(kh) == "string" and kh ~= "" then
    vim.api.nvim_set_hl(0, "MdViewKeyHint", { link = kh, default = false })
  else
    local ok_c, cmt = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
    if ok_c and cmt and cmt.fg then
      vim.api.nvim_set_hl(0, "MdViewKeyHint", { fg = cmt.fg, default = false })
    else
      vim.api.nvim_set_hl(0, "MdViewKeyHint", { fg = "#888888", default = false })
    end
  end

  defined = true
end

function M.ensure()
  if not defined then
    M.setup(nil)
  end
end

---动态 font 样式组缓存（名 → true）
local font_hl_cache = {}

---按 fg/bg/bold/italic 生成/复用高亮组名
---@param fg string|nil #rrggbb
---@param bg string|nil #rrggbb
---@param bold boolean|nil
---@param italic boolean|nil
---@return string|nil hl_group
function M.ensure_font_hl(fg, bg, bold, italic)
  bold = bold == true
  italic = italic == true
  if (not fg or fg == "") and (not bg or bg == "") and not bold and not italic then
    return nil
  end
  local key = (fg or "x")
    .. "_"
    .. (bg or "x")
    .. (bold and "_b" or "")
    .. (italic and "_i" or "")
  key = key:gsub("[^%w#_]", "")
  local name = "MdViewFont_" .. key:gsub("#", "")
  -- 组名长度/字符限制
  if #name > 60 then
    name = "MdViewFont_" .. tostring(vim.fn.sha256(key):sub(1, 12))
  end
  local opts = { default = false }
  if fg and fg ~= "" then
    opts.fg = fg
  end
  if bg and bg ~= "" then
    opts.bg = bg
  end
  if bold then
    opts.bold = true
  end
  if italic then
    opts.italic = true
  end
  pcall(vim.api.nvim_set_hl, 0, name, opts)
  font_hl_cache[name] = true
  return name
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
