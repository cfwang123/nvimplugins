---@mod mdview.i18n 控制/提示中英文 + 系统语言检测
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    key_hint = " 关闭(q)  刷新(r)  激活(Enter)  目录(t)  顶(go)  帮助(?)  中英(L)  返回(C-o)  图(gi)  高清(gh)  系统(o)  复制(c)  源码(gs)  │ mdview ",
    contents = "◆ 目录",
    copy = "[复制]",
    copied = "[已复制]",
    help_title = " 帮助 ",
    help_lines = {
      "mdview 快捷键",
      "",
      "  q          关闭预览",
      "  r          刷新预览",
      "  <CR>       激活：TOC/折叠/图片/链接",
      "  t          打开/关闭目录 TOC",
      "  go         跳到文内目录顶部",
      "  ?          本帮助（开/关）",
      "  L          切换中/英文界面",
      "  <C-o>      返回：文内跳转 / 上一篇 md 预览",
      "  gi         打开光标处图片（float；支持高清）",
      "  gh         临时显示当前页高清图（滚动/焦点/改大小清除）",
      "  o          光标在图片上：系统程序打开原图",
      "  c / yc     复制光标处代码块（c 一键）",
      "  [复制]     代码块顶栏按钮，点击/回车复制",
      "  gs         跳到源文件对应行",
      "",
      "  编辑窗：",
      "  <CR>       光标在 ![图](路径) 上打开预览；在 [链](url) 上跳转",
      "  C-左键     同上（Ctrl+鼠标左键）",
      "",
      "  gt / gT    切换 tab（系统默认）",
      "",
      "  q / Esc    关闭本窗口",
    },
    toc_empty = "mdview: 无标题可列目录",
    need_markdown = "mdview: 请先打开 Markdown 编辑缓冲（或预览窗）",
    toc_fail = "mdview: 打开目录失败",
    help_fail = "mdview: 打开帮助失败",
    state_missing = "mdview: 预览状态丢失（试 :MdViewRefresh）",
    jump_empty = "mdview: 跳转历史为空",
    no_image = "mdview: 光标处无图片",
    no_code = "mdview: 光标处无代码块",
    empty_code = "mdview: 代码块为空",
    copied_n = "mdview: 已复制 %d 行 (%s)",
    heading_nf = "mdview: 未找到标题: ",
    open_fail = "mdview: 打开失败: ",
    prev_gone = "mdview: 上一文件已不存在: ",
    not_md = "mdview: 不是 markdown buffer",
    open_md_first = "mdview: 请先打开 markdown 文件",
    no_preview_buf = "mdview: 无预览 buffer",
    gfx_fail = "mdview: 无法加载 graphics: ",
    page_hd_off = "mdview: 已关闭页内高清",
    page_hd_unsupported = "mdview: 当前终端不支持高清叠层（需 WezTerm/Kitty/Ghostty）",
    page_hd_none = "mdview: 当前页没有可叠高清的图片（或编码失败）",
    page_hd_on = "mdview: 页内高清已开 · 滚动/焦点切换/改大小或再按 gh 关闭",
    lang_to_en = "mdview: 界面 → English",
    lang_to_zh = "mdview: 界面 → 中文",
  },
  en = {
    key_hint = " Close(q)  Refresh(r)  Activate(Enter)  TOC(t)  Top(go)  Help(?)  Lang(L)  Back(C-o)  Img(gi)  HD(gh)  Open(o)  Copy(c)  Src(gs)  │ mdview ",
    contents = "◆ Contents",
    copy = "[Copy]",
    copied = "[Copied]",
    help_title = " Help ",
    help_lines = {
      "mdview keys",
      "",
      "  q          Close preview",
      "  r          Refresh preview",
      "  <CR>       Activate: TOC / fold / image / link",
      "  t          Toggle outline TOC",
      "  go         Jump to in-doc TOC top",
      "  ?          This help (toggle)",
      "  L          Toggle Chinese / English UI",
      "  <C-o>      Back: in-doc jump / previous md",
      "  gi         Image float under cursor (HD if supported)",
      "  gh         Temp page HD overlays (scroll/focus/resize clears)",
      "  o          Open image with system app",
      "  c / yc     Copy code block under cursor",
      "  [Copy]     Code bar button: click/Enter to copy",
      "  gs         Jump to source line",
      "",
      "  Editor:",
      "  <CR>       On ![img](path) open preview; on [link](url) jump/open",
      "  C-Left     Same (Ctrl+LeftMouse)",
      "",
      "  gt / gT    Switch tabs (default)",
      "",
      "  q / Esc    Close this window",
    },
    toc_empty = "mdview: no headings for TOC",
    need_markdown = "mdview: open a Markdown buffer (or preview) first",
    toc_fail = "mdview: failed to open TOC float",
    help_fail = "mdview: failed to open help float",
    state_missing = "mdview: preview state missing (try :MdViewRefresh)",
    jump_empty = "mdview: jump list empty",
    no_image = "mdview: no image under cursor",
    no_code = "mdview: no code block under cursor",
    empty_code = "mdview: empty code block",
    copied_n = "mdview: copied %d lines (%s)",
    heading_nf = "mdview: heading not found: ",
    open_fail = "mdview: open failed: ",
    prev_gone = "mdview: previous file gone: ",
    not_md = "mdview: not a markdown buffer",
    open_md_first = "mdview: open a markdown file first",
    no_preview_buf = "mdview: no preview buffer",
    gfx_fail = "mdview: failed to load graphics: ",
    page_hd_off = "mdview: page HD off",
    page_hd_unsupported = "mdview: terminal has no HD graphics (WezTerm/Kitty/Ghostty)",
    page_hd_none = "mdview: no HD images on this page (or encode failed)",
    page_hd_on = "mdview: page HD on · scroll/focus/resize or gh again to clear",
    lang_to_en = "mdview: UI → English",
    lang_to_zh = "mdview: UI → 中文",
  },
}

