---@mod mdview.source_fold
--- Markdown 源 buffer 折叠：
--- 1) ATX 标题（# … ######）
--- 2) HTML <details> 正文（默认收起；open 属性或用户展开后保持）
local config = require("mdview.config")
local html = require("mdview.html")
local window = require("mdview.window")

local M = {}

--- buf -> cache
local cache = {}
--- buf -> { [key]=true } 用户曾展开的 details（按 summary 键）
local details_open = {}
local au_installed = false

local DETAILS_BOOST = 10

---@param buf integer
---@return boolean
local function is_md_source(buf)
  if not buf or buf == 0 or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if window.is_preview_buf(buf) then
    return false
  end
  if vim.b[buf].mdview_toc_float or vim.b[buf].mdview_image_float or vim.b[buf].mdview_help_float then
    return false
  end
  local ft = vim.bo[buf].filetype or ""
  if ft == "markdown" or ft == "md" or ft == "pandoc" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf):lower()
  return name:match("%.md$") ~= nil
    or name:match("%.markdown$") ~= nil
    or name:match("%.mdx$") ~= nil
end

---@return boolean
local function heading_fold_enabled()
  local cfg = config.get()
  if cfg.source_heading_fold == false then
    return false
  end
  if cfg.source_heading_fold == true then
    return true
  end
  return cfg.heading_fold ~= false
end

---@return boolean
local function details_fold_enabled()
  local cfg = config.get()
  if cfg.html and cfg.html.details == false then
    return false
  end
  if cfg.source_details_fold == false then
    return false
  end
  -- 默认开启源码 details 折叠
  return true
end

---@return boolean
local function feature_enabled()
  return heading_fold_enabled() or details_fold_enabled()
end

---解析每行 ATX 标题层级；非标题为 0。跳过 fenced code。
---@param lines string[]
---@return number[]
local function scan_heading_levels(lines)
  local out = {}
  local in_fence = false
  local fence_ch, fence_n = nil, 0
  for i, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$") or line
    local ticks = trimmed:match("^(```+)") or trimmed:match("^(~~~+)")
    if ticks then
      local ch = ticks:sub(1, 1)
      local n = #ticks
      if not in_fence then
        in_fence = true
        fence_ch = ch
        fence_n = n
      elseif ch == fence_ch and n >= fence_n then
        in_fence = false
        fence_ch, fence_n = nil, 0
      end
      out[i] = 0
    elseif in_fence then
      out[i] = 0
    else
      local hashes = line:match("^(#+)[ \t]+") or line:match("^(#+)$")
      if hashes and #hashes >= 1 and #hashes <= 6 then
        out[i] = #hashes
      else
        out[i] = 0
      end
    end
  end
  return out
end

---扫描所有 details 块（含嵌套）
---@param lines string[]
---@param cfg table
---@return table[]
local function scan_details(lines, cfg)
  local list = {}
  if not details_fold_enabled() then
    return list
  end
  local in_fence = false
  local fence_ch, fence_n = nil, 0
  local i = 1
  local n = #lines
  while i <= n do
    local line = lines[i]
    local trimmed = line:match("^%s*(.-)%s*$") or line
    local ticks = trimmed:match("^(```+)") or trimmed:match("^(~~~+)")
    if ticks then
      local ch = ticks:sub(1, 1)
      local tn = #ticks
      if not in_fence then
        in_fence = true
        fence_ch = ch
        fence_n = tn
      elseif ch == fence_ch and tn >= fence_n then
        in_fence = false
        fence_ch, fence_n = nil, 0
      end
      i = i + 1
    elseif in_fence then
      i = i + 1
    elseif trimmed:lower():match("^<details[%s>]") then
      local det = html.extract_details(lines, i, cfg)
      if det and det.end_idx and det.end_idx >= i then
        local fold_start = det.body_line_offset or (i + 1)
        -- 含 summary 行，折叠预览更可读
        for j = i, det.end_idx do
          if lines[j]:lower():find("<summary", 1, true) then
            fold_start = j
            break
          end
        end
        if fold_start <= i then
          fold_start = i + 1
        end
        local fold_end = det.end_idx - 1
        local end_line = lines[det.end_idx] or ""
        if end_line:lower():find("</details>", 1, true) and not end_line:lower():find("<details", 1, true) then
          -- 闭合标签独占一行：不纳入折叠，保持可见
          fold_end = det.end_idx - 1
        else
          fold_end = det.end_idx
        end
        if fold_end >= fold_start then
          local nest = 1
          for _, o in ipairs(list) do
            if o.start < i and o.end_idx >= det.end_idx then
              nest = nest + 1
            end
          end
          list[#list + 1] = {
            start = i,
            end_idx = det.end_idx,
            fold_start = fold_start,
            fold_end = fold_end,
            open_attr = det.open and true or false,
            summary = det.summary or "Details",
            nest = nest,
            key = string.format("%s\0%d", det.summary or "", nest),
          }
        end
        i = i + 1 -- 继续扫嵌套
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return list
end

