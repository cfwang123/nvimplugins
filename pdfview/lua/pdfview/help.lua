---@mod pdfview.help
local M = {}

local float_win = nil
local float_buf = nil

function M.close()
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    pcall(vim.api.nvim_win_close, float_win, true)
  end
  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    pcall(vim.api.nvim_buf_delete, float_buf, { force = true })
  end
  float_win = nil
  float_buf = nil
end

function M.is_open()
  return float_win and vim.api.nvim_win_is_valid(float_win)
end

function M.toggle_float()
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    M.close()
    return
  end
  require("pdfview.highlight").ensure()
  local i18n = require("pdfview.i18n")
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.deepcopy(i18n.t("help_lines"))
  if type(lines) ~= "table" then
    lines = { tostring(lines) }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].pdfview_help_float = true

  local width = math.min(68, math.floor(vim.o.columns * 0.75))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.6))
  height = math.max(height, 12)
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
    title = i18n.t("help_title"),
    title_pos = "center",
  })
  pcall(function()
    vim.wo[win].winhl = "Normal:PdfViewHelpFloat,FloatBorder:PdfViewHelpFloatBorder"
  end)
  float_win = win
  float_buf = buf

  local opts = { buffer = buf, silent = true, nowait = true }
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, function()
      M.close()
    end, opts)
  end
end

return M
