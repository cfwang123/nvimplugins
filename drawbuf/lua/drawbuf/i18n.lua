---@mod drawbuf.i18n zh/en UI
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    tool_pencil = "铅笔",
    tool_eraser = "橡皮",
    tool_line = "直线",
    tool_rect = "矩形",
    tool_ellipse = "椭圆",
    tool_fill = "填充",
    char = "字符",
    fg = "前景",
    bg = "背景",
    demo = "演示",
    save = "保存",
    clear = "清空",
    undo = "撤销",
    quit = "退出",
    lang = "中英",
    pick_tool = "选择工具",
    pick_char = "选择字符（100% / 1/2 / 1/4）",
    pick_demo = "加载演示图案（彩色）",
    pick_fg = "选择前景色",
    pick_bg = "选择背景色",
    pick = "选择",
    none_canvas = "无（画布底色）",
    save_as = "保存为: ",
    export_as = "导出文本: ",
    saved = "drawbuf: 已保存 ",
    save_fail = "drawbuf: 保存失败: ",
    exported = "drawbuf: 已导出 ",
    export_fail = "drawbuf: 导出失败: ",
    loaded = "drawbuf: 已加载「",
    draw_on = "drawbuf: 连续绘制 开",
    draw_off = "drawbuf: 连续绘制 关",
    shape_cancel = "drawbuf: 已取消图形绘制",
    shape_hint = "drawbuf: 拖动/移动到终点，Space/松开确认，Esc 取消",
    confirm_clear = "清空整个画布？",
    confirm_quit = "画布未保存，关闭？",
    yes_no = "&是\n&否",
    help = table.concat({
      "drawbuf 操作说明:",
      "  铅笔：鼠标拖拽绘制；右键擦除；p 连续绘制",
      "  直线/矩形/椭圆：按下起点→拖动预览→松开确认；Esc 取消",
      "  底部状态栏：工具 / 字符 / 前景 / 背景 / 演示 / 保存 / 清空 / 撤销 / 退出 / 中英",
      "  色块：100% █ + 1/2 + 1/4；选色 float 真彩色",
      "  hjkl 移动  u 撤销  C 清空  s 保存  Y 中英  q 退出",
    }, "\n"),
    block = {
      ["█"] = "100% 全方格",
      ["▀"] = "上半 1/2",
      ["▄"] = "下半 1/2",
      ["▌"] = "左半 1/2",
      ["▐"] = "右半 1/2",
      ["▘"] = "左上 1/4",
      ["▝"] = "右上 1/4",
      ["▖"] = "左下 1/4",
      ["▗"] = "右下 1/4",
      ["▚"] = "对角",
      ["▞"] = "对角",
      ["▙"] = "3/4",
      ["▛"] = "3/4",
      ["▜"] = "3/4",
      ["▟"] = "3/4",
    },
    lang_to_en = "drawbuf: UI → English",
    lang_to_zh = "drawbuf: UI → 中文",
  },
  en = {
    tool_pencil = "Pencil",
    tool_eraser = "Eraser",
    tool_line = "Line",
    tool_rect = "Rect",
    tool_ellipse = "Ellipse",
    tool_fill = "Fill",
    char = "Char",
    fg = "FG",
    bg = "BG",
    demo = "Demo",
    save = "Save",
    clear = "Clear",
    undo = "Undo",
    quit = "Quit",
    lang = "EN/中",
    pick_tool = "Select tool",
    pick_char = "Select glyph (100% / 1/2 / 1/4)",
    pick_demo = "Load demo pattern",
    pick_fg = "Select foreground",
    pick_bg = "Select background",
    pick = "Select",
    none_canvas = "none (canvas bg)",
    save_as = "Save as: ",
    export_as = "Export text: ",
    saved = "drawbuf: saved ",
    save_fail = "drawbuf: save failed: ",
    exported = "drawbuf: exported ",
    export_fail = "drawbuf: export failed: ",
    loaded = "drawbuf: loaded «", -- + name + »
    draw_on = "drawbuf: continuous draw ON",
    draw_off = "drawbuf: continuous draw OFF",
    shape_cancel = "drawbuf: shape cancelled",
    shape_hint = "drawbuf: drag to end, Space/release confirm, Esc cancel",
    confirm_clear = "Clear entire canvas?",
    confirm_quit = "Unsaved canvas. Close?",
    yes_no = "&Yes\n&No",
    help = table.concat({
      "drawbuf help:",
      "  Pencil: drag to paint; right-click erase; p continuous",
      "  Line/Rect/Ellipse: press start → drag preview → release; Esc cancel",
      "  Status bar: tool / char / FG / BG / demo / save / clear / undo / quit / lang",
      "  Blocks: 100% █ + 1/2 + 1/4; color float truecolor",
      "  hjkl move  u undo  C clear  s save  Y lang  q quit",
    }, "\n"),
    block = {
      ["█"] = "100% full",
      ["▀"] = "upper 1/2",
      ["▄"] = "lower 1/2",
      ["▌"] = "left 1/2",
      ["▐"] = "right 1/2",
      ["▘"] = "UL 1/4",
      ["▝"] = "UR 1/4",
      ["▖"] = "LL 1/4",
      ["▗"] = "LR 1/4",
      ["▚"] = "diag",
      ["▞"] = "diag",
      ["▙"] = "3/4",
      ["▛"] = "3/4",
      ["▜"] = "3/4",
      ["▟"] = "3/4",
    },
    lang_to_en = "drawbuf: UI → English",
    lang_to_zh = "drawbuf: UI → 中文",
  },
}

function M.detect()
  local cands = { vim.v.lang, vim.v.ctype, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" and c ~= "C" and c ~= "POSIX" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) or low:match("zh[_%-]") then
        return "zh"
      end
      if low:match("^en") or low:match("en[_%-]") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    local ok, out = pcall(vim.fn.system, {
      "powershell",
      "-NoProfile",
      "-Command",
      "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
    })
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

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.detect()
  end
  return lang
end

function M.get()
  return lang
end

function M.set(l)
  if l == "zh" or l == "en" then
    lang = l
  end
  return lang
end

function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  return lang
end

function M.t(key)
  local pack = STR[lang] or STR.zh
  local v = pack[key]
  if v ~= nil then
    return v
  end
  return STR.zh[key] or STR.en[key] or key
end

function M.block_label(ch)
  local pack = STR[lang] or STR.zh
  local b = pack.block or {}
  return b[ch] or (STR.zh.block and STR.zh.block[ch]) or ""
end

function M.tool_label(tool)
  local map = {
    pencil = "tool_pencil",
    eraser = "tool_eraser",
    line = "tool_line",
    rect = "tool_rect",
    ellipse = "tool_ellipse",
    fill = "tool_fill",
  }
  local k = map[tool]
  return k and M.t(k) or tool
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/drawbuf-nvim-prefs.json"
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
