---@mod nvimgames.menu 浮动窗口选游戏
local M = {}

local GAMES = {
  { key = "1", id = "mine", label = "扫雷 (Mine)", open = function()
    require("nvimgames.mine").open({})
  end },
  { key = "2", id = "sokoban", label = "推箱子 (Sokoban)", open = function()
    require("nvimgames.sokoban").open({})
  end },
  { key = "3", id = "twentyfour", label = "24点 (Game24)", open = function()
    require("nvimgames.twentyfour").open({})
  end },
  { key = "4", id = "tetris", label = "俄罗斯方块 (Tetris)", open = function()
    require("nvimgames.tetris").open({})
  end },
}

local function ensure_hl()
  if not vim.o.termguicolors then
    vim.o.termguicolors = true
  end
  vim.api.nvim_set_hl(0, "NvimGamesMenuBorder", { fg = "#89b4fa", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "NvimGamesMenuTitle", { fg = "#89b4fa", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "NvimGamesMenuItem", { fg = "#cdd6f4", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "NvimGamesMenuKey", { fg = "#f9e2af", bg = "#1e1e2e", bold = true })
  vim.api.nvim_set_hl(0, "NvimGamesMenuHint", { fg = "#6c7086", bg = "#1e1e2e" })
  vim.api.nvim_set_hl(0, "NvimGamesMenuNormal", { fg = "#cdd6f4", bg = "#1e1e2e" })
end

local function close_float(state)
  if not state then
    return
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
end

---居中浮动窗口选游戏：数字键进入，Esc 退出
function M.open()
  ensure_hl()

  local lines = {
    "  nvimgames",
    "",
  }
  for _, g in ipairs(GAMES) do
    table.insert(lines, string.format("  %s  %s", g.key, g.label))
  end
  table.insert(lines, "")
  table.insert(lines, "  数字选择 · Esc 退出")

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strwidth(l))
  end
  width = math.max(width + 2, 28)
  local height = #lines

  local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local row = math.max(0, math.floor((ui.height - height) / 2) - 1)
  local col = math.max(0, math.floor((ui.width - width) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "nvimgames://menu")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " nvimgames ",
    title_pos = "center",
    noautocmd = true,
  })

  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].winhl = "Normal:NvimGamesMenuNormal,FloatBorder:NvimGamesMenuBorder,FloatTitle:NvimGamesMenuTitle"
  end)

  local ns = vim.api.nvim_create_namespace("nvimgames_menu")
  -- 标题
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    end_col = #lines[1],
    hl_group = "NvimGamesMenuTitle",
    hl_mode = "combine",
  })
  -- 选项行：数字高亮
  for i, g in ipairs(GAMES) do
    local row0 = i + 1 -- lines: title, blank, then items at index 3,4,5 → row 2,3,4
    local line = lines[row0 + 1]
    local key_pat = g.key
    local bi = line:find(key_pat, 1, true)
    if bi then
      vim.api.nvim_buf_set_extmark(buf, ns, row0, bi - 1, {
        end_col = bi - 1 + #key_pat,
        hl_group = "NvimGamesMenuKey",
        hl_mode = "combine",
        priority = 200,
      })
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row0, 0, {
      end_col = #line,
      hl_group = "NvimGamesMenuItem",
      hl_mode = "combine",
      priority = 100,
    })
  end
  -- 底部提示
  local hint_row = #lines - 1
  vim.api.nvim_buf_set_extmark(buf, ns, hint_row, 0, {
    end_col = #lines[hint_row + 1],
    hl_group = "NvimGamesMenuHint",
    hl_mode = "combine",
  })

  local state = { buf = buf, win = win }

  local function pick(idx)
    local g = GAMES[idx]
    if not g then
      return
    end
    close_float(state)
    -- 关浮窗后再开游戏，避免窗口叠乱
    vim.schedule(function()
      g.open()
    end)
  end

  local function dismiss()
    close_float(state)
  end

  local opts = { buffer = buf, silent = true, nowait = true, noremap = true }
  for i, g in ipairs(GAMES) do
    vim.keymap.set("n", g.key, function()
      pick(i)
    end, opts)
  end
  vim.keymap.set("n", "<Esc>", dismiss, opts)
  vim.keymap.set("n", "q", dismiss, opts)
  vim.keymap.set("n", "<C-c>", dismiss, opts)

  -- 屏蔽误操作
  for _, lhs in ipairs({ "i", "a", "A", "o", "O", "v", "V", "<C-v>" }) do
    vim.keymap.set("n", lhs, "<Nop>", opts)
  end

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      close_float(state)
    end,
  })

  return state
end

function M.games()
  return GAMES
end

function M.open_by_id(id)
  for _, g in ipairs(GAMES) do
    if g.id == id then
      g.open()
      return true
    end
  end
  return false
end

return M
