---@mod calendar 月历浮窗：公历 / 农历 / 节假日 / 备注与颜色标记
local i18n = require("calendar.i18n")
local lunar = require("calendar.lunar")
local notes = require("calendar.notes")

local M = {}

local default_config = {
  ui_lang = "auto",
  border = "rounded",
  ---打开月历的快捷键；false 关闭
  keys_open = "<leader>cal",
  ---时钟刷新间隔 ms；0 关闭
  clock_ms = 1000,
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}

local CELL_W = 8 ---每格显示宽度
local NS = vim.api.nvim_create_namespace("calendar")

local state = {
  buf = nil,
  win = nil,
  view_y = 0,
  view_m = 0,
  sel_y = 0,
  sel_m = 0,
  sel_d = 0,
  ---日 → { line, col_byte, end_col } 用于点击与高亮
  day_pos = {}, ---@type table<integer, {line:integer, col:integer, end_col:integer, lab_line:integer}>
  clock_timer = nil,
  lines = {}, ---@type string[]
}

local COLOR_HL = {
  red = "CalendarMarkRed",
  orange = "CalendarMarkOrange",
  yellow = "CalendarMarkYellow",
  green = "CalendarMarkGreen",
  blue = "CalendarMarkBlue",
  purple = "CalendarMarkPurple",
  pink = "CalendarMarkPink",
}

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
  set_hl("CalendarNormal", { fg = "#111111", bg = "#ffffff", ctermfg = 233, ctermbg = 15 })
  set_hl("CalendarTitle", { fg = "#003366", bg = "#ffffff", bold = true, ctermfg = 24, ctermbg = 15 })
  set_hl("CalendarHelp", { fg = "#666666", bg = "#ffffff", ctermfg = 242, ctermbg = 15 })
  set_hl("CalendarHead", { fg = "#003366", bg = "#e8f0ff", bold = true, ctermfg = 24, ctermbg = 189 })
  set_hl("CalendarBorder", { fg = "#4488aa", bg = "#ffffff", ctermfg = 67, ctermbg = 15 })
  set_hl("CalendarToday", { fg = "#0d47a1", bg = "#fff3b0", bold = true, ctermfg = 25, ctermbg = 229 })
  set_hl("CalendarSelect", { fg = "#ffffff", bg = "#1565c0", bold = true, ctermfg = 15, ctermbg = 25 })
  set_hl("CalendarWeekend", { fg = "#c62828", bg = "#ffffff", ctermfg = 160, ctermbg = 15 })
  set_hl("CalendarFest", { fg = "#c62828", bg = "#ffffff", bold = true, ctermfg = 160, ctermbg = 15 })
  set_hl("CalendarLunar", { fg = "#666666", bg = "#ffffff", ctermfg = 242, ctermbg = 15 })
  set_hl("CalendarNoteDot", { fg = "#e53935", bg = "#ffffff", bold = true, ctermfg = 160, ctermbg = 15 })
  set_hl("CalendarNoteDotSel", { fg = "#ffcdd2", bg = "#1565c0", bold = true, ctermfg = 217, ctermbg = 25 })
  set_hl("CalendarDetail", { fg = "#111111", bg = "#f5f5f5", ctermfg = 233, ctermbg = 255 })
  set_hl("CalendarNote", { fg = "#1b5e20", bg = "#f5f5f5", ctermfg = 22, ctermbg = 255 })
  set_hl("CalendarMarkRed", { fg = "#ffffff", bg = "#e53935", bold = true, ctermfg = 15, ctermbg = 160 })
  set_hl("CalendarMarkOrange", { fg = "#111111", bg = "#ffb74d", bold = true, ctermfg = 233, ctermbg = 214 })
  set_hl("CalendarMarkYellow", { fg = "#111111", bg = "#ffee58", bold = true, ctermfg = 233, ctermbg = 226 })
  set_hl("CalendarMarkGreen", { fg = "#ffffff", bg = "#43a047", bold = true, ctermfg = 15, ctermbg = 34 })
  set_hl("CalendarMarkBlue", { fg = "#ffffff", bg = "#1e88e5", bold = true, ctermfg = 15, ctermbg = 32 })
  set_hl("CalendarMarkPurple", { fg = "#ffffff", bg = "#8e24aa", bold = true, ctermfg = 15, ctermbg = 91 })
  set_hl("CalendarMarkPink", { fg = "#111111", bg = "#f48fb1", bold = true, ctermfg = 233, ctermbg = 211 })
