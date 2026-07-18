---@mod taskmgr.i18n
local M = {}
---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    title = " 进程管理 ",
    help = " q关闭  i//搜索  Tab/[]选列  s排序  D隐列  +/-列宽  v列  x结束  L  ? ",
    help_full = table.concat({
      "快捷键：",
      "  q         关闭",
      "  i / a / / 进入搜索（直接打字，BS 删除，Enter/Esc 结束）",
      "  Esc       退出搜索；有关键词则清空；否则关闭",
      "  F         清空搜索",
      "  r         刷新",
      "  Tab / ] / [   选择当前列（标题 列名*；用于排序/调宽/隐藏）",
      "  s         按当前列排序（再按切换升/降）",
      "  D         隐藏当前列",
      "  + / =     当前列加宽（无上限）",
      "  - / _     当前列变窄",
      "  zh/zl     左右滚动",
      "  v         列显隐面板",
      "  x         结束光标进程",
      "  L / ?     中英 / 帮助",
      "",
      "CPU% 全核合计 100%（类任务管理器）；空闲进程不高亮。",
      "内存：Windows≈提交大小；Linux≈USS/RSS。GPU% 需 NVIDIA 驱动时可用。",
      "依赖：pip install psutil（Win/Linux/macOS 统一后端）",
      "列显隐面板：Space 切换  a全显  d默认  q关闭",
    }, "\n"),
    col_pid = "PID",
    col_name = "名称",
    col_cpu = "CPU%",
    col_mem = "内存", -- Win≈提交大小；Linux≈USS/RSS
    col_mem_pct = "内存%",
    col_gpu = "GPU%",
    col_user = "用户",
    col_cmd = "路径/命令",
    sort = "排序",
    asc = "升",
    desc = "降",
    col_focus = "调宽列",
    loading = "加载进程中…",
    empty = "无进程数据",
    fail = "taskmgr: 获取失败: ",
    need_python = "taskmgr: 需要 Python3",
    need_psutil = "taskmgr: 需要 psutil，请执行: pip install psutil",
    script_missing = "taskmgr: 缺少脚本 ",
    killed = "taskmgr: 已结束 PID ",
    kill_fail = "taskmgr: 结束失败 PID ",
    kill_confirm = "结束进程 PID=%s %s ? [y/N] ",
    lang_to_en = "taskmgr: UI → English",
    lang_to_zh = "taskmgr: UI → 中文",
    auto = "自动刷新",
    procs = "进程",
    backend = "后端",
    sys_cpu = "CPU",
    sys_gpu = "GPU",
    sys_mem = "内存",
    hidden = "已隐藏列",
    search = "搜索",
    search_empty = "输入关键词筛选…",
    search_clear = "F 清空",
    search_prompt = "taskmgr 搜索: ",
    search_none = "无匹配进程",
    col_picker_title = " 列显示 ",
    col_picker_help = " Space/Enter 切换  1-9 列  a全显  d默认  q关闭 ",
    col_picker_hint = "至少保留一列可见；关闭面板后主表立即更新",
    col_keep_one = "taskmgr: 至少保留一列可见",
  },
  en = {
    title = " Processes ",
    help = " q close  i// search  Tab/[] col  s sort  D hide  +/- width  v cols  x kill  L  ? ",
    help_full = table.concat({
      "Keys:",
      "  q         close",
      "  i / a / / search (type to filter; BS delete; Enter/Esc done)",
      "  Esc       leave search; clear query; or close",
      "  F         clear search",
      "  r         refresh",
      "  Tab / ] / [   select column (title name*; sort/width/hide)",
      "  s         sort by focused column (again toggles order)",
      "  D         hide focused column",
      "  + / =     wider column (no max)",
      "  - / _     narrower column",
      "  zh/zl     horizontal scroll",
      "  v         column visibility popup",
      "  x         kill process",
      "  L / ?     language / help",
      "",
      "CPU% is total of all cores = 100%. Idle is not highlighted.",
      "Memory: Windows≈commit size; Linux≈USS/RSS. GPU% needs NVIDIA when available.",
      "Requires: pip install psutil (Win/Linux/macOS).",
      "Column popup: Space toggle  a all  d defaults  q close",
    }, "\n"),
    col_pid = "PID",
    col_name = "Name",
    col_cpu = "CPU%",
    col_mem = "Memory", -- Win≈commit; Linux≈USS/RSS
    col_mem_pct = "Mem%",
    col_gpu = "GPU%",
    col_user = "User",
    col_cmd = "Path/Cmd",
    sort = "Sort",
    asc = "asc",
    desc = "desc",
    col_focus = "Width col",
    loading = "Loading processes…",
    empty = "No process data",
    fail = "taskmgr: fetch failed: ",
    need_python = "taskmgr: needs Python3",
    need_psutil = "taskmgr: needs psutil — run: pip install psutil",
    script_missing = "taskmgr: missing script ",
    killed = "taskmgr: killed PID ",
    kill_fail = "taskmgr: kill failed PID ",
    kill_confirm = "Kill PID=%s %s ? [y/N] ",
    lang_to_en = "taskmgr: UI → English",
    lang_to_zh = "taskmgr: UI → 中文",
    auto = "auto",
    procs = "procs",
    backend = "backend",
    sys_cpu = "CPU",
    sys_gpu = "GPU",
    sys_mem = "Mem",
    hidden = "hidden",
    search = "Search",
    search_empty = "type to filter…",
    search_clear = "F clear",
    search_prompt = "taskmgr search: ",
    search_none = "No matching processes",
    col_picker_title = " Columns ",
    col_picker_help = " Space/Enter toggle  1-9 col  a all  d defaults  q close ",
    col_picker_hint = "Keep at least one column; main table updates immediately",
    col_keep_one = "taskmgr: keep at least one column visible",
  },
}

local function detect_lang()
  local cands = { vim.v.lang, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 then
    return "zh"
  end
  return "en"
end

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  elseif user_lang == "auto" or user_lang == nil then
    lang = detect_lang()
  end
end

function M.get()
  return lang
end

function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  return lang
end

---@param key string
---@return string
function M.t(key)
  local t = STR[lang] or STR.zh
  return t[key] or (STR.en[key] or key)
end

return M
