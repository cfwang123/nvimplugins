---@mod pdfview.extract
--- 调用 extract.py / extract_docx.py，缓存 JSON + 导出图片
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

  local json_path, img_dir = M.paths_for(path)
  vim.fn.mkdir(img_dir, "p")

  if not force and cache_fresh(path, json_path) then
    local ok, data = pcall(function()
      local lines = vim.fn.readfile(json_path)
      return vim.json.decode(table.concat(lines, "\n"))
    end)
    if ok and type(data) == "table" and data.pages then
      return data, nil
    end
  end

  local py = python_cmd()
  if not py then
    return nil, "python not found"
  end

  local script
  if kind == "pdf" then
    script = plugin_root() .. "/scripts/extract.py"
  else
    script = plugin_root() .. "/scripts/extract_docx.py"
  end
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) ~= 1 then
    return nil, "extract script missing: " .. script
  end

  local cfg = config.get()
  local cmd
  if kind == "pdf" then
    local max_pages = tonumber(cfg.max_pages) or 0
    cmd = {
      py,
      "-X",
      "utf8",
      script,
      path,
      json_path,
      img_dir,
      tostring(max_pages),
    }
  else
    cmd = {
      py,
      "-X",
      "utf8",
      script,
      path,
      json_path,
      img_dir,
    }
  end

  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    local msg = (out or ""):gsub("%s+$", "")
    if msg == "" then
      msg = "extract failed (exit " .. tostring(vim.v.shell_error) .. ")"
    end
    if kind == "pdf" then
      msg = msg .. " (need: pip install pymupdf)"
    elseif kind == "doc" then
      msg = msg .. " (.doc 需 LibreOffice soffice 转 docx，或另存为 .docx)"
    end
    return nil, msg
  end

  local ok, data = pcall(function()
    local lines = vim.fn.readfile(json_path)
    return vim.json.decode(table.concat(lines, "\n"))
  end)
  if not ok or type(data) ~= "table" then
    return nil, "invalid extract JSON: " .. tostring(data)
  end
  return data, nil
end

return M
