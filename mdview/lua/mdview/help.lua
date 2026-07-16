---@mod mdview.help
--- 快捷键帮助 float（? 打开 / q 关闭）
local M = {}

local float_state = {
  win = nil,
  buf = nil,
}

local HELP_LINES = {
  "mdview 快捷键",
  "",
  "  q          关闭预览",
  "  r          刷新预览",
  "  <CR>       激活：TOC/折叠/图片/链接",
  "  t          打开/关闭目录 TOC",
  "  go         跳到文内目录顶部",
  "  ?          本帮助（开/关）",
  "  <C-o>      返回：文内跳转 / 上一篇 md 预览",
  "  gi         打开光标处图片（float；支持高清）",
  "  gh         临时显示当前页高清图（滚动/焦点/改大小清除）",
  "  o          光标在图片上：系统程序打开原图",
  "  c / yc     复制光标处代码块（c 一键）",
  "  [Copy]     代码块顶栏按钮，点击/回车复制",
  "  gs         跳到源文件对应行",
  "",
  "  gt / gT    切换 tab（系统默认）",
  "",
  "  q / Esc    关闭本窗口",
}

function M.close_float()
  if float_state.win and vim.api.nvim_win_is_valid(float_state.win) then
    pcall(vim.api.nvim_win_close, float_state.win, true)
  end
  if float_state.buf and vim.api.nvim_buf_is_valid(float_state.buf) then
    pcall(vim.api.nvim_buf_delete, float_state.buf, { force = true })
  end
  float_state.win = nil
  float_state.buf = nil
end

function M.is_open()
  return float_state.win and vim.api.nvim_win_is_valid(float_state.win)
end

function M.open_float()
  if M.is_open() then
    M.close_float()
    return
  end

  require("mdview.highlight").ensure()

  local lines = vim.deepcopy(HELP_LINES)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "mdview_help"
  vim.b[buf].mdview_help_float = true

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width + 4, 36), math.floor(vim.o.columns * 0.7))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  height = math.max(height, 8)

  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Help ",
    title_pos = "center",
    zindex = 55,
  })
  if not ok or not win then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify("mdview: failed to open help float", vim.log.levels.ERROR)
    return
  end

  float_state.win = win
  float_state.buf = buf

  pcall(function()
    vim.wo[win].cursorline = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    vim.wo[win].winhl = table.concat({
      "Normal:MdViewHelpFloat",
      "NormalFloat:MdViewHelpFloat",
      "FloatBorder:MdViewHelpFloatBorder",
      "FloatTitle:MdViewHelpFloatTitle",
    }, ",")
  end)

  local ns = vim.api.nvim_create_namespace("mdview_help_float")
  -- 标题行 bold
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, {
    end_col = #lines[1],
    hl_group = "MdViewHelpFloatTitle",
  })

  local map_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", function()
    M.close_float()
  end, map_opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close_float()
  end, map_opts)
  vim.keymap.set("n", "?", function()
    M.close_float()
  end, map_opts)

  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(win),
    callback = function()
      float_state.win = nil
      float_state.buf = nil
    end,
  })
end

function M.toggle_float()
  if M.is_open() then
    M.close_float()
  else
    M.open_float()
  end
end

return M
