---@mod nvimplugins.help 合集帮助浮窗：命令 / 快捷键 / 点击运行
local M = {}

local state = {
  buf = nil,
  win = nil,
  hits = {}, ---@type { row: integer, kind: string, value: string, desc?: string }[]
}

local NS = vim.api.nvim_create_namespace("nvimplugins_help")

local function is_zh()
  if vim.g.nvimplugins_lang == "zh" then
    return true
  end
  if vim.g.nvimplugins_lang == "en" then
    return false
  end
  local cands = { vim.v.lang, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) then
        return true
      end
    end
  end
  if vim.fn.has("win32") == 1 then
    local ok, out = pcall(vim.fn.system, {
      "powershell",
      "-NoProfile",
      "-Command",
      "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
    })
    if ok and type(out) == "string" and vim.trim(out):lower():match("^zh") then
      return true
    end
  end
  return true
end

local function t(zh, en)
  return is_zh() and zh or en
end

---尝试读取插件当前 keys_open / 其它键
---@param modname string
---@param field string
---@param default string|false|nil
---@return string
local function cfg_key(modname, field, default)
  local ok, mod = pcall(require, modname)
  if ok and type(mod) == "table" then
    local cfg
    if type(mod.get_config) == "function" then
      pcall(function()
        cfg = mod.get_config()
      end)
    end
    if type(cfg) ~= "table" and type(mod._config) == "table" then
      cfg = mod._config
    end
    if type(cfg) == "table" and cfg[field] ~= nil then
      local v = cfg[field]
      if v == false or v == "" then
        return t("（已关闭）", "(disabled)")
      end
      return tostring(v)
    end
  end
  -- maparg 探测实际映射
  if type(default) == "string" and default ~= "" then
    local m = vim.fn.maparg(default, "n", false, true)
    if type(m) == "table" and m.lhs then
      return m.lhs
    end
    return default
  end
  return default and tostring(default) or "-"
end

---展开 leader 显示
---@param lhs string
---@return string
local function pretty_lhs(lhs)
  if type(lhs) ~= "string" then
    return "-"
  end
  local leader = vim.g.mapleader
  if leader == nil or leader == "" then
    leader = "\\"
  end
  if leader == " " then
    leader = "<Space>"
  end
  return (lhs:gsub("<[Ll]eader>", leader))
end

---@class HelpItem
---@field plugin string
---@field title_zh string
---@field title_en string
---@field desc_zh string
---@field desc_en string
---@field commands { cmd: string, desc_zh: string, desc_en: string }[]
---@field keys { field?: string, default?: string, desc_zh: string, desc_en: string, modes?: string }[]

