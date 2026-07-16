---@mod mdview.code
--- 代码块：Tree-sitter → syntax → 单色
local M = {}

local lang_ft = {
  js = "javascript",
  ts = "typescript",
  py = "python",
  rb = "ruby",
  rs = "rust",
  sh = "bash",
  bash = "bash",
  zsh = "zsh",
  yml = "yaml",
  md = "markdown",
  csharp = "cs",
  ["c++"] = "cpp",
  ["c#"] = "cs",
}

local function resolve_ft(lang)
  if not lang or lang == "" or lang == "text" then
    return nil
  end
  lang = lang:lower()
  return lang_ft[lang] or lang
end

---@param lang string
---@param lines string[]
---@param mode "auto"|"treesitter"|"syntax"|"none"
---@return table[]|nil list of {row, col, end_col, hl}
function M.highlight(lang, lines, mode)
  mode = mode or "auto"
  if mode == "none" or not lines or #lines == 0 then
    return nil
  end
  local ft = resolve_ft(lang)
  if not ft then
    return nil
  end

  local try_ts = mode == "auto" or mode == "treesitter"
  local try_syn = mode == "auto" or mode == "syntax"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_option, buf, "filetype", ft)

  local marks = nil
  if try_ts then
    marks = M._highlight_treesitter(buf, ft, #lines)
  end
  if (not marks or #marks == 0) and try_syn and mode ~= "treesitter" then
    marks = M._highlight_syntax(buf, #lines)
  end

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if marks and #marks > 0 then
    return marks
  end
  return nil
end

function M._highlight_treesitter(buf, lang, line_count)
  local ok_start = pcall(function()
    vim.treesitter.start(buf, lang)
  end)
  if not ok_start then
    -- 再试 filetype 名
    local ok2 = pcall(vim.treesitter.start, buf)
    if not ok2 then
      return nil
    end
  end

  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return nil
  end

  local query = nil
  pcall(function()
    query = vim.treesitter.query.get(lang, "highlights")
  end)
  if not query then
    pcall(function()
      local ft = vim.bo[buf].filetype
      query = vim.treesitter.query.get(ft, "highlights")
    end)
  end
  if not query then
    return nil
  end

  local marks = {}
  local max_lines = math.min(line_count, 400)
  for id, node, _ in query:iter_captures(trees[1]:root(), buf, 0, max_lines) do
    local name = query.captures[id]
    if name and not name:match("^_") then
      local hl = "@" .. name
      local srow, scol, erow, ecol = node:range()
      if srow < max_lines then
        if srow == erow then
          marks[#marks + 1] = { row = srow, col = scol, end_col = ecol, hl = hl }
        else
          for r = srow, math.min(erow, max_lines - 1) do
            local line = vim.api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
            local c0 = (r == srow) and scol or 0
            local c1 = (r == erow) and ecol or #line
            marks[#marks + 1] = { row = r, col = c0, end_col = c1, hl = hl }
          end
        end
      end
    end
  end
  return marks
end

function M._highlight_syntax(buf, line_count)
  local marks = {}
  local max_lines = math.min(line_count, 200)
  local ok = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("syntax enable")
    vim.cmd("setlocal syntax=" .. vim.bo.filetype)
  end)
  if not ok then
    return nil
  end

  for row = 0, max_lines - 1 do
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local len = #line
    if len > 0 then
      local col = 0
      local step = 1
      while col < len do
        local hl_id = vim.fn.synID(row + 1, col + 1, 1)
        local trans = vim.fn.synIDtrans(hl_id)
        local name = vim.fn.synIDattr(trans, "name")
        local end_col = col + 1
        while end_col < len do
          local id2 = vim.fn.synIDtrans(vim.fn.synID(row + 1, end_col + 1, 1))
          if id2 ~= trans then
            break
          end
          end_col = end_col + 1
        end
        if name and name ~= "" then
          marks[#marks + 1] = { row = row, col = col, end_col = end_col, hl = name }
        end
        col = end_col
      end
    end
  end
  return #marks > 0 and marks or nil
end

return M
