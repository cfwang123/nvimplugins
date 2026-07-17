---@mod nvimgames.tetris 俄罗斯方块（特殊★ / 人机对战垃圾攻击）
local M = {}

local i18n = require("nvimgames.i18n")
local ns = vim.api.nvim_create_namespace("nvimgames_tetris")
local state_by_buf = {} ---@type table<integer, table>
local hl_ready = false
local render ---@type fun(buf: integer)

local COLS = 10
local ROWS = 20
local CELL_W = 2

local default_config = {
  ---特殊块：累计多少分出现 1 个（完成后重新从 0 计）
  special_score = 1000,
  tick_ms = 600,
  min_tick_ms = 120,
  tick_step = 40,
  lines_per_level = 10,
  ---AI 思考/动作间隔 ms
  ai_tick_ms = 180,
  ---AI 下落相对玩家更慢的倍率（>1 更慢）
  ai_tick_scale = 1.15,
  ---特殊块填格动画间隔 ms（较快）
  special_fill_ms = 35,
}

local config = vim.deepcopy(default_config)

local SHAPES = {
  I = {
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } },
    { { 2, 0 }, { 2, 1 }, { 2, 2 }, { 2, 3 } },
    { { 0, 2 }, { 1, 2 }, { 2, 2 }, { 3, 2 } },
    { { 1, 0 }, { 1, 1 }, { 1, 2 }, { 1, 3 } },
  },
  O = {
    { { 1, 0 }, { 2, 0 }, { 1, 1 }, { 2, 1 } },
  },
  T = {
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, 2 } },
  },
  S = {
    { { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } },
    { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 2, 2 } },
    { { 1, 1 }, { 2, 1 }, { 0, 2 }, { 1, 2 } },
    { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 1, 2 } },
  },
  Z = {
    { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } },
    { { 2, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 1, 2 }, { 2, 2 } },
    { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 0, 2 } },
  },
  J = {
    { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 2, 0 }, { 1, 1 }, { 1, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 2, 2 } },
    { { 1, 0 }, { 1, 1 }, { 0, 2 }, { 1, 2 } },
  },
  L = {
    { { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    { { 1, 0 }, { 1, 1 }, { 1, 2 }, { 2, 2 } },
    { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 0, 2 } },
    { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 1, 2 } },
  },
  -- 特殊 1 格：4 个旋转态仅表示朝向（形状相同）
  -- rot 0↓ 1← 2↑ 3→
  X = {
    { { 0, 0 } },
    { { 0, 0 } },
    { { 0, 0 } },
    { { 0, 0 } },
  },
}

-- 画面箭头：明确表示当前朝向（占 2 显示列）
local SPECIAL_ARROWS = { [0] = "↓ ", [1] = "← ", [2] = "↑ ", [3] = "→ " }
local function special_dir_name(rot)
  local keys = {
    [0] = "tetris_dir_down",
    [1] = "tetris_dir_left",
    [2] = "tetris_dir_up",
    [3] = "tetris_dir_right",
  }
  return i18n.t(keys[rot] or "tetris_dir_down")
end

local function side_label(side)
  if side.is_ai then
    return i18n.t("tetris_label_ai")
  end
  return i18n.t("tetris_label_you")
end

local BAG_KINDS = { "I", "O", "T", "S", "Z", "J", "L" }

local KIND_HL = {
  I = "TetrisI",
  O = "TetrisO",
  T = "TetrisT",
  S = "TetrisS",
  Z = "TetrisZ",
  J = "TetrisJ",
  L = "TetrisL",
  X = "TetrisSpecial",
  F = "TetrisSpecial", -- 特殊填充格
  G = "TetrisGarbage",
}

---一次消除的「行数」越多，垃圾惩罚越重（支持 >4，特殊块可造成大量清除）
--- 2→1, 3→3, 4→6, 5→10, 6→15, 8→28, 10→45（三角数）
local function garbage_for_lines(n)
  n = math.floor(tonumber(n) or 0)
  if n < 2 then
    return 0
  end
  return math.floor(n * (n - 1) / 2)
end

---消行得分：行数越多越高（不封顶 4）
local function score_for_lines(n, level)
  n = math.floor(tonumber(n) or 0)
  level = level or 1
  if n <= 0 then
    return 0
  end
  -- 1→100, 2→300, 3→500, 4→800, 之后每多 1 行 +500
  local table_score = { 100, 300, 500, 800 }
  local base
  if n <= 4 then
    base = table_score[n]
  else
    base = 800 + (n - 4) * 500
  end
  return base * level
end

local function ensure_hl()
  if hl_ready then
    return
  end
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  vim.api.nvim_set_hl(0, "TetrisTitle", { fg = "#4fc3f7", bg = "#0a1628", bold = true })
  vim.api.nvim_set_hl(0, "TetrisStatus", { fg = "#e0f2ff", bg = "#0d2137" })
  vim.api.nvim_set_hl(0, "TetrisHint", { fg = "#80deea", bg = "#0a1628" })
  vim.api.nvim_set_hl(0, "TetrisEmpty", { fg = "#1565c0", bg = "#0d2137" })
  vim.api.nvim_set_hl(0, "TetrisEmptyAlt", { fg = "#1e88e5", bg = "#102a43" })
  vim.api.nvim_set_hl(0, "TetrisBorder", { fg = "#4fc3f7", bg = "#061018", bold = true })
  vim.api.nvim_set_hl(0, "TetrisBorderAi", { fg = "#ffab91", bg = "#061018", bold = true })
  vim.api.nvim_set_hl(0, "TetrisGameOver", { fg = "#ffffff", bg = "#ff5252", bold = true })
  vim.api.nvim_set_hl(0, "TetrisPaused", { fg = "#333300", bg = "#ffff00", bold = true })
  vim.api.nvim_set_hl(0, "TetrisWin", { fg = "#003300", bg = "#69f0ae", bold = true })
  -- 实心方块：明亮高饱和（fg≈bg 使块面发亮）
  vim.api.nvim_set_hl(0, "TetrisI", { fg = "#84ffff", bg = "#18ffff", bold = true })
  vim.api.nvim_set_hl(0, "TetrisO", { fg = "#ffff8d", bg = "#ffea00", bold = true })
  vim.api.nvim_set_hl(0, "TetrisT", { fg = "#ea80fc", bg = "#e040fb", bold = true })
  vim.api.nvim_set_hl(0, "TetrisS", { fg = "#b9f6ca", bg = "#69f0ae", bold = true })
  vim.api.nvim_set_hl(0, "TetrisZ", { fg = "#ff8a80", bg = "#ff5252", bold = true })
  vim.api.nvim_set_hl(0, "TetrisJ", { fg = "#82b1ff", bg = "#448aff", bold = true })
  vim.api.nvim_set_hl(0, "TetrisL", { fg = "#ffd180", bg = "#ffab40", bold = true })
  vim.api.nvim_set_hl(0, "TetrisSpecial", { fg = "#ff80ab", bg = "#ff4081", bold = true })
  vim.api.nvim_set_hl(0, "TetrisGarbage", { fg = "#ffcc80", bg = "#ff9800", bold = true })
  -- 影子落点：同色系暗淡实心块（比实体暗很多，不抢眼）
  vim.api.nvim_set_hl(0, "TetrisGhostI", { fg = "#1a3a40", bg = "#1a4a52" })
  vim.api.nvim_set_hl(0, "TetrisGhostO", { fg = "#3a3a18", bg = "#4a4a1e" })
  vim.api.nvim_set_hl(0, "TetrisGhostT", { fg = "#2a1a35", bg = "#3a2448" })
  vim.api.nvim_set_hl(0, "TetrisGhostS", { fg = "#1a3320", bg = "#244a2e" })
  vim.api.nvim_set_hl(0, "TetrisGhostZ", { fg = "#3a1a1a", bg = "#4a2424" })
  vim.api.nvim_set_hl(0, "TetrisGhostJ", { fg = "#1a2a40", bg = "#243a55" })
  vim.api.nvim_set_hl(0, "TetrisGhostL", { fg = "#3a2a14", bg = "#4a3820" })
  vim.api.nvim_set_hl(0, "TetrisGhostX", { fg = "#3a1a28", bg = "#4a2435" })
  vim.api.nvim_set_hl(0, "TetrisGhost", { fg = "#1a3035", bg = "#1e3840" })
  hl_ready = true
