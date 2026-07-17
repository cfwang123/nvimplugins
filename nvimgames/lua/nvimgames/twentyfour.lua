---@mod nvimgames.twentyfour 计算 24 点
local M = {}

local i18n = require("nvimgames.i18n")
local ns = vim.api.nvim_create_namespace("nvimgames_twentyfour")
local state_by_buf = {} ---@type table<integer, table>
local hl_ready = false

local default_config = {
  ---只发可解牌局
  solvable_only = true,
  ---尝试发牌上限（可解模式下）
  max_deal_tries = 200,
}

local config = vim.deepcopy(default_config)

local SUITS = {
  { sym = "♠", name = "spade", hl = "TFCardBlack" },
  { sym = "♥", name = "heart", hl = "TFCardRed" },
  { sym = "♣", name = "club", hl = "TFCardBlack" },
  { sym = "♦", name = "diamond", hl = "TFCardRed" },
}

local RANK_LABEL = {
  [1] = "A",
  [11] = "J",
  [12] = "Q",
  [13] = "K",
}

local function ensure_hl()
  if hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  vim.api.nvim_set_hl(0, "TFTitle", { fg = "#89b4fa", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "TFStatus", { fg = "#cdd6f4", bg = "#313244" })
  vim.api.nvim_set_hl(0, "TFHint", { fg = "#a6adc8", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "TFOk", { fg = "#1e1e2e", bg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "TFBad", { fg = "#1e1e2e", bg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "TFCardRed", { fg = "#f38ba8", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "TFCardBlack", { fg = "#cdd6f4", bg = "#313244", bold = true })
  vim.api.nvim_set_hl(0, "TFCardBorder", { fg = "#fab387", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "TFCardFace", { fg = "#cdd6f4", bg = "#45475a", bold = true })
  vim.api.nvim_set_hl(0, "TFExpr", { fg = "#f9e2af", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "TFScore", { fg = "#94e2d5", bg = "#1e1e2e", bold = true })
  hl_ready = true
end

local function rank_label(v)
  return RANK_LABEL[v] or tostring(v)
end

local function pad_label(s, w)
  w = w or 2
  local sw = vim.fn.strwidth(s)
  if sw >= w then
    return s
  end
  return s .. string.rep(" ", w - sw)
end

---生成一副牌中抽 4 张（不重复）
local function deal_raw()
  local deck = {}
  for s = 1, 4 do
    for r = 1, 13 do
      table.insert(deck, { rank = r, suit = s })
    end
  end
  for i = #deck, 2, -1 do
    local j = math.random(i)
    deck[i], deck[j] = deck[j], deck[i]
  end
  local cards = {}
  for i = 1, 4 do
    table.insert(cards, deck[i])
  end
  return cards
end

local function card_values(cards)
  local vals = {}
  for _, c in ipairs(cards) do
    table.insert(vals, c.rank)
  end
  return vals
end

---求解：返回是否可解，以及一个表达式（若可解）
---@param nums number[]
---@return boolean, string|nil
local function solve24(nums)
  ---@type { v: number, e: string }[]
  local function nodes_from(list)
    local t = {}
    for _, n in ipairs(list) do
      table.insert(t, { v = n + 0.0, e = tostring(n) })
    end
    return t
  end

  local found = nil

  local function dfs(nodes)
    if found then
      return true
    end
    if #nodes == 1 then
      if math.abs(nodes[1].v - 24) < 1e-6 then
        found = nodes[1].e
        return true
      end
      return false
    end
    for i = 1, #nodes do
      for j = 1, #nodes do
        if i ~= j then
          local a, b = nodes[i], nodes[j]
          local rest = {}
          for k = 1, #nodes do
            if k ~= i and k ~= j then
              table.insert(rest, nodes[k])
            end
          end
          local cands = {
            { v = a.v + b.v, e = "(" .. a.e .. "+" .. b.e .. ")" },
            { v = a.v - b.v, e = "(" .. a.e .. "-" .. b.e .. ")" },
            { v = a.v * b.v, e = "(" .. a.e .. "*" .. b.e .. ")" },
          }
          if math.abs(b.v) > 1e-9 then
            table.insert(cands, { v = a.v / b.v, e = "(" .. a.e .. "/" .. b.e .. ")" })
          end
          -- 减/除不交换已覆盖 a-b、a/b；再补 b-a、b/a 以穷尽
          table.insert(cands, { v = b.v - a.v, e = "(" .. b.e .. "-" .. a.e .. ")" })
          if math.abs(a.v) > 1e-9 then
            table.insert(cands, { v = b.v / a.v, e = "(" .. b.e .. "/" .. a.e .. ")" })
          end
          for _, c in ipairs(cands) do
            local nextn = {}
            for _, r in ipairs(rest) do
              table.insert(nextn, r)
            end
            table.insert(nextn, c)
            if dfs(nextn) then
              return true
            end
          end
        end
      end
    end
    return false
  end

  dfs(nodes_from(nums))
  return found ~= nil, found
end

local function deal_cards()
  local tries = config.max_deal_tries or 200
  for _ = 1, tries do
    local cards = deal_raw()
    if not config.solvable_only then
      return cards, nil
    end
    local ok, expr = solve24(card_values(cards))
    if ok then
      return cards, expr
    end
  end
  -- 兜底：固定可解局 8,3,3,3 → (8/(3-8/3))=24
  local fallback = {
    { rank = 8, suit = 1 },
    { rank = 3, suit = 2 },
    { rank = 3, suit = 3 },
    { rank = 3, suit = 4 },
  }
  local _, expr = solve24(card_values(fallback))
  return fallback, expr
end

---从表达式提取数字（支持 10）
---@param expr string
---@return number[]|nil, string|nil
local function extract_numbers(expr)
  local nums = {}
  local i = 1
  local n = #expr
  while i <= n do
    local ch = expr:sub(i, i)
    if ch:match("%d") then
      local j = i
      while j <= n and expr:sub(j, j):match("%d") do
        j = j + 1
      end
      -- 不允许小数点后接（本游戏仅整数点）
      if j <= n and expr:sub(j, j) == "." then
        return nil, i18n.t("tf_no_decimal")
      end
      local num = tonumber(expr:sub(i, j - 1))
      if not num then
        return nil, i18n.t("tf_parse_fail")
      end
      table.insert(nums, num)
      i = j
    else
      i = i + 1
    end
  end
  return nums, nil
end

---@param expr string
---@return boolean, string|nil
local function validate_charset(expr)
  -- 允许数字、+ - * / ( ) 空格、×÷（替换）
  local s = expr
  s = s:gsub("×", "*"):gsub("÷", "/"):gsub("x", "*"):gsub("X", "*")
  if s:find("[^%d%s%+%-%*/%(%)]") then
    return false, i18n.t("tf_only_ops")
  end
  return true, s
end

---@param expr string
---@return number|nil, string|nil
local function safe_eval(expr)
  local okc, cleaned = validate_charset(expr)
  if not okc then
    return nil, cleaned
  end
  expr = cleaned
  if expr:match("^%s*$") then
    return nil, i18n.t("tf_expr_empty")
  end
  -- 禁止连续运算符等交给 load；限制长度
  if #expr > 80 then
    return nil, i18n.t("tf_expr_long")
  end
  local chunk, err = load("return (" .. expr .. ")")
  if not chunk then
    return nil, i18n.tf("tf_syntax", tostring(err))
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, i18n.tf("tf_calc_err", tostring(result))
  end
  if type(result) ~= "number" then
    return nil, i18n.t("tf_not_number")
  end
  if result ~= result or result == math.huge or result == -math.huge then
    return nil, i18n.t("tf_invalid")
  end
  return result, nil
end

---@param cards table[]
---@param expr string
---@return boolean, string, number|nil  ok, message, value
local function judge(cards, expr)
  local okc, cleaned = validate_charset(expr)
  if not okc then
    return false, cleaned, nil
  end
  expr = cleaned

  local used, eerr = extract_numbers(expr)
  if not used then
    return false, eerr or i18n.t("tf_parse_fail"), nil
  end

  local need = card_values(cards)
  if #used ~= 4 then
    return false, i18n.tf("tf_need_4", #used), nil
  end

  local a, b = {}, {}
  for i = 1, 4 do
    a[i] = need[i]
    b[i] = used[i]
  end
  table.sort(a)
  table.sort(b)
  for i = 1, 4 do
    if a[i] ~= b[i] then
      local need_s = table.concat(vim.tbl_map(tostring, need), ", ")
      local used_s = table.concat(vim.tbl_map(tostring, used), ", ")
      return false, i18n.tf("tf_use_cards", need_s, used_s), nil
    end
  end

  local val, verr = safe_eval(expr)
  if not val then
    return false, verr or i18n.t("tf_eval_fail"), nil
  end
  if math.abs(val - 24) < 1e-6 then
    return true, i18n.tf("tf_correct", val), val
  end
  return false, i18n.tf("tf_wrong_val", val), val
end

---单张牌 5 行 × 宽约 7
local function card_lines(card)
  local lab = pad_label(rank_label(card.rank), 2)
  local suit = SUITS[card.suit].sym
  local top = "┌─────┐"
  local r1 = "│" .. lab .. "   │"
  local r2 = "│  " .. suit .. "  │"
  local r3 = "│   " .. lab .. "│"
  local bot = "└─────┘"
  if vim.fn.strwidth(lab) == 1 then
    r3 = "│    " .. lab .. "│"
  end
  return { top, r1, r2, r3, bot }, SUITS[card.suit].hl
end

---公式行前缀（仅此前缀之后可编辑；随语言切换）
local function expr_prefix()
  return i18n.t("tf_expr_prefix")
end

---剥掉公式前缀（兼容中英文）
local function strip_expr_prefix(line)
  local p = expr_prefix()
  if line:sub(1, #p) == p then
    return line:sub(#p + 1)
  end
  local stripped = line:gsub("^%s*公式[>:：]%s*", ""):gsub("^%s*expr[>:：]%s*", "")
  return vim.trim(stripped)
end

local function apply_win(win)
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].list = false
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].statuscolumn = ""
  end)
end

local function disable_selection(buf)
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv", "gh", "gH" }) do
    pcall(vim.keymap.set, { "n", "v", "x", "s" }, lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
    })
  end
end

---@param st table
---@param buf integer
---@return string
local function read_expr(st, buf)
  if not st.expr_row then
    return st.last_expr or ""
  end
  local line = vim.api.nvim_buf_get_lines(buf, st.expr_row, st.expr_row + 1, false)[1] or ""
  local p = expr_prefix()
  if line:sub(1, #p) == p then
    return vim.trim(line:sub(#p + 1))
  end
  return vim.trim(strip_expr_prefix(line))
end

---光标移到公式行末尾，可选进入插入模式
local function focus_expr(st, buf, start_insert)
  if not st.expr_row or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    win = 0
  end
  local p = expr_prefix()
  local line = vim.api.nvim_buf_get_lines(buf, st.expr_row, st.expr_row + 1, false)[1] or p
  if line:sub(1, #p) ~= p then
    line = p .. (st.last_expr or "")
    st.rendering = true
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, st.expr_row, st.expr_row + 1, false, { line })
    st.rendering = false
  end
  local col = #line -- 0-based 插在末尾时用 #line
  pcall(vim.api.nvim_win_set_cursor, win, { st.expr_row + 1, col })
  if start_insert and not st.solved then
    vim.cmd("startinsert!")
  end
end

local function render(buf)
  local st = state_by_buf[buf]
  if not st then
    return
  end
  ensure_hl()
  st.rendering = true

  local prefix = expr_prefix()

  -- 渲染前从 buffer 同步公式（开新局 / 主动清空时跳过，避免把旧输入写回来）
  if not st.skip_buf_expr_sync and st.expr_row and vim.api.nvim_buf_is_valid(buf) then
    local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if cur_lines[st.expr_row + 1] then
      local line = cur_lines[st.expr_row + 1]
      if line:sub(1, #prefix) == prefix then
        st.last_expr = line:sub(#prefix + 1)
      else
        st.last_expr = strip_expr_prefix(line)
      end
    end
  end
  st.skip_buf_expr_sync = false

  local title = i18n.tf("tf_title", st.score or 0, st.rounds or 0)
  local help = i18n.t("tf_help")

  local lines = { title, "" }
  ---@type {row:integer, col:integer, end_col:integer, hl:string}[]
  local marks = {}

  table.insert(marks, { row = 0, col = 0, end_col = #title, hl = "TFTitle" })

  local card_row_data = { {}, {}, {}, {}, {} } ---@type string[][]
  local card_hls = {} ---@type string[]
  for ci, card in ipairs(st.cards) do
    local clines, hl = card_lines(card)
    card_hls[ci] = hl
    for ri = 1, 5 do
      table.insert(card_row_data[ri], clines[ri])
    end
  end

  for ri = 1, 5 do
    local gap = "  "
    local parts = {}
    local byte_col = 0
    local line_marks = {}
    for ci = 1, 4 do
      if ci > 1 then
        table.insert(parts, gap)
        byte_col = byte_col + #gap
      end
      local piece = card_row_data[ri][ci]
      local blen = #piece
      local hl = card_hls[ci]
      table.insert(line_marks, { byte_col, byte_col + blen, hl })
      table.insert(parts, piece)
      byte_col = byte_col + blen
    end
    local line = table.concat(parts)
    table.insert(lines, "  " .. line)
    local row0 = #lines - 1
    local pre = 2
    for _, m in ipairs(line_marks) do
      table.insert(marks, {
        row = row0,
        col = pre + m[1],
        end_col = pre + m[2],
        hl = m[3],
      })
    end
  end

  table.insert(lines, "")
  local vals = card_values(st.cards)
  local val_line = i18n.tf(
    "tf_points",
    table.concat(vim.tbl_map(function(v)
      return rank_label(v) .. "=" .. v
    end, vals), "  ")
  )
  table.insert(lines, val_line)
  table.insert(marks, { row = #lines - 1, col = 0, end_col = #val_line, hl = "TFHint" })

  table.insert(lines, "")
  -- 可编辑公式行
  st.expr_row = #lines -- 0-based
  local expr_line = prefix .. (st.last_expr or "")
  table.insert(lines, expr_line)
  table.insert(marks, {
    row = st.expr_row,
    col = 0,
    end_col = #prefix,
    hl = "TFExpr",
  })
  if #(st.last_expr or "") > 0 then
    table.insert(marks, {
      row = st.expr_row,
      col = #prefix,
      end_col = #expr_line,
      hl = "TFExpr",
    })
  end

  local msg = st.message or i18n.t("tf_prompt_default")
  local msg_hl = "TFStatus"
  if st.message_kind == "ok" then
    msg_hl = "TFOk"
  elseif st.message_kind == "bad" then
    msg_hl = "TFBad"
  end
  table.insert(lines, msg)
  table.insert(marks, { row = #lines - 1, col = 0, end_col = #msg, hl = msg_hl })

  if st.show_answer and st.answer then
    local ans = i18n.tf("tf_answer", st.answer)
    table.insert(lines, ans)
    table.insert(marks, { row = #lines - 1, col = 0, end_col = #ans, hl = "TFHint" })
  end

  table.insert(lines, "")
  table.insert(lines, help)
  table.insert(marks, { row = #lines - 1, col = 0, end_col = #help, hl = "TFStatus" })
  local lang_line = " " .. i18n.t("tf_btn_lang") .. " "
  table.insert(lines, lang_line)
  -- 整行高亮，便于识别可点
  table.insert(marks, {
    row = #lines - 1,
    col = 0,
    end_col = #lang_line,
    hl = "TFOk",
  })
  st.lang_row = #lines -- 1-based buffer line for getmousepos().line

  -- 锁定行快照（公式行可改，对比时跳过 st.expr_row）
  st.locked_lines = vim.list_extend({}, lines)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m.row, m.col, {
      end_row = m.row,
      end_col = m.end_col,
      hl_group = m.hl,
      hl_mode = "replace",
      priority = 200,
      strict = false,
    })
  end

  vim.bo[buf].modified = false
  st.rendering = false

  -- 光标落到公式行
  if vim.api.nvim_get_current_buf() == buf then
    focus_expr(st, buf, false)
  end
end

---其它行被改坏时恢复；同步公式内容
local function protect_buffer(buf)
  local st = state_by_buf[buf]
  if not st or st.rendering or not st.locked_lines or not st.expr_row then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local need_rerender = false

  if #lines ~= #st.locked_lines then
    if lines[st.expr_row + 1] then
      local line = lines[st.expr_row + 1]
      local p = expr_prefix()
      if line:sub(1, #p) == p then
        st.last_expr = line:sub(#p + 1)
      else
        st.last_expr = vim.trim(strip_expr_prefix(line))
      end
    end
    need_rerender = true
  else
    for i = 1, #st.locked_lines do
      if i - 1 ~= st.expr_row and lines[i] ~= st.locked_lines[i] then
        need_rerender = true
        break
      end
    end
    -- 同步 / 修复公式行前缀
    local p = expr_prefix()
    local line = lines[st.expr_row + 1] or ""
    if line:sub(1, #p) ~= p then
      st.last_expr = vim.trim(strip_expr_prefix(line))
      st.rendering = true
      vim.api.nvim_buf_set_lines(buf, st.expr_row, st.expr_row + 1, false, {
        p .. (st.last_expr or ""),
      })
      st.rendering = false
      focus_expr(st, buf, false)
    else
      st.last_expr = line:sub(#p + 1)
    end
  end

  if need_rerender then
    render(buf)
  end
end

local function clear_input(st, buf, msg)
  st.last_expr = ""
  st.await_clear = false
  st.err_expr = nil
  st.skip_buf_expr_sync = true
  st.message = msg or i18n.t("tf_prompt")
  st.message_kind = nil
  render(buf)
  focus_expr(st, buf, true)
end

local function new_round(st, keep_score)
  local cards, answer = deal_cards()
  st.cards = cards
  st.answer = answer
  st.show_answer = false
  st.last_expr = ""
  st.await_clear = false
  st.err_expr = nil
  st.skip_buf_expr_sync = true -- 强制清空公式行，勿从旧 buffer 同步
  st.message = i18n.t("tf_prompt")
  st.message_kind = nil
  st.solved = false
  st.score = st.score or 0
  st.rounds = (st.rounds or 0) + 1
  if not keep_score then
    -- keep_score：保留得分；局数始终 +1
  end
end

local function submit_expr(st, buf)
  -- 先退出插入模式
  if vim.fn.mode():match("[iR]") then
    vim.cmd("stopinsert")
  end
  if st.solved then
    st.message = i18n.t("tf_already")
    st.message_kind = "ok"
    st.await_clear = false
    render(buf)
    return
  end
  local input = read_expr(st, buf)
  st.last_expr = input
  if input == "" then
    st.message = i18n.t("tf_empty_input")
    st.message_kind = "bad"
    st.await_clear = false
    render(buf)
    focus_expr(st, buf, true)
    return
  end
  local ok, msg = judge(st.cards, input)
  if ok then
    st.solved = true
    st.score = (st.score or 0) + 1
    st.message = i18n.tf("tf_ok_next", msg)
    st.message_kind = "ok"
    st.await_clear = false
    st.err_expr = nil
  else
    -- 错误提示保留公式；Space 清空
    st.message = i18n.tf("tf_bad_space", msg)
    st.message_kind = "bad"
    st.await_clear = true
    st.err_expr = input
  end
  render(buf)
  if not st.solved then
    -- 出错后回到普通模式，方便按 Space 清空；再 i 可继续改
    focus_expr(st, buf, false)
  end
end

function M.open(opts)
  opts = opts or {}
  ensure_hl()
  math.randomseed(os.time() % 100000 + (vim.uv.hrtime() % 100000))

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, "nvimgames://twentyfour")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "nvimgames_twentyfour"
  vim.bo[buf].modifiable = true
  vim.api.nvim_win_set_buf(win, buf)
  apply_win(win)
  disable_selection(buf)

  local st = {
    score = 0,
    rounds = 0,
    last_expr = "",
  }
  state_by_buf[buf] = st
  new_round(st, false)

  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, function()
      local s = state_by_buf[buf]
      if s then
        fn(s)
      end
    end, { buffer = buf, silent = true, nowait = true, desc = "twentyfour: " .. (desc or "") })
  end

  -- 进入编辑：跳到公式行
  local function go_edit(s)
    if s.solved then
      s.message = i18n.t("tf_already")
      s.message_kind = "ok"
      render(buf)
      return
    end
    focus_expr(s, buf, true)
  end

  map("n", "i", go_edit, "edit")
  map("n", "a", go_edit, "edit")
  map("n", "A", go_edit, "edit")
  map("n", "I", go_edit, "edit")
  map("n", "o", go_edit, "edit")
  map("n", "O", go_edit, "edit")

  -- Enter 判定（普通 / 插入）
  map("n", "<CR>", function(s)
    submit_expr(s, buf)
  end, "submit")
  map("i", "<CR>", function(s)
    submit_expr(s, buf)
  end, "submit")

  -- 判定失败后：Space 清空输入（插入模式下也拦截）
  map("n", "<Space>", function(s)
    if s.await_clear then
      clear_input(s, buf, i18n.t("tf_cleared"))
    end
  end, "clear on error")
  vim.keymap.set("i", "<Space>", function()
    local s = state_by_buf[buf]
    if s and s.await_clear then
      vim.schedule(function()
        if state_by_buf[buf] then
          clear_input(s, buf, i18n.t("tf_cleared"))
        end
      end)
      return ""
    end
    return " "
  end, { buffer = buf, expr = true, silent = true, desc = "twentyfour: space clear or type" })

  map("n", "r", function(s)
    if vim.fn.mode():match("[iR]") then
      vim.cmd("stopinsert")
    end
    new_round(s, true)
    render(buf)
    focus_expr(s, buf, true)
  end, "redeal")

  map("n", "h", function(s)
    if not s.answer then
      local ok, expr = solve24(card_values(s.cards))
      s.answer = ok and expr or nil
    end
    if s.answer then
      s.show_answer = not s.show_answer
      s.message = s.show_answer and i18n.t("tf_show_ans") or i18n.t("tf_hide_ans")
      s.message_kind = nil
    else
      s.message = i18n.t("tf_no_ans")
      s.message_kind = "bad"
    end
    render(buf)
  end, "hint")

  map("n", "q", function()
    if vim.fn.mode():match("[iR]") then
      vim.cmd("stopinsert")
    end
    state_by_buf[buf] = nil
    pcall(vim.cmd, "bdelete!")
  end, "quit")

  local function do_toggle_lang(s)
    if vim.fn.mode():match("[iR]") then
      pcall(vim.cmd, "stopinsert")
    end
    i18n.toggle()
    s.message = i18n.t("lang_switched")
    s.message_kind = nil
    render(buf)
  end

  -- 中英文：仅 u
  map("n", "u", do_toggle_lang, "lang")

  map("n", "?", function()
    vim.notify(i18n.t("tf_help_box"), vim.log.levels.INFO)
  end, "help")

  if vim.o.mouse == "" then
    vim.o.mouse = "a"
  end

  ---点击底栏「中文/EN」切换语言（n/i 松开时判定，不抢其它行的鼠标）
  local function on_lang_release()
    local s = state_by_buf[buf]
    if not s or not s.lang_row then
      return
    end
    local mp = vim.fn.getmousepos()
    local w = vim.fn.bufwinid(buf)
    if w == -1 or mp.winid ~= w then
      return
    end
    if mp.line == s.lang_row then
      do_toggle_lang(s)
    end
  end
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<LeftRelease>", on_lang_release, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "twentyfour: click lang button",
    })
    vim.keymap.set(mode, "<2-LeftMouse>", on_lang_release, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "twentyfour: double-click lang",
    })
  end

  -- 插入时若光标跑到非公式行，拉回
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    callback = function()
      local s = state_by_buf[buf]
      if not s or s.rendering or not s.expr_row then
        return
      end
      local pos = vim.api.nvim_win_get_cursor(0)
      local row, col = pos[1] - 1, pos[2]
      if row ~= s.expr_row then
        -- 普通模式允许浏览；插入模式强制回公式行
        if vim.fn.mode():match("[iR]") then
          focus_expr(s, buf, true)
        end
        return
      end
      -- 不允许删到前缀里：光标不得小于前缀长度
      local p = expr_prefix()
      if col < #p then
        pcall(vim.api.nvim_win_set_cursor, 0, { s.expr_row + 1, #p })
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      protect_buffer(buf)
      local s = state_by_buf[buf]
      -- 出错后若用户已改动公式，取消「Space 清空」拦截，恢复正常空格
      if s and s.await_clear and not s.rendering then
        local cur = read_expr(s, buf)
        if cur ~= (s.err_expr or "") then
          s.await_clear = false
          s.err_expr = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      state_by_buf[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("TFHl_" .. buf, { clear = true }),
    callback = function()
      hl_ready = false
      ensure_hl()
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end,
  })

  render(buf)
  -- 开局直接进入输入
  vim.schedule(function()
    if state_by_buf[buf] then
      focus_expr(state_by_buf[buf], buf, true)
    end
  end)
  return buf
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", default_config, user or {})
  hl_ready = false
end

function M.config()
  return config
end

return M
