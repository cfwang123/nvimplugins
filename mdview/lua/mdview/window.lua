---@mod mdview.window
local config = require("mdview.config")

local M = {}

---@param width_cfg number
---@param total number
local function compute_width(width_cfg, total)
  if width_cfg > 0 and width_cfg <= 1 then
    return math.max(20, math.floor(total * width_cfg))
  end
  return math.max(20, math.floor(width_cfg))
end

function M.apply_winopts(win, cfg)
  cfg = cfg or config.get()
  for k, v in pairs(cfg.winopts or {}) do
    pcall(function()
      vim.wo[win][k] = v
    end)
  end
end

---创建预览 buffer
function M.create_preview_buf(source_buf)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "mdview"
  vim.b[buf].mdview_preview = true
  M.bind_preview_source(buf, source_buf)
  return buf
end

---更新预览关联的源 buffer（同 tab 切换 md 时复用预览窗）
function M.bind_preview_source(preview_buf, source_buf)
  if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
    return
  end
  vim.b[preview_buf].mdview_source = source_buf
  local label = "preview"
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    local name = vim.api.nvim_buf_get_name(source_buf)
    label = name ~= "" and vim.fn.fnamemodify(name, ":t") or tostring(source_buf)
  end
  -- 标签页/buffer 列表显示「文件名 [mdview]」；重名时加 buf 号
  local shown = label .. " [mdview]"
  local ok = pcall(vim.api.nvim_buf_set_name, preview_buf, shown)
  if not ok then
    pcall(vim.api.nvim_buf_set_name, preview_buf, shown .. ":" .. preview_buf)
  end
end

---当前 tab 内所有 mdview 预览窗
function M.list_preview_wins(tab)
  tab = tab or 0
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local b = vim.api.nvim_win_get_buf(win)
    if M.is_preview_buf(b) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

function M.is_preview_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].mdview_preview == true
end

---侧边打开预览窗
function M.open_side(source_win, preview_buf, cfg)
  cfg = cfg or config.get()
  local cur = source_win or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(cur)
  local total = vim.api.nvim_win_get_width(cur)
  local w = compute_width(cfg.width or 0.45, total)

  if cfg.split_direction == "left" then
    vim.cmd("leftabove vsplit")
  else
    vim.cmd("rightbelow vsplit")
  end
  local pwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pwin, preview_buf)
  vim.api.nvim_win_set_width(pwin, w)
  M.apply_winopts(pwin, cfg)
  -- 回到源窗
  vim.api.nvim_set_current_win(cur)
  return pwin
end

function M.close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

return M
