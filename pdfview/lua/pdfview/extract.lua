---@mod pdfview.extract
--- 调用 extract.py / extract_docx.py；PDF 支持按页范围懒提取 + 单页缓存
local config = require("pdfview.config")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function python_cmd(cfg)
  cfg = cfg or config.get()
  local py = cfg.python or (cfg.image and cfg.image.python) or "python"
  if vim.fn.executable(py) == 1 then
    return py
  end
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  return nil
end

---缓存目录：stdpath cache/pdfview/<hash>/
---@param path string
---@return string dir
function M.cache_dir(path)
  path = vim.fn.fnamemodify(path, ":p")
  local key = vim.fn.sha256(path)
  local dir = vim.fn.stdpath("cache") .. "/pdfview/" .. key:sub(1, 24)
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param path string
---@return string json_path, string img_dir
function M.paths_for(path)
  local dir = M.cache_dir(path)
  return dir .. "/doc.json", dir .. "/images"
end

---@param path string
---@return string
function M.meta_path(path)
  return M.cache_dir(path) .. "/meta.json"
end

---@param path string
---@param page number
---@return string
function M.page_path(path, page)
  return M.cache_dir(path) .. "/pages/" .. tostring(page) .. ".json"
end

---@param path string
---@return string|nil kind "pdf"|"docx"|"doc"
function M.kind_of(path)
  if not path or path == "" then
    return nil
  end
  local lower = path:lower()
  if lower:match("%.pdf$") then
    return "pdf"
  end
  if lower:match("%.docx$") then
    return "docx"
  end
  if lower:match("%.doc$") then
    return "doc"
  end
  return nil
end

function M.is_supported(path)
  return M.kind_of(path) ~= nil
end

---@param path string
---@param json_path string
---@return boolean
local function cache_fresh(path, json_path)
  if vim.fn.filereadable(json_path) ~= 1 then
    return false
  end
  local mtime = vim.fn.getftime(path)
  local jm = vim.fn.getftime(json_path)
  if mtime < 0 or jm < 0 then
    return false
  end
  if mtime > jm then
    return false
  end
  return true
end

local function read_json_file(fpath)
  if vim.fn.filereadable(fpath) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(fpath), "\n"))
  end)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

local function write_json_file(fpath, data)
  pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(fpath, ":h"), "p")
    vim.fn.writefile({ vim.json.encode(data) }, fpath)
  end)
end

---占位页（尚未提取）
---@param pno number
---@return table
local function pending_page(pno)
  return {
    page = pno,
    blocks = {},
    _pending = true,
  }
end

---把已提取页合并进 data.pages（按页码 1..page_count 数组）
---@param data table
---@param pages table[]
local function merge_pages(data, pages)
  data.pages = data.pages or {}
  local pc = data.page_count or #data.pages
  for _, p in ipairs(pages or {}) do
    local n = tonumber(p.page) or 0
    if n >= 1 and n <= pc then
      p._pending = nil
      data.pages[n] = p
    end
  end
  -- 补齐空洞为 pending
  for i = 1, pc do
    if not data.pages[i] then
      data.pages[i] = pending_page(i)
    end
  end
end

---@param data table
---@param pno number
---@return boolean
function M.page_ready(data, pno)
  if not data or not data.pages then
    return false
  end
  local p = data.pages[pno]
  return p ~= nil and p._pending ~= true
end

---从磁盘加载已缓存的单页
---@param path string
---@param pno number
---@return table|nil
local function load_cached_page(path, pno)
  if not cache_fresh(path, M.page_path(path, pno)) then
    -- 页文件存在但源更新：也拒绝
    local pp = M.page_path(path, pno)
    if vim.fn.filereadable(pp) == 1 and cache_fresh(path, M.meta_path(path)) then
      -- meta 仍新鲜则页文件可用（页文件 mtime 可能新于 pdf 若刚提取）
      local mtime_pdf = vim.fn.getftime(path)
      local mtime_page = vim.fn.getftime(pp)
      if mtime_page >= 0 and mtime_pdf >= 0 and mtime_page >= mtime_pdf then
        return read_json_file(pp)
      end
    end
    return nil
  end
  return read_json_file(M.page_path(path, pno))
