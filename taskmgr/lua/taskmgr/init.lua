---@mod taskmgr 进程管理 float（类任务管理器）
---窗口固定 80%×80%；buffer 全自绘 + dirty 更新；支持搜索并高亮匹配字符
local i18n = require("taskmgr.i18n")

local M = {}

---@class TaskColumn
---@field id string
---@field width number
---@field visible boolean
---@field min_w number

local COL_DEFS = {
  { id = "pid", width = 8, visible = true, min_w = 4 },
  { id = "name", width = 24, visible = true, min_w = 6 },
  { id = "cpu", width = 8, visible = true, min_w = 5 },
  { id = "mem", width = 12, visible = true, min_w = 6 }, -- 提交大小
  { id = "mem_pct", width = 8, visible = true, min_w = 5 }, -- 提交%
  { id = "gpu", width = 8, visible = true, min_w = 5 },
  { id = "user", width = 14, visible = false, min_w = 4 },
  { id = "cmd", width = 40, visible = false, min_w = 8 },
}

local default_config = {
  python = "python",
  ui_lang = "auto",
  border = "rounded",
  keys_open = "<leader>ta",
  ---自动刷新间隔 ms；0 关闭
  refresh_ms = 2000,
  ---采样间隔（传给脚本）ms
  sample_ms = 400,
  ---浮窗相对编辑器比例（打开时固定，之后不再改尺寸）
  width_ratio = 0.8,
  height_ratio = 0.8,
  ---CPU 高亮：升序阈值（%）。默认 ≥3% 起色，之后按程度加深背景
  --- 例 {3,15,40,70} → 4 档；也可用 cpu_hl_min 只改起点（会写入 levels[1]）
  cpu_hl_min = 3,
  cpu_levels = { 3, 15, 40, 70 },
  ---内存高亮：按「提交大小」MB。默认 ≥200MB 起色
  mem_hl_min_mb = 200,
  mem_mb_levels = { 200, 500, 1000, 2000 },
  ---GPU% 高亮起点与档位（0-100）
  gpu_hl_min = 3,
  gpu_levels = { 3, 15, 40, 70 },
  max_rows = 500,
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}

---@class TaskFrame
---@field lines string[]
---@field extmarks {line:number, col:number, end_col:number, hl:string}[]
---@field row_map table<number, table>
---@field header_line number
---@field data_top number
---@field data_bot number

local state = {
  buf = nil,
  win = nil,
  procs = {}, ---@type table[]
  total_mem = 0,
  mem_used = 0,
  commit_limit = 0,
  sys_cpu = 0,
  sys_gpu = 0,
  cpu_count = 1,
  backend = "",
  busy = false,
  timer = nil,
  sort_key = "cpu",
  sort_asc = false,
  columns = nil, ---@type TaskColumn[]
  ---当前调宽列 id（按列 id，不随显隐错位）
  col_focus_id = "name",
  row_map = {}, ---@type table<number, table>
  header_line = 5,
  data_top = 6,
  data_bot = 6,
  search_line = 4, ---1-based 搜索行（title/sys/help 之后）
  status = "",
  err = nil,
  ---搜索（自绘输入，不进 insert，避免 BS 键码污染）
  query = "",
  searching = false, --- 搜索模式（getcharstr 循环）
  _painting = false,
  ---dirty 自绘
  dirty = false,
  paint_scheduled = false,
  frame = nil, ---@type TaskFrame|nil
  ---打开时锁定的窗口尺寸（之后 paint 不再改）
  win_w = nil,
  win_h = nil,
  win_row = nil,
  win_col = nil,
  ---保持选中（按 pid）
  sel_pid = nil,
  ---列显隐 float
  col_picker_buf = nil,
  col_picker_win = nil,
  col_picker_sel = 1, ---1-based 行（对应 columns 下标）
  ---autocmd group
  augroup = nil,
}

local NS = vim.api.nvim_create_namespace("taskmgr_view")
local NS_COL = vim.api.nvim_create_namespace("taskmgr_cols")

local function prefs_path()
  return vim.fn.stdpath("data") .. "/taskmgr-nvim-cols.json"
end

---nvim_set_hl：0.9 不支持 force 键（会 invalid key，整组高亮失败）
---@param name string
---@param val table
local function set_hl(name, val)
  local o = {}
  for k, v in pairs(val) do
    o[k] = v
  end
  if vim.fn.has("nvim-0.10") == 1 then
    o.force = true
  end
  pcall(vim.api.nvim_set_hl, 0, name, o)
end

local function ensure_hl()
  -- gui + cterm：无 termguicolors 时仍能看见列高亮
  set_hl("TaskmgrNormal", { fg = "#111111", bg = "#ffffff", ctermfg = 233, ctermbg = 15 })
  set_hl("TaskmgrTitle", { fg = "#111111", bg = "#ffffff", bold = true, ctermfg = 233, ctermbg = 15 })
  set_hl("TaskmgrHelp", { fg = "#666666", bg = "#ffffff", ctermfg = 242, ctermbg = 15 })
  set_hl("TaskmgrHead", { fg = "#003366", bg = "#e8f0ff", bold = true, ctermfg = 24, ctermbg = 189 })
  set_hl("TaskmgrBorder", { fg = "#4488aa", bg = "#ffffff", ctermfg = 67, ctermbg = 15 })
  set_hl("TaskmgrStatus", { fg = "#006600", bg = "#ffffff", ctermfg = 28, ctermbg = 15 })
  set_hl("TaskmgrErr", { fg = "#aa0000", bg = "#ffffff", bold = true, ctermfg = 124, ctermbg = 15 })
  set_hl("TaskmgrFocusCol", { fg = "#003366", bg = "#fff3b0", bold = true, ctermfg = 24, ctermbg = 229 })
  set_hl("TaskmgrSearch", { fg = "#0d47a1", bg = "#fff9c4", ctermfg = 25, ctermbg = 229 })
  set_hl("TaskmgrMatch", { fg = "#000000", bg = "#ffeb3b", bold = true, ctermfg = 16, ctermbg = 226 })
  -- CPU：绿 → 黄 → 橙 → 红（背景随程度加深）
  set_hl("TaskmgrCpu1", { fg = "#1b5e20", bg = "#e8f5e9", ctermfg = 22, ctermbg = 194 })
  set_hl("TaskmgrCpu2", { fg = "#f57f17", bg = "#fff9c4", bold = true, ctermfg = 178, ctermbg = 229 })
  set_hl("TaskmgrCpu3", { fg = "#e65100", bg = "#ffe0b2", bold = true, ctermfg = 166, ctermbg = 223 })
  set_hl("TaskmgrCpu4", { fg = "#b71c1c", bg = "#ffcdd2", bold = true, ctermfg = 124, ctermbg = 217 })
  -- 内存：浅蓝 → 紫 → 粉 → 红
  set_hl("TaskmgrMem1", { fg = "#0d47a1", bg = "#e3f2fd", ctermfg = 25, ctermbg = 153 })
  set_hl("TaskmgrMem2", { fg = "#4a148c", bg = "#f3e5f5", bold = true, ctermfg = 54, ctermbg = 189 })
  set_hl("TaskmgrMem3", { fg = "#880e4f", bg = "#fce4ec", bold = true, ctermfg = 89, ctermbg = 218 })
  set_hl("TaskmgrMem4", { fg = "#b71c1c", bg = "#ffcdd2", bold = true, ctermfg = 124, ctermbg = 217 })
