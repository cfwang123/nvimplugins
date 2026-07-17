---@mod nvimgames.menu 浮动窗口选游戏
local M = {}

local i18n = require("nvimgames.i18n")

local function game_list()
  local t = i18n.t
  return {
    {
      key = "1",
      id = "mine",
      label = t("game_mine"),
      open = function()
        require("nvimgames.mine").open({})
      end,
    },
    {
      key = "2",
      id = "sokoban",
      label = t("game_sokoban"),
      open = function()
        require("nvimgames.sokoban").open({})
      end,
    },
    {
      key = "3",
      id = "twentyfour",
      label = t("game_twentyfour"),
      open = function()
        require("nvimgames.twentyfour").open({})
      end,
    },
    {
      key = "4",
      id = "tetris",
      label = t("game_tetris"),
      open = function()
        require("nvimgames.tetris").open({})
      end,
    },
  }
end

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
  vim.api.nvim_set_hl(0, "NvimGamesMenuBtn", { fg = "#111111", bg = "#e8e8e8", bold = true })
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

local function paint_menu(state)
  local t = i18n.t
  local games = game_list()
  state.games = games

  local lines = {
    "  " .. t("menu_title"),
    "",
  }
  for _, g in ipairs(games) do
    table.insert(lines, string.format("  %s  %s", g.key, g.label))
  end
  table.insert(lines, "")
  local lang_line = "  " .. t("lang_btn")
  table.insert(lines, lang_line)
  table.insert(lines, "  " .. t("menu_hint"))

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strwidth(l))
  end
  width = math.max(width + 2, 32)
  local height = #lines

  local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local row = math.max(0, math.floor((ui.height - height) / 2) - 1)
  local col = math.max(0, math.floor((ui.width - width) / 2))

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_config, state.win, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
    })
  end

  local ns = state.ns
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, {
    end_col = #lines[1],
    hl_group = "NvimGamesMenuTitle",
    hl_mode = "combine",
  })
  for i, g in ipairs(games) do
    local row0 = i + 1
    local line = lines[row0 + 1]
    local bi = line:find(g.key, 1, true)
    if bi then
      vim.api.nvim_buf_set_extmark(state.buf, ns, row0, bi - 1, {
        end_col = bi - 1 + #g.key,
        hl_group = "NvimGamesMenuKey",
        hl_mode = "combine",
        priority = 200,
      })
    end
    vim.api.nvim_buf_set_extmark(state.buf, ns, row0, 0, {
      end_col = #line,
      hl_group = "NvimGamesMenuItem",
      hl_mode = "combine",
      priority = 100,
    })
  end
  -- lang button row
  local lang_row = #lines - 2
  local ll = lines[lang_row + 1]
  local lbi = ll:find(vim.trim(t("lang_btn")), 1, true)
  if not lbi then
    lbi = ll:find("%[", 1, true) or 3
  end
  -- highlight whole lang line as button-ish
  vim.api.nvim_buf_set_extmark(state.buf, ns, lang_row, 0, {
    end_col = #ll,
    hl_group = "NvimGamesMenuBtn",
    hl_mode = "combine",
    priority = 150,
  })
  state.lang_row = lang_row + 1 -- 1-based for mouse.line

  local hint_row = #lines - 1
  vim.api.nvim_buf_set_extmark(state.buf, ns, hint_row, 0, {
    end_col = #lines[hint_row + 1],
    hl_group = "NvimGamesMenuHint",
    hl_mode = "combine",
  })
end

---居中浮动窗口选游戏：数字键进入，u 切换语言，Esc 退出
function M.open()
  ensure_hl()
  -- 确保语言已初始化
  if not vim.g.nvimgames_setup_done then
    require("nvimgames").setup()
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "nvimgames://menu")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 32,
    height = 12,
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

  local state = {
    buf = buf,
    win = win,
    ns = vim.api.nvim_create_namespace("nvimgames_menu"),
    games = {},
  }
  paint_menu(state)

  local function pick(idx)
    local g = state.games[idx]
    if not g then
      return
    end
    close_float(state)
    vim.schedule(function()
      g.open()
    end)
  end

  local function dismiss()
    close_float(state)
  end

  local function toggle_lang()
    i18n.toggle()
    paint_menu(state)
  end

  for i = 1, 4 do
    vim.keymap.set("n", tostring(i), function()
      pick(i)
    end, { buffer = buf, silent = true, nowait = true })
  end
  vim.keymap.set("n", "u", toggle_lang, { buffer = buf, silent = true, nowait = true, desc = "toggle language" })
  vim.keymap.set("n", "U", toggle_lang, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", dismiss, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "q", dismiss, { buffer = buf, silent = true, nowait = true })

  if vim.o.mouse == "" then
    vim.o.mouse = "a"
  end
  vim.keymap.set("n", "<LeftMouse>", function()
    local mp = vim.fn.getmousepos()
    if not state.win or mp.winid ~= state.win then
      return
    end
    -- click lang row
    if state.lang_row and mp.line == state.lang_row then
      toggle_lang()
      return
    end
    -- click game rows: title=1 blank=2 items start at 3
    local idx = mp.line - 2
    if idx >= 1 and idx <= #state.games then
      pick(idx)
    end
  end, { buffer = buf, silent = true, nowait = true })
end

return M