end

---@param s string
---@param w integer
---@return string
local function pad_dw(s, w)
  s = tostring(s or "")
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then
    return s
  end
  return s .. string.rep(" ", w - dw)
end

---@param s string
---@param w integer
---@return string
local function center_dw(s, w)
  s = tostring(s or "")
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then
    return s
  end
  local left = math.floor((w - dw) / 2)
  local right = w - dw - left
  return string.rep(" ", left) .. s .. string.rep(" ", right)
end

local function today()
  local t = os.date("*t")
  return t.year, t.month, t.day
end

local function clamp_day(y, m, d)
  local dim = lunar.days_in_month(y, m)
  if d < 1 then
    d = 1
  end
  if d > dim then
    d = dim
  end
  return d
end

---@param y integer
---@param m integer
---@param delta integer
---@return integer ny
---@return integer nm
local function add_month(y, m, delta)
  local idx = y * 12 + (m - 1) + delta
  local ny = math.floor(idx / 12)
  local nm = (idx % 12) + 1
  if nm < 1 then
    nm = nm + 12
    ny = ny - 1
  end
  return ny, nm
end

local function stop_clock()
  if state.clock_timer then
    pcall(vim.fn.timer_stop, state.clock_timer)
    state.clock_timer = nil
  end
end

local function close_popup()
  stop_clock()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf = nil, nil
  state.day_pos = {}
  state.lines = {}
end

---按选中日跳转视图月
local function sync_view_to_sel()
  state.view_y = state.sel_y
  state.view_m = state.sel_m
end

---@param delta integer days
local function move_day(delta)
  local y, m, d = state.sel_y, state.sel_m, state.sel_d
  d = d + delta
  while d > lunar.days_in_month(y, m) do
    d = d - lunar.days_in_month(y, m)
    y, m = add_month(y, m, 1)
  end
  while d < 1 do
    y, m = add_month(y, m, -1)
    d = d + lunar.days_in_month(y, m)
  end
  if y < 1900 then
    y, m, d = 1900, 1, 31
  elseif y > 2100 then
    y, m, d = 2100, 12, 31
  end
  state.sel_y, state.sel_m, state.sel_d = y, m, d
  sync_view_to_sel()
  M._render()
end

local function move_month(delta)
  local y, m = add_month(state.view_y, state.view_m, delta)
  state.view_y, state.view_m = y, m
  state.sel_y, state.sel_m = y, m
  state.sel_d = clamp_day(y, m, state.sel_d)
  M._render()
end

local function move_year(delta)
  local y = state.view_y + delta
  if y < 1900 then
    y = 1900
  end
  if y > 2100 then
    y = 2100
  end
  state.view_y = y
  state.sel_y = y
  state.sel_d = clamp_day(y, state.sel_m, state.sel_d)
  M._render()
end

local function go_today()
  local y, m, d = today()
  state.view_y, state.view_m = y, m
  state.sel_y, state.sel_m, state.sel_d = y, m, d
  M._render()
end

local function edit_note()
  local y, m, d = state.sel_y, state.sel_m, state.sel_d
  local cur = notes.get(y, m, d)
  vim.ui.input({
    prompt = i18n.t("note_prompt"),
    default = cur.note or "",
  }, function(input)
    if input == nil then
      return
    end
    notes.set(y, m, d, input, nil)
    vim.notify(i18n.t("note_saved"), vim.log.levels.INFO)
    M._render()
  end)