---计算每行 fold level（数字）
---@param lines string[]
---@param cfg table
---@return number[] levels
---@return table[] details
local function compute_levels(lines, cfg)
  local n = #lines
  local heading = heading_fold_enabled() and scan_heading_levels(lines) or {}
  local levels = {}
  local depth = 0
  for i = 1, n do
    if heading[i] and heading[i] > 0 then
      depth = heading[i]
    end
    levels[i] = depth
  end

  local details = scan_details(lines, cfg)
  for _, d in ipairs(details) do
    local boost = DETAILS_BOOST * (d.nest or 1)
    for i = d.fold_start, d.fold_end do
      if i >= 1 and i <= n then
        levels[i] = (levels[i] or 0) + boost
      end
    end
  end
  return levels, details
end

---应用 details 默认收起：foldlevel 盖住 10+；再 foldopen 需要保持展开的
---@param buf integer
local function apply_details_closed(buf)
  local c = cache[buf]
  if not c or not details_fold_enabled() then
    return
  end
  local open_map = details_open[buf] or {}
  local wins = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      wins[#wins + 1] = w
    end
  end
  if #wins == 0 then
    return
  end
  -- 标题层级 1–6 默认展开；details 用 +10/+20…，自然 > foldlevel 而收起
  for _, w in ipairs(wins) do
    pcall(function()
      vim.wo[w].foldlevel = 6
    end)
  end
  if not c.details then
    return
  end
  for _, d in ipairs(c.details) do
    local keep_open = d.open_attr or open_map[d.key]
    if keep_open and d.fold_start then
      for _, w in ipairs(wins) do
        pcall(function()
          vim.api.nvim_win_call(w, function()
            vim.cmd(tostring(d.fold_start) .. "foldopen!")
          end)
        end)
      end
    end
  end
end

---根据当前窗口 fold 状态记住用户展开的 details
---@param buf integer
local function snapshot_open_details(buf)
  local c = cache[buf]
  if not c or not c.details then
    return
  end
  local open_map = {}
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        win = w
        break
      end
    end
  end
  if win == -1 then
    details_open[buf] = details_open[buf] or {}
    return
  end
  pcall(function()
    vim.api.nvim_win_call(win, function()
      for _, d in ipairs(c.details) do
        if d.fold_start then
          local fc = vim.fn.foldclosed(d.fold_start)
          if fc == -1 then
            -- 未关闭 = 展开
            open_map[d.key] = true
          end
        end
      end
    end)
  end)
  -- 保留 open 属性对应的键
  for _, d in ipairs(c.details) do
    if d.open_attr then
      open_map[d.key] = true
    end
  end
  details_open[buf] = open_map
end

---@param buf integer
function M.rebuild(buf)
  if not is_md_source(buf) or not feature_enabled() then
    cache[buf] = nil
    return
  end
  snapshot_open_details(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cfg = config.get()
  local levels, details = compute_levels(lines, cfg)
  cache[buf] = {
    levels = levels,
    details = details,
    n = #lines,
  }
  -- 等 fold 树更新后再默认收起
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then
      apply_details_closed(buf)
    end
  end)
end

---@param buf integer
local function schedule_rebuild(buf)
  local c = cache[buf]
  if c and c.timer then
    pcall(function()
      c.timer:stop()
    end)
  end
  local delay = config.get().debounce_ms or 150
  local timer = vim.defer_fn(function()
    if cache[buf] then
      cache[buf].timer = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      M.rebuild(buf)
    end
  end, delay)
  cache[buf] = cache[buf] or {}
  cache[buf].timer = timer
end

---foldexpr：返回每行 fold level（数字）
---@param lnum integer
---@return number
function M.foldexpr(lnum)
  local buf = vim.api.nvim_get_current_buf()
  if not feature_enabled() then
    return 0
  end
  local c = cache[buf]
  if not c or not c.levels then
    M.rebuild(buf)
    c = cache[buf]
  end
  if not c or not c.levels then
    return 0
  end
  return c.levels[lnum] or 0
end

function M.foldtext()
  local fs = vim.v.foldstart
  local fe = vim.v.foldend
  local line = vim.fn.getline(fs) or ""
  line = line:gsub("%s+$", "")
  -- details：优先展示 summary 文案
  local sum = line:match("<%s*[Ss][Uu][Mm][Mm][Aa][Rr][Yy][^>]*>(.-)</%s*[Ss][Uu][Mm][Mm][Aa][Rr][Yy]%s*>")
  if sum then
    sum = sum:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if sum ~= "" then
      line = "▸ " .. sum
    end
  end
  local n = math.max(0, fe - fs)
  local i18n = require("mdview.i18n")
  local suffix = i18n.t("source_fold_lines")
  if type(suffix) == "string" and suffix:find("%%d") then
    return line .. "  " .. string.format(suffix, n)
  end
  return string.format("%s  … (%d)", line, n)
end

---@param win integer
---@param buf integer
function M.apply_win(win, buf)
  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  if not feature_enabled() then
    return
  end
  pcall(function()
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = "v:lua.require'mdview.source_fold'.foldexpr(v:lnum)"
    vim.wo[win].foldtext = "v:lua.require'mdview.source_fold'.foldtext()"
    vim.wo[win].foldenable = true
    -- 6：标题 1–6 展开；details +10 起默认收起（见 apply_details_closed）
    vim.wo[win].foldlevel = 6
    local fc = vim.wo[win].foldcolumn
    if fc == nil or fc == "0" or fc == "" then
      vim.wo[win].foldcolumn = "1"
    end
  end)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
      apply_details_closed(buf)
    end
  end)