end

---快速取 PDF 元信息（页数），不抽正文
---@param path string
---@param force boolean|nil
---@return table|nil meta_data, string|nil err
function M.pdf_meta(path, force)
  path = vim.fn.fnamemodify(path, ":p")
  local mp = M.meta_path(path)
  if not force and cache_fresh(path, mp) then
    local data = read_json_file(mp)
    -- 旧缓存无 toc 字段时重拉（大纲侧栏需要）
    if data and data.page_count and type(data.toc) == "table" then
      return data, nil
    end
  end
  local py = python_cmd()
  if not py then
    return nil, "python not found"
  end
  local script = plugin_root() .. "/scripts/extract.py"
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) ~= 1 then
    return nil, "extract script missing: " .. script
  end
  local out = vim.fn.system({ py, "-X", "utf8", script, path, "--meta" })
  if vim.v.shell_error ~= 0 then
    return nil, (out or ""):gsub("%s+$", "")
  end
  -- 可能夹杂 pymupdf 警告行，取最后一段 JSON
  local raw = (out or ""):gsub("^\239\187\191", ""):gsub("\r", "")
  local json_str = raw:match("(%b{})%s*$") or raw
  local ok, data = pcall(vim.json.decode, vim.trim(json_str))
  if not ok or type(data) ~= "table" or data.ok == false then
    return nil, (type(data) == "table" and data.error) or "meta parse failed"
  end
  write_json_file(mp, {
    path = path,
    mtime = data.mtime,
    size = data.size,
    page_count = data.page_count,
    meta = data.meta or {},
    toc = data.toc or {},
  })
  return data, nil
end

