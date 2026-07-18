---@mod es Everything 文件搜索（Windows es.exe CLI）
local M = {}
local i18n = require("es.i18n")

-- 仿 Everything 绿色放大镜（终端字符图标）
local ICON = "⌕" -- U+2315 TELEPHONE RECORDER-like search; fallback glyph
-- 更常见的放大镜
ICON = "🔍"

local default_config = {
  ---es.exe 可执行文件：PATH 中的名，或绝对路径
  es_cmd = "es",
  ---最多返回条数（传给 es -n）；列表用虚拟滚动，仅渲染窗口可见行
  max_results = 10000,
  ---默认快捷键；false 关闭
  keys_open = "<leader>es",
  ---仅文件（es /a-d）；false 则含目录
  files_only = true,
  ---打开时把当前 pwd 作为关键词预填进输入框（可 Backspace/Ctrl-u 清除）
  prefill_cwd = true,
  ---默认是否显示文件大小列（浮窗内可切换）
  show_size = true,
  ---打开文件命令："edit" | "split" | "vsplit" | "tabedit"
  open_cmd = "edit",
  ---es 额外参数（字符串列表）
  extra_args = {},
  ---输入防抖（毫秒）
  debounce_ms = 120,
  ---es 超时（毫秒）；大批量结果时适当放宽
  timeout_ms = 60000,
  ---浮窗
  width = 0.85,
  height = 0.65,
  border = "rounded",
  ---结果文件编码
  encoding = "utf-8",
  ---标题图标（Everything 风格）
  icon = ICON,
  ---匹配完整路径（es -p）；关键词 AND 时更符合“在路径下筛选”
  match_path = true,
  ---界面语言："auto" | "zh" | "en"；L 切换并记忆
  ui_lang = "auto",
  ---兼容旧配置名：cwd_only 视为 prefill_cwd
  cwd_only = nil,
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}

---@class EsResult
---@field path string  绝对路径（打开文件用）
---@field size integer|nil
---@field display string  列表显示路径（cwd 下会去掉前缀）
---@field under_cwd boolean  是否位于当前工作目录下

---@class EsState
---@field buf integer|nil
---@field win integer|nil
---@field query string
---@field qcol integer  查询串内光标：0-based 字符下标，可等于 #chars（末尾）
---@field focus string  "prompt" | "list"
---@field results EsResult[]
---@field sel integer  1-based 当前选中结果下标
---@field view_top integer  1-based 窗口内第一条结果在 results 中的下标
---@field job integer|nil
---@field timer any
---@field searching boolean
---@field last_err string|nil
---@field show_size boolean
---@field inserting boolean  是否在输入行 insert（支持中文 IME）
---@field _rendering boolean

local state = {
  buf = nil,
  win = nil,
  query = "",
  qcol = 0,
  focus = "prompt",
  results = {},
  sel = 1,
  view_top = 1,
  job = nil,
  timer = nil,
  searching = false,
  last_err = nil,
  show_size = true,
  inserting = false,
  _rendering = false,
}

local NS = vim.api.nvim_create_namespace("es_picker")
local SIZE_COL_W = 9
---固定表头行数：输入 / 状态 / 分隔线
local HEADER_LINES = 3

-- 前向声明（互相调用）
local schedule_search
local render
local enter_insert
local leave_insert
local set_query

---扩展名 → emoji 文件类型图标
---用户指定代码类型统一白纸 📄：cs/php/html/css/cshtml/py/js
local EXT_ICONS = {
  -- 代码（白纸）
  cs = "📄",
  php = "📄",
  html = "📄",
  htm = "📄",
  css = "📄",
  scss = "📄",
  less = "📄",
  cshtml = "📄",
  py = "📄",
  js = "📄",
  jsx = "📄",
  -- 其它代码
  lua = "🌙",
  ts = "🔷",
  tsx = "⚛️",
  java = "☕",
  c = "🔧",
  h = "🔧",
  cpp = "🔧",
  cc = "🔧",
  cxx = "🔧",
  hpp = "🔧",
  go = "🐹",
  rs = "🦀",
  rb = "💎",
  swift = "🐦",
  kt = "🟣",
  kts = "🟣",
  scala = "🔴",
  r = "📊",
  sql = "🗃️",
  sh = "💻",
  bash = "💻",
  ps1 = "💻",
  bat = "💻",
  cmd = "💻",
  vim = "💚",
  -- 标记 / 文档
  md = "📝",
  markdown = "📝",
  txt = "📄",
  rst = "📄",
  pdf = "📕",
  doc = "📘",
  docx = "📘",
  xls = "📗",
  xlsx = "📗",
  xlsm = "📗",
  ppt = "📙",
  pptx = "📙",
  csv = "📊",
  -- 配置 / 数据
  json = "📋",
  jsonc = "📋",
  yaml = "⚙️",
  yml = "⚙️",
  toml = "⚙️",
  ini = "⚙️",
  conf = "⚙️",
  cfg = "⚙️",
  xml = "📰",
  svg = "🖼️",
  -- 图片 / 媒体
  png = "🖼️",
  jpg = "🖼️",
  jpeg = "🖼️",
  gif = "🖼️",
  webp = "🖼️",
  bmp = "🖼️",
  ico = "🖼️",
  mp3 = "🎵",
  wav = "🎵",
  flac = "🎵",
  mid = "🎹",
  midi = "🎹",
  mp4 = "🎬",
  mkv = "🎬",
  avi = "🎬",
  mov = "🎬",
  webm = "🎬",
  -- 压缩 / 包
  zip = "📦",
  rar = "📦",
  ["7z"] = "📦",
  tar = "📦",
  gz = "📦",
  bz2 = "📦",
  xz = "📦",
  -- 其它
  exe = "⚙️",
  dll = "🧩",
  so = "🧩",
  lib = "🧩",
  obj = "🧱",
  o = "🧱",
  log = "📜",
  lock = "🔒",
  gitignore = "🙈",
  dockerfile = "🐳",
  draw = "🎨",
}

---@param path string
---@return string
local function file_type_icon(path)
  if not path or path == "" then
    return "📄"
  end
  if vim.fn.isdirectory(path) == 1 then
    return "📁"
  end
  local name = path:match("([^/\\]+)$") or path
  local lower = vim.fn.tolower(name)
  -- 无扩展名的特殊文件名
  if lower == "dockerfile" or lower == "makefile" or lower == "cmakelists.txt" then
    return EXT_ICONS.dockerfile or "📄"
  end
  if lower == ".gitignore" or lower == ".gitattributes" then
    return EXT_ICONS.gitignore or "🙈"
  end
  local ext = lower:match("%.([^.]+)$")
  if ext and EXT_ICONS[ext] then
    return EXT_ICONS[ext]
  end
  if ext == "md" then
    return "📝"
  end
  return "📄"
end
---输入行前缀：「图标 + 空格」
local function prompt_prefix()
  local ic = config.icon or ICON
  return ic .. " "
end

