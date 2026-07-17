---@mod xlsview.extract
local config = require("xlsview.config")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function python_cmd(cfg)
  cfg = cfg or config.get()
  local py = cfg.python or "python"
  if vim.fn.executable(py) == 1 then
    return py
  end
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  return nil
end

function M.cache_dir(path)
  path = vim.fn.fnamemodify(path, ":p")
  local key = vim.fn.sha256(path)
  local dir = vim.fn.stdpath("cache") .. "/xlsview/" .. key:sub(1, 24)
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.kind_of(path)
  if not path or path == "" then
    return nil
  end
  local lower = path:lower()
  if lower:match("%.xlsx$") or lower:match("%.xlsm$") or lower:match("%.xltx$") or lower:match("%.xltm$") then
    return "xlsx"
  end
  return nil
end

function M.is_supported(path)
  return M.kind_of(path) ~= nil
end

local function cache_fresh(path, json_path)
  if vim.fn.filereadable(json_path) ~= 1 then
    return false
  end
  local mtime = vim.fn.getftime(path)
  local jm = vim.fn.getftime(json_path)
  return mtime >= 0 and jm >= 0 and mtime <= jm
end

function M.extract(path, force)
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "file not found: " .. path
  end
  if not M.is_supported(path) then
    return nil, "unsupported (need .xlsx/.xlsm): " .. path
  end

  local dir = M.cache_dir(path)
  local json_path = dir .. "/book.json"

  if not force and cache_fresh(path, json_path) then
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(json_path), "\n"))
    end)
    if ok and type(data) == "table" and data.sheets then
      return data, nil
    end
  end

  local py = python_cmd()
  if not py then
    return nil, "python not found"
  end
  local script = vim.fn.fnamemodify(plugin_root() .. "/scripts/extract.py", ":p")
  if vim.fn.filereadable(script) ~= 1 then
    return nil, "extract.py missing: " .. script
  end

  local cfg = config.get()
  local cmd = {
    py,
    "-X",
    "utf8",
    script,
    path,
    json_path,
    tostring(cfg.max_rows or 500),
    tostring(cfg.max_cols or 64),
  }
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    local msg = (out or ""):gsub("%s+$", "")
    if msg == "" then
      msg = "extract failed"
    end
    return nil, msg .. " (need: pip install openpyxl)"
  end

  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(json_path), "\n"))
  end)
  if not ok or type(data) ~= "table" then
    return nil, "invalid JSON: " .. tostring(data)
  end
  return data, nil
end

return M