end

local function board_idx(x, y)
  return y * COLS + x + 1
end

local function empty_board()
  local b = {}
  for i = 1, COLS * ROWS do
    b[i] = false
  end
  return b
end

local function copy_board(b)
  local n = {}
  for i = 1, COLS * ROWS do
    n[i] = b[i]
  end
  return n
end

local function piece_cells(piece)
  local rot = SHAPES[piece.kind]
  local shape = rot[(piece.rot % #rot) + 1]
  local cells = {}
  for _, c in ipairs(shape) do
    table.insert(cells, { x = piece.x + c[1], y = piece.y + c[2] })
  end
  return cells
end

local function in_bounds(x, y)
  return x >= 0 and x < COLS and y >= 0 and y < ROWS
end

local function collides_board(board, piece)
  for _, c in ipairs(piece_cells(piece)) do
    if c.x < 0 or c.x >= COLS or c.y >= ROWS then
      return true
    end
    if c.y >= 0 and board[board_idx(c.x, c.y)] then
      return true
    end
  end
  return false
end

local function collides(side, piece)
  return collides_board(side.board, piece)
end

local function try_move(side, dx, dy, drot)
  if not side.piece or side.game_over then
    return false
  end
  local nrot = #SHAPES[side.piece.kind]
  local p = {
    kind = side.piece.kind,
    x = side.piece.x + (dx or 0),
    y = side.piece.y + (dy or 0),
    rot = (side.piece.rot + (drot or 0)) % nrot,
  }
  -- Lua 负模
  if p.rot < 0 then
    p.rot = p.rot + nrot
  end
  if collides(side, p) then
    return false
  end
  side.piece = p
  return true
end

local function ghost_y(side)
  if not side.piece then
    return nil
  end
  local p = {
    kind = side.piece.kind,
    x = side.piece.x,
    y = side.piece.y,
    rot = side.piece.rot,
  }
  while true do
    local n = { kind = p.kind, x = p.x, y = p.y + 1, rot = p.rot }
    if collides(side, n) then
      return p.y
    end
    p = n
  end
end

---生成一袋 7 种方块（打乱）
local function make_bag_batch()
  local bag = {}
  for _, k in ipairs(BAG_KINDS) do
    table.insert(bag, k)
  end
  for i = #bag, 2, -1 do
    local j = math.random(i)
    bag[i], bag[j] = bag[j], bag[i]
  end
  return bag
end

---对战：共享序列按索引取，双方顺序一致（各用各的进度）
local function ensure_shared_seq(sess, need_index)
  sess.shared_seq = sess.shared_seq or {}
  while #sess.shared_seq < need_index do
    local batch = make_bag_batch()
    for _, k in ipairs(batch) do
      table.insert(sess.shared_seq, k)
    end
  end
end

---取下一个种类；特殊块优先且不消耗共享序列
local function next_kind(sess, side)
  if side.special_ready then
    side.special_ready = false
    return "X"
  end
  if sess.versus then
    side.seq_i = (side.seq_i or 0) + 1
    ensure_shared_seq(sess, side.seq_i)
    return sess.shared_seq[side.seq_i]
  end
  if not side.bag or #side.bag == 0 then
    side.bag = make_bag_batch()
  end
  return table.remove(side.bag, 1)
end

---预览下一个（不消耗）
local function peek_next_kind(sess, side)
  if side.special_ready then
    return "X"
  end
  if sess.versus then
    local i = (side.seq_i or 0) + 1
    ensure_shared_seq(sess, i)
    return sess.shared_seq[i]
  end
  if not side.bag or #side.bag == 0 then
    side.bag = make_bag_batch()
  end
  return side.bag[1]
end

local function spawn_piece(sess, side)
  local kind = next_kind(sess, side)
  local piece = {
    kind = kind,
    x = kind == "X" and 4 or 3,
    y = kind == "I" and -1 or 0,
    rot = 0,
  }
  if collides(side, piece) then
    piece.y = 0
    if collides(side, piece) then
      side.piece = piece
      side.game_over = true
      side.ai_plan = nil
      return false
    end
  end
  side.piece = piece
  side.ai_plan = nil
  return true
end

local function clear_full_lines_board(board)
  local write_y = ROWS - 1
  local cleared = 0
  local newb = empty_board()
  for y = ROWS - 1, 0, -1 do
    local full = true
    for x = 0, COLS - 1 do
      if not board[board_idx(x, y)] then
        full = false
        break
      end
    end
    if full then
      cleared = cleared + 1
    else
      for x = 0, COLS - 1 do
        newb[board_idx(x, write_y)] = board[board_idx(x, y)]
      end
      write_y = write_y - 1
    end
  end
  return newb, cleared
end

---特殊块填充：仅沿箭头「前方」填空格（绝不向上填）
--- rot: 0↓ 只向下整列前方 / 1← 只向左整行前方 / 2↑ 不填充 / 3→ 只向右
local function collect_special_fill_cells(board, x, y, rot)
  rot = (tonumber(rot) or 0) % 4
  if rot < 0 then
    rot = rot + 4
  end
  local cells = {}
  -- ↑：禁止填充
  if rot == 2 then
    return cells
  end
  local function try_add(cx, cy)
    if cx >= 0 and cx < COLS and cy >= 0 and cy < ROWS and not board[board_idx(cx, cy)] then
      table.insert(cells, { x = cx, y = cy })
    end
  end
  if rot == 0 then
    -- ↓：只填落点下方（同一列 cy > y），不填上方
    for cy = y + 1, ROWS - 1 do
      try_add(x, cy)
    end
  elseif rot == 1 then
    -- ←：只填左侧
    for cx = x - 1, 0, -1 do
      try_add(cx, y)
    end
  elseif rot == 3 then
    -- →：只填右侧
    for cx = x + 1, COLS - 1 do
      try_add(cx, y)
    end
  end
  return cells
end

---特殊计分是否冻结（已就绪 / 特殊块下落中 / 填充动画中）
local function special_meter_frozen(side)
  if side.special_ready or side.special_lock or side.animating then
    return true
  end
  if side.piece and side.piece.kind == "X" then
    return true
  end
  return false
end

local function add_score(side, points)
  if points <= 0 then
    return
  end
  side.score = (side.score or 0) + points
  -- 特殊块进度：独立累计；就绪或特殊过程中不加，完成后清零再重新计
  if special_meter_frozen(side) then
    return
  end
  local interval = config.special_score or 1000
  if interval <= 0 then
    return
  end
  side.special_progress = (side.special_progress or 0) + points
  if side.special_progress >= interval then
    side.special_ready = true
    -- 挂起期间进度停在阈值，不连续刷
    side.special_progress = interval
  end
end

---特殊块下落+消除全部完成后：重新从 0 计分
local function reset_special_meter(side)
  side.special_progress = 0
  side.special_lock = false
  -- special_ready 在出块时已清
end

---从底部顶入垃圾行：整行实心随机方，留 1 个随机空洞
local function inject_garbage(side, rows)
  if rows <= 0 then
    return
  end
  rows = math.min(rows, ROWS - 1)
  -- 上移
  for y = 0, ROWS - 1 - rows do
    for x = 0, COLS - 1 do
      side.board[board_idx(x, y)] = side.board[board_idx(x, y + rows)]
    end
  end
  for i = 0, rows - 1 do
    local y = ROWS - rows + i
    local hole = math.random(0, COLS - 1)
    -- 再随机挖 0~1 个额外洞，增加「随机方块」感
    local hole2 = math.random() < 0.35 and math.random(0, COLS - 1) or hole
    for x = 0, COLS - 1 do
      if x == hole or x == hole2 then
        side.board[board_idx(x, y)] = false
      else
        side.board[board_idx(x, y)] = "G"
      end
    end
  end
  -- 顶行被顶出则败
  for x = 0, COLS - 1 do
    if side.board[board_idx(x, 0)] then
      -- 检查是否溢出：若上移前顶部有块已在 0..rows-1
    end
  end
  -- 若顶部 rows 行在上移前有块则可能顶死：检测 y=0 在注入后若原顶部有内容
  -- 简化：spawn 时 collides 判负
end

local function other_side(sess, side)
  if not sess.versus then
    return nil
  end
  if side == sess.player then
    return sess.ai
  end
  return sess.player
end

---锁定后的公共结算（消行 / 垃圾 / 出块 / 胜负）
---@param from_special boolean|nil 是否刚完成特殊块（含↑仅1格）
local function finish_lock(sess, side, special_filled, from_special)
  special_filled = special_filled or 0
  from_special = from_special or side.special_lock

  local cleared
  side.board, cleared = clear_full_lines_board(side.board)
  if cleared > 0 then
    side.lines = side.lines + cleared
    add_score(side, score_for_lines(cleared, side.level or 1))
    side.level = 1 + math.floor(side.lines / (config.lines_per_level or 10))
    sess.message = i18n.tf("tetris_cleared", side_label(side), cleared)
  end

  if special_filled > 0 then
    add_score(side, special_filled * 15)
  end

  -- 对战惩罚：整行 + 特殊填充格数（可 >4）
  if sess.versus then
    local punish = cleared + special_filled
    local g = garbage_for_lines(punish)
    local opp = other_side(sess, side)
    if g > 0 and opp and not opp.game_over then
      opp.pending_garbage = (opp.pending_garbage or 0) + g
      sess.message = i18n.tf(
        "tetris_punish",
        side_label(side),
        punish,
        cleared,
        special_filled,
        side_label(opp),
        g
      )
    end
  end

  -- 当前块已落地：结算本方待收垃圾
  if (side.pending_garbage or 0) > 0 and not side.game_over then
    local g = side.pending_garbage
    side.pending_garbage = 0
    inject_garbage(side, g)
    sess.message = i18n.tf("tetris_garbage", side_label(side), g)
  end

  -- 特殊块：下落+填充/消除全部完成后，特殊计分从 0 重新开始
  if from_special then
    reset_special_meter(side)
  end

  side.animating = false
  if sess.player and not sess.player.animating and (not sess.ai or not sess.ai.animating) then
    sess.animating = false
  end

  if not side.game_over then
    spawn_piece(sess, side)
  end

  if sess.versus then
    local p, a = sess.player, sess.ai
    if p.game_over and not a.game_over then
      sess.winner = "ai"
      sess.game_over = true
      sess.message = i18n.t("tetris_ai_win")
    elseif a.game_over and not p.game_over then
      sess.winner = "player"
      sess.game_over = true
      sess.message = i18n.t("tetris_you_win")
    elseif p.game_over and a.game_over then
      sess.winner = "draw"
      sess.game_over = true
      sess.message = i18n.t("tetris_draw")
    end
  else
    if side.game_over then
      sess.game_over = true
      sess.message = i18n.t("tetris_over")
    end
  end
end

local function stop_fill_timer(side)
  if side.fill_timer then
    pcall(function()
      side.fill_timer:stop()
      side.fill_timer:close()
    end)
    side.fill_timer = nil
  end
end

---特殊块填行/列动画：每次填 1 格
local function start_special_fill_anim(sess, side, hit)
  local rot = (hit.rot or 0) % 4
  local cells = collect_special_fill_cells(side.board, hit.x, hit.y, rot)
  -- 落点保留箭头朝向（X:rot），不刷成实心，便于辨认
  if hit.x >= 0 and hit.y >= 0 and hit.x < COLS and hit.y < ROWS then
    side.board[board_idx(hit.x, hit.y)] = "X:" .. tostring(rot)
  end

  local dname = special_dir_name(rot)
  if rot == 2 then
    -- 向上：仅 1 格，无填充动画
    sess.message = i18n.tf("tetris_special_up", side_label(side))
    finish_lock(sess, side, 0, true)
    if sess.buf and vim.api.nvim_buf_is_valid(sess.buf) then
      render(sess.buf)
    end
    return
  end

  local axis = (rot == 0) and i18n.t("tetris_axis_col") or i18n.t("tetris_axis_row")
  sess.message = i18n.tf("tetris_special_fill", side_label(side), dname, axis)

  if #cells == 0 then
    finish_lock(sess, side, 0, true)
    if sess.buf and vim.api.nvim_buf_is_valid(sess.buf) then
      render(sess.buf)
    end
    return
  end

  side.animating = true
  sess.animating = true
  stop_fill_timer(side)

  local idx = 0
  local ms = config.special_fill_ms or 35
  side.fill_timer = vim.uv.new_timer()
  if not side.fill_timer then
    -- 无 timer 则瞬间填完
    for _, c in ipairs(cells) do
      side.board[board_idx(c.x, c.y)] = "F"
    end
    finish_lock(sess, side, #cells, true)
    return
  end

  local function step()
    vim.schedule(function()
      if not state_by_buf[sess.buf] then
        stop_fill_timer(side)
        return
      end
      idx = idx + 1
      if idx > #cells then
        stop_fill_timer(side)
        finish_lock(sess, side, #cells, true)
        if sess.buf and vim.api.nvim_buf_is_valid(sess.buf) then
          render(sess.buf)
        end
        return
      end
      local c = cells[idx]
      side.board[board_idx(c.x, c.y)] = "F"
      sess.message = i18n.tf("tetris_special_cell", side_label(side), dname, idx, #cells)
      if sess.buf and vim.api.nvim_buf_is_valid(sess.buf) then
        render(sess.buf)
      end
      if side.fill_timer then
        side.fill_timer:start(ms, 0, step)
      end
    end)
  end
  side.fill_timer:start(ms, 0, step)
end

local function lock_piece(sess, side)
  local piece = side.piece
  if not piece or side.animating then
    return
  end
  local cells = piece_cells(piece)
  local special_hits = {}
  for _, c in ipairs(cells) do
    if c.y >= 0 and c.y < ROWS and c.x >= 0 and c.x < COLS then
      if piece.kind == "X" then
        local rot = piece.rot or 0
        side.board[board_idx(c.x, c.y)] = "X:" .. tostring(rot) -- 箭头朝向
        table.insert(special_hits, { x = c.x, y = c.y, rot = rot })
      else
        side.board[board_idx(c.x, c.y)] = piece.kind
      end
    elseif c.y < 0 then
      side.game_over = true
    end
  end

  side.piece = nil
  side.ai_plan = nil

  if #special_hits > 0 and not side.game_over then
    -- 特殊：动画填满行/列，结束后再 finish_lock 并重置特殊计分
    side.special_lock = true
    start_special_fill_anim(sess, side, special_hits[1])
    return
  end

  finish_lock(sess, side, 0, false)
end

local function hard_drop(sess, side)
  if not side.piece or side.game_over or sess.paused or sess.game_over then
    return
  end
  local n = 0
  while try_move(side, 0, 1, 0) do
    n = n + 1
  end
  if n > 0 then
    add_score(side, n * 2)
  end
  lock_piece(sess, side)
end

local function soft_drop_step(sess, side)
  if sess.paused or sess.game_over or side.game_over then
    return false
  end
  if not try_move(side, 0, 1, 0) then
    lock_piece(sess, side)
    return false
  end
  add_score(side, 1)
  return true
end

local function tick_interval(side)
  local lv = side.level or 1
  local ms = (config.tick_ms or 600) - (lv - 1) * (config.tick_step or 40)
  local min_ms = config.min_tick_ms or 120
  if ms < min_ms then
    ms = min_ms
  end
  return ms
end

---评估盘面：越低越好
local function eval_board(board)
  local heights = {}
  local holes = 0
  local aggregate = 0
  for x = 0, COLS - 1 do
    local h = 0
    local seen = false
    for y = 0, ROWS - 1 do
      if board[board_idx(x, y)] then
        if not seen then
          h = ROWS - y
          seen = true
        end
      elseif seen then
        holes = holes + 1
      end
    end
    heights[x] = h
    aggregate = aggregate + h
  end
  local bump = 0
  for x = 0, COLS - 2 do
    bump = bump + math.abs(heights[x] - heights[x + 1])
  end
  return holes * 40 + aggregate * 2 + bump * 3
end

local function sim_lock(board, piece)
  local b = copy_board(board)
  local p = { kind = piece.kind, x = piece.x, y = piece.y, rot = piece.rot }
  while true do
    local n = { kind = p.kind, x = p.x, y = p.y + 1, rot = p.rot }
    if collides_board(b, n) then
      break
    end
    p = n
  end
  for _, c in ipairs(piece_cells(p)) do
    if c.y < 0 then
      return nil, 99999
    end
    if in_bounds(c.x, c.y) then
      if piece.kind == "X" then
        b[board_idx(c.x, c.y)] = "X:" .. tostring(p.rot or 0)
      else
        b[board_idx(c.x, c.y)] = piece.kind
      end
    end
  end
  -- 特殊块：模拟前方填充（与真实规则一致，↑ 不填）
  if piece.kind == "X" then
    local rot = (p.rot or 0) % 4
    for _, c in ipairs(piece_cells(p)) do
      if c.y >= 0 then
        local fills = collect_special_fill_cells(b, c.x, c.y, rot)
        for _, f in ipairs(fills) do
          b[board_idx(f.x, f.y)] = "F"
        end
      end
    end
  end
  local cleared
  b, cleared = clear_full_lines_board(b)
  local score = eval_board(b) - cleared * 80
  -- 特殊↑几乎无收益，AI 避免选用
  if piece.kind == "X" and (p.rot or 0) % 4 == 2 then
    score = score + 500
  end
  return { x = p.x, y = p.y, rot = p.rot }, score
end

local function ai_compute_plan(side)
  if not side.piece then
    return nil
  end
  local kind = side.piece.kind
  local nrot = #SHAPES[kind]
  local best, best_s = nil, 1e18
  for rot = 0, nrot - 1 do
    -- 特殊块：不选朝上（无填充）
    if not (kind == "X" and rot == 2) then
      for x = -2, COLS + 1 do
        local piece = { kind = kind, x = x, y = 0, rot = rot }
        if kind == "I" then
          piece.y = -1
        end
        if not collides(side, piece) then
          local plan, sc = sim_lock(side.board, piece)
          if plan and sc < best_s then
            best_s = sc
            best = { x = plan.x, rot = plan.rot }
          end
        end
      end
    end
  end
  return best
end

local function ai_step(sess, side)
  if not side.piece or side.game_over or side.animating or sess.paused or sess.game_over then
    return
  end
  if not side.ai_plan then
    side.ai_plan = ai_compute_plan(side)
  end
  local plan = side.ai_plan
  if not plan then
    hard_drop(sess, side)
    return
  end
  -- 先转到目标旋转
  if side.piece.rot ~= plan.rot then
    if not try_move(side, 0, 0, 1) then
      try_move(side, 0, 0, -1)
    end
    return
  end
  -- 水平移动
  if side.piece.x < plan.x then
    if not try_move(side, 1, 0, 0) then
      hard_drop(sess, side)
    end
    return
  end
  if side.piece.x > plan.x then
    if not try_move(side, -1, 0, 0) then
      hard_drop(sess, side)
    end
    return
  end
  -- 到位硬降
  hard_drop(sess, side)
end

local function stop_timer(sess)
  if sess.timer then
    pcall(function()
      sess.timer:stop()
      sess.timer:close()
    end)
    sess.timer = nil
  end
  if sess.ai_timer then
    pcall(function()
      sess.ai_timer:stop()
      sess.ai_timer:close()
    end)
    sess.ai_timer = nil
  end
  if sess.player then
    stop_fill_timer(sess.player)
    sess.player.animating = false
  end
  if sess.ai then
    stop_fill_timer(sess.ai)
    sess.ai.animating = false
  end
  sess.animating = false
end

local function make_side(label, is_ai)
  return {
    label = label,
    is_ai = is_ai and true or false,
    board = empty_board(),
    piece = nil,
    bag = nil,
    seq_i = 0, -- 共享序列进度（对战）
    score = 0,
    lines = 0,
    level = 1,
    special_ready = false,
    special_progress = 0, -- 距下个特殊块的累计分（完成后归零）
    special_lock = false,
    pending_garbage = 0,
    game_over = false,
    ai_plan = nil,
  }
end

local function reset_side(sess, side)
  side.board = empty_board()
  side.piece = nil
  side.bag = nil
  side.seq_i = 0
  side.score = 0
  side.lines = 0
  side.level = 1
  side.special_ready = false
  side.special_progress = 0
  side.special_lock = false
  side.pending_garbage = 0
  side.game_over = false
  side.ai_plan = nil
  if not sess.versus then
    side.bag = make_bag_batch()
  end
  spawn_piece(sess, side)
end

local function build_display(side, show_ghost)
  local display = {}
  for i = 1, COLS * ROWS do
    display[i] = side.board[i]
  end
  if show_ghost and side.piece and not side.game_over then
    local gy = ghost_y(side)
    if gy then
      local ghost = { kind = side.piece.kind, x = side.piece.x, y = gy, rot = side.piece.rot }
      local gtag = "ghost:" .. side.piece.kind
      if side.piece.kind == "X" then
        gtag = "ghost:X:" .. tostring(side.piece.rot or 0)
      end
      for _, c in ipairs(piece_cells(ghost)) do
        if c.y >= 0 and in_bounds(c.x, c.y) and not display[board_idx(c.x, c.y)] then
          display[board_idx(c.x, c.y)] = gtag
        end
      end
    end
  end
  if side.piece and not side.game_over then
    for _, c in ipairs(piece_cells(side.piece)) do
      if c.y >= 0 and in_bounds(c.x, c.y) then
        if side.piece.kind == "X" then
          display[board_idx(c.x, c.y)] = "X:" .. tostring(side.piece.rot or 0)
        else
          display[board_idx(c.x, c.y)] = side.piece.kind
        end
      end
    end
  end
  return display
end

local function special_arrow_text(rot)
  rot = (tonumber(rot) or 0) % 4
  if rot < 0 then
    rot = rot + 4
  end
  return SPECIAL_ARROWS[rot] or "↓ "
end

local function cell_text_hl(kind, x, y)
  if not kind then
    local alt = (x + y) % 2 == 0
    return "  ", alt and "TetrisEmpty" or "TetrisEmptyAlt"
  end
  -- 影子：同形状淡色实心块；特殊块影子显示朝向箭头
  if type(kind) == "string" and kind:sub(1, 6) == "ghost:" then
    local rest = kind:sub(7)
    if rest:sub(1, 1) == "X" then
      local rot = tonumber(rest:match("X:(%d+)")) or 0
      return special_arrow_text(rot), "TetrisGhostX"
    end
    local ghl = "TetrisGhost" .. rest
    return "██", ghl
  end
  -- 特殊块：X / X:0..3 用箭头表示朝向
  if type(kind) == "string" and (kind == "X" or kind:sub(1, 2) == "X:") then
    local rot = 0
    if kind:sub(1, 2) == "X:" then
      rot = tonumber(kind:sub(3)) or 0
    end
    return special_arrow_text(rot), "TetrisSpecial"
  end
  if kind == "G" then
    return "██", "TetrisGarbage"
  end
  if kind == "F" then
    -- 填充格：实心，与箭头落点区分
    return "██", "TetrisSpecial"
  end
  return "██", KIND_HL[kind] or "TetrisI"
end

---画一侧场地，返回 lines 与 marks（相对 row 偏移 0 起）
local function paint_board(display, border_hl)
  local lines = {}
  local marks = {}
  local top = "╔" .. string.rep("═", COLS * CELL_W) .. "╗"
  local bot = "╚" .. string.rep("═", COLS * CELL_W) .. "╝"
  table.insert(lines, top)
  table.insert(marks, { 0, 0, #top, border_hl })

  for y = 0, ROWS - 1 do
    local parts = { "║" }
    local byte_col = #"║"
    local row_marks = {}
    for x = 0, COLS - 1 do
      local text, hl = cell_text_hl(display[board_idx(x, y)], x, y)
      if vim.fn.strwidth(text) < CELL_W then
        text = text .. string.rep(" ", CELL_W - vim.fn.strwidth(text))
      end
      table.insert(row_marks, { byte_col, byte_col + #text, hl })
      table.insert(parts, text)
      byte_col = byte_col + #text
    end
    table.insert(parts, "║")
    local line = table.concat(parts)
    table.insert(lines, line)
    local row0 = #lines - 1
    table.insert(marks, { row0, 0, #"║", border_hl })
    table.insert(marks, { row0, #line - #"║", #line, border_hl })
    for _, m in ipairs(row_marks) do
      table.insert(marks, { row0, m[1], m[2], m[3] })
    end
  end
  table.insert(lines, bot)
  table.insert(marks, { #lines - 1, 0, #bot, border_hl })
  return lines, marks
end

local function pad_line(s, w)
  local sw = vim.fn.strwidth(s)
  if sw >= w then
    return s
  end
  return s .. string.rep(" ", w - sw)
end

---下一个方块：固定 4×4 格子 + 边框（宽 10 显示列）
local PREVIEW_N = 4
local PREVIEW_INNER_W = PREVIEW_N * CELL_W -- 8
local PREVIEW_BOX_W = PREVIEW_INNER_W + 2 -- 左右边框

local function paint_next_preview(kind)
  local marks = {} ---@type {row:integer,col:integer,end_col:integer,hl:string}[]
  local border_hl = "TetrisBorder"
  local empty_hl = "TetrisEmpty"

  -- 4×4 占用表
  local grid = {}
  for i = 1, PREVIEW_N * PREVIEW_N do
    grid[i] = false
  end

  local function set_cell(px, py, val)
    if px >= 0 and px < PREVIEW_N and py >= 0 and py < PREVIEW_N then
      grid[py * PREVIEW_N + px + 1] = val
    end
  end

  if kind == "X" then
    set_cell(1, 1, "X:0") -- 预览默认朝下 ↓
  elseif kind and SHAPES[kind] then
    local shape = SHAPES[kind][1]
    local minx, miny, maxx, maxy = 99, 99, -99, -99
    for _, c in ipairs(shape) do
      minx = math.min(minx, c[1])
      miny = math.min(miny, c[2])
      maxx = math.max(maxx, c[1])
      maxy = math.max(maxy, c[2])
    end
    local sw = maxx - minx + 1
    local sh = maxy - miny + 1
    local ox = math.floor((PREVIEW_N - sw) / 2) - minx
    local oy = math.floor((PREVIEW_N - sh) / 2) - miny
    for _, c in ipairs(shape) do
      set_cell(c[1] + ox, c[2] + oy, kind)
    end
  end

  local lines = {}
  -- 顶边固定显示宽 PREVIEW_BOX_W：┌──下一──┐
  local label = i18n.t("tetris_next")
  local lab_w = vim.fn.strwidth(label)
  local pad = math.max(0, PREVIEW_INNER_W - lab_w)
  local pad_l = math.floor(pad / 2)
  local pad_r = pad - pad_l
  local top = "┌" .. string.rep("─", pad_l) .. label .. string.rep("─", pad_r) .. "┐"
  table.insert(lines, top)
  table.insert(marks, { row = 0, col = 0, end_col = #top, hl = border_hl })
  local title_i = top:find(label, 1, true)
  if title_i then
    table.insert(marks, {
      row = 0,
      col = title_i - 1,
      end_col = title_i - 1 + #label,
      hl = "TetrisHint",
    })
  end

  for py = 0, PREVIEW_N - 1 do
    local parts = { "│" }
    local byte_col = #"│"
    local row_marks = {}
    for px = 0, PREVIEW_N - 1 do
      local cell = grid[py * PREVIEW_N + px + 1]
      local text, hl
      if not cell then
        text, hl = "  ", empty_hl
      elseif cell == "X" or (type(cell) == "string" and cell:sub(1, 2) == "X:") then
        local rot = 0
        if type(cell) == "string" and cell:sub(1, 2) == "X:" then
          rot = tonumber(cell:sub(3)) or 0
        end
        text, hl = special_arrow_text(rot), "TetrisSpecial"
      else
        text, hl = "██", KIND_HL[cell] or "TetrisI"
      end
      if vim.fn.strwidth(text) < CELL_W then
        text = text .. string.rep(" ", CELL_W - vim.fn.strwidth(text))
      end
      table.insert(row_marks, { byte_col, byte_col + #text, hl })
      table.insert(parts, text)
      byte_col = byte_col + #text
    end
    table.insert(parts, "│")
    local line = table.concat(parts)
    table.insert(lines, line)
    local row0 = #lines - 1
    table.insert(marks, { row = row0, col = 0, end_col = #"│", hl = border_hl })
    table.insert(marks, { row = row0, col = #line - #"│", end_col = #line, hl = border_hl })
    for _, m in ipairs(row_marks) do
      table.insert(marks, { row = row0, col = m[1], end_col = m[2], hl = m[3] })
    end
  end

  local bot = "└" .. string.rep("─", PREVIEW_INNER_W) .. "┘"
  table.insert(lines, bot)
  table.insert(marks, { row = #lines - 1, col = 0, end_col = #bot, hl = border_hl })

  return lines, marks, PREVIEW_BOX_W
end

render = function(buf)
  local sess = state_by_buf[buf]
  if not sess or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  ensure_hl()

  local p = sess.player
  local mode_tag = sess.versus and i18n.t("tetris_mode_versus") or i18n.t("tetris_mode_solo")
  local need = config.special_score or 1000
  local function special_meter_text(side)
    if side.special_ready or (side.piece and side.piece.kind == "X") or side.special_lock or side.animating then
      return i18n.t("tetris_special_ready")
    end
    return string.format("%d/%d", side.special_progress or 0, need)
  end
  local title = i18n.tf("tetris_title", mode_tag, p.score, p.lines, special_meter_text(p))
  if sess.versus and sess.ai then
    title = title
      .. i18n.tf(
        "tetris_title_ai",
        sess.ai.score,
        special_meter_text(sess.ai),
        p.pending_garbage or 0,
        sess.ai.pending_garbage or 0
      )
  else
    title = title .. i18n.tf("tetris_title_level", p.level)
  end

  local help = sess.versus and i18n.t("tetris_help_vs") or i18n.t("tetris_help")

  local out = { title, "" }
  ---@type {row:integer,col:integer,end_col:integer,hl:string}[]
  local marks = {}
  table.insert(marks, { row = 0, col = 0, end_col = #title, hl = "TetrisTitle" })

  local d1 = build_display(p, true)
  local b1, m1 = paint_board(d1, "TetrisBorder")
  local next1 = peek_next_kind(sess, p)
  local n1_lines, n1_marks, prev_w = paint_next_preview(next1)
  prev_w = prev_w or PREVIEW_BOX_W
  local board_w = vim.fn.strwidth(b1[1] or "")

  ---把 board marks (row,col0,col1,hl 数组) 与 preview marks 合并进 out
  local function emit_side_by_side(left_lines, left_marks, right_lines, right_marks, left_w, right_w, gap)
    gap = gap or "  "
    local n = math.max(#left_lines, #right_lines)
    for i = 1, n do
      local L = pad_line(left_lines[i] or "", left_w)
      local R = pad_line(right_lines[i] or "", right_w)
      local line = L .. gap .. R
      table.insert(out, line)
      local row0 = #out - 1
      if left_lines[i] and left_marks then
        for _, m in ipairs(left_marks) do
          local mr = m.row or m[1]
          local mc0 = m.col or m[2]
          local mc1 = m.end_col or m[3]
          local mhl = m.hl or m[4]
          if mr == i - 1 then
            table.insert(marks, { row = row0, col = mc0, end_col = mc1, hl = mhl })
          end
        end
      end
      local off = #L + #gap
      if right_lines[i] and right_marks then
        for _, m in ipairs(right_marks) do
          local mr = m.row or m[1]
          local mc0 = m.col or m[2]
          local mc1 = m.end_col or m[3]
          local mhl = m.hl or m[4]
          if mr == i - 1 then
            table.insert(marks, { row = row0, col = off + mc0, end_col = off + mc1, hl = mhl })
          end
        end
      end
    end
  end

  if sess.versus and sess.ai then
    local d2 = build_display(sess.ai, false)
    local b2, m2 = paint_board(d2, "TetrisBorderAi")
    local next2 = peek_next_kind(sess, sess.ai)
    local n2_lines, n2_marks = paint_next_preview(next2)
    local gap = " "
    local mid = " │ "

    -- 标题行：你 [空对齐预览宽] | 电脑
    local head = pad_line(i18n.t("tetris_you"), board_w)
      .. gap
      .. pad_line("", prev_w)
      .. mid
      .. pad_line(i18n.t("tetris_ai"), board_w)
      .. gap
      .. pad_line("", prev_w)
    table.insert(out, head)
    table.insert(marks, { row = #out - 1, col = 0, end_col = #head, hl = "TetrisHint" })

    -- 逐行：板1+预览1 | 板2+预览2
    local n = math.max(#b1, #b2, #n1_lines, #n2_lines)
    for i = 1, n do
      local L = pad_line(b1[i] or "", board_w)
      local Pn = pad_line(n1_lines[i] or "", prev_w)
      local R = pad_line(b2[i] or "", board_w)
      local An = pad_line(n2_lines[i] or "", prev_w)
      local line = L .. gap .. Pn .. mid .. R .. gap .. An
      table.insert(out, line)
      local row0 = #out - 1

      local function apply_board(bmarks, bi, off)
        if not bi then
          return
        end
        for _, m in ipairs(bmarks) do
          if m[1] == i - 1 then
            table.insert(marks, { row = row0, col = m[2] + off, end_col = m[3] + off, hl = m[4] })
          end
        end
      end
      local function apply_prev(pmarks, pi, off)
        if not pi then
          return
        end
        for _, m in ipairs(pmarks) do
          if m.row == i - 1 then
            table.insert(marks, {
              row = row0,
              col = off + m.col,
              end_col = off + m.end_col,
              hl = m.hl,
            })
          end
        end
      end

      apply_board(m1, b1[i], 0)
      apply_prev(n1_marks, n1_lines[i], #L + #gap)
      apply_board(m2, b2[i], #L + #gap + #Pn + #mid)
      apply_prev(n2_marks, n2_lines[i], #L + #gap + #Pn + #mid + #R + #gap)
    end
  else
    -- 单人：场地 | 4×4 下一
    local head = pad_line(i18n.t("tetris_you"), board_w) .. "  " .. pad_line("", prev_w)
    table.insert(out, head)
    table.insert(marks, { row = #out - 1, col = 0, end_col = #head, hl = "TetrisHint" })
    emit_side_by_side(b1, m1, n1_lines, n1_marks, board_w, prev_w, "  ")
  end

  table.insert(out, "")
  local msg = sess.message or ""
  if sess.paused then
    msg = i18n.t("tetris_paused")
  end
  table.insert(out, msg)
  local mhl = "TetrisHint"
  if sess.game_over then
    if sess.winner == "player" then
      mhl = "TetrisWin"
    else
      mhl = "TetrisGameOver"
    end
  elseif sess.paused then
    mhl = "TetrisPaused"
  end
  table.insert(marks, { row = #out - 1, col = 0, end_col = #msg, hl = mhl })
  table.insert(out, help)
  table.insert(marks, { row = #out - 1, col = 0, end_col = #help, hl = "TetrisStatus" })
  local lang_line = " " .. i18n.t("tetris_btn_lang") .. " "
  table.insert(out, lang_line)
  table.insert(marks, { row = #out - 1, col = 0, end_col = #lang_line, hl = "TetrisStatus" })
  sess.lang_row = #out -- 1-based for mouse.line

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
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
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function start_timers(sess, buf)
  stop_timer(sess)
  if sess.game_over or sess.paused then
    return
  end

  -- 玩家重力
  sess.timer = vim.uv.new_timer()
  if sess.timer then
    local function schedule_p()
      local ms = tick_interval(sess.player)
      sess.timer:start(ms, 0, function()
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then
            stop_timer(sess)
            return
          end
          local s = state_by_buf[buf]
          if not s or s.game_over or s.paused or s.player.game_over then
            if s and (s.game_over or s.player.game_over) then
              render(buf)
            end
            return
          end
          if s.player.animating then
            if not s.game_over and not s.paused then
              schedule_p()
            end
            return
          end
          if not try_move(s.player, 0, 1, 0) then
            lock_piece(s, s.player)
          end
          render(buf)
          if not s.game_over and not s.paused then
            schedule_p()
          end
        end)
      end)
    end
    schedule_p()
  end

  -- AI
  if sess.versus and sess.ai then
    sess.ai_timer = vim.uv.new_timer()
    if sess.ai_timer then
      local function schedule_ai()
        local base = config.ai_tick_ms or 180
        local scale = config.ai_tick_scale or 1.15
        local ms = math.floor(base * scale)
        sess.ai_timer:start(ms, 0, function()
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(buf) then
              stop_timer(sess)
              return
            end
            local s = state_by_buf[buf]
            if not s or s.game_over or s.paused or not s.ai or s.ai.game_over then
              if s then
                render(buf)
              end
              return
            end
            if s.ai.animating then
              if not s.game_over and not s.paused then
                schedule_ai()
              end
              return
            end
            -- AI 偶发自然下落
            s.ai_fall = (s.ai_fall or 0) + 1
            local fall_every = 3
            if s.ai_fall >= fall_every then
              s.ai_fall = 0
              if not try_move(s.ai, 0, 1, 0) then
                lock_piece(s, s.ai)
              else
                ai_step(s, s.ai)
              end
            else
              ai_step(s, s.ai)
            end
            render(buf)
            if not s.game_over and not s.paused then
              schedule_ai()
            end
          end)
        end)
      end
      schedule_ai()
    end
  end
end

local function new_game(sess, versus)
  stop_timer(sess)
  sess.versus = versus and true or false
  sess.paused = false
  sess.game_over = false
  sess.winner = nil
  sess.shared_seq = {} -- 对战共用出块序列
  sess.player = make_side(i18n.t("tetris_label_you"), false)
  if sess.versus then
    sess.ai = make_side(i18n.t("tetris_label_ai"), true)
    -- 先保证共享序列足够，再双方各自从同一序列起点取块
    ensure_shared_seq(sess, 14)
    reset_side(sess, sess.player)
    reset_side(sess, sess.ai)
    sess.message = i18n.t("tetris_start_versus")
  else
    sess.ai = nil
    reset_side(sess, sess.player)
    sess.message = i18n.tf("tetris_start_solo", config.special_score or 1000)
  end
end

local function apply_win(win)
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].list = false
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].statuscolumn = ""
  end)
end

local function hide_cursor(buf)
  vim.api.nvim_set_hl(0, "TetrisNoCursor", { blend = 100, nocombine = true })
  local prev = nil
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      prev = vim.o.guicursor
      vim.o.guicursor = "a:TetrisNoCursor"
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave", "BufWipeout" }, {
    buffer = buf,
    callback = function()
      if prev ~= nil then
        vim.o.guicursor = prev
        prev = nil
      end
    end,
  })
  prev = vim.o.guicursor
  vim.o.guicursor = "a:TetrisNoCursor"
end

local function disable_selection(buf)
  for _, lhs in ipairs({ "v", "V", "<C-v>", "gv" }) do
    -- 注意：v 键留给 versus，用 visual 屏蔽时排除单独 v... 对战用大写 V 屏蔽
  end
  for _, lhs in ipairs({ "V", "<C-v>", "gv" }) do
    pcall(vim.keymap.set, { "n", "v", "x", "s" }, lhs, "<Nop>", {
      buffer = buf,
      silent = true,
      nowait = true,
    })
  end
end

function M.open(opts)
  opts = opts or {}
  ensure_hl()
  math.randomseed(os.time() % 100000 + (vim.uv.hrtime() % 100000))

  local versus = opts.mode == "versus" or opts.versus == true

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, "nvimgames://tetris")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "nvimgames_tetris"
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(win, buf)
  apply_win(win)
  disable_selection(buf)
  hide_cursor(buf)

  local sess = { buf = buf }
  state_by_buf[buf] = sess
  new_game(sess, versus)

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      local s = state_by_buf[buf]
      if not s then
        return
      end
      fn(s)
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end, { buffer = buf, silent = true, nowait = true, desc = "tetris: " .. (desc or "") })
  end

  local function with_player(fn)
    return function(s)
      if s.game_over or s.paused or s.player.game_over or s.player.animating then
        return
      end
      fn(s, s.player)
    end
  end

  map("h", with_player(function(s, side)
    try_move(side, -1, 0, 0)
  end), "left")
  map("l", with_player(function(s, side)
    try_move(side, 1, 0, 0)
  end), "right")
  map("j", with_player(function(s, side)
    soft_drop_step(s, side)
  end), "soft drop")
  map("k", with_player(function(s, side)
    try_move(side, 0, 0, 1)
  end), "rotate")
  map("<Left>", with_player(function(s, side)
    try_move(side, -1, 0, 0)
  end), "left")
  map("<Right>", with_player(function(s, side)
    try_move(side, 1, 0, 0)
  end), "right")
  map("<Down>", with_player(function(s, side)
    soft_drop_step(s, side)
  end), "soft drop")
  map("<Up>", with_player(function(s, side)
    try_move(side, 0, 0, 1)
  end), "rotate")
  map("z", with_player(function(s, side)
    try_move(side, 0, 0, -1)
  end), "rotate ccw")
  map("x", with_player(function(s, side)
    try_move(side, 0, 0, 1)
  end), "rotate cw")
  map("<Space>", with_player(function(s, side)
    hard_drop(s, side)
  end), "hard drop")

  map("p", function(s)
    if s.game_over then
      return
    end
    s.paused = not s.paused
    if s.paused then
      stop_timer(s)
      s.message = i18n.t("tetris_paused")
    else
      s.message = i18n.t("tetris_resume")
      start_timers(s, buf)
    end
  end, "pause")

  map("r", function(s)
    new_game(s, s.versus)
    start_timers(s, buf)
  end, "restart")

  map("v", function(s)
    new_game(s, true)
    start_timers(s, buf)
  end, "versus")

  map("m", function(s)
    new_game(s, false)
    start_timers(s, buf)
  end, "solo")

  map("q", function(s)
    stop_timer(s)
    state_by_buf[buf] = nil
    pcall(vim.cmd, "bdelete!")
  end, "quit")

  map("u", function(s)
    i18n.toggle()
    s.message = i18n.t("lang_switched")
    if s.player then
      s.player.label = i18n.t("tetris_label_you")
    end
    if s.ai then
      s.ai.label = i18n.t("tetris_label_ai")
    end
  end, "lang")
  map("U", function(s)
    i18n.toggle()
    s.message = i18n.t("lang_switched")
    if s.player then
      s.player.label = i18n.t("tetris_label_you")
    end
    if s.ai then
      s.ai.label = i18n.t("tetris_label_ai")
    end
  end, "lang")

  map("?", function()
    vim.notify(i18n.t("tetris_help_box"), vim.log.levels.INFO)
  end, "help")

  if vim.o.mouse == "" then
    vim.o.mouse = "a"
  end
  vim.keymap.set("n", "<LeftMouse>", function()
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
      i18n.toggle()
      s.message = i18n.t("lang_switched")
      if s.player then
        s.player.label = i18n.t("tetris_label_you")
      end
      if s.ai then
        s.ai.label = i18n.t("tetris_label_ai")
      end
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end
  end, { buffer = buf, silent = true, nowait = true })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local s = state_by_buf[buf]
      if s then
        stop_timer(s)
      end
      state_by_buf[buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("TetrisHl_" .. buf, { clear = true }),
    callback = function()
      hl_ready = false
      ensure_hl()
      if vim.api.nvim_buf_is_valid(buf) then
        render(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      local s = state_by_buf[buf]
      if s and not s.game_over and not s.paused and not s.timer then
        start_timers(s, buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    callback = function()
      local s = state_by_buf[buf]
      if s then
        stop_timer(s)
      end
    end,
  })

  render(buf)
  start_timers(sess, buf)
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