---合集帮助目录（静态 + 运行时解析快捷键）
---@return HelpItem[]
local function catalog()
  return {
    {
      plugin = "mdview",
      title_zh = "Markdown 预览",
      title_en = "Markdown preview",
      desc_zh = "单窗/侧边预览 Markdown",
      desc_en = "Single / side Markdown preview",
      commands = {
        { cmd = "MdView", desc_zh = "打开预览", desc_en = "Open preview" },
        { cmd = "MdSideView", desc_zh = "侧边预览", desc_en = "Side preview" },
        { cmd = "MdViewRefresh", desc_zh = "刷新", desc_en = "Refresh" },
        { cmd = "MdViewSync", desc_zh = "同步滚动位置", desc_en = "Sync scroll" },
        { cmd = "MdViewToc", desc_zh = "TOC 大纲浮窗", desc_en = "TOC outline float" },
      },
      keys = {
        { default = "<leader>mv", desc_zh = "单窗预览", desc_en = "Single-window preview" },
        { default = "<leader>ms", desc_zh = "侧边预览", desc_en = "Side preview" },
        { default = "<leader>toc", desc_zh = "编辑窗/预览 TOC", desc_en = "TOC from editor/preview" },
        { default = "t", desc_zh = "预览内 TOC", desc_en = "TOC in preview" },
        { default = "L", desc_zh = "预览内中英", desc_en = "In preview: language" },
      },
    },
    {
      plugin = "pdfview",
      title_zh = "PDF / Word 预览",
      title_en = "PDF / Word preview",
      desc_zh = "文档预览与高清叠层",
      desc_en = "Document preview + HD overlay",
      commands = {
        { cmd = "PdfView", desc_zh = "预览 PDF/文档", desc_en = "Preview PDF/doc" },
        { cmd = "DocView", desc_zh = "预览文档", desc_en = "Preview document" },
        { cmd = "PdfViewRefresh", desc_zh = "刷新", desc_en = "Refresh" },
        { cmd = "PdfViewClose", desc_zh = "关闭", desc_en = "Close" },
      },
      keys = {
        { default = "-", desc_zh = "预览内 L 中英；gh 页内高清", desc_en = "In preview: L lang; gh page HD" },
      },
    },
    {
      plugin = "xlsview",
      title_zh = "Excel 预览",
      title_en = "Excel preview",
      desc_zh = ".xlsx/.xlsm 表格预览",
      desc_en = "Preview .xlsx/.xlsm",
      commands = {
        { cmd = "XlsView", desc_zh = "打开预览", desc_en = "Open preview" },
        { cmd = "XlsViewRefresh", desc_zh = "刷新", desc_en = "Refresh" },
        { cmd = "XlsViewClose", desc_zh = "关闭", desc_en = "Close" },
      },
      keys = {
        { default = "-", desc_zh = "预览内 L 中英；n/p 切表", desc_en = "In preview: L lang; n/p sheets" },
      },
    },
    {
      plugin = "imgbuf",
      title_zh = "图片字符画",
      title_en = "Image buffer",
      desc_zh = "图片转字符画 / 可选高清",
      desc_en = "Image as character art / optional HD",
      commands = {
        { cmd = "Imgbuf", desc_zh = "打开图片", desc_en = "Open image" },
        { cmd = "ImgbufClipboard", desc_zh = "剪贴板图片", desc_en = "Clipboard image" },
        { cmd = "ImgbufAnimTest", desc_zh = "动画测试", desc_en = "Anim test" },
      },
      keys = {
        { default = "-", desc_zh = "预览内 L 中英", desc_en = "In preview: L lang" },
      },
    },
    {
      plugin = "music",
      title_zh = "音乐播放器",
      title_en = "Music player",
      desc_zh = "音频 + Windows MIDI（winmm）",
      desc_en = "Audio + Windows MIDI (winmm)",
      commands = {
        { cmd = "Music", desc_zh = "打开/控制（音频或预设）", desc_en = "Open / control (audio or preset)" },
        { cmd = "MusicMidi", desc_zh = "MIDI 播放器 / 预设", desc_en = "MIDI player / presets" },
        { cmd = "MusicToggle", desc_zh = "播放/暂停", desc_en = "Play/pause" },
        { cmd = "MusicNext", desc_zh = "下一首", desc_en = "Next" },
        { cmd = "MusicPrev", desc_zh = "上一首", desc_en = "Prev" },
        { cmd = "MusicStop", desc_zh = "停止", desc_en = "Stop" },
      },
      keys = {
        { default = "Y", desc_zh = "播放器内中英", desc_en = "In player: language" },
        { field = "keys_midi", default = "<leader>mx", desc_zh = "打开 MIDI 播放器", desc_en = "Open MIDI player" },
        { default = "m", desc_zh = "MIDI 内置预设", desc_en = "MIDI presets (in MIDI mode)" },
      },
    },
    {
      plugin = "videobuf",
      title_zh = "视频预览",
      title_en = "Video buffer",
      desc_zh = "终端视频字符画预览",
      desc_en = "Terminal video preview",
      commands = {
        { cmd = "Videobuf", desc_zh = "打开视频", desc_en = "Open video" },
        { cmd = "VideobufToggle", desc_zh = "播放/暂停", desc_en = "Play/pause" },
        { cmd = "VideobufStop", desc_zh = "停止", desc_en = "Stop" },
        { cmd = "VideobufNext", desc_zh = "下一个", desc_en = "Next" },
        { cmd = "VideobufPrev", desc_zh = "上一个", desc_en = "Prev" },
        { cmd = "VideobufClose", desc_zh = "关闭", desc_en = "Close" },
        { cmd = "VideobufFps", desc_zh = "设置 FPS", desc_en = "Set FPS" },
      },
      keys = {},
    },
    {
      plugin = "ntemoji",
      title_zh = "NERDTree 图标",
      title_en = "NERDTree icons",
      desc_zh = "emoji 文件/目录图标（替代 vim-devicons）",
      desc_en = "Emoji file/folder icons (vim-devicons alternative)",
      commands = {},
      keys = {},
    },
    {
      plugin = "tts",
      title_zh = "文本朗读",
      title_en = "Text-to-speech",
      desc_zh = "Windows SAPI 朗读",
      desc_en = "Windows SAPI speech",
      commands = {
        { cmd = "TTS", desc_zh = "朗读（参数或当前行）", desc_en = "Speak text/line" },
        { cmd = "TTSStop", desc_zh = "停止", desc_en = "Stop" },
        { cmd = "TTSVoices", desc_zh = "列出发音人", desc_en = "List voices" },
      },
      keys = {
        { field = "keys_play", default = "<leader>vo", desc_zh = "从光标段起播", desc_en = "Speak from cursor" },
        { field = "keys_stop", default = "<leader>vs", desc_zh = "停止朗读", desc_en = "Stop speech" },
      },
    },
    {
      plugin = "nvimgames",
      title_zh = "小游戏",
      title_en = "Mini games",
      desc_zh = "扫雷/推箱子/24点/方块",
      desc_en = "Mines/Sokoban/24/Tetris",
      commands = {
        { cmd = "NvimGames", desc_zh = "游戏菜单", desc_en = "Game menu" },
        { cmd = "Mine", desc_zh = "扫雷", desc_en = "Minesweeper" },
        { cmd = "Sokoban", desc_zh = "推箱子", desc_en = "Sokoban" },
        { cmd = "Game24", desc_zh = "24 点", desc_en = "24-point" },
        { cmd = "Tetris", desc_zh = "俄罗斯方块", desc_en = "Tetris" },
      },
      keys = {
        { default = "-", desc_zh = "局内 u 切换中英", desc_en = "In-game: u lang" },
      },
    },
    {
      plugin = "drawbuf",
      title_zh = "色块绘图",
      title_en = "Block drawing",
      desc_zh = "Unicode 色块画布",
      desc_en = "Unicode block canvas",
      commands = {
        { cmd = "Draw", desc_zh = "打开画布", desc_en = "Open canvas" },
      },
      keys = {
        { default = "-", desc_zh = "画布内 Y 中英", desc_en = "On canvas: Y lang" },
      },
    },
    {
      plugin = "es",
      title_zh = "Everything 搜文件",
      title_en = "Everything search",
      desc_zh = "Windows 全局文件搜索",
      desc_en = "Windows file search",
      commands = {
        { cmd = "ES", desc_zh = "打开搜索浮窗", desc_en = "Open search" },
        { cmd = "Es", desc_zh = "同上", desc_en = "Same as :ES" },
      },
      keys = {
        { field = "keys_open", default = "<leader>es", desc_zh = "打开搜索", desc_en = "Open search" },
      },
    },
    {
      plugin = "qrbuf",
      title_zh = "二维码",
      title_en = "QR code",
      desc_zh = "文本/选区 → 终端二维码",
      desc_en = "Text/selection → QR",
      commands = {
        { cmd = "QrBuf", desc_zh = "生成二维码", desc_en = "Generate QR" },
        { cmd = "QR", desc_zh = "同上", desc_en = "Alias" },
      },
      keys = {
        {
          field = "keys_open",
          default = "<leader>qr",
          desc_zh = "当前行/选区二维码",
          desc_en = "QR from line/selection",
          modes = "n/v",
        },
      },
    },
    {
      plugin = "httpbuf",
      title_zh = "HTTP 调试",
      title_en = "HTTP scratch",
      desc_zh = "编辑请求并查看响应",
      desc_en = "Edit request, view response",
      commands = {
        { cmd = "HttpBuf", desc_zh = "打开编辑器", desc_en = "Open editor" },
        { cmd = "Http", desc_zh = "同上", desc_en = "Alias" },
        { cmd = "HttpSend", desc_zh = "发送当前 buffer 请求", desc_en = "Send current buffer" },
      },
      keys = {
        { field = "keys_open", default = "<leader>http", desc_zh = "打开 HTTP 编辑器", desc_en = "Open HTTP editor" },
      },
    },
    {
      plugin = "weather",
      title_zh = "天气",
      title_en = "Weather",
      desc_zh = "状态栏天气 + 10 天预报",
      desc_en = "Statusline + 10-day forecast",
      commands = {
        { cmd = "Weather", desc_zh = "10 天预报浮窗", desc_en = "10-day popup" },
        { cmd = "WeatherCity", desc_zh = "设置城市", desc_en = "Set city" },
        { cmd = "WeatherRefresh", desc_zh = "强制刷新", desc_en = "Force refresh" },
      },
      keys = {
        { field = "keys_open", default = "<leader>we", desc_zh = "打开预报", desc_en = "Open forecast" },
      },
    },
    {
      plugin = "nvimplugins",
      title_zh = "合集元命令",
      title_en = "Bundle meta",
      desc_zh = "依赖检查与帮助",
      desc_en = "Deps check & help",
      commands = {
        { cmd = "NvimpluginsHelp", desc_zh = "本帮助窗口", desc_en = "This help" },
        { cmd = "NvimpluginsDeps", desc_zh = "检查/安装 Python 依赖", desc_en = "Check/install Python deps" },
        { cmd = "NvimpluginsDepsProbe", desc_zh = "调试依赖探测", desc_en = "Debug dep probe" },
      },
      keys = {
        { default = "<leader>hh", desc_zh = "打开本帮助", desc_en = "Open this help" },
      },
    },
  }
