---@mod tablemode.i18n 中英文提示
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    enabled = "tablemode: 已开启",
    disabled = "tablemode: 已关闭",
    realigned = "tablemode: 已重新对齐",
    not_in_table = "tablemode: 光标不在表格内",
    tableized = "tablemode: 已转换为表格（%d 行）",
    deleted_row = "tablemode: 已删除 %d 行",
    deleted_col = "tablemode: 已删除 %d 列",
    inserted_col = "tablemode: 已插入 %d 列",
    empty_selection = "tablemode: 无内容可转换",
    delimiter_prompt = "分隔符（默认 ,）: ",
    status_on = "TABLE",
    status_off = "",
  },
  en = {
    enabled = "tablemode: enabled",
    disabled = "tablemode: disabled",
    realigned = "tablemode: realigned",
    not_in_table = "tablemode: cursor not in a table",
    tableized = "tablemode: tableized %d lines",
    deleted_row = "tablemode: deleted %d row(s)",
    deleted_col = "tablemode: deleted %d column(s)",
    inserted_col = "tablemode: inserted %d column(s)",
    empty_selection = "tablemode: nothing to tableize",
    delimiter_prompt = "Delimiter (default ,): ",
    status_on = "TABLE",
    status_off = "",
  },
}

function M.detect()
  local cands = {
    vim.v.lang,
    vim.v.ctype,
    vim.env.LC_ALL,
    vim.env.LC_MESSAGES,
    vim.env.LANG,
    vim.o.langmenu,
  }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" and c ~= "C" and c ~= "POSIX" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 then
    local ok, out = pcall(vim.fn.system, {
      "powershell",
      "-NoProfile",
      "-Command",
      "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
    })
    if ok and type(out) == "string" then
      local low = vim.trim(out):lower()
      if low:match("^zh") then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  return "zh"
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/tablemode-nvim-prefs.json"
end

function M.load_prefs()
  local f = prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" and (data.lang == "zh" or data.lang == "en") then
    return data.lang
  end
  return nil
end

function M.save_prefs()
  pcall(function()
    local f = prefs_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({ vim.json.encode({ lang = lang }) }, f)
  end)
end

---@param user_lang? string
function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    local remembered = M.load_prefs()
    if remembered then
      lang = remembered
    else
      lang = M.detect()
    end
  end
  return lang
end

function M.get()
  return lang
end

function M.set(l, opts)
  opts = opts or {}
  if l == "zh" or l == "en" then
    lang = l
    if opts.persist ~= false then
      M.save_prefs()
    end
  end
  return lang
end

function M.toggle(opts)
  lang = (lang == "zh") and "en" or "zh"
  if not opts or opts.persist ~= false then
    M.save_prefs()
  end
  return lang
end

---@param key string
---@param ... any
function M.t(key, ...)
  local pack = STR[lang] or STR.zh
  local s = pack[key] or (STR.en and STR.en[key]) or key
  if select("#", ...) > 0 then
    return string.format(s, ...)
  end
  return s
end

return M