end

---@param buf integer
function M.attach(buf)
  if not is_md_source(buf) or not feature_enabled() then
    return
  end
  if vim.b[buf].mdview_source_fold_attached then
    M.rebuild(buf)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        M.apply_win(w, buf)
      end
    end
    return
  end
  vim.b[buf].mdview_source_fold_attached = true
  M.rebuild(buf)

  local g = vim.api.nvim_create_augroup("mdview_source_fold_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufWritePost" }, {
    group = g,
    buffer = buf,
    callback = function()
      schedule_rebuild(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    group = g,
    buffer = buf,
    callback = function()
      M.rebuild(buf)
      local w = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(w) == buf then
        M.apply_win(w, buf)
      end
    end,
  })
  -- 用户 zo/zc 后记一次（插入离开 / 普通模式变更时采样）
  vim.api.nvim_create_autocmd({ "CursorHold", "InsertLeave" }, {
    group = g,
    buffer = buf,
    callback = function()
      snapshot_open_details(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = g,
    buffer = buf,
    callback = function()
      cache[buf] = nil
      details_open[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, g)
    end,
  })

  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      M.apply_win(w, buf)
    end
  end
end

function M.ensure_au()
  if not feature_enabled() then
    return
  end
  if not au_installed then
    au_installed = true
    local g = vim.api.nvim_create_augroup("mdview_source_fold_global", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = g,
      pattern = { "markdown", "md", "pandoc" },
      callback = function(ev)
        M.attach(ev.buf)
      end,
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
      group = g,
      callback = function(ev)
        if is_md_source(ev.buf) then
          M.attach(ev.buf)
        end
      end,
    })
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and is_md_source(b) then
      M.attach(b)
    end
  end
end

return M