end

local function ensure_hl()
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpNormal", { fg = "#111111", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpTitle", { fg = "#003366", bg = "#ffffff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpHead", { fg = "#ffffff", bg = "#336699", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpPlugin", { fg = "#000000", bg = "#e8f0ff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpCmd", { fg = "#006600", bg = "#ffffff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpKey", { fg = "#880000", bg = "#ffffff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpMeta", { fg = "#666666", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpBorder", { fg = "#336699", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "NvpHelpHint", { fg = "#444444", bg = "#fff8e0", force = true })
end

local function close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf, state.hits = nil, nil, {}
end

---仅「必须带参数」的命令：预填命令行等待输入（不自动回车）
local NEEDS_ARG = {
  WeatherCity = true,
  VideobufFps = true,
  NvimpluginsDeps = false, -- 可选参数，直接执行
}

local function feed_keys(str, mode)
  mode = mode or "n"
  local keys = vim.api.nvim_replace_termcodes(str, true, false, true)
  vim.api.nvim_feedkeys(keys, mode, false)
end

local function run_hit(hit)
  if not hit then
    return
  end
  if hit.kind == "cmd" then
    local cmd = hit.value
    close()
    -- 等帮助窗关掉后再跑，避免焦点仍在 float
    vim.schedule(function()
      if NEEDS_ARG[cmd] then
        -- 必须参数：预填 ":Cmd "，由用户补全后回车
        feed_keys(":" .. cmd .. " ", "n")
        return
      end
      -- 直接执行。feedkeys 带 <CR>，无需再手动回车
      local ok = pcall(vim.cmd, cmd)
      if not ok then
        feed_keys(":" .. cmd .. "<CR>", "n")
      end
    end)
  elseif hit.kind == "key" then
    local lhs = hit.value
    close()
    vim.schedule(function()
      if not lhs or lhs == "" or lhs == "-" then
        return
      end
      local s = tostring(lhs)
      if s:find("已关闭", 1, true) or s:find("disabled", 1, true) then
        return
      end
      -- 展开 <leader> 再触发（replace_termcodes 不会替 mapleader）
      s = pretty_lhs(s)
      if s == "<Space>" or s:match("^<Space>") then
        -- 已是 <Space> 形式，feedkeys 可识别
      end
      feed_keys(s, "m")
    end)
  end
