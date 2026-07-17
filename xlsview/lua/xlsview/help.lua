---@mod xlsview.help
local M = {}

local win, buf

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  win, buf = nil, nil
end

function M.is_open()
  return win and vim.api.nvim_win_is_valid(win)
end

function M.toggle_float()
  if win and vim.api.nvim_win_is_valid(win) then
    M.close()
    return
  end
  require("xlsview.highlight").ensure()
  local i18n = require("xlsview.i18n")
  local lines = vim.deepcopy(i18n.t("help_lines"))
  if type(lines) ~= "table" then
    lines = { tostring(lines) }
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(52, math.floor(vim.o.columns * 0.7))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = i18n.t("help_title"),
    title_pos = "center",
  })
  pcall(function()
    vim.wo[win].winhl = "Normal:XlsViewHelpFloat,FloatBorder:XlsViewHelpFloatBorder"
  end)
  local opts = { buffer = buf, silent = true, nowait = true }
  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function()
      M.close()
    end, opts)
  end
end

return M