---从输入行剥离前缀，得到查询串。
---Backspace 可能只删掉空格、半个 emoji 或整段前缀；此时绝不能把残留图标当 query，
---否则会变成「🔍 🔍」（双图标）。
---@param line string
---@return string query
---@return boolean prefix_ok  前缀是否完整
local function extract_query_from_line(line)
  line = line or ""
  local pref = prompt_prefix()
  local ic = config.icon or ICON
  if pref ~= "" and line:sub(1, #pref) == pref then
    return line:sub(#pref + 1), true
  end
  -- 图标在、空格被删：🔍query
  if ic ~= "" and line:sub(1, #ic) == ic then
    local rest = line:sub(#ic + 1)
    if rest:sub(1, 1) == " " then
      rest = rest:sub(2)
    end
    return rest, false
  end
  -- 前缀整段被删，或半截多字节被破坏：整行当 query，但去掉误入的图标字符
  local q = line
  if ic ~= "" then
    -- 去掉行首图标（含后随空格）
    while true do
      local s, e = q:find(ic, 1, true)
      if not s then
        break
      end
      -- 仅剥行首一段
      if s == 1 then
        q = q:sub(e + 1)
        if q:sub(1, 1) == " " then
          q = q:sub(2)
        end
      else
        break
      end
    end
  end
  return q, false
end

local function is_win()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

local function ensure_hl()
  local function hl(name, spec)
    spec.force = true
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
  -- 白底 + 黑/灰字；图标用 Everything 绿
  hl("EsNormal", { fg = "#111111", bg = "#ffffff" })
  hl("EsPrompt", { fg = "#111111", bg = "#ffffff", bold = true })
  hl("EsPromptPrefix", { fg = "#60B020", bg = "#ffffff", bold = true })
  -- 单格方块光标（勿用宽字符 / virt_text）
  hl("EsCursor", { fg = "#ffffff", bg = "#111111", bold = true, ctermbg = "Black", ctermfg = "White" })
  hl("EsMatch", { fg = "#222222", bg = "#ffffff" })
  hl("EsMatchSel", { fg = "#000000", bg = "#dddddd", bold = true })
  hl("EsStatus", { fg = "#666666", bg = "#ffffff" })
  hl("EsBorder", { fg = "#60B020", bg = "#ffffff" })
  hl("EsEmpty", { fg = "#888888", bg = "#ffffff", italic = true })
  hl("EsTitle", { fg = "#60B020", bg = "#ffffff", bold = true })
  hl("EsSep", { fg = "#bbbbbb", bg = "#ffffff" })
  hl("EsSize", { fg = "#555555", bg = "#ffffff" })
  hl("EsSizeSel", { fg = "#000000", bg = "#dddddd", bold = true })
  -- 结果中与输入词匹配的片段
  hl("EsHit", { fg = "#8B4513", bg = "#FFE082", bold = true })
  hl("EsHitSel", { fg = "#000000", bg = "#FFCA28", bold = true })
end

local function dw(s)
  return vim.fn.strdisplaywidth(s or "")
end

local function qlen()
  return vim.fn.strchars(state.query or "")
end

local function clamp_qcol()
  local n = qlen()
  if state.qcol < 0 then
    state.qcol = 0
  elseif state.qcol > n then
    state.qcol = n
  end
end

---当前 pwd 作为关键词：`"D:\foo\bar" `（双引号 + 引号外空格）
---注意：路径末尾不要带 `\`。es CLI 对「含空格路径 + 末尾反斜杠」会 0 结果（如 C:\Program Files\）。
---@return string
local function cwd_keyword()
  local p = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  if p == "" then
    return ""
  end
  -- 统一为 Windows 反斜杠风格
  if is_win() then
    p = p:gsub("/", "\\")
  end
  -- 去掉末尾分隔符（避免 Program Files\ 等 0 命中）
  p = p:gsub("[/\\]+$", "")
  -- 路径内引号 → ""
  p = p:gsub('"', '""')
  return '"' .. p .. '" '
end

---传给 es 的单个词：去掉误带的引号；绝对路径去掉末尾 \（含空格时尤其必要）
---@param t string
---@return string
local function normalize_es_term(t)
  t = vim.trim(t or "")
  if t == "" then
    return t
  end
  -- 整段被引号包住时去掉（引号只用于输入分词，不应传给 es）
  local unq = t:match('^"(.*)"$')
  if unq then
    t = unq
  end
  -- 盘符路径 / UNC：去末尾斜杠
  if t:match("^%a:[/\\]") or t:match("^\\\\") then
    t = t:gsub("[/\\]+$", "")
  elseif t:find("%s") then
    -- 其它含空格片段也去掉末尾 \
    t = t:gsub("[/\\]+$", "")
  end
  return t
end

---规范化目录路径（统一分隔符、去末尾斜杠）
---@param p string
---@return string
local function norm_dir(p)
  p = tostring(p or "")
  if is_win() then
    p = p:gsub("/", "\\")
  else
    p = p:gsub("\\", "/")
  end
  p = p:gsub("[/\\]+$", "")
  return p
end

---@return string
local function get_cwd_norm()
  return norm_dir(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))
end

---是否像绝对路径关键词（盘符路径 / UNC），应用 -path 精确限定而非子串匹配
---@param t string
---@return boolean
local function is_abs_path_term(t)
  t = tostring(t or "")
  if t:match("^%a:[/\\]") then
    return true
  end
  if t:match("^\\\\") then
    return true
  end
  return false
end

---file 是否位于 root 目录下（边界正确：Program Files 不含 Program Files (x86)）
---@param file string
---@param root string
---@return boolean
local function path_is_under_root(file, root)
  file = tostring(file or "")
  root = norm_dir(root)
  if file == "" or root == "" then
    return false
  end
  local sep = is_win() and "\\" or "/"
  local fn = is_win() and file:gsub("/", "\\") or file:gsub("\\", "/")
  local fl = is_win() and vim.fn.tolower(fn) or fn
  local rl = is_win() and vim.fn.tolower(root) or root
  if fl == rl then
    return true
  end
  -- 必须以 root\ 开头，不能是 rootXXX
  local pref = rl .. sep
  return fl:sub(1, #pref) == pref
end

---若 abs 在 cwd 下，返回相对显示路径；否则返回原路径
---@param abs string
---@param cwd string
---@return boolean under_cwd
---@return string display
local function relativize_to_cwd(abs, cwd)
  abs = tostring(abs or "")
  cwd = norm_dir(cwd)
  if abs == "" or cwd == "" then
    return false, abs
  end
  if not path_is_under_root(abs, cwd) then
    return false, abs
  end
  local abs_n = norm_dir(abs)
  local cl = is_win() and vim.fn.tolower(cwd) or cwd
  local al = is_win() and vim.fn.tolower(abs_n) or abs_n
  if al == cl then
    return true, "."
  end
  local sep = is_win() and "\\" or "/"
  local pref_len = #cwd + #sep
  -- 用与 cwd 相同长度前缀（大小写可能不同）从 abs_n 截取
  return true, abs_n:sub(pref_len + 1)
end

---拆分：绝对路径词 → path roots；其余 → 普通关键词
---@param terms string[]
---@return string[] path_roots
---@return string[] keywords
local function classify_terms(terms)
  local path_roots, keywords = {}, {}
  for _, t in ipairs(terms or {}) do
    local nt = normalize_es_term(t)
    if nt == "" then
      -- skip
    elseif is_abs_path_term(nt) then
      path_roots[#path_roots + 1] = norm_dir(nt)
    else
      keywords[#keywords + 1] = nt
    end
  end
  return path_roots, keywords
end

---加工结果：按 path roots 过滤 + 相对路径显示 + cwd 内优先排序
---@param results EsResult[]
---@param path_roots? string[]
---@return EsResult[]
local function process_results(results, path_roots)
  path_roots = path_roots or {}
  local cwd = get_cwd_norm()
  local filtered = {}
  for i, item in ipairs(results) do
    local ok = true
    -- 所有绝对路径词都必须作为「目录前缀」成立（AND），避免 Program Files ⊂ Program Files (x86)
    for _, root in ipairs(path_roots) do
      if not path_is_under_root(item.path, root) then
        ok = false
        break
      end
    end
    if ok then
      local under, disp = relativize_to_cwd(item.path, cwd)
      item.under_cwd = under
      item.display = disp
      item._ord = i
      filtered[#filtered + 1] = item
    end
  end
  table.sort(filtered, function(a, b)
    if a.under_cwd ~= b.under_cwd then
      return a.under_cwd and not b.under_cwd
    end
    return (a._ord or 0) < (b._ord or 0)
  end)
  return filtered
end

---按显示宽度取前缀
---@param s string
---@param budget integer
---@return string
local function take_prefix_dw(s, budget)
  if budget <= 0 then
    return ""
  end
  local out = ""
  local n = vim.fn.strchars(s)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    if dw(out .. ch) > budget then
      break
    end
    out = out .. ch
  end
  return out
end

---按显示宽度取后缀
---@param s string
---@param budget integer
---@return string
local function take_suffix_dw(s, budget)
  if budget <= 0 then
    return ""
  end
  local out = ""
  local n = vim.fn.strchars(s)
  for i = n, 1, -1 do
    local ch = vim.fn.strcharpart(s, i - 1, 1)
    if dw(ch .. out) > budget then
      break
    end
    out = ch .. out
  end
  return out
end

---文件名过长时压缩，优先保留扩展名
---@param name string
---@param maxw integer
---@return string
local function truncate_keep_ext(name, maxw)
  if dw(name) <= maxw then
    return name
  end
  local ell = "..."
  local ell_w = dw(ell)
  if maxw <= ell_w then
    return take_suffix_dw(name, maxw)
  end
  local ext = name:match("(%.[^%.\\/]+)$") or ""
  local base = (#ext > 0) and name:sub(1, #name - #ext) or name
  local ext_w = dw(ext)
  local budget = maxw - ell_w - ext_w
  if budget < 1 then
    -- 至少保住扩展名尾部
    return take_suffix_dw(name, maxw)
  end
  return take_prefix_dw(base, budget) .. ell .. ext
end

---路径压缩：优先完整显示「文件名+扩展名」，中间目录折叠为 ...
---例：C:\Users\foo\bar\baz\longname.cshtml → C:\Users\...\longname.cshtml
---@param s string
---@param maxw integer
---@return string
local function truncate_middle(s, maxw)
  s = s or ""
  maxw = math.max(0, maxw or 0)
  if maxw <= 0 then
    return ""
  end
  if dw(s) <= maxw then
    return s
  end
  local ell = "..."
  local ell_w = dw(ell)
  if maxw <= ell_w then
    return take_suffix_dw(s, maxw)
  end

  -- 拆目录 / 文件名
  local name = s:match("([^/\\]+)$") or s
  local dir = (#name < #s) and s:sub(1, #s - #name) or ""
  local name_w = dw(name)

  -- 连文件名都放不下：压文件名但保扩展名
  if name_w >= maxw then
    return truncate_keep_ext(name, maxw)
  end

  -- 只够显示 ... + 文件名
  if name_w + ell_w >= maxw then
    return truncate_keep_ext(name, maxw)
  end

  -- 给目录前缀留宽：head...name，完整保留文件名（含扩展名）
  local head_budget = maxw - ell_w - name_w
  if head_budget < 1 then
    return ell .. name
  end
  if dir == "" then
    return truncate_keep_ext(name, maxw)
  end
  local head = take_prefix_dw(dir, head_budget)
  -- 避免 head 以半截分隔符难看：若末字符不是分隔且后面还有内容，仍可直接拼
  return head .. ell .. name
end

---@param n integer|nil
---@return string
local function fmt_size(n)
  n = tonumber(n)
  if n == nil then
    return ""
  end
  local abs = math.abs(n)
  if abs < 1024 then
    return string.format("%dB", n)
  end
  if abs < 1024 * 1024 then
    return string.format("%.1fK", n / 1024)
  end
  if abs < 1024 * 1024 * 1024 then
    return string.format("%.1fM", n / (1024 * 1024))
  end
  return string.format("%.1fG", n / (1024 * 1024 * 1024))
end

---@param s string
---@param width integer
---@return string
local function pad_left(s, width)
  s = s or ""
  local w = dw(s)
  if w >= width then
    return s
  end
  return string.rep(" ", width - w) .. s
end

---@param s string
---@return string
local function decode_line(s)
  if not s or s == "" then
    return s
  end
  s = s:gsub("\r", "")
  local enc = config.encoding or "utf-8"
  if enc == "utf-8" or enc == "utf8" then
    return s
  end
  if enc == "auto" then
    if not s:find("[\128-\255]") then
      return s
    end
    for _, from in ipairs({ "utf-8", "cp936", "gbk", "gb2312" }) do
      local ok, out = pcall(vim.fn.iconv, s, from, "utf-8")
      if ok and type(out) == "string" and out ~= "" and not out:find("\0", 1, true) then
        if from == "utf-8" then
          return s
        end
        return out
      end
    end
    return s
  end
  local ok, out = pcall(vim.fn.iconv, s, enc, "utf-8")
  if ok and type(out) == "string" and out ~= "" then
    return out
  end
  return s
end

---@param line string
---@return EsResult|nil
local function parse_csv_result(line)
  line = vim.trim(decode_line(tostring(line or "")))
  if line == "" then
    return nil
  end
  if line:lower():match("^size,") or line:lower() == "filename" then
    return nil
  end
  local size_s, path = line:match('^(%-?%d+)%s*,%s*"(.*)"%s*$')
  if size_s and path then
    path = path:gsub('""', '"')
    return { path = path, size = tonumber(size_s) }
  end
  size_s, path = line:match("^(%-?%d+)%s*,%s*(.+)$")
  if size_s and path then
    path = path:gsub('^"(.*)"$', "%1")
    return { path = path, size = tonumber(size_s) }
  end
  path = line:gsub('^"(.*)"$', "%1")
  if path ~= "" then
    return { path = path, size = nil }
  end
  return nil
end

---空格分词（彼此 AND）。es 需要每个词单独 argv；整串带空格时路径+关键词会 0 结果。
---支持 "双引号短语" 作为一个词（路径含空格时请加引号）。
---@param q string
---@return string[]
local function split_search_terms(q)
  q = vim.trim(q or "")
  local terms = {}
  local i = 1
  local len = #q
  while i <= len do
    while i <= len and q:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then
      break
    end
    if q:sub(i, i) == '"' then
      local j = i + 1
      local parts = {}
      while j <= len do
        local c = q:sub(j, j)
        if c == '"' then
          j = j + 1
          break
        end
        parts[#parts + 1] = c
        j = j + 1
      end
      local phrase = table.concat(parts)
      if phrase ~= "" then
        terms[#terms + 1] = phrase
      end
      i = j
    else
      local j = i
      while j <= len and not q:sub(j, j):match("%s") do
        j = j + 1
      end
      local t = q:sub(i, j - 1)
      if t ~= "" then
        terms[#terms + 1] = t
      end
      i = j
    end
  end
  return terms
end

---@param path string
---@return EsResult[]
local function read_export_csv(path)
  local results = {}
  if not path or vim.fn.filereadable(path) ~= 1 then
    return results
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return results
  end
  for _, line in ipairs(lines) do
    local item = parse_csv_result(line)
    if item and item.path and item.path ~= "" then
      results[#results + 1] = item
    end
  end
  return results
end

---@return string|nil
local function resolve_es_cmd()
  local cmd = config.es_cmd or "es"
  if cmd == "" then
    cmd = "es"
  end
  if vim.fn.executable(cmd) == 1 then
    return cmd
  end
  local candidates = {
    "es.exe",
    "C:\\bin\\es.exe",
    vim.fn.expand("~/bin/es.exe"),
    vim.fn.expand("~/AppData/Local/Microsoft/WindowsApps/es.exe"),
    "C:\\Program Files\\Everything\\es.exe",
    "C:\\Program Files (x86)\\Everything\\es.exe",
  }
  for _, c in ipairs(candidates) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      return c
    end
  end
  if vim.fn.filereadable(cmd) == 1 then
    return cmd
  end
  return nil
end

local function cancel_job()
  if state.job and state.job > 0 then
    pcall(vim.fn.jobstop, state.job)
  end
  state.job = nil
  state.searching = false
end

local function cancel_timer()
  if state.timer then
    pcall(function()
      state.timer:stop()
      state.timer:close()
    end)
    state.timer = nil
  end
end

function M.is_open()
  return state.win
    and vim.api.nvim_win_is_valid(state.win)
    and state.buf
    and vim.api.nvim_buf_is_valid(state.buf)
end

local function close_ui()
  cancel_timer()
  cancel_job()
  state.inserting = false
  pcall(vim.cmd, "stopinsert")
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf = nil, nil
  state.results = {}
  state.sel = 1
  state.view_top = 1
  state.query = ""
  state.qcol = 0
  state.focus = "prompt"
  state.last_err = nil
end

---@param path string
---@param how? string
local function open_path(path, how)
  if not path or path == "" then
    return
  end
  how = how or config.open_cmd or "edit"
  local cmd = how
  if how == "edit" then
    cmd = "edit"
  elseif how == "split" or how == "sp" then
    cmd = "split"
  elseif how == "vsplit" or how == "vs" then
    cmd = "vsplit"
  elseif how == "tabedit" or how == "tab" then
    cmd = "tabedit"
  end
  close_ui()
  if vim.fn.isdirectory(path) == 1 then
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
    return
  end
  pcall(vim.cmd, cmd .. " " .. vim.fn.fnameescape(path))
end

local function win_cols()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return vim.api.nvim_win_get_width(state.win)
  end
  return math.max(40, vim.o.columns - 4)
end

---结果区可见行数（窗口高度 − 表头）
---@return integer
local function list_height()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return math.max(1, vim.api.nvim_win_get_height(state.win) - HEADER_LINES)
  end
  return 20
end

---保证选中项落在可见窗口内，必要时滚动 view_top
local function ensure_sel_visible()
  local n = #state.results
  if n == 0 then
    state.view_top = 1
    return
  end
  if state.sel < 1 then
    state.sel = 1
  elseif state.sel > n then
    state.sel = n
  end
  local h = list_height()
  local top = state.view_top or 1
  if top < 1 then
    top = 1
  end
  if state.sel < top then
    top = state.sel
  elseif state.sel > top + h - 1 then
    top = state.sel - h + 1
  end
  local max_top = math.max(1, n - h + 1)
  if top > max_top then
    top = max_top
  end
  state.view_top = top
end

local function status_text()
  local n = #state.results
  local q = state.query
  local size_flag = state.show_size and i18n.t("size_on") or i18n.t("size_off")
  local focus = state.focus == "list" and i18n.t("focus_list") or i18n.t("focus_prompt")
  if state.searching then
    return " " .. i18n.t("searching") .. "  " .. size_flag .. "  [" .. focus .. "]"
  end
  if state.last_err and state.last_err ~= "" then
    return " " .. state.last_err
  end
  if vim.trim(q or "") == "" then
    return string.format(" %s  [%s]  %s", size_flag, focus, i18n.t("hint_idle"))
  end
  if n == 0 then
    return string.format(
      " %s  %s  [%s]  %s",
      i18n.t("no_results"),
      size_flag,
      focus,
      i18n.t("f2_size")
    )
  end
  local sel = math.max(1, math.min(state.sel, n))
  local h = list_height()
  local top = state.view_top or 1
  local bot = math.min(n, top + h - 1)
  return " " .. i18n.t("status_hits", sel, n, top, bot, size_flag, focus)
end

---@param item EsResult
---@param cols integer
---@return string line
---@return integer size_end  大小列结束字节列；无大小列为 0
---@return integer path_start  路径起始字节列（0-based）
local function format_result_line(item, cols)
  -- 列表显示：cwd 下用相对路径，其它用绝对路径；左侧 emoji 类型图标
  local path = item.display or item.path or ""
  local icon = file_type_icon(item.path or path)
  local icon_block = icon .. " "
  local icon_bytes = #icon_block
  local icon_w = dw(icon_block)

  if state.show_size then
    local size_part = pad_left(fmt_size(item.size), SIZE_COL_W)
    local size_block = " " .. size_part .. " "
    local size_end = #size_block
    local path_start = size_end + icon_bytes
    local path_w = math.max(8, cols - dw(size_block) - icon_w)
    return size_block .. icon_block .. truncate_middle(path, path_w), size_end, path_start
  end
  local left = " " .. icon_block
  local path_start = #left
  return left .. truncate_middle(path, math.max(8, cols - dw(left))), 0, path_start
end

---在 text 中查找 term 的所有出现（大小写不敏感，0-based 字节区间 [s,e)）
---@param text string
---@param term string
---@return { s: integer, e: integer }[]
local function find_term_spans(text, term)
  local spans = {}
  if not text or text == "" or not term or term == "" then
    return spans
  end
  -- 纯空白跳过
  if vim.trim(term) == "" then
    return spans
  end
  local ok_tl, low_text = pcall(vim.fn.tolower, text)
  local ok_tn, low_term = pcall(vim.fn.tolower, term)
  if not ok_tl or not ok_tn or not low_text or not low_term or low_term == "" then
    low_text = text
    low_term = term
  end
  -- 字节级 plain find（中文 tolower 不变，路径盘符可折叠）
  local from = 1
  local tlen = #low_term
  while from <= #low_text do
    local s, e = string.find(low_text, low_term, from, true)
    if not s then
      break
    end
    spans[#spans + 1] = { s = s - 1, e = e }
    from = s + 1
  end
  return spans
end

---根据当前查询词，在路径显示段上计算匹配字节区间（相对整行）
---@param line string
---@param path_start integer
---@param terms string[]
---@return { s: integer, e: integer }[]
local function match_spans_on_line(line, path_start, terms)
  local out = {}
  if not line or path_start < 0 or path_start >= #line then
    return out
  end
  local path_disp = line:sub(path_start + 1)
  if path_disp == "" or not terms or #terms == 0 then
    return out
  end
  local seen = {}
  for _, term in ipairs(terms) do
    -- 过长路径词若整段就是盘符路径，仍高亮
    for _, sp in ipairs(find_term_spans(path_disp, term)) do
      local s = path_start + sp.s
      local e = path_start + sp.e
      local key = s .. ":" .. e
      if not seen[key] and s < e and e <= #line then
        seen[key] = true
        out[#out + 1] = { s = s, e = e }
      end
    end
  end
  return out
end

---查询串中 0-based 字符列 → 字节列（用于 extmark / cursor）
---@param q string
---@param char_col integer
---@return integer
local function charcol_to_bytecol(q, char_col)
  if char_col <= 0 then
    return 0
  end
  local part = vim.fn.strcharpart(q, 0, char_col)
  return #part
end

local function is_inserting()
  return state.inserting and M.is_open() and vim.fn.mode():find("i") ~= nil
end

local function place_prompt_cursor()
  if not M.is_open() then
    return
  end
  if state.focus ~= "prompt" then
    return
  end
  clamp_qcol()
  local pref = prompt_prefix()
  local byte = #pref + charcol_to_bytecol(state.query or "", state.qcol)
  pcall(vim.api.nvim_win_set_cursor, state.win, { 1, byte })
end

---从输入行同步 query（insert 模式下供 IME 使用；不整页重绘第 1 行）
local function sync_query_from_line()
  if not M.is_open() or state._rendering then
    return
  end
  local line1 = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
  local pref = prompt_prefix()
  local q, prefix_ok = extract_query_from_line(line1)
  if not prefix_ok then
    -- 前缀被删/破坏：恢复前缀，且 q 已剥离残留图标
    state._rendering = true
    pcall(function()
      vim.bo[state.buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { pref .. q })
      local col = #pref + #q
      pcall(vim.api.nvim_win_set_cursor, state.win, { 1, col })
    end)
    state._rendering = false
    line1 = pref .. q
  end
  -- 光标位置 → qcol（以恢复后的行 + 前缀为准）
  local okc, cur = pcall(vim.api.nvim_win_get_cursor, state.win)
  if okc and cur then
    local bcol = cur[2] -- 0-based byte
    local before
    if bcol <= #pref then
      before = ""
      -- 不允许光标进入前缀
      pcall(vim.api.nvim_win_set_cursor, state.win, { 1, #pref })
    else
      before = line1:sub(#pref + 1, bcol)
    end
    state.qcol = vim.fn.strchars(before)
  end
  if q ~= state.query then
    state.query = q
    state.focus = "prompt"
    schedule_search()
  end
end

---构建状态行 + 分隔 + 结果（不含输入行）
---@return string[]
---@return table[]
local function build_body()
  ensure_sel_visible()
  local cols = win_cols()
  local q = state.query or ""
  local lines = {}
  lines[1] = status_text()
  lines[2] = string.rep("─", math.max(20, cols - 2))

  local meta = {}
  local results = state.results
  local terms = split_search_terms(q)
  local n = #results

  if n == 0 then
    if vim.trim(q) == "" then
      lines[#lines + 1] = "  " .. i18n.t("empty_hint")
    elseif state.searching then
      lines[#lines + 1] = i18n.t("searching_dots")
    else
      lines[#lines + 1] = "  " .. i18n.t("no_match")
    end
  else
    local h = list_height()
    local top = state.view_top or 1
    local bot = math.min(n, top + h - 1)
    for i = top, bot do
      local item = results[i]
      local line, size_end, path_start = format_result_line(item, cols)
      lines[#lines + 1] = line
      meta[#meta + 1] = {
        size_end = size_end,
        path_start = path_start or 0,
        hits = match_spans_on_line(line, path_start or 0, terms),
        result_idx = i,
      }
    end
  end
  return lines, meta
end

---@param meta table[]
---@param body_lines string[]
local function paint_body_highlights(meta, body_lines)
  -- body 从 buffer 行 1 开始（0-based）：status=1, sep=2, results=3...
  pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 1, 0, {
    end_line = 2,
    end_col = 0,
    hl_group = "EsStatus",
  })
  local sep = body_lines[2] or ""
  pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 2, 0, {
    end_col = #sep,
    hl_group = "EsSep",
  })

  local n = #state.results
  if n == 0 or #meta == 0 then
    return
  end
  local sel = math.max(1, math.min(state.sel, n))
  for mi, m in ipairs(meta) do
    local row = HEADER_LINES + mi - 1 -- 0-based buffer row
    local line = body_lines[mi + 2] or "" -- body_lines[1]=status,[2]=sep,[3]=first result
    local is_sel = m.result_idx == sel and state.focus == "list"
    local size_end = m.size_end or 0
    local hits = m.hits or {}
    local hl_main = is_sel and "EsMatchSel" or "EsMatch"
    local hl_size = is_sel and "EsSizeSel" or "EsSize"
    local hl_hit = is_sel and "EsHitSel" or "EsHit"
    if size_end > 0 and size_end <= #line then
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, row, 0, {
        end_col = size_end,
        hl_group = hl_size,
        priority = 10,
      })
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, row, size_end, {
        end_col = #line,
        hl_group = hl_main,
        priority = 10,
      })
    else
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, row, 0, {
        end_col = #line,
        hl_group = hl_main,
        priority = 10,
      })
    end
    if is_sel then
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, row, 0, {
        end_col = #line,
        line_hl_group = "EsMatchSel",
        priority = 5,
      })
    end
    for _, sp in ipairs(hits) do
      if sp.s >= 0 and sp.e > sp.s and sp.e <= #line then
        pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, row, sp.s, {
          end_col = sp.e,
          hl_group = hl_hit,
          priority = 20,
        })
      end
    end
  end
end

local function paint_prompt_highlights(q, pref, inserting)
  pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 0, 0, {
    end_col = #pref,
    hl_group = "EsPromptPrefix",
  })
  if #q > 0 then
    pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 0, #pref, {
      end_col = #pref + #q,
      hl_group = "EsPrompt",
    })
  end
  -- insert 模式用真实光标（IME 需要）；normal 用单格 EsCursor
  if state.focus == "prompt" and not inserting then
    clamp_qcol()
    local b0 = #pref + charcol_to_bytecol(q, state.qcol)
    local ch = vim.fn.strcharpart(q, state.qcol, 1)
    if ch == "" then
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 0, b0, {
        end_col = b0 + 1,
        hl_group = "EsCursor",
        priority = 100,
      })
    else
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, 0, b0, {
        end_col = b0 + #ch,
        hl_group = "EsCursor",
        priority = 100,
      })
    end
  end
end

---渲染
---@param opts? { body_only?: boolean }
render = function(opts)
  opts = opts or {}
  if not M.is_open() then
    return
  end
  ensure_hl()
  ensure_sel_visible()

  local inserting = is_inserting()
  local body_only = opts.body_only and inserting
  local q = state.query or ""
  local pref = prompt_prefix()
  local body_lines, meta = build_body()
  local n = #state.results

  state._rendering = true
  pcall(function()
    vim.bo[state.buf].modifiable = true
    if body_only then
      -- 只更新第 2 行起，避免打断中文 IME 组字
      vim.api.nvim_buf_set_lines(state.buf, 1, -1, false, body_lines)
    else
      local prompt_line = pref .. q
      if not inserting then
        -- normal：末尾留 1 ASCII 空格给方块光标
        prompt_line = prompt_line .. " "
      end
      local all = { prompt_line }
      for _, l in ipairs(body_lines) do
        all[#all + 1] = l
      end
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, all)
    end
    -- insert 保持可改；列表/normal 锁定
    vim.bo[state.buf].modifiable = inserting or false
  end)
  state._rendering = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  if not body_only then
    paint_prompt_highlights(q, pref, inserting)
  else
    -- 仍刷新前缀色（不改文字）
    paint_prompt_highlights(q, pref, true)
  end
  paint_body_highlights(meta, body_lines)

  if inserting then
    -- 不抢光标，IME 组字中
    return
  end

  if state.focus == "prompt" then
    place_prompt_cursor()
  elseif n > 0 and state.win and vim.api.nvim_win_is_valid(state.win) then
    local top = state.view_top or 1
    local row = HEADER_LINES + (state.sel - top) + 1
    local max_row = vim.api.nvim_buf_line_count(state.buf)
    if row < 1 then
      row = 1
    elseif row > max_row then
      row = max_row
    end
    pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
  end
end

leave_insert = function()
  state.inserting = false
  if vim.fn.mode():find("i") then
    pcall(vim.cmd, "stopinsert")
  end
  if M.is_open() then
    pcall(function()
      vim.bo[state.buf].modifiable = false
    end)
  end
end

enter_insert = function()
  if not M.is_open() then
    return
  end
  state.focus = "prompt"
  state.inserting = true
  render()
  pcall(function()
    vim.bo[state.buf].modifiable = true
  end)
  place_prompt_cursor()
  vim.schedule(function()
    if not M.is_open() then
      return
    end
    state.inserting = true
    pcall(function()
      vim.bo[state.buf].modifiable = true
    end)
    pcall(vim.cmd, "startinsert")
  end)
end

---@param query string
local function run_search(query)
  query = query or ""
  state.query = query
  state.last_err = nil

  -- trim：`D:\path\ ` 单独会 0 结果
  local search_q = vim.trim(query)
  -- 空格分词 → 多个 argv，es 按 AND 组合（单字符串带空格时路径+词会失败）
  local terms = split_search_terms(search_q)
  local function refresh_ui()
    if is_inserting() then
      render({ body_only = true })
    else
      render()
    end
  end

  if #terms == 0 then
    cancel_job()
    state.results = {}
    state.sel = 1
    state.view_top = 1
    refresh_ui()
    return
  end

  local es = resolve_es_cmd()
  if not es then
    state.results = {}
    state.sel = 1
    state.view_top = 1
    state.last_err = i18n.t("es_not_found")
    refresh_ui()
    return
  end

  cancel_job()
  state.searching = true
  refresh_ui()

  local tmp = vim.fn.tempname() .. "_es_export.csv"
  pcall(vim.fn.delete, tmp)

  local path_roots, keywords = classify_terms(terms)

  local args = { es }
  if config.files_only then
    table.insert(args, "/a-d")
  end
  local maxn = tonumber(config.max_results) or 10000
  table.insert(args, "-n")
  table.insert(args, tostring(maxn))
  table.insert(args, "-size")
  table.insert(args, "-size-format")
  table.insert(args, "1")
  table.insert(args, "-no-header")
  table.insert(args, "-export-csv")
  table.insert(args, tmp)
  -- 绝对路径用 -path 精确限定目录（避免 "Program Files" 命中 "Program Files (x86)"）
  -- es 的 -path 取最后一个；多个根目录时用第一个查询，其余靠结果过滤
  if #path_roots > 0 then
    table.insert(args, "-path")
    table.insert(args, path_roots[1])
  end
  -- 关键词匹配完整路径（在 -path 范围内）
  if config.match_path ~= false and #keywords > 0 then
    table.insert(args, "-p")
  end
  for _, a in ipairs(config.extra_args or {}) do
    table.insert(args, a)
  end
  for _, k in ipairs(keywords) do
    table.insert(args, k)
  end

  local err_chunks = {}
  local job = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            err_chunks[#err_chunks + 1] = decode_line(line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local results = process_results(read_export_csv(tmp), path_roots)
        pcall(vim.fn.delete, tmp)
        if not M.is_open() then
          return
        end
        state.searching = false
        state.job = nil
        state.results = results
        state.sel = 1
        state.view_top = 1
        if #results == 0 and code ~= 0 then
          local err = table.concat(err_chunks, " ")
          if err == "" then
            err = i18n.t("es_exit", code)
          end
          state.last_err = err
        end
        if is_inserting() then
          render({ body_only = true })
        else
          render()
        end
      end)
    end,
  })

  if job <= 0 then
    state.searching = false
    state.job = nil
    pcall(vim.fn.delete, tmp)
    state.last_err = i18n.t("es_start_fail")
    if is_inserting() then
      render({ body_only = true })
    else
      render()
    end
    return
  end
  state.job = job
  local timeout = tonumber(config.timeout_ms) or 8000
  if timeout > 0 then
    vim.defer_fn(function()
      if state.job == job then
        cancel_job()
        pcall(vim.fn.delete, tmp)
        state.last_err = i18n.t("es_timeout", timeout)
        if M.is_open() then
          if is_inserting() then
            render({ body_only = true })
          else
            render()
          end
        end
      end
    end, timeout)
  end
end

schedule_search = function()
  cancel_timer()
  local ms = tonumber(config.debounce_ms) or 120
  state.timer = vim.defer_fn(function()
    state.timer = nil
    if M.is_open() then
      run_search(state.query)
    end
  end, ms)
end

---设置查询；keep_col=true 时不改 qcol
---@param q string
---@param do_search boolean|nil
---@param opts? { keep_col?: boolean, col?: integer, stay_insert?: boolean }
set_query = function(q, do_search, opts)
  opts = opts or {}
  state.query = q or ""
  if opts.col ~= nil then
    state.qcol = opts.col
  elseif not opts.keep_col then
    state.qcol = qlen()
  end
  clamp_qcol()
  state.focus = "prompt"
  if do_search == false then
    render()
    if opts.stay_insert then
      enter_insert()
    end
    return
  end
  schedule_search()
  if is_inserting() or opts.stay_insert then
    -- 更新输入行文字（IME 外的程序化设置）并同步光标
    local pref = prompt_prefix()
    state._rendering = true
    pcall(function()
      vim.bo[state.buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { pref .. state.query })
      local col = #pref + charcol_to_bytecol(state.query or "", state.qcol)
      pcall(vim.api.nvim_win_set_cursor, state.win, { 1, col })
    end)
    state._rendering = false
    render({ body_only = true })
    if opts.stay_insert and not is_inserting() then
      enter_insert()
    end
  else
    render()
  end
end

local function insert_chars(text)
  if not text or text == "" then
    return
  end
  -- 单行
  text = tostring(text):gsub("[\r\n].*", "")
  local q = state.query or ""
  clamp_qcol()
  local left = vim.fn.strcharpart(q, 0, state.qcol)
  local right = vim.fn.strcharpart(q, state.qcol, qlen() - state.qcol)
  local newq = left .. text .. right
  local newcol = state.qcol + vim.fn.strchars(text)
  set_query(newq, true, { col = newcol })
end

local function backspace()
  clamp_qcol()
  if state.qcol <= 0 then
    return
  end
  local q = state.query or ""
  local left = vim.fn.strcharpart(q, 0, state.qcol - 1)
  local right = vim.fn.strcharpart(q, state.qcol, qlen() - state.qcol)
  set_query(left .. right, true, { col = state.qcol - 1 })
end

local function delete_forward()
  clamp_qcol()
  local n = qlen()
  if state.qcol >= n then
    return
  end
  local q = state.query or ""
  local left = vim.fn.strcharpart(q, 0, state.qcol)
  local right = vim.fn.strcharpart(q, state.qcol + 1, n - state.qcol - 1)
  set_query(left .. right, true, { col = state.qcol })
end

local function cursor_left()
  state.focus = "prompt"
  clamp_qcol()
  if state.qcol > 0 then
    state.qcol = state.qcol - 1
  end
  render()
end

local function cursor_right()
  state.focus = "prompt"
  clamp_qcol()
  if state.qcol < qlen() then
    state.qcol = state.qcol + 1
  end
  render()
end

local function cursor_home()
  state.focus = "prompt"
  state.qcol = 0
  render()
end

local function cursor_end()
  state.focus = "prompt"
  state.qcol = qlen()
  render()
end

local function delete_word_back()
  clamp_qcol()
  if state.qcol <= 0 then
    return
  end
  local q = state.query or ""
  local left = vim.fn.strcharpart(q, 0, state.qcol)
  local right = vim.fn.strcharpart(q, state.qcol, qlen() - state.qcol)
  -- 去掉光标前空白，再去掉一个词
  local new_left = left:gsub("%s+$", "")
  new_left = new_left:gsub("%S+$", "")
  set_query(new_left .. right, true, { col = vim.fn.strchars(new_left) })
end

local function move_sel(delta)
  local n = #state.results
  if n == 0 then
    return
  end
  leave_insert()
  state.focus = "list"
  state.sel = state.sel + delta
  if state.sel < 1 then
    state.sel = n
  elseif state.sel > n then
    state.sel = 1
  end
  render()
end

---按页滚动选中（虚拟列表）
local function move_sel_page(dir)
  local n = #state.results
  if n == 0 then
    return
  end
  leave_insert()
  state.focus = "list"
  local step = list_height()
  if dir < 0 then
    state.sel = math.max(1, state.sel - step)
  else
    state.sel = math.min(n, state.sel + step)
  end
  render()
end

local function current_path()
  local n = #state.results
  if n == 0 then
    return nil
  end
  local i = math.max(1, math.min(state.sel, n))
  local item = state.results[i]
  return item and item.path or nil
end

---系统默认程序打开
---@param path string
local function system_open(path)
  if not path or path == "" then
    return
  end
  if vim.ui and type(vim.ui.open) == "function" then
    local ok, err = pcall(vim.ui.open, path)
    if ok then
      vim.notify(i18n.t("system_open") .. path, vim.log.levels.INFO)
      return
    end
    vim.notify(i18n.t("system_open_fail") .. tostring(err), vim.log.levels.WARN)
  end
  -- Windows: start "" "path"
  if is_win() then
    local job = vim.fn.jobstart({ "cmd.exe", "/c", "start", '""', path }, { detach = true })
    if job > 0 then
      vim.notify(i18n.t("system_open") .. path, vim.log.levels.INFO)
    else
      vim.notify(i18n.t("system_open_fail2"), vim.log.levels.ERROR)
    end
    return
  end
  vim.notify(i18n.t("system_open_win_only"), vim.log.levels.WARN)
end

---复制路径到剪贴板
---@param path string
local function copy_path(path)
  if not path or path == "" then
    return
  end
  pcall(vim.fn.setreg, "+", path)
  pcall(vim.fn.setreg, "*", path)
  pcall(vim.fn.setreg, '"', path)
  vim.notify(i18n.t("copied") .. path, vim.log.levels.INFO)
end

---在资源管理器中显示并选中
---@param path string
local function reveal_in_explorer(path)
  if not path or path == "" then
    return
  end
  if not is_win() then
    vim.notify(i18n.t("explorer_win_only"), vim.log.levels.WARN)
    return
  end
  -- explorer /select,"C:\path\file"
  local arg = "/select," .. path
  local job = vim.fn.jobstart({ "explorer.exe", arg }, { detach = true })
  if job <= 0 then
    -- 回退：打开所在目录
    local dir = path
    if vim.fn.isdirectory(path) ~= 1 then
      dir = vim.fn.fnamemodify(path, ":h")
    end
    vim.fn.jobstart({ "explorer.exe", dir }, { detach = true })
  end
  vim.notify(i18n.t("explorer_show") .. path, vim.log.levels.INFO)
end

local function toggle_show_size()
  state.show_size = not state.show_size
  render()
end

local function toggle_ui_lang()
  local next_lang = i18n.toggle({ persist = true })
  local msg = (next_lang == "en") and i18n.t("lang_to_en") or i18n.t("lang_to_zh")
  vim.notify(msg, vim.log.levels.INFO)
  if is_inserting() then
    render({ body_only = true })
  else
    render()
  end
end

---重新填入当前 pwd 关键词
local function refill_cwd()
  local kw = cwd_keyword()
  set_query(kw, true, { col = vim.fn.strchars(kw), stay_insert = true })
end

local function bind_keys(buf)
  local opts = { buffer = buf, silent = true, nowait = true, noremap = true }

  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, vim.tbl_extend("force", opts, { desc = "es: " .. (desc or "") }))
  end
  local function nmap(lhs, fn, desc)
    map("n", lhs, fn, desc)
  end
  local function imap(lhs, fn, desc)
    map("i", lhs, fn, desc)
  end

  -- normal：Esc 关闭；insert：Esc 退出输入到 normal（可导航）
  nmap("<Esc>", close_ui, "close")
  nmap("<C-c>", close_ui, "close")
  imap("<Esc>", function()
    leave_insert()
    state.focus = "prompt"
    render()
  end, "leave insert")
  imap("<C-c>", function()
    leave_insert()
    close_ui()
  end, "close")

  local function do_open(how)
    local p = current_path()
    if p then
      leave_insert()
      open_path(p, how or config.open_cmd)
    end
  end

  nmap("<CR>", function()
    do_open(config.open_cmd)
  end, "open")
  imap("<CR>", function()
    do_open(config.open_cmd)
  end, "open")
  nmap("<C-v>", function()
    do_open("vsplit")
  end, "vsplit")
  nmap("<C-x>", function()
    do_open("split")
  end, "split")
  nmap("<C-t>", function()
    do_open("tabedit")
  end, "tab")

  -- 列表导航
  nmap("<Down>", function()
    move_sel(1)
  end, "down")
  nmap("<Up>", function()
    move_sel(-1)
  end, "up")
  nmap("<C-n>", function()
    move_sel(1)
  end, "down")
  nmap("<C-j>", function()
    move_sel(1)
  end, "down")
  nmap("<C-k>", function()
    move_sel(-1)
  end, "up")
  imap("<Down>", function()
    move_sel(1)
  end, "down")
  imap("<C-n>", function()
    move_sel(1)
  end, "down")
  imap("<Up>", function()
    if #state.results > 0 then
      move_sel(-1)
    end
  end, "up")
  nmap("<C-d>", function()
    move_sel_page(1)
  end, "page down")
  nmap("<C-u>", function()
    if state.focus == "list" then
      move_sel_page(-1)
    else
      set_query("", true, { col = 0, stay_insert = true })
    end
  end, "page up / clear")
  imap("<C-u>", function()
    set_query("", true, { col = 0, stay_insert = true })
  end, "clear query")
  nmap("<PageDown>", function()
    move_sel_page(1)
  end, "page down")
  nmap("<PageUp>", function()
    move_sel_page(-1)
  end, "page up")
  nmap("<Tab>", function()
    if state.focus == "prompt" and #state.results > 0 then
      leave_insert()
      state.focus = "list"
      render()
    else
      enter_insert()
    end
  end, "toggle focus")
  imap("<Tab>", function()
    if #state.results > 0 then
      leave_insert()
      state.focus = "list"
      render()
    end
  end, "to list")

  -- normal 下进入输入（支持中文 IME）
  nmap("i", enter_insert, "insert")
  nmap("a", enter_insert, "insert")
  nmap("I", enter_insert, "insert")
  nmap("A", enter_insert, "insert")
  nmap("o", enter_insert, "insert")

  nmap("<Left>", cursor_left, "cursor left")
  nmap("<Right>", cursor_right, "cursor right")
  nmap("<Home>", cursor_home, "cursor home")
  nmap("<End>", cursor_end, "cursor end")

  ---Insert 下删除：只改 query，绝不删前缀（否则双图标）。
  ---禁止用 expr 返回 termcode：会把内部键码以文字形式插入（显示成 <80>kb）。
  local function cursor_at_or_in_prefix()
    local pref = prompt_prefix()
    local okc, cur = pcall(vim.api.nvim_win_get_cursor, state.win)
    if not okc or not cur then
      return true
    end
    return cur[2] <= #pref
  end
  local function insert_backspace()
    if cursor_at_or_in_prefix() then
      place_prompt_cursor()
      return
    end
    sync_query_from_line()
    if state.qcol <= 0 then
      place_prompt_cursor()
      return
    end
    backspace()
  end
  local function insert_delete_forward()
    if cursor_at_or_in_prefix() then
      place_prompt_cursor()
      return
    end
    sync_query_from_line()
    delete_forward()
  end
  local function insert_delete_word()
    if cursor_at_or_in_prefix() then
      place_prompt_cursor()
      return
    end
    sync_query_from_line()
    if state.qcol <= 0 then
      place_prompt_cursor()
      return
    end
    delete_word_back()
  end

  nmap("<BS>", function()
    if state.qcol > 0 then
      backspace()
    else
      enter_insert()
    end
  end, "backspace / insert")
  nmap("<Del>", function()
    if state.qcol < qlen() then
      delete_forward()
    else
      enter_insert()
    end
  end, "delete / insert")
  imap("<BS>", insert_backspace, "backspace")
  imap("<C-h>", insert_backspace, "backspace")
  imap("<Del>", insert_delete_forward, "delete")
  imap("<C-w>", insert_delete_word, "delete word")

  -- 系统打开 / 复制路径 / 资源管理器
  local function with_path(fn)
    return function()
      local p = current_path()
      if p then
        fn(p)
      end
    end
  end
  nmap("<C-o>", with_path(system_open), "system open")
  nmap("<C-p>", with_path(copy_path), "copy path")
  nmap("<C-r>", with_path(reveal_in_explorer), "reveal in explorer")
  imap("<C-o>", with_path(system_open), "system open")
  imap("<C-p>", with_path(copy_path), "copy path")
  imap("<C-r>", with_path(reveal_in_explorer), "reveal in explorer")

  nmap("<F3>", function()
    leave_insert()
    vim.ui.input({ prompt = "ES query: ", default = state.query }, function(input)
      if input == nil then
        enter_insert()
        return
      end
      set_query(input, true, { col = vim.fn.strchars(input), stay_insert = true })
    end)
  end, "input dialog")

  nmap("<C-s>", toggle_show_size, "toggle size")
  nmap("<M-s>", toggle_show_size, "toggle size")
  nmap("<A-s>", toggle_show_size, "toggle size")
  nmap("<F2>", toggle_show_size, "toggle size")
  imap("<F2>", toggle_show_size, "toggle size")
  nmap("<C-g>", refill_cwd, "refill cwd keyword")
  imap("<C-g>", refill_cwd, "refill cwd keyword")
  -- 中英文切换（与 mdview/tts 等一致用 L）
  nmap("L", toggle_ui_lang, "toggle language")
  nmap("<C-l>", toggle_ui_lang, "toggle language")
  imap("<C-l>", toggle_ui_lang, "toggle language")

  -- 列表焦点 s 切换大小；其它可打印键进入 insert
  nmap("s", function()
    if state.focus == "list" then
      toggle_show_size()
    else
      enter_insert()
    end
  end, "size / insert")
  nmap("S", function()
    if state.focus == "list" then
      toggle_show_size()
    else
      enter_insert()
    end
  end, "size / insert")

  -- IME：TextChangedI 同步查询，搜索结果只刷新 body
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, {
    buffer = buf,
    callback = function()
      if state._rendering then
        return
      end
      state.inserting = true
      state.focus = "prompt"
      sync_query_from_line()
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = buf,
    callback = function()
      state.inserting = false
      -- 离开 insert 时再完整渲染一次（含方块光标）
      if M.is_open() then
        sync_query_from_line()
        vim.schedule(function()
          if M.is_open() and not is_inserting() then
            render()
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    callback = function()
      state.inserting = true
      state.focus = "prompt"
      pcall(function()
        vim.bo[buf].modifiable = true
      end)
    end,
  })
end

---@param opts? { query?: string, prefill_cwd?: boolean }
function M.open(opts)
  opts = opts or {}
  if not is_win() then
    vim.notify(i18n.t("win_only"), vim.log.levels.WARN)
    return
  end

  M.ensure_setup()

  if M.is_open() then
    pcall(vim.api.nvim_set_current_win, state.win)
    if opts.query ~= nil then
      set_query(opts.query, true, { col = vim.fn.strchars(opts.query) })
    end
    return
  end

  ensure_hl()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "es-picker"
  pcall(vim.api.nvim_buf_set_name, buf, "es://picker")

  local width = config.width
  local height = config.height
  if width <= 1 then
    width = math.floor(vim.o.columns * width)
  end
  if height <= 1 then
    height = math.floor(vim.o.lines * height)
  end
  width = math.max(40, math.min(width, vim.o.columns - 4))
  height = math.max(10, math.min(height, vim.o.lines - 4))
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)
  if row < 0 then
    row = 0
  end

  local ic = config.icon or ICON
  local title = string.format(" %s Everything ", ic)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = config.border or "rounded",
    title = title,
    title_pos = "center",
    zindex = 60,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    -- insert 时显示真实光标（中文 IME 需要）；normal 时 Cursor 贴近背景
    vim.wo[win].winhighlight =
      "Normal:EsNormal,NormalFloat:EsNormal,FloatBorder:EsBorder,FloatTitle:EsTitle,EndOfBuffer:EsNormal,Cursor:EsCursor,CursorLine:EsNormal"
  end)

  state.buf = buf
  state.win = win
  state.results = {}
  state.sel = 1
  state.view_top = 1
  state.last_err = nil
  state.show_size = config.show_size ~= false
  state.focus = "prompt"
  state.inserting = false

  -- 初始查询：显式 query > 预填 pwd > 空
  local do_prefill = config.prefill_cwd
  if config.cwd_only ~= nil and config.prefill_cwd == nil then
    do_prefill = config.cwd_only
  end
  if opts.prefill_cwd ~= nil then
    do_prefill = opts.prefill_cwd
  end

  if opts.query ~= nil then
    state.query = opts.query
  elseif do_prefill then
    state.query = cwd_keyword()
  else
    state.query = ""
  end
  state.qcol = qlen()

  bind_keys(buf)

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buf,
    once = true,
    callback = function()
      cancel_timer()
      cancel_job()
      if state.buf == buf then
        state.buf, state.win = nil, nil
        state.results = {}
        state.query = ""
        state.qcol = 0
        state.inserting = false
      end
    end,
  })

  local aug = vim.api.nvim_create_augroup("EsPickerUI", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = aug,
    callback = function()
      if M.is_open() then
        if is_inserting() then
          render({ body_only = true })
        else
          render()
        end
      end
    end,
  })

  if vim.trim(state.query) ~= "" then
    run_search(state.query)
  else
    render()
  end
  -- 默认进入 insert，可直接用中文输入法
  enter_insert()
end

---@param query? string
function M.search(query)
  M.open({ query = query or "" })
end

local function apply_keys()
  for _, lhs in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", lhs)
  end
  keys_applied = {}
  local lhs = config.keys_open
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, function()
      M.open({})
    end, { silent = true, desc = "es: Everything search" })
    keys_applied[#keys_applied + 1] = lhs
  end
end

---@param user? table
function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  -- 兼容旧名 cwd_only
  if user and user.prefill_cwd == nil and user.cwd_only ~= nil then
    config.prefill_cwd = user.cwd_only
  end
  -- 界面语言：setup 指定 > 记忆 > 系统
  local lang_opt = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang_opt = user.ui_lang
  end
  if lang_opt == "zh" or lang_opt == "en" then
    i18n.setup(lang_opt)
  else
    i18n.setup("auto")
  end
  apply_keys()
  setup_done = true
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

---@return table
function M.get_config()
  return config
end

return M