---同步提取 PDF 页范围 [from,to]（1-based），写入单页缓存并返回页列表
---@param path string
---@param from number
---@param to number
---@param force boolean|nil
---@return table|nil pages, string|nil err, table|nil header {page_count, meta, ...}
function M.extract_pdf_range(path, from, to, force)
  path = vim.fn.fnamemodify(path, ":p")
  from = math.max(1, tonumber(from) or 1)
  to = math.max(from, tonumber(to) or from)

  local json_path, img_dir = M.paths_for(path)
  vim.fn.mkdir(img_dir, "p")
  vim.fn.mkdir(M.cache_dir(path) .. "/pages", "p")

  -- 尽量用缓存填满
  local pages = {}
  local missing = {}
  if not force then
    for p = from, to do
      local cached = load_cached_page(path, p)
      if cached and cached.page then
        pages[#pages + 1] = cached
      else
        missing[#missing + 1] = p
      end
    end
  else
    for p = from, to do
      missing[#missing + 1] = p
    end
  end

  local header = nil
  if #missing == 0 then
    local meta = M.pdf_meta(path, false)
    return pages, nil, meta
  end

  -- 把 missing 收成连续区间批量提取
  table.sort(missing)
  local ranges = {}
  local a, b = missing[1], missing[1]
  for i = 2, #missing do
    if missing[i] == b + 1 then
      b = missing[i]
    else
      ranges[#ranges + 1] = { a, b }
      a, b = missing[i], missing[i]
    end
  end
  ranges[#ranges + 1] = { a, b }

  local py = python_cmd()
  if not py then
    return nil, "python not found", nil
  end
  local script = plugin_root() .. "/scripts/extract.py"
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) ~= 1 then
    return nil, "extract script missing: " .. script, nil
  end

  local cfg = config.get()
  local max_pages = tonumber(cfg.max_pages) or 0

  for _, rg in ipairs(ranges) do
    local r0, r1 = rg[1], rg[2]
    if max_pages > 0 then
      -- 全局上限：不超过 max_pages
      if r0 > max_pages then
        break
      end
      r1 = math.min(r1, max_pages)
    end
    local tmp = M.cache_dir(path) .. string.format("/range_%d_%d.json", r0, r1)
    local cmd = {
      py,
      "-X",
      "utf8",
      script,
      path,
      tmp,
      img_dir,
      "0",
      tostring(r0),
      tostring(r1),
    }
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      local msg = (out or ""):gsub("%s+$", "")
      if msg == "" then
        msg = "extract failed (exit " .. tostring(vim.v.shell_error) .. ")"
      end
      return nil, msg .. " (need: pip install pymupdf)", nil
    end
    local data = read_json_file(tmp)
    if data and data.pages then
      header = data
      for _, p in ipairs(data.pages) do
        pages[#pages + 1] = p
      end
    end
  end

  -- 排序 pages by page number
  table.sort(pages, function(x, y)
    return (x.page or 0) < (y.page or 0)
  end)

  if not header then
    header = M.pdf_meta(path, false)
  end
  return pages, nil, header
end

---构建带占位的完整 data（PDF 懒提取入口）
---@param path string
---@param initial_to number 先提取到第几页
---@param force boolean|nil
---@return table|nil data, string|nil err
function M.extract_pdf_lazy(path, initial_to, force)
  path = vim.fn.fnamemodify(path, ":p")
  local meta, err = M.pdf_meta(path, force)
  if not meta then
    return nil, err
  end
  local pc = tonumber(meta.page_count) or 0
  if pc < 1 then
    return nil, "empty PDF"
  end
  local cfg = config.get()
  local max_pages = tonumber(cfg.max_pages) or 0
  if max_pages > 0 then
    pc = math.min(pc, max_pages)
  end
  initial_to = math.max(1, math.min(pc, tonumber(initial_to) or 8))

  local data = {
    version = 2,
    kind = "pdf",
    path = path,
    mtime = meta.mtime,
    size = meta.size,
    meta = meta.meta or {},
    toc = meta.toc or {},
    page_count = pc,
    pages = {},
    lazy = true,
  }
  for i = 1, pc do
    data.pages[i] = pending_page(i)
  end

  local pages, e2, header = M.extract_pdf_range(path, 1, initial_to, force)
  if not pages then
    return nil, e2
  end
  if header and header.meta then
    data.meta = header.meta
  end
  merge_pages(data, pages)
  -- 轻量索引（不全量正文）
  local json_path = select(1, M.paths_for(path))
  write_json_file(json_path, {
    version = 2,
    path = path,
    page_count = pc,
    meta = data.meta,
    lazy = true,
    extracted_hint = initial_to,
  })
  return data, nil
end

---异步提取页范围；完成回调 on_done(ok, pages|nil, err)
---@param path string
---@param from number
---@param to number
---@param force boolean|nil
---@param on_done fun(ok:boolean, pages?:table[], err?:string)
---@return integer|nil job_id
function M.extract_pdf_range_async(path, from, to, force, on_done)
  path = vim.fn.fnamemodify(path, ":p")
  from = math.max(1, tonumber(from) or 1)
  to = math.max(from, tonumber(to) or from)
  on_done = on_done or function() end

  -- 已全部缓存则同步返回
  if not force then
    local all = {}
    local miss = false
    for p = from, to do
      local c = load_cached_page(path, p)
      if c then
        all[#all + 1] = c
      else
        miss = true
        break
      end
    end
    if not miss then
      vim.schedule(function()
        on_done(true, all, nil)
      end)
      return nil
    end
  end

  local py = python_cmd()
  if not py then
    vim.schedule(function()
      on_done(false, nil, "python not found")
    end)
    return nil
  end
  local script = plugin_root() .. "/scripts/extract.py"
  script = vim.fn.fnamemodify(script, ":p")
  local json_path, img_dir = M.paths_for(path)
  vim.fn.mkdir(img_dir, "p")
  local tmp = M.cache_dir(path) .. string.format("/range_%d_%d.json", from, to)
  local cmd = {
    py,
    "-X",
    "utf8",
    script,
    path,
    tmp,
    img_dir,
    "0",
    tostring(from),
    tostring(to),
  }
  local chunks = {}
  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            chunks[#chunks + 1] = line
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          on_done(false, nil, "extract exit " .. tostring(code) .. " " .. table.concat(chunks, " "))
          return
        end
        local data = read_json_file(tmp)
        if not data or not data.pages then
          on_done(false, nil, "invalid range json")
          return
        end
        on_done(true, data.pages, nil)
      end)
    end,
  })
  if job <= 0 then
    on_done(false, nil, "jobstart failed")
    return nil
  end
  return job
end

---兼容旧接口：全文/按 max_pages 提取（Word 仍用此路径；PDF 走懒提取）
---@param path string
---@param force boolean|nil
---@return table|nil data, string|nil err
function M.extract(path, force)
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "file not found: " .. path
  end

  local kind = M.kind_of(path)
  if not kind then
    return nil, "unsupported file type (pdf/docx/doc): " .. path
  end

  -- PDF：懒提取（首屏页数由 config.extract_chunk 控制）
  if kind == "pdf" then
    local cfg = config.get()
    local chunk = tonumber(cfg.extract_chunk) or 8
    local buf = tonumber(cfg.viewport_buffer) or 2
    local initial = math.max(chunk, 1 + buf * 2)
    return M.extract_pdf_lazy(path, initial, force)
  end

  local json_path, img_dir = M.paths_for(path)
  vim.fn.mkdir(img_dir, "p")

  if not force and cache_fresh(path, json_path) then
    local data = read_json_file(json_path)
    if data and data.pages then
      data.kind = kind
      return data, nil
    end
  end

  local py = python_cmd()
  if not py then
    return nil, "python not found"
  end

  local script = plugin_root() .. "/scripts/extract_docx.py"
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) ~= 1 then
    return nil, "extract script missing: " .. script
  end

  local cmd = {
    py,
    "-X",
    "utf8",
    script,
    path,
    json_path,
    img_dir,
  }

  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    local msg = (out or ""):gsub("%s+$", "")
    if msg == "" then
      msg = "extract failed (exit " .. tostring(vim.v.shell_error) .. ")"
    end
    if kind == "doc" then
      msg = msg .. " (.doc 需 LibreOffice soffice 转 docx，或另存为 .docx)"
    end
    return nil, msg
  end

  local data = read_json_file(json_path)
  if not data then
    return nil, "invalid extract JSON"
  end
  data.kind = kind
  return data, nil
end

---确保 data 中 [from,to] 页已提取；若有缺失则同步提取并 merge
---@param path string
---@param data table
---@param from number
---@param to number
---@param force boolean|nil
---@return boolean ok, string|nil err
function M.ensure_pages_sync(path, data, from, to, force)
  if not data or not data.pages then
    return false, "no data"
  end
  local pc = data.page_count or #data.pages
  from = math.max(1, from)
  to = math.min(pc, to)
  local need = false
  for p = from, to do
    if force or not M.page_ready(data, p) then
      need = true
      break
    end
  end
  if not need then
    return true, nil
  end
  local pages, err = M.extract_pdf_range(path, from, to, force)
  if not pages then
    return false, err
  end
  merge_pages(data, pages)
  return true, nil
end

---异步 ensure；on_done(ok, changed, err)
---@param path string
---@param data table
---@param from number
---@param to number
---@param force boolean|nil
---@param on_done fun(ok:boolean, changed:boolean, err?:string)
---@return integer|nil job_id
function M.ensure_pages_async(path, data, from, to, force, on_done)
  on_done = on_done or function() end
  if not data or not data.pages then
    on_done(false, false, "no data")
    return nil
  end
  local pc = data.page_count or #data.pages
  from = math.max(1, from)
  to = math.min(pc, to)
  local miss_from, miss_to = nil, nil
  for p = from, to do
    if force or not M.page_ready(data, p) then
      miss_from = miss_from or p
      miss_to = p
    end
  end
  if not miss_from then
    on_done(true, false, nil)
    return nil
  end
  return M.extract_pdf_range_async(path, miss_from, miss_to, force, function(ok, pages, err)
    if not ok then
      on_done(false, false, err)
      return
    end
    merge_pages(data, pages or {})
    on_done(true, true, nil)
  end)
end

return M