end

local function hit_at_cursor()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  for _, h in ipairs(state.hits) do
    if h.row == row then
      return h
    end
  end
  return nil
end

function M.open()
  ensure_hl()
  close()

  local lines = {}
  local hits = {}
  local function add(line, hit)
    lines[#lines + 1] = line
    if hit then
      hit.row = #lines
      hits[#hits + 1] = hit
    end
  end

  add(t("  nvimplugins 帮助  ·  点击/回车运行  ·  q 关闭", "  nvimplugins help  ·  Enter/click run  ·  q close"))
  add(t("  快捷键显示已解析 <leader>；配置过的 keys_* 会尽量读取当前值", "  Keys show expanded <leader>; keys_* try current config"))
  add(string.rep("─", 78))

  for _, item in ipairs(catalog()) do
    -- 未加载的子插件不显示（整仓元项 nvimplugins 始终显示）
    local loaded = item.plugin == "nvimplugins" or vim.g["loaded_" .. item.plugin]
    if not loaded then
      goto continue
    end
    local title = t(item.title_zh, item.title_en)
    local desc = t(item.desc_zh, item.desc_en)
    add("")
    add(
      string.format("● [%s] %s — %s", item.plugin, title, desc),
      nil
    )
    -- 命令
    if item.commands and #item.commands > 0 then
      add("  " .. t("命令:", "Commands:"), nil)
      for _, c in ipairs(item.commands) do
        local d = t(c.desc_zh, c.desc_en)
        local line = string.format("    ▶ :%s  — %s", c.cmd, d)
        add(line, { kind = "cmd", value = c.cmd, desc = d })
      end
    end
    -- 快捷键
    if item.keys and #item.keys > 0 then
      add("  " .. t("快捷键:", "Keys:"), nil)
      for _, k in ipairs(item.keys) do
        local lhs
        if k.field then
          lhs = cfg_key(item.plugin, k.field, k.default)
        else
          lhs = k.default or "-"
        end
        local show = pretty_lhs(tostring(lhs))
        local d = t(k.desc_zh, k.desc_en)
        local modes = k.modes and (" [" .. k.modes .. "]") or ""
        local clickable = show ~= "-" and not show:find("已关闭") and not show:find("disabled")
        local line = string.format("    ▶ %s%s  — %s", show, modes, d)
        if clickable then
          add(line, { kind = "key", value = lhs, desc = d })
        else
          add(line, nil)
        end
      end
    end
    ::continue::
  end

  add("")
  add(t("  图例: ● 已加载  ▶ 可点击/回车执行（未加载的插件已隐藏）", "  Legend: ● loaded  ▶ click/Enter to run (unloaded plugins hidden)"))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "nvimplugins-help"
  pcall(vim.api.nvim_buf_set_name, buf, "nvimplugins://help")

  local width = math.min(90, math.max(60, vim.o.columns - 6))
  local height = math.min(32, math.max(16, vim.o.lines - 6))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = t(" nvimplugins 帮助 ", " nvimplugins help "),
    title_pos = "center",
    zindex = 70,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].number = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].winhighlight =
      "Normal:NvpHelpNormal,NormalFloat:NvpHelpNormal,FloatBorder:NvpHelpBorder,FloatTitle:NvpHelpTitle,CursorLine:NvpHelpHint"
  end)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  -- 标题
  if lines[1] then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, 0, {
      end_col = #lines[1],
      hl_group = "NvpHelpTitle",
    })
  end
  if lines[2] then
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, 1, 0, {
      end_col = #lines[2],
      hl_group = "NvpHelpMeta",
    })
  end
  for i, line in ipairs(lines) do
    if line:match("^●") or line:match("^○") then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, 0, {
        end_col = #line,
        hl_group = "NvpHelpPlugin",
      })
    elseif line:find("▶ :") then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, 0, {
        end_col = #line,
        hl_group = "NvpHelpCmd",
      })
    elseif line:find("▶ ") and not line:find("▶ :") then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, 0, {
        end_col = #line,
        hl_group = "NvpHelpKey",
      })
    end
  end

  state.buf = buf
  state.win = win
  state.hits = hits

  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", o, { desc = "close help" }))
  vim.keymap.set("n", "<Esc>", close, vim.tbl_extend("force", o, { desc = "close help" }))
  vim.keymap.set("n", "<CR>", function()
    run_hit(hit_at_cursor())
  end, vim.tbl_extend("force", o, { desc = "run item" }))
  local function on_click()
    vim.schedule(function()
      if state.buf and vim.api.nvim_get_current_buf() == state.buf then
        run_hit(hit_at_cursor())
      end
    end)
  end
  vim.keymap.set("n", "<LeftRelease>", on_click, o)
  vim.keymap.set("n", "<2-LeftMouse>", on_click, o)
end

---注册帮助命令与 <leader>hh
---@param opts? { keys_help?: string|false }
function M.setup(opts)
  opts = opts or {}
  local lhs = opts.keys_help
  if lhs == nil then
    lhs = "<leader>hh"
  end
  if lhs and lhs ~= false and lhs ~= "" then
    pcall(vim.keymap.del, "n", lhs)
    vim.keymap.set("n", lhs, function()
      M.open()
    end, { silent = true, desc = "nvimplugins: help" })
  end
  pcall(function()
    vim.api.nvim_create_user_command("NvimpluginsHelp", function()
      M.open()
    end, { desc = "nvimplugins: help window (commands & keys)" })
  end)
end

return M