end

local function cycle_color()
  local y, m, d = state.sel_y, state.sel_m, state.sel_d
  local cur = notes.get(y, m, d)
  local next_c = notes.next_color(cur.color)
  notes.set(y, m, d, nil, next_c)
  vim.notify(i18n.t("color_set") .. i18n.color_name(next_c), vim.log.levels.INFO)
  M._render()
end

local function clear_mark()
  local y, m, d = state.sel_y, state.sel_m, state.sel_d
  notes.clear(y, m, d)
  vim.notify(i18n.t("note_cleared"), vim.log.levels.INFO)
  M._render()
end

---构建整页文本与 day_pos
function M._render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  ensure_hl()
  local lang = i18n.get()
  local y, m = state.view_y, state.view_m
  local ty, tm, td = today()
  local months = i18n.list("months")
  local weekdays = i18n.list("weekdays")
  local clock = os.date("%Y-%m-%d %H:%M:%S")

  local title_left
  if lang == "en" then
    title_left = string.format("%s %d", months[m] or m, y)
  else
    title_left = string.format("%d年%s", y, months[m] or (m .. "月"))
  end

  local lines = {}
  local marks = {} ---@type {line:integer, col:integer, end_col:integer, hl:string}[]
  local day_pos = {}

  local line0 = pad_dw(i18n.t("title") .. "  " .. title_left, 40) .. tostring(clock)
  lines[#lines + 1] = line0
  lines[#lines + 1] = i18n.t("help")
  lines[#lines + 1] = string.rep("─", 7 * CELL_W)

  -- 星期头
  local head_parts = {}
  for i = 1, 7 do
    head_parts[#head_parts + 1] = center_dw(weekdays[i] or "", CELL_W)
  end
  local head = table.concat(head_parts)
  lines[#lines + 1] = head
  marks[#marks + 1] = { line = #lines - 1, col = 0, end_col = #head, hl = "CalendarHead" }

  local first_wd = lunar.weekday(y, m, 1) -- 0=Sun
  local dim = lunar.days_in_month(y, m)
  local day = 1
  -- 最多 6 周
  -- 注意：extmark 的 col/end_col 是**字节**偏移；中文 UTF-8 不能按显示宽度当字节用
  for week = 0, 5 do
    if day > dim then
      break
    end
    local num_parts = {}
    local lab_parts = {}
    ---@type {day:integer, num_col:integer, num_end:integer, cell_num_col:integer, cell_num_end:integer, lab_col:integer, lab_end:integer, is_fest:boolean, is_weekend:boolean, color?:string}[]
    local row_meta = {}
    local num_byte, lab_byte = 0, 0

    for w = 0, 6 do
      if (week == 0 and w < first_wd) or day > dim then
        local blank = string.rep(" ", CELL_W)
        num_parts[#num_parts + 1] = blank
        lab_parts[#lab_parts + 1] = blank
        num_byte = num_byte + #blank
        lab_byte = lab_byte + #blank
      else
        local num_trim = tostring(day)
        local num_s = center_dw(num_trim, CELL_W)
        local lab, is_fest = lunar.cell_label(y, m, day, lang)
        local note = notes.get(y, m, day)
        local has_note = note.note and note.note ~= ""
        -- 有备注：标签后加红色 ●（显示宽通常为 1）
        local NOTE_DOT = "●"
        if has_note then
          local with = lab .. NOTE_DOT
          if vim.fn.strdisplaywidth(with) <= CELL_W then
            lab = with
          else
            -- 标签过长时优先保留 ●
            lab = NOTE_DOT
            has_note = true
          end
        end
        local lab_s = center_dw(lab, CELL_W)

        local cell_num_col = num_byte
        local cell_lab_col = lab_byte
        num_parts[#num_parts + 1] = num_s
        lab_parts[#lab_parts + 1] = lab_s
        num_byte = num_byte + #num_s
        lab_byte = lab_byte + #lab_s

        -- 数字在 cell 内的字节范围（左侧 pad 为空格，1 字节/格）
        local pad_left = math.floor((CELL_W - vim.fn.strdisplaywidth(num_trim)) / 2)
        local dig_col = cell_num_col + pad_left
        local dig_end = dig_col + #num_trim

        -- ● 在 lab_s 中的字节位置（用于单独上红色）
        local note_dot_col, note_dot_end = nil, nil
        if has_note then
          local dot_off = lab_s:find(NOTE_DOT, 1, true)
          if dot_off then
            note_dot_col = cell_lab_col + dot_off - 1
            note_dot_end = note_dot_col + #NOTE_DOT
          end
        end

        row_meta[#row_meta + 1] = {
          day = day,
          num_col = dig_col,
          num_end = dig_end,
          cell_num_col = cell_num_col,
          cell_num_end = num_byte,
          lab_col = cell_lab_col,
          lab_end = lab_byte,
          note_dot_col = note_dot_col,
          note_dot_end = note_dot_end,
          is_fest = is_fest,
          is_weekend = (w == 0 or w == 6),
          color = note.color,
        }
        day = day + 1
      end
    end

    local num_line = table.concat(num_parts)
    local lab_line = table.concat(lab_parts)
    lines[#lines + 1] = num_line
    local num_lnum = #lines - 1
    lines[#lines + 1] = lab_line
    local lab_lnum = #lines - 1

    for _, meta in ipairs(row_meta) do
      day_pos[meta.day] = {
        line = num_lnum,
        col = meta.num_col,
        end_col = meta.num_end,
        lab_line = lab_lnum,
        lab_col = meta.lab_col,
        lab_end = meta.lab_end,
        cell_num_col = meta.cell_num_col,
        cell_num_end = meta.cell_num_end,
      }
      local is_sel = (y == state.sel_y and m == state.sel_m and meta.day == state.sel_d)
      local is_today = (y == ty and m == tm and meta.day == td)

      if is_sel then
        -- 选中：整格高亮（数字行 + 农历行），避免 UTF-8 切片错位
        marks[#marks + 1] = {
          line = num_lnum,
          col = meta.cell_num_col,
          end_col = meta.cell_num_end,
          hl = "CalendarSelect",
        }
        marks[#marks + 1] = {
          line = lab_lnum,
          col = meta.lab_col,
          end_col = meta.lab_end,
          hl = "CalendarSelect",
        }
        -- 备注 ● 在选中底上仍用浅红强调
        if meta.note_dot_col and meta.note_dot_end then
          marks[#marks + 1] = {
            line = lab_lnum,
            col = meta.note_dot_col,
            end_col = meta.note_dot_end,
            hl = "CalendarNoteDotSel",
          }
        end
      else
        local num_hl
        if meta.color and COLOR_HL[meta.color] then
          num_hl = COLOR_HL[meta.color]
        elseif is_today then
          num_hl = "CalendarToday"
        elseif meta.is_weekend or meta.is_fest then
          num_hl = "CalendarWeekend"
        end
        if num_hl then
          marks[#marks + 1] = {
            line = num_lnum,
            col = meta.num_col,
            end_col = meta.num_end,
            hl = num_hl,
          }
        end
        local lab_hl = meta.is_fest and "CalendarFest" or "CalendarLunar"
        marks[#marks + 1] = {
          line = lab_lnum,
          col = meta.lab_col,
          end_col = meta.lab_end,
          hl = lab_hl,
        }
        -- 备注指示点：红色 ●
        if meta.note_dot_col and meta.note_dot_end then
          marks[#marks + 1] = {
            line = lab_lnum,
            col = meta.note_dot_col,
            end_col = meta.note_dot_end,
            hl = "CalendarNoteDot",
          }
        end
      end
    end
  end

  lines[#lines + 1] = string.rep("─", 7 * CELL_W)

  -- 详情区
  local sy, sm, sd = state.sel_y, state.sel_m, state.sel_d
  local wd = lunar.weekday(sy, sm, sd)
  local wd_name = weekdays[wd + 1] or ""
  local lunar_info = lunar.solar_to_lunar(sy, sm, sd)
  local lunar_s = ""
  if lunar_info then
    lunar_s = (lang == "en") and lunar_info.full_en or lunar_info.full_zh
  end
  local fests = lunar.festivals(sy, sm, sd, lang)
  local fest_s = (#fests > 0) and table.concat(fests, " · ") or i18n.t("no_holiday")
  local n = notes.get(sy, sm, sd)
  local note_s = (n.note and n.note ~= "") and n.note or i18n.t("no_note")
  local mark_s = (n.color and n.color ~= "") and i18n.color_name(n.color) or i18n.t("no_mark")

  local is_today_sel = (sy == ty and sm == tm and sd == td)
  local sel_tag = is_today_sel and (" [" .. i18n.t("today") .. "]") or ""

  local detail1 = string.format(
    "%s: %04d-%02d-%02d (%s)%s  %s: %s",
    i18n.t("selected"),
    sy,
    sm,
    sd,
    wd_name,
    sel_tag,
    i18n.t("lunar"),
    lunar_s
  )
  local detail2 = string.format("%s: %s", i18n.t("holiday"), fest_s)
  local detail3 = string.format("%s: %s", i18n.t("note"), note_s)
  local detail4 = string.format("%s: %s", i18n.t("mark"), mark_s)

  local d_start = #lines
  lines[#lines + 1] = detail1
  lines[#lines + 1] = detail2
  lines[#lines + 1] = detail3
  lines[#lines + 1] = detail4

  for i = d_start, #lines - 1 do
    local hl = (i == d_start + 2) and "CalendarNote" or "CalendarDetail"
    marks[#marks + 1] = { line = i, col = 0, end_col = #(lines[i + 1] or ""), hl = hl }
  end

  -- title / help
  marks[#marks + 1] = { line = 0, col = 0, end_col = #lines[1], hl = "CalendarTitle" }
  marks[#marks + 1] = { line = 1, col = 0, end_col = #lines[2], hl = "CalendarHelp" }

  state.lines = lines
  state.day_pos = day_pos

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for _, mk in ipairs(marks) do
    local line = lines[mk.line + 1] or ""
    local ec = math.min(mk.end_col, #line)
    local sc = math.min(mk.col, ec)
    if ec > sc then
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, mk.line, sc, {
        end_col = ec,
        hl_group = mk.hl,
      })
    end
  end

  -- 光标移到选中日
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local pos = day_pos[state.sel_d]
    if pos and state.view_y == state.sel_y and state.view_m == state.sel_m then
      pcall(vim.api.nvim_win_set_cursor, state.win, { pos.line + 1, pos.col })
    end
    local w = 0
    for _, l in ipairs(lines) do
      w = math.max(w, vim.fn.strdisplaywidth(l))
    end
    w = math.min(math.max(w + 2, 58), vim.o.columns - 4)
    local h = math.min(#lines + 2, vim.o.lines - 4)
    pcall(vim.api.nvim_win_set_config, state.win, {
      relative = "editor",
      width = w,
      height = h,
      row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - w) / 2)),
      title = i18n.t("title"),
      title_pos = "center",
    })
  end
end

---仅刷新时钟（标题行），避免整表闪烁
local function tick_clock()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  if not state.lines or not state.lines[1] then
    return
  end
  -- 整页重绘最简单可靠（含时间）
  M._render()
end

local function bind_keys(buf)
  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", o, { desc = desc }))
  end

  map("q", close_popup, "calendar: close")
  map("<Esc>", close_popup, "calendar: close")
  map("h", function()
    move_day(-1)
  end, "calendar: prev day")
  map("l", function()
    move_day(1)
  end, "calendar: next day")
  map("<Left>", function()
    move_day(-1)
  end, "calendar: prev day")
  map("<Right>", function()
    move_day(1)
  end, "calendar: next day")
  map("j", function()
    move_day(7)
  end, "calendar: next week")
  map("k", function()
    move_day(-7)
  end, "calendar: prev week")
  map("<Down>", function()
    move_day(7)
  end, "calendar: next week")
  map("<Up>", function()
    move_day(-7)
  end, "calendar: prev week")
  map("[", function()
    move_month(-1)
  end, "calendar: prev month")
  map("]", function()
    move_month(1)
  end, "calendar: next month")
  map("<", function()
    move_month(-1)
  end, "calendar: prev month")
  map(">", function()
    move_month(1)
  end, "calendar: next month")
  map("{", function()
    move_year(-1)
  end, "calendar: prev year")
  map("}", function()
    move_year(1)
  end, "calendar: next year")
  map("t", go_today, "calendar: today")
  map("n", edit_note, "calendar: note")
  map("c", cycle_color, "calendar: color")
  map("x", clear_mark, "calendar: clear")
  map("L", function()
    local lang = i18n.toggle()
    vim.notify(lang == "en" and i18n.t("lang_to_en") or i18n.t("lang_to_zh"), vim.log.levels.INFO)
    M._render()
  end, "calendar: lang")

  -- 鼠标点击选日：按屏幕列（每格 CELL_W）+ 星期位匹配
  map("<LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    if not mouse or mouse.winid ~= state.win then
      return
    end
    local r = mouse.line
    local c = math.max(0, (mouse.column or 1) - 1)
    local w_idx = math.floor(c / CELL_W)
    if w_idx < 0 or w_idx > 6 then
      return
    end
    for day, pos in pairs(state.day_pos) do
      if r == pos.line + 1 or r == pos.lab_line + 1 then
        if lunar.weekday(state.view_y, state.view_m, day) == w_idx then
          state.sel_y, state.sel_m, state.sel_d = state.view_y, state.view_m, day
          M._render()
          return
        end
      end
    end
  end, "calendar: click day")
end

function M.open()
  M.ensure_setup()
  ensure_hl()

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    close_popup()
  end

  local y, m, d = today()
  if state.sel_y == 0 then
    state.view_y, state.view_m = y, m
    state.sel_y, state.sel_m, state.sel_d = y, m, d
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "calendar"
  pcall(vim.api.nvim_buf_set_name, buf, "calendar://month")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 60,
    height = 22,
    row = 2,
    col = 4,
    style = "minimal",
    border = config.border or "rounded",
    title = i18n.t("title"),
    title_pos = "center",
    zindex = 60,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight =
      "Normal:CalendarNormal,NormalFloat:CalendarNormal,FloatBorder:CalendarBorder,FloatTitle:CalendarTitle"
  end)

  state.buf = buf
  state.win = win
  bind_keys(buf)
  M._render()

  stop_clock()
  local ms = tonumber(config.clock_ms) or 1000
  if ms > 0 then
    state.clock_timer = vim.fn.timer_start(ms, function()
      vim.schedule(tick_clock)
    end, { ["repeat"] = -1 })
  end

  vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
    buffer = buf,
    once = true,
    callback = function()
      stop_clock()
      state.win, state.buf = nil, nil
    end,
  })
end

function M.close()
  close_popup()
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
    end, { silent = true, desc = "calendar: open month float" })
    keys_applied[#keys_applied + 1] = lhs
  end
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  local lang = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang = user.ui_lang
  end
  if lang == "zh" or lang == "en" then
    i18n.setup(lang)
  else
    i18n.setup("auto")
  end
  apply_keys()
  setup_done = true
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
end

return M