---Detect system / nvim UI language → "zh" | "en"
---@return "zh"|"en"
function M.detect()
  local cands = {
    vim.v.lang,
    vim.v.ctype,
    vim.env.LC_ALL,
    vim.env.LC_MESSAGES,
    vim.env.LANG,
  }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" and c ~= "C" and c ~= "POSIX" then
      local low = c:lower()
      if low:match("^zh")
        or low:find("chinese", 1, true)
        or low:match("zh[_%-]")
      then
        return "zh"
      end
      if low:match("^en") or low:match("en[_%-]") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    local ok, out = pcall(function()
      return vim.fn.system({
        "powershell",
        "-NoProfile",
        "-Command",
        "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
      })
    end)
    if ok and type(out) == "string" then
      local low = vim.trim(out):lower()
      if low:match("^zh") then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  return "zh"
end

---@param user_lang string|nil "zh"|"en"|"auto"|nil
function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.detect()
  end
  return lang
end

---@return "zh"|"en"
function M.get()
  return lang
end

---@param l "zh"|"en"|nil
function M.set(l)
  if l == "zh" or l == "en" then
    lang = l
  end
  return lang
end

---@return "zh"|"en"
function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  return lang
end

---@param key string
---@return string|table
function M.t(key)
  local pack = STR[lang] or STR.zh
  local v = pack[key]
  if v ~= nil then
    return v
  end
  return STR.zh[key] or STR.en[key] or key
end

---prefs 路径（可选记忆语言）
local function prefs_path()
  return vim.fn.stdpath("data") .. "/mdview-nvim-prefs.json"
end

function M.load_prefs()
  local f = prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" and (data.ui_lang == "zh" or data.ui_lang == "en") then
    return data.ui_lang
  end
  return nil
end

function M.save_prefs()
  pcall(function()
    local f = prefs_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({ vim.json.encode({ ui_lang = lang }) }, f)
  end)
end

return M