end

local function script_path()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  return vim.fn.fnamemodify(src, ":p:h:h:h") .. "/scripts/list_procs.py"
end

local function resolve_python()
  local cands = { config.python, "python", "python3" }
  if vim.fn.has("win32") == 1 then
    table.insert(cands, "py")
  end
  for _, c in ipairs(cands) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      local abs = vim.fn.exepath(c)
      if not abs or abs == "" then
        abs = c
      end
      abs = vim.fn.fnamemodify(abs, ":p")
      if c == "py" or abs:lower():match("[/\\]py%.exe$") then
        return { abs, "-3" }
      end
      return { abs }
    end
  end
  return nil
end

---异步跑外部命令：优先 vim.system（0.10+），否则 jobstart（0.9 / Windows 更稳）
---@param cmd string[]
---@param opts? { text?: boolean, timeout?: number }
---@param on_exit fun(res: { code: number, stdout: string, stderr: string })
local function run_async(cmd, opts, on_exit)
  opts = opts or {}
  if vim.system then
    local ok = pcall(function()
      vim.system(cmd, { text = opts.text ~= false, timeout = opts.timeout }, function(res)
        on_exit({
          code = res.code or -1,
          stdout = res.stdout or "",
          stderr = res.stderr or "",
        })
      end)
    end)
    if ok then
      return
    end
  end

  local out_chunks, err_chunks = {}, {}
  local finished = false
  local function finish(res)
    if finished then
      return
    end
    finished = true
    on_exit(res)
  end

  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= nil then
          out_chunks[#out_chunks + 1] = line
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= nil then
          err_chunks[#err_chunks + 1] = line
        end
      end
    end,
    on_exit = function(_, code)
      -- jobstart 行缓冲会多一个尾空串，去掉以免多余换行
      if out_chunks[#out_chunks] == "" then
        out_chunks[#out_chunks] = nil
      end
      if err_chunks[#err_chunks] == "" then
        err_chunks[#err_chunks] = nil
      end
      finish({
        code = code or -1,
        stdout = table.concat(out_chunks, "\n"),
        stderr = table.concat(err_chunks, "\n"),
      })
    end,
  })
  if job <= 0 then
    finish({ code = -1, stdout = "", stderr = "jobstart failed" })
    return
  end
  local timeout = tonumber(opts.timeout)
  if timeout and timeout > 0 then
    vim.defer_fn(function()
      if finished then
        return
      end
      -- 仍在跑则强停，on_exit 会 finish
      if vim.fn.jobwait({ job }, 0)[1] == -1 then
        pcall(vim.fn.jobstop, job)
      end
    end, timeout)
  end
end

---打开时计算并锁定的几何
local function compute_geometry()
  local wr = tonumber(config.width_ratio) or 0.8
  local hr = tonumber(config.height_ratio) or 0.8
  if wr < 0.3 then
    wr = 0.3
  end
  if wr > 0.98 then
    wr = 0.98
  end
  if hr < 0.3 then
    hr = 0.3
  end
  if hr > 0.98 then
    hr = 0.98
  end
  local w = math.max(40, math.floor(vim.o.columns * wr))
  local h = math.max(12, math.floor(vim.o.lines * hr))
  w = math.min(w, vim.o.columns - 2)
  h = math.min(h, vim.o.lines - 2)
  local row = math.max(0, math.floor((vim.o.lines - h) / 2))
  local col = math.max(0, math.floor((vim.o.columns - w) / 2))
  return w, h, row, col
end

local function default_columns()
  local cols = {}
  for _, d in ipairs(COL_DEFS) do
    cols[#cols + 1] = {
      id = d.id,
      width = d.width,
      visible = d.visible,
      min_w = d.min_w or 4,
    }
  end
  return cols
end

local function load_col_prefs()
  local f = prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" and type(data.columns) == "table" then
    return data
  end
  return nil
end

local function save_col_prefs()
  pcall(function()
    local cols = {}
    for _, c in ipairs(state.columns or {}) do
      cols[#cols + 1] = { id = c.id, width = c.width, visible = c.visible }
    end
    local f = prefs_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({
      vim.json.encode({
        columns = cols,
        sort_key = state.sort_key,
        sort_asc = state.sort_asc,
      }),
    }, f)
  end)
end

local function init_columns()
  local cols = default_columns()
  local pref = load_col_prefs()
  if pref and pref.columns then
    local by_id = {}
    for _, c in ipairs(pref.columns) do
      if type(c) == "table" and c.id then
        by_id[c.id] = c
      end
    end
    for _, c in ipairs(cols) do
      local p = by_id[c.id]
      if p then
        if type(p.width) == "number" then
          c.width = math.max(c.min_w or 4, math.floor(p.width))
        end
        if type(p.visible) == "boolean" then
          c.visible = p.visible
        end
      end
    end
    if type(pref.sort_key) == "string" then
      state.sort_key = pref.sort_key
    end
    if type(pref.sort_asc) == "boolean" then
      state.sort_asc = pref.sort_asc
    end
  end
  local any = false
  for _, c in ipairs(cols) do
    if c.visible then
      any = true
      break
    end
  end
  if not any then
    cols[1].visible = true
    cols[2].visible = true
  end
  state.columns = cols
end

local function visible_columns()
  local out = {}
  for _, c in ipairs(state.columns or {}) do
    if c.visible then
      out[#out + 1] = c
    end
  end
  return out
end

local function col_label(id)
  local map = {
    pid = "col_pid",
    name = "col_name",
    cpu = "col_cpu",
    mem = "col_mem",
    mem_pct = "col_mem_pct",
    gpu = "col_gpu",
    user = "col_user",
    cmd = "col_cmd",
  }
  return i18n.t(map[id] or id)
end

local function str_width(s)
  return vim.fn.strdisplaywidth(tostring(s or ""))
end

---nvim_buf_set_lines 禁止行内含换行；进程 cmdline 等可能带 \\n
---注意：Lua pattern 字符类里不能写 \\0（会 malformed pattern）
local function one_line(s)
  s = tostring(s or "")
  s = s:gsub("\r\n", " ")
  s = s:gsub("\r", " ")
  s = s:gsub("\n", " ")
  s = s:gsub("%z", " ")
  return s
end

---截断到显示宽度 w（可带 …），不补空格
local function trunc_display(s, w)
  s = tostring(s or "")
  if w <= 0 then
    return ""
  end
  if str_width(s) <= w then
    return s
  end
  if w == 1 then
    return "…"
  end
  local acc, i = "", 1
  while i <= #s do
    local b = s:byte(i)
    local len = 1
    if b >= 0xF0 then
      len = 4
    elseif b >= 0xE0 then
      len = 3
    elseif b >= 0xC0 then
      len = 2
    end
    local piece = s:sub(i, i + len - 1)
    if str_width(acc .. piece) > w - 1 then
      break
    end
    acc = acc .. piece
    i = i + len
  end
  return acc .. "…"
end

---补齐到显示宽度 w；返回 cell, content_byte_off（内容起始字节偏移，用于匹配高亮）
local function pad_align(s, w, align)
  s = trunc_display(s, w)
  local dw = str_width(s)
  local pad = w - dw
  if pad < 0 then
    pad = 0
  end
  if align == "right" then
    local left = string.rep(" ", pad)
    return left .. s, #left
  end
  return s .. string.rep(" ", pad), 0
end

local function fmt_mem(bytes)
  local n = tonumber(bytes) or 0
  if n < 1024 then
    return string.format("%d B", n)
  elseif n < 1024 * 1024 then
    return string.format("%.1f KB", n / 1024)
  elseif n < 1024 * 1024 * 1024 then
    return string.format("%.1f MB", n / (1024 * 1024))
  end
  return string.format("%.2f GB", n / (1024 * 1024 * 1024))
end

local function cell_value(proc, id)
  if id == "pid" then
    return tostring(proc.pid or 0)
  elseif id == "name" then
    return one_line(proc.name or "")
  elseif id == "cpu" then
    return string.format("%.1f", tonumber(proc.cpu) or 0)
  elseif id == "mem" then
    return fmt_mem(proc.mem)
  elseif id == "mem_pct" then
    return string.format("%.1f", tonumber(proc.mem_pct) or 0)
  elseif id == "gpu" then
    return string.format("%.1f", tonumber(proc.gpu) or 0)
  elseif id == "user" then
    return one_line(proc.user or "")
  elseif id == "cmd" then
    return one_line(proc.cmd or "")
  end
  return ""
end

local function cell_align(id)
  if id == "pid" or id == "cpu" or id == "mem" or id == "mem_pct" or id == "gpu" then
    return "right"
  end
  return "left"
end

---系统空闲进程：不参与 CPU 过高高亮
local function is_idle_proc(proc)
  if not proc then
    return false
  end
  if proc.idle == true then
    return true
  end
  local pid = tonumber(proc.pid)
  if pid == 0 then
    return true
  end
  local n = string.lower(tostring(proc.name or ""))
  return n == "system idle process" or n == "idle" or n:find("idle process", 1, true) ~= nil
end

---升序阈值：value < levels[1] → 0（不高亮）；≥ levels[i] → 档位 i（最多 4）
---@param value number
---@param levels number[]
---@return integer 0..4
local function level_of(value, levels)
  levels = levels or {}
  local v = tonumber(value) or 0
  if #levels == 0 then
    return 0
  end
  local first = tonumber(levels[1]) or 0
  if v < first then
    return 0
  end
  local lv = 1
  for i = 1, math.min(4, #levels) do
    local t = tonumber(levels[i])
    if t and v >= t then
      lv = i
    end
  end
  return lv
end

---合并用户写的 min 起点到 levels[1]
local function resolve_levels(levels, min_override)
  local lv = {}
  for i, x in ipairs(levels or {}) do
    lv[i] = tonumber(x) or 0
  end
  if min_override ~= nil then
    local m = tonumber(min_override)
    if m then
      if #lv == 0 then
        lv[1] = m
      else
        lv[1] = m
        -- 保证升序：后续档位不低于起点
        for i = 2, #lv do
          if lv[i] < m then
            lv[i] = m
          end
        end
      end
    end
  end
  table.sort(lv)
  return lv
end

local function cpu_hl(proc)
  if is_idle_proc(proc) then
    return nil
  end
  local cpu = tonumber(proc.cpu) or 0
  local levels = resolve_levels(config.cpu_levels, config.cpu_hl_min)
  local lv = level_of(cpu, levels)
  if lv >= 4 then
    return "TaskmgrCpu4"
  elseif lv == 3 then
    return "TaskmgrCpu3"
  elseif lv == 2 then
    return "TaskmgrCpu2"
  elseif lv == 1 then
    return "TaskmgrCpu1"
  end
  return nil
end

local function mem_hl(proc)
  -- 按提交大小 MB 着色
  local mb = (tonumber(proc.mem) or 0) / (1024 * 1024)
  local levels = resolve_levels(config.mem_mb_levels, config.mem_hl_min_mb)
  local lv = level_of(mb, levels)
  if lv >= 4 then
    return "TaskmgrMem4"
  elseif lv == 3 then
    return "TaskmgrMem3"
  elseif lv == 2 then
    return "TaskmgrMem2"
  elseif lv == 1 then
    return "TaskmgrMem1"
  end
  return nil
end

local function gpu_hl(proc)
  if is_idle_proc(proc) then
    return nil
  end
  local gpu = tonumber(proc.gpu) or 0
  local levels = resolve_levels(config.gpu_levels, config.gpu_hl_min)
  local lv = level_of(gpu, levels)
  if lv >= 4 then
    return "TaskmgrCpu4"
  elseif lv == 3 then
    return "TaskmgrCpu3"
  elseif lv == 2 then
    return "TaskmgrCpu2"
  elseif lv == 1 then
    return "TaskmgrCpu1"
  end
  return nil
end

---在 text 中找 query 的所有不重叠子串匹配（大小写不敏感），返回 0-based byte [start, end)
local function match_ranges(text, query)
  local out = {}
  if not query or query == "" or not text or text == "" then
    return out
  end
  local tl = string.lower(text)
  local ql = string.lower(query)
  if ql == "" then
    return out
  end
  local from = 1
  while from <= #tl do
    local a, b = string.find(tl, ql, from, true)
    if not a then
      break
    end
    out[#out + 1] = { a - 1, b }
    from = b + 1
  end
  return out
end

local function proc_matches_query(proc, q)
  if not q or q == "" then
    return true
  end
  local ql = string.lower(q)
  local hay = string.lower(table.concat({
    tostring(proc.pid or ""),
    tostring(proc.name or ""),
    tostring(proc.user or ""),
    tostring(proc.cmd or ""),
  }, "\0"))
  return hay:find(ql, 1, true) ~= nil
end

local function sorted_filtered_procs()
  local key = state.sort_key or "cpu"
  local asc = state.sort_asc and true or false
  local q = vim.trim(state.query or "")
  local list = {}
  for _, p in ipairs(state.procs or {}) do
    if proc_matches_query(p, q) then
      list[#list + 1] = p
    end
  end
  table.sort(list, function(a, b)
    local va, vb
    if key == "name" or key == "user" or key == "cmd" then
      va = string.lower(tostring(a[key] or ""))
      vb = string.lower(tostring(b[key] or ""))
      if va == vb then
        return (a.pid or 0) < (b.pid or 0)
      end
      if asc then
        return va < vb
      end
      return va > vb
    elseif key == "mem" then
      va = tonumber(a.mem) or 0
      vb = tonumber(b.mem) or 0
    elseif key == "mem_pct" then
      va = tonumber(a.mem_pct) or 0
      vb = tonumber(b.mem_pct) or 0
    elseif key == "gpu" then
      va = tonumber(a.gpu) or 0
      vb = tonumber(b.gpu) or 0
    elseif key == "pid" then
      va = tonumber(a.pid) or 0
      vb = tonumber(b.pid) or 0
    elseif key == "cpu" then
      va = tonumber(a.cpu) or 0
      vb = tonumber(b.cpu) or 0
    else
      -- 未知列：尝试数值字段，否则当字符串
      va = tonumber(a[key]) or 0
      vb = tonumber(b[key]) or 0
    end
    if va == vb then
      return (a.pid or 0) < (b.pid or 0)
    end
    if asc then
      return va < vb
    end
    return va > vb
  end)
  return list
end

---标记 dirty 并调度一次 paint（同 tick 合并）
local function mark_dirty()
  state.dirty = true
  if state.paint_scheduled then
    return
  end
  state.paint_scheduled = true
  vim.schedule(function()
    state.paint_scheduled = false
    if state.dirty then
      M._paint()
    end
  end)
end

---搜索行前缀（避免特殊 Unicode，防止 BS 截断多字节产生 <80><ba> 乱码）
local function search_prefix()
  return i18n.t("search") .. "> "
end

---清理 query 中因错误 BS/键码产生的垃圾字节
local function clean_query(s)
  s = tostring(s or "")
  -- Neovim 特殊键内部前缀 0x80 及后随字节
  s = s:gsub(string.char(0x80) .. "[\128-\255]?", "")
  -- 去掉其它 C1 控制字节
  s = s:gsub("[\1-\8\11\12\14-\31\127]", "")
  return s
end

---当前调宽目标列（按 col_focus_id，找不到则回退第一可见列）
---@return TaskColumn|nil
local function focused_column()
  local vis = visible_columns()
  if #vis == 0 then
    return nil
  end
  local id = state.col_focus_id
  if id then
    for _, c in ipairs(vis) do
      if c.id == id then
        return c
      end
    end
  end
  state.col_focus_id = vis[1].id
  return vis[1]
end

local function ensure_col_focus()
  focused_column()
end

local function set_sort(key)
  if not key or key == "" then
    return
  end
  if state.sort_key == key then
    state.sort_asc = not state.sort_asc
  else
    state.sort_key = key
    state.sort_asc = (key == "name" or key == "user" or key == "cmd")
  end
  save_col_prefs()
  mark_dirty()
end

---对当前调宽/选中列排序（s）
local function sort_focused_column()
  local col = focused_column()
  if not col then
    return
  end
  set_sort(col.id)
end

local function adjust_width(delta)
  local col = focused_column()
  if not col then
    return
  end
  -- 不限制最大宽度（可超出窗口，靠横向滚动查看）
  local min_w = col.min_w or 4
  col.width = math.max(min_w, (col.width or min_w) + delta)
  save_col_prefs()
  mark_dirty()
end

local function cycle_col_focus(dir)
  local vis = visible_columns()
  if #vis == 0 then
    return
  end
  local idx = 1
  for i, c in ipairs(vis) do
    if c.id == state.col_focus_id then
      idx = i
      break
    end
  end
  idx = ((idx - 1 + dir) % #vis) + 1
  state.col_focus_id = vis[idx].id
  mark_dirty()
end

local function visible_count()
  local n = 0
  for _, c in ipairs(state.columns or {}) do
    if c.visible then
      n = n + 1
    end
  end
  return n
end

---切换第 idx 列显隐（1-based）；至少保留一列可见
---@param idx number
---@return boolean changed
local function set_column_visible(idx, visible)
  local cols = state.columns or {}
  local c = cols[idx]
  if not c then
    return false
  end
  if visible == c.visible then
    return false
  end
  if not visible and visible_count() <= 1 then
    vim.notify(i18n.t("col_keep_one"), vim.log.levels.WARN)
    return false
  end
  c.visible = visible and true or false
  ensure_col_focus()
  save_col_prefs()
  mark_dirty()
  return true
end

local function toggle_column_by_index(idx)
  local cols = state.columns or {}
  local c = cols[idx]
  if not c then
    return false
  end
  return set_column_visible(idx, not c.visible)
end

---隐藏当前选中列（D）
local function hide_focused_column()
  local col = focused_column()
  if not col then
    return
  end
  local cols = state.columns or {}
  local idx = nil
  for i, c in ipairs(cols) do
    if c.id == col.id then
      idx = i
      break
    end
  end
  if not idx then
    return
  end
  set_column_visible(idx, false)
  ensure_col_focus()
end

local function close_col_picker()
  if state.col_picker_win and vim.api.nvim_win_is_valid(state.col_picker_win) then
    pcall(vim.api.nvim_win_close, state.col_picker_win, true)
  end
  if state.col_picker_buf and vim.api.nvim_buf_is_valid(state.col_picker_buf) then
    pcall(vim.api.nvim_buf_delete, state.col_picker_buf, { force = true })
  end
  state.col_picker_win, state.col_picker_buf = nil, nil
end

local function render_col_picker()
  if not state.col_picker_buf or not vim.api.nvim_buf_is_valid(state.col_picker_buf) then
    return
  end
  local cols = state.columns or {}
  local lines = {}
  lines[#lines + 1] = i18n.t("col_picker_title")
  lines[#lines + 1] = i18n.t("col_picker_help")
  lines[#lines + 1] = string.rep("─", 36)
  local first_data = #lines + 1
  for i, c in ipairs(cols) do
    local mark = c.visible and "☑" or "☐"
    local lab = col_label(c.id)
    lines[#lines + 1] = string.format(" %d  %s  %s", i, mark, lab)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = i18n.t("col_picker_hint")

  vim.bo[state.col_picker_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.col_picker_buf, 0, -1, false, lines)
  vim.bo[state.col_picker_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.col_picker_buf, NS_COL, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, state.col_picker_buf, NS_COL, 0, 0, {
    end_col = #lines[1],
    hl_group = "TaskmgrTitle",
  })
  pcall(vim.api.nvim_buf_set_extmark, state.col_picker_buf, NS_COL, 1, 0, {
    end_col = #lines[2],
    hl_group = "TaskmgrHelp",
  })
  for i, c in ipairs(cols) do
    local line1 = first_data + i - 1 -- 1-based
    if c.visible and lines[line1] then
      pcall(vim.api.nvim_buf_set_extmark, state.col_picker_buf, NS_COL, line1 - 1, 0, {
        end_col = #lines[line1],
        hl_group = "TaskmgrStatus",
      })
    end
  end

  if state.col_picker_win and vim.api.nvim_win_is_valid(state.col_picker_win) then
    local sel = state.col_picker_sel or 1
    if sel < 1 then
      sel = 1
    end
    if sel > #cols then
      sel = #cols
    end
    state.col_picker_sel = sel
    local cur_line = first_data + sel - 1
    pcall(vim.api.nvim_win_set_cursor, state.col_picker_win, { cur_line, 0 })
  end
end

local function open_col_picker()
  if not state.columns then
    init_columns()
  end
  close_col_picker()

  local cols = state.columns or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "taskmgr-cols"
  pcall(vim.api.nvim_buf_set_name, buf, "taskmgr://columns")

  local width = 40
  local height = math.min(#cols + 6, math.max(10, vim.o.lines - 4))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = config.border or "rounded",
    title = i18n.t("col_picker_title"),
    title_pos = "center",
    zindex = 80,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].cursorline = true
    vim.wo[win].winhighlight =
      "Normal:TaskmgrNormal,NormalFloat:TaskmgrNormal,FloatBorder:TaskmgrBorder,FloatTitle:TaskmgrTitle,CursorLine:TaskmgrFocusCol"
  end)

  state.col_picker_buf = buf
  state.col_picker_win = win
  if not state.col_picker_sel or state.col_picker_sel < 1 then
    state.col_picker_sel = 1
  end
  if state.col_picker_sel > #cols then
    state.col_picker_sel = #cols
  end

  local function sel_from_cursor()
    if not state.col_picker_win or not vim.api.nvim_win_is_valid(state.col_picker_win) then
      return state.col_picker_sel
    end
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, state.col_picker_win)
    if not ok or not cur then
      return state.col_picker_sel
    end
    -- 数据从第 4 行开始（title/help/sep）
    local idx = cur[1] - 3
    if idx < 1 then
      idx = 1
    end
    if idx > #cols then
      idx = #cols
    end
    state.col_picker_sel = idx
    return idx
  end

  local function after_change()
    render_col_picker()
  end

  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "q", close_col_picker, vim.tbl_extend("force", o, { desc = "taskmgr: close col picker" }))
  vim.keymap.set("n", "<Esc>", close_col_picker, vim.tbl_extend("force", o, { desc = "taskmgr: close col picker" }))
  vim.keymap.set("n", "<CR>", function()
    local idx = sel_from_cursor()
    toggle_column_by_index(idx)
    after_change()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: toggle col" }))
  vim.keymap.set("n", "<Space>", function()
    local idx = sel_from_cursor()
    toggle_column_by_index(idx)
    after_change()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: toggle col" }))
  vim.keymap.set("n", "x", function()
    local idx = sel_from_cursor()
    toggle_column_by_index(idx)
    after_change()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: toggle col" }))
  for i = 1, 9 do
    vim.keymap.set("n", tostring(i), function()
      if toggle_column_by_index(i) then
        state.col_picker_sel = i
      end
      after_change()
    end, vim.tbl_extend("force", o, { desc = "taskmgr: toggle col " .. i }))
  end
  vim.keymap.set("n", "a", function()
    for _, c in ipairs(state.columns or {}) do
      c.visible = true
    end
    ensure_col_focus()
    save_col_prefs()
    mark_dirty()
    after_change()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: show all cols" }))
  vim.keymap.set("n", "d", function()
    -- 恢复默认显隐（整表赋值，避免逐列 hide 触发「至少一列」）
    for i, def in ipairs(COL_DEFS) do
      local c = (state.columns or {})[i]
      if c then
        c.visible = def.visible and true or false
      end
    end
    if visible_count() == 0 then
      local name_col = (state.columns or {})[2]
      if name_col then
        name_col.visible = true
      elseif (state.columns or {})[1] then
        state.columns[1].visible = true
      end
    end
    ensure_col_focus()
    save_col_prefs()
    mark_dirty()
    after_change()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: default cols" }))
  vim.keymap.set("n", "j", function()
    sel_from_cursor()
    state.col_picker_sel = math.min(#cols, (state.col_picker_sel or 1) + 1)
    render_col_picker()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: col picker down" }))
  vim.keymap.set("n", "k", function()
    sel_from_cursor()
    state.col_picker_sel = math.max(1, (state.col_picker_sel or 1) - 1)
    render_col_picker()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: col picker up" }))

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buf,
    once = true,
    callback = function()
      state.col_picker_buf, state.col_picker_win = nil, nil
    end,
  })

  render_col_picker()
end

---纯计算一帧（不碰 buffer/window）
---@return TaskFrame
local function build_frame()
  ensure_hl()
  ensure_col_focus()
  local vis = visible_columns()
  local lines = {}
  local extmarks = {} ---@type {line:number, col:number, end_col:number, hl:string}[]
  local row_map = {}
  local q = state.query or ""
  local qtrim = vim.trim(q)

  local sort_arrow = state.sort_asc and "↑" or "↓"
  local sort_lab = col_label(state.sort_key) .. sort_arrow
  local focus_col = focused_column()
  local focus_lab = focus_col and (col_label(focus_col.id) .. "*") or "-"
  local list = sorted_filtered_procs()

  local title = string.format(
    "%s  %s:%s  %s:%s  %s:%d/%d  %s:%s",
    i18n.t("title"),
    i18n.t("sort"),
    sort_lab,
    i18n.t("col_focus"),
    focus_lab,
    i18n.t("procs"),
    #list,
    #(state.procs or {}),
    i18n.t("backend"),
    state.backend ~= "" and state.backend or "-"
  )
  lines[#lines + 1] = title

  -- 系统总体占用
  local mem_used = tonumber(state.mem_used) or 0
  local mem_tot = tonumber(state.total_mem) or 0
  local mem_line
  if mem_tot > 0 then
    mem_line = string.format(
      "%s %s/%s (%.0f%%)",
      i18n.t("sys_mem"),
      fmt_mem(mem_used),
      fmt_mem(mem_tot),
      (mem_used / mem_tot) * 100.0
    )
  else
    mem_line = string.format("%s %s", i18n.t("sys_mem"), fmt_mem(mem_used))
  end
  local sys_line = string.format(
    "%s %.1f%%   %s %.1f%%   %s",
    i18n.t("sys_cpu"),
    tonumber(state.sys_cpu) or 0,
    i18n.t("sys_gpu"),
    tonumber(state.sys_gpu) or 0,
    mem_line
  )
  lines[#lines + 1] = sys_line
  lines[#lines + 1] = i18n.t("help")

  -- 搜索行：前缀 + query（搜索模式末尾显示光标块）
  local pref = search_prefix()
  local caret = state.searching and "▌" or ""
  local search_line = pref .. q .. caret
  lines[#lines + 1] = search_line
  state.search_line = #lines

  -- 表头（总宽可超过窗口，横向滚动查看）
  local head_parts = {}
  local head_ranges = {}
  local col_pos = 0
  for i, c in ipairs(vis) do
    local lab = col_label(c.id)
    if c.id == state.sort_key then
      lab = lab .. (state.sort_asc and "↑" or "↓")
    end
    local cell = select(1, pad_align(lab, c.width, cell_align(c.id)))
    if i > 1 then
      head_parts[#head_parts + 1] = " "
      col_pos = col_pos + 1
    end
    local start = col_pos
    head_parts[#head_parts + 1] = cell
    col_pos = col_pos + #cell
    head_ranges[#head_ranges + 1] = { start = start, end_ = col_pos, id = c.id, idx = i }
  end
  local head = table.concat(head_parts)
  local table_w = math.max(str_width(head), 40)
  lines[#lines + 1] = string.rep("─", table_w)
  lines[#lines + 1] = head
  local header_line = #lines
  lines[#lines + 1] = string.rep("─", table_w)
  local data_top = #lines + 1

  local max_rows = tonumber(config.max_rows) or 500
  local count = 0

  if state.err and #(state.procs or {}) == 0 then
    lines[#lines + 1] = i18n.t("fail") .. tostring(state.err)
  elseif #(state.procs or {}) == 0 then
    lines[#lines + 1] = state.busy and i18n.t("loading") or i18n.t("empty")
  elseif #list == 0 then
    lines[#lines + 1] = i18n.t("search_none")
  else
    for _, proc in ipairs(list) do
      count = count + 1
      if count > max_rows then
        break
      end
      local parts = {}
      local ranges = {}
      local pos = 0
      for i, c in ipairs(vis) do
        local val = cell_value(proc, c.id)
        local cell, content_off = pad_align(val, c.width, cell_align(c.id))
        if i > 1 then
          parts[#parts + 1] = " "
          pos = pos + 1
        end
        local start = pos
        parts[#parts + 1] = cell
        local endp = pos + #cell
        pos = endp

        -- 当前列浅底（可被 CPU/内存/匹配高亮覆盖）
        if c.id == state.col_focus_id then
          ranges[#ranges + 1] = { start = start, end_ = endp, hl = "TaskmgrFocusCol", pri = 110 }
        end

        if c.id == "cpu" then
          local hl = cpu_hl(proc)
          if hl then
            ranges[#ranges + 1] = { start = start, end_ = endp, hl = hl, pri = 150 }
          end
        elseif c.id == "mem" or c.id == "mem_pct" then
          local hl = mem_hl(proc)
          if hl then
            ranges[#ranges + 1] = { start = start, end_ = endp, hl = hl, pri = 150 }
          end
        elseif c.id == "gpu" then
          local hl = gpu_hl(proc)
          if hl then
            ranges[#ranges + 1] = { start = start, end_ = endp, hl = hl, pri = 150 }
          end
        end

        -- 搜索匹配高亮
        if qtrim ~= "" then
          local content = trunc_display(val, c.width)
          for _, mr in ipairs(match_ranges(content, qtrim)) do
            local ms = start + content_off + mr[1]
            local me = start + content_off + mr[2]
            if me > ms and me <= endp then
              ranges[#ranges + 1] = { start = ms, end_ = me, hl = "TaskmgrMatch", pri = 200 }
            end
          end
        end
      end
      local row = table.concat(parts)
      lines[#lines + 1] = row
      local line_idx = #lines
      row_map[line_idx] = proc
      for _, r in ipairs(ranges) do
        extmarks[#extmarks + 1] = {
          line = line_idx - 1,
          col = r.start,
          end_col = r.end_,
          hl = r.hl,
          pri = r.pri,
        }
      end
    end
  end
  local data_bot = #lines

  local hidden = {}
  for i, c in ipairs(state.columns or {}) do
    if not c.visible then
      hidden[#hidden + 1] = string.format("%d:%s", i, col_label(c.id))
    end
  end
  if #hidden > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = i18n.t("hidden") .. ": " .. table.concat(hidden, "  ")
  end

  -- 固定装饰 extmarks
  -- 行序：1 title  2 sys  3 help  4 search  ...
  if lines[1] then
    extmarks[#extmarks + 1] = { line = 0, col = 0, end_col = #lines[1], hl = "TaskmgrTitle" }
  end
  if lines[2] then
    extmarks[#extmarks + 1] = { line = 1, col = 0, end_col = #lines[2], hl = "TaskmgrStatus" }
  end
  if lines[3] then
    extmarks[#extmarks + 1] = { line = 2, col = 0, end_col = #lines[3], hl = "TaskmgrHelp" }
  end
  local sline = state.search_line or 4
  if lines[sline] then
    local pref = search_prefix()
    extmarks[#extmarks + 1] = {
      line = sline - 1,
      col = 0,
      end_col = math.min(#pref, #lines[sline]),
      hl = "TaskmgrSearch",
    }
    if (state.query or "") == "" and not state.searching then
      extmarks[#extmarks + 1] = {
        line = sline - 1,
        col = #pref,
        end_col = #pref,
        hl = "TaskmgrHelp",
        virt_text = { { i18n.t("search_empty"), "TaskmgrHelp" } },
        virt_text_pos = "inline",
      }
    end
  end
  if lines[header_line] then
    extmarks[#extmarks + 1] = {
      line = header_line - 1,
      col = 0,
      end_col = #lines[header_line],
      hl = "TaskmgrHead",
      pri = 100,
    }
    for _, hr in ipairs(head_ranges) do
      if hr.id == state.col_focus_id then
        -- 优先级高于表头底色，确保当前列黄底可见
        extmarks[#extmarks + 1] = {
          line = header_line - 1,
          col = hr.start,
          end_col = hr.end_,
          hl = "TaskmgrFocusCol",
          pri = 160,
        }
      end
    end
  end

  return {
    lines = lines,
    extmarks = extmarks,
    row_map = row_map,
    header_line = header_line,
    data_top = data_top,
    data_bot = data_bot,
    search_line = state.search_line,
  }
end

---将 frame 以 dirty 方式写入 buffer（仅改变化行；窗口尺寸不改）
---刷新时尽量保持光标行列不变
function M._paint()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.dirty = false
    return
  end
  if not state.dirty then
    return
  end
  state.dirty = false
  state._painting = true

  local keep_cursor = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local okc, cur = pcall(vim.api.nvim_win_get_cursor, state.win)
    if okc and cur then
      keep_cursor = { cur[1], cur[2] }
    end
  end

  local frame = build_frame()
  local old = state.frame
  local lines = frame.lines
  -- 兜底：任何行内换行都会导致 set_lines 报错
  for i, ln in ipairs(lines) do
    if type(ln) ~= "string" then
      lines[i] = tostring(ln or "")
    end
    if lines[i]:find("\n", 1, true) or lines[i]:find("\r", 1, true) or lines[i]:find("\0", 1, true) then
      lines[i] = one_line(lines[i])
    end
  end
  local sline = frame.search_line or state.search_line or 3

  vim.bo[state.buf].modifiable = true
  local ok_set, err_set = pcall(function()
    if not old or not old.lines or #old.lines ~= #lines then
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    else
      for i = 1, #lines do
        if old.lines[i] ~= lines[i] then
          vim.api.nvim_buf_set_lines(state.buf, i - 1, i, false, { lines[i] })
        end
      end
    end
  end)
  if not ok_set then
    -- 极端情况：整表按净化行重写
    local safe = {}
    for i, ln in ipairs(lines) do
      safe[i] = one_line(ln)
    end
    pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, safe)
    lines = safe
    vim.notify("taskmgr: paint " .. tostring(err_set), vim.log.levels.DEBUG)
  end
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for _, em in ipairs(frame.extmarks) do
    local pri = em.pri
    if not pri then
      if em.hl == "TaskmgrMatch" then
        pri = 200
      elseif em.hl == "TaskmgrFocusCol" then
        pri = 160
      elseif em.hl and (em.hl:find("^TaskmgrCpu") or em.hl:find("^TaskmgrMem")) then
        pri = 150
      else
        pri = 100
      end
    end
    local opts = {
      end_col = em.end_col,
      hl_group = em.hl,
      priority = pri,
    }
    if em.virt_text then
      opts.virt_text = em.virt_text
      opts.virt_text_pos = em.virt_text_pos or "inline"
      opts.end_col = nil
      opts.hl_group = nil
    end
    pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, em.line, em.col, opts)
  end

  state.frame = frame
  state.row_map = frame.row_map
  state.header_line = frame.header_line
  state.data_top = frame.data_top
  state.data_bot = frame.data_bot
  state.search_line = frame.search_line or sline

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    if state.searching then
      -- 搜索模式：光标停在搜索行
      local line = lines[state.search_line] or ""
      pcall(vim.api.nvim_win_set_cursor, state.win, { state.search_line, math.max(0, #line - 1) })
    elseif keep_cursor then
      local lc = vim.api.nvim_buf_line_count(state.buf)
      local row = keep_cursor[1]
      if row < 1 then
        row = 1
      end
      if row > lc then
        row = lc
      end
      local bline = vim.api.nvim_buf_get_lines(state.buf, row - 1, row, false)[1] or ""
      local col = keep_cursor[2]
      if col < 0 then
        col = 0
      end
      if col > #bline then
        col = #bline
      end
      pcall(vim.api.nvim_win_set_cursor, state.win, { row, col })
      local proc = state.row_map[row]
      if proc and proc.pid then
        state.sel_pid = proc.pid
      end
    end
  end
  state._painting = false
end

---兼容旧名
function M._render()
  state.dirty = true
  M._paint()
end

local function remember_sel()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  local ok, cur = pcall(vim.api.nvim_win_get_cursor, state.win)
  if not ok or not cur then
    return
  end
  local proc = state.row_map[cur[1]]
  if proc and proc.pid then
    state.sel_pid = proc.pid
  end
end

local function close()
  state.searching = false
  if vim.fn.mode():find("i") then
    pcall(vim.cmd, "stopinsert")
  end
  close_col_picker()
  if state.timer then
    pcall(function()
      vim.fn.timer_stop(state.timer)
    end)
    state.timer = nil
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf = nil, nil
  state.row_map = {}
  state.frame = nil
  state.dirty = false
  state.searching = false
  state.win_w, state.win_h, state.win_row, state.win_col = nil, nil, nil, nil
end

local function fetch(cb)
  if state.busy then
    if cb then
      cb(false)
    end
    return
  end
  local py = resolve_python()
  if not py then
    state.err = i18n.t("need_python")
    mark_dirty()
    if cb then
      cb(false)
    end
    return
  end
  local script = script_path()
  if vim.fn.filereadable(script) ~= 1 then
    state.err = i18n.t("script_missing") .. script
    mark_dirty()
    if cb then
      cb(false)
    end
    return
  end

  state.busy = true
  mark_dirty()
  local sample = tonumber(config.sample_ms) or 400
  local cmd = {}
  for _, x in ipairs(py) do
    cmd[#cmd + 1] = x
  end
  cmd[#cmd + 1] = "-X"
  cmd[#cmd + 1] = "utf8"
  cmd[#cmd + 1] = script
  cmd[#cmd + 1] = tostring(sample)

  run_async(cmd, { text = true, timeout = 20000 }, function(res)
    vim.schedule(function()
      state.busy = false
      local code = res.code or -1
      local stdout = res.stdout or ""
      local stderr = res.stderr or ""
      -- 去掉可能的 UTF-8 BOM
      stdout = vim.trim(stdout):gsub("^\239\187\191", "")
      local okj, data = pcall(vim.json.decode, stdout)
      if not okj or type(data) ~= "table" then
        state.err = (stderr ~= "" and stderr) or ("bad json / code " .. tostring(code))
        state.procs = {}
        mark_dirty()
        if cb then
          cb(false)
        end
        return
      end
      if not data.ok then
        local err = tostring(data.err or "not ok")
        if err:find("need_psutil", 1, true) or err:find("No module named 'psutil'", 1, true) then
          state.err = i18n.t("need_psutil")
        else
          state.err = err
        end
        state.procs = {}
        mark_dirty()
        if cb then
          cb(false)
        end
        return
      end
      remember_sel()
      state.err = nil
      state.procs = data.procs or {}
      state.total_mem = tonumber(data.total_mem) or 0
      state.mem_used = tonumber(data.mem_used) or 0
      state.commit_limit = tonumber(data.commit_limit) or 0
      state.sys_cpu = tonumber(data.sys_cpu) or 0
      state.sys_gpu = tonumber(data.sys_gpu) or 0
      state.cpu_count = tonumber(data.cpu_count) or 1
      state.backend = tostring(data.backend or "")
      -- 若脚本未给 sys_cpu，用非 idle 进程 CPU 合计近似
      if (not data.sys_cpu) or data.sys_cpu == nil then
        local sum = 0
        for _, p in ipairs(state.procs) do
          if not (p.idle or tonumber(p.pid) == 0) then
            sum = sum + (tonumber(p.cpu) or 0)
          end
        end
        if sum > 100 then
          sum = 100
        end
        state.sys_cpu = sum
      end
      mark_dirty()
      if cb then
        cb(true)
      end
    end)
  end)
end

local function proc_under_cursor()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return nil
  end
  local ok, cur = pcall(vim.api.nvim_win_get_cursor, state.win)
  if not ok or not cur then
    return nil
  end
  return state.row_map[cur[1]]
end

local function kill_proc()
  local proc = proc_under_cursor()
  if not proc or not proc.pid then
    return
  end
  local pid = tonumber(proc.pid)
  local name = tostring(proc.name or "")
  vim.ui.input({
    prompt = string.format(i18n.t("kill_confirm"), tostring(pid), name),
  }, function(input)
    if not input then
      return
    end
    local ans = vim.trim(input):lower()
    if ans ~= "y" and ans ~= "yes" then
      return
    end
    local cmd
    if vim.fn.has("win32") == 1 then
      cmd = { "taskkill", "/PID", tostring(pid), "/F" }
    else
      -- Linux / macOS
      cmd = { "kill", "-TERM", tostring(pid) }
    end
    run_async(cmd, { text = true }, function(res)
      vim.schedule(function()
        if (res.code or 1) == 0 then
          vim.notify(i18n.t("killed") .. tostring(pid), vim.log.levels.INFO)
        else
          local msg = vim.trim(res.stderr or res.stdout or "")
          vim.notify(i18n.t("kill_fail") .. tostring(pid) .. " " .. msg, vim.log.levels.WARN)
        end
        fetch()
      end)
    end)
  end)
end

local function paint_now()
  state.dirty = true
  M._paint()
  pcall(vim.cmd, "redraw")
end

local function query_delete_char()
  local q = state.query or ""
  local n = vim.fn.strchars(q)
  if n <= 0 then
    return
  end
  state.query = vim.fn.strcharpart(q, 0, n - 1)
end

local function query_append(ch)
  if not ch or ch == "" then
    return
  end
  ch = tostring(ch):gsub("[\r\n]", "")
  if ch == "" then
    return
  end
  -- 丢弃控制字符 / 异常键码字节
  if #ch == 1 then
    local b = ch:byte()
    if b < 32 or b == 127 then
      return
    end
  end
  if ch:find(string.char(0x80), 1, true) then
    return
  end
  state.query = (state.query or "") .. ch
end

local function keycode(name)
  if vim.keycode then
    return vim.keycode(name)
  end
  return vim.api.nvim_replace_termcodes(name, true, false, true)
end

---自绘搜索：阻塞读键，不进 insert（BS 按「字符」删，不会写进 buffer）
local function run_search_mode()
  if state.searching then
    return
  end
  if not state.buf or not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  state.searching = true
  state.query = state.query or ""
  paint_now()

  local k_bs = keycode("<BS>")
  local k_c_h = keycode("<C-h>")
  local k_del = keycode("<Del>")
  local k_esc = keycode("<Esc>")
  local k_cr = keycode("<CR>")
  local k_cu = keycode("<C-u>")
  local k_cw = keycode("<C-w>")

  while state.searching and state.buf and vim.api.nvim_buf_is_valid(state.buf) do
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == nil then
      break
    end
    if ch == k_esc or ch == "\27" then
      state.searching = false
      break
    elseif ch == k_cr or ch == "\r" or ch == "\n" then
      state.searching = false
      break
    elseif ch == k_bs or ch == k_c_h or ch == "\8" then
      query_delete_char()
      paint_now()
    elseif ch == k_del then
      -- 光标总在末尾，Del 等同 BS
      query_delete_char()
      paint_now()
    elseif ch == k_cu or ch == k_cw then
      state.query = ""
      paint_now()
    else
      query_append(ch)
      paint_now()
    end
  end

  state.searching = false
  paint_now()
end

local function clear_search()
  state.searching = false
  if state.query == "" then
    mark_dirty()
    return
  end
  state.query = ""
  mark_dirty()
end

local function show_help()
  vim.notify(i18n.t("help_full"), vim.log.levels.INFO)
end

local function setup_buf_autocmds(buf)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = vim.api.nvim_create_augroup("taskmgr_buf_" .. tostring(buf), { clear = true })
  -- 搜索不再依赖 insert autocmd
end

local function start_timer()
  if state.timer then
    pcall(function()
      vim.fn.timer_stop(state.timer)
    end)
    state.timer = nil
  end
  local ms = tonumber(config.refresh_ms) or 0
  if ms <= 0 then
    return
  end
  if ms < 800 then
    ms = 800
  end
  state.timer = vim.fn.timer_start(ms, function()
    vim.schedule(function()
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        if state.timer then
          pcall(vim.fn.timer_stop, state.timer)
          state.timer = nil
        end
        return
      end
      fetch()
    end)
  end, { ["repeat"] = -1 })
end

local function bind_keys(buf)
  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", o, { desc = "taskmgr: close" }))
  vim.keymap.set("n", "<Esc>", function()
    if state.searching then
      state.searching = false
      mark_dirty()
      return
    end
    if state.query ~= "" then
      clear_search()
    else
      close()
    end
  end, vim.tbl_extend("force", o, { desc = "taskmgr: clear search / close" }))
  vim.keymap.set("n", "r", function()
    fetch()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: refresh" }))
  -- s：对当前选中列排序（再按切换升/降）
  vim.keymap.set("n", "s", function()
    sort_focused_column()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: sort focused col" }))
  -- 调宽/选中列切换：Tab 与 []
  vim.keymap.set("n", "<Tab>", function()
    cycle_col_focus(1)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: next col" }))
  vim.keymap.set("n", "<S-Tab>", function()
    cycle_col_focus(-1)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: prev col" }))
  vim.keymap.set("n", "]", function()
    cycle_col_focus(1)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: next col" }))
  vim.keymap.set("n", "[", function()
    cycle_col_focus(-1)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: prev col" }))
  vim.keymap.set("n", "+", function()
    adjust_width(4)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: wider" }))
  vim.keymap.set("n", "=", function()
    adjust_width(4)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: wider" }))
  vim.keymap.set("n", "-", function()
    adjust_width(-4)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: narrower" }))
  vim.keymap.set("n", "_", function()
    adjust_width(-4)
  end, vim.tbl_extend("force", o, { desc = "taskmgr: narrower" }))
  -- 横向滚动
  vim.keymap.set("n", "zl", "zl", vim.tbl_extend("force", o, { desc = "taskmgr: scroll right" }))
  vim.keymap.set("n", "zh", "zh", vim.tbl_extend("force", o, { desc = "taskmgr: scroll left" }))
  vim.keymap.set("n", "zL", "zL", vim.tbl_extend("force", o, { desc = "taskmgr: scroll half right" }))
  vim.keymap.set("n", "zH", "zH", vim.tbl_extend("force", o, { desc = "taskmgr: scroll half left" }))
  vim.keymap.set("n", "<ScrollWheelRight>", "zl", vim.tbl_extend("force", o, { desc = "taskmgr: wheel right" }))
  vim.keymap.set("n", "<ScrollWheelLeft>", "zh", vim.tbl_extend("force", o, { desc = "taskmgr: wheel left" }))
  vim.keymap.set("n", "v", function()
    open_col_picker()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: column visibility" }))
  -- D：隐藏当前列；x：结束进程（d 小写也结束，避免与 D 冲突）
  vim.keymap.set("n", "D", function()
    hide_focused_column()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: hide focused col" }))
  vim.keymap.set("n", "x", kill_proc, vim.tbl_extend("force", o, { desc = "taskmgr: kill" }))
  -- 搜索：/ i 等进入自绘输入（getcharstr，不进 insert）
  vim.keymap.set("n", "/", run_search_mode, vim.tbl_extend("force", o, { desc = "taskmgr: search" }))
  vim.keymap.set("n", "i", run_search_mode, vim.tbl_extend("force", o, { desc = "taskmgr: search" }))
  vim.keymap.set("n", "a", run_search_mode, vim.tbl_extend("force", o, { desc = "taskmgr: search" }))
  vim.keymap.set("n", "I", run_search_mode, vim.tbl_extend("force", o, { desc = "taskmgr: search" }))
  vim.keymap.set("n", "A", run_search_mode, vim.tbl_extend("force", o, { desc = "taskmgr: search" }))
  vim.keymap.set("n", "f", run_search_mode, vim.tbl_extend("force", o, { desc = "taskmgr: search" }))
  vim.keymap.set("n", "F", clear_search, vim.tbl_extend("force", o, { desc = "taskmgr: clear search" }))
  vim.keymap.set("n", "L", function()
    local l = i18n.toggle()
    vim.notify(l == "en" and i18n.t("lang_to_en") or i18n.t("lang_to_zh"), vim.log.levels.INFO)
    mark_dirty()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: lang" }))
  vim.keymap.set("n", "?", show_help, vim.tbl_extend("force", o, { desc = "taskmgr: help" }))
  vim.keymap.set("n", "j", function()
    remember_sel()
    vim.cmd("normal! j")
    remember_sel()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: down" }))
  vim.keymap.set("n", "k", function()
    remember_sel()
    vim.cmd("normal! k")
    remember_sel()
  end, vim.tbl_extend("force", o, { desc = "taskmgr: up" }))
end

function M.open()
  M.ensure_setup()
  ensure_hl()
  if not state.columns then
    init_columns()
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_set_current_win, state.win)
    fetch()
    return
  end

  close()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "taskmgr"
  pcall(vim.api.nvim_buf_set_name, buf, "taskmgr://processes")

  local w, h, row, col = compute_geometry()
  state.win_w, state.win_h, state.win_row, state.win_col = w, h, row, col

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
    style = "minimal",
    border = config.border or "rounded",
    title = i18n.t("title"),
    title_pos = "center",
    zindex = 60,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].cursorline = true
    vim.wo[win].list = false
    vim.wo[win].sidescroll = 1
    vim.wo[win].sidescrolloff = 2
    -- 允许内容宽于窗口，用 zl/zh / 光标左右 横向滚动
    vim.wo[win].winhighlight =
      "Normal:TaskmgrNormal,NormalFloat:TaskmgrNormal,FloatBorder:TaskmgrBorder,FloatTitle:TaskmgrTitle,CursorLine:TaskmgrHead"
  end)

  state.buf = buf
  state.win = win
  state.frame = nil
  state.query = state.query or ""
  state.searching = false
  if not state.col_focus_id then
    state.col_focus_id = "name"
  end
  bind_keys(buf)
  setup_buf_autocmds(buf)

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buf,
    once = true,
    callback = function()
      if state.timer then
        pcall(vim.fn.timer_stop, state.timer)
        state.timer = nil
      end
      if state.augroup then
        pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
      end
      state.buf, state.win = nil, nil
      state.frame = nil
      state.searching = false
      state.win_w, state.win_h = nil, nil
    end,
  })

  -- 禁止拖动改尺寸：paint 永不 set_config 尺寸
  state.busy = false
  state.dirty = true
  M._paint()
  fetch()
  start_timer()
end

function M.refresh()
  fetch()
end

function M.close()
  close()
end

local function apply_keys()
  for _, lhs in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", lhs)
  end
  keys_applied = {}
  local lhs = config.keys_open
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, function()
      M.open()
    end, { silent = true, desc = "taskmgr: process manager" })
    keys_applied[#keys_applied + 1] = lhs
  end
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  local lang = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang = user.ui_lang
  end
  i18n.setup(lang)
  if not state.columns then
    init_columns()
  end
  apply_keys()
  setup_done = true
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
end

function M.get_config()
  return config
end

M._config = config

return M
