---@mod httpbuf.i18n
local M = {}
---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    title = " HTTP ",
    help = " r/Ctrl-Enter 发送  q 关闭  L 中英  e 编辑请求  y 复制响应 ",
    sending = "发送中…",
    done = "完成",
    fail = "失败",
    empty = "httpbuf: 空请求",
    no_url = "httpbuf: 未找到 URL（首行：METHOD URL）",
    curl_miss = "httpbuf: 未找到 curl，尝试 Python…",
    py_miss = "httpbuf: 需要 curl 或 Python3",
    sent = "httpbuf: 已发送 ",
    copied = "httpbuf: 已复制响应",
    lang_to_en = "httpbuf: UI → English",
    lang_to_zh = "httpbuf: UI → 中文",
    req_title = "请求",
    res_title = "响应",
    template = "GET https://httpbin.org/get\nAccept: application/json\n\n",
  },
  en = {
    title = " HTTP ",
    help = " r/Ctrl-Enter send  q close  L lang  e edit req  y copy body ",
    sending = "Sending…",
    done = "Done",
    fail = "Failed",
    empty = "httpbuf: empty request",
    no_url = "httpbuf: no URL (first line: METHOD URL)",
    curl_miss = "httpbuf: curl missing, trying Python…",
    py_miss = "httpbuf: need curl or Python3",
    sent = "httpbuf: sent ",
    copied = "httpbuf: response copied",
    lang_to_en = "httpbuf: UI → English",
    lang_to_zh = "httpbuf: UI → 中文",
    req_title = "Request",
    res_title = "Response",
    template = "GET https://httpbin.org/get\nAccept: application/json\n\n",
  },
}

function M.detect()
  local cands = { vim.v.lang, vim.env.LC_ALL, vim.env.LC_MESSAGES, vim.env.LANG }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" then
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
    if ok and type(out) == "string" and vim.trim(out):lower():match("^zh") then
      return "zh"
    end
  end
  return "zh"
end

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.load_prefs() or M.detect()
  end
  return lang
end

function M.get()
  return lang
end

function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  M.save_prefs()
  return lang
end

function M.t(key)
  local pack = STR[lang] or STR.zh
  return pack[key] or STR.zh[key] or key
end

local function prefs_path()
  return vim.fn.stdpath("data") .. "/httpbuf-nvim-prefs.json"
end

function M.load_prefs()
  local f = prefs_path()
  if vim.fn.filereadable(f) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(f), "\n"))
  end)
  if ok and type(data) == "table" and (data.ui_lang == "zh" or data.ui_lang == "en") then
    return data.ui_lang
  end
  return nil
end

function M.save_prefs()
  pcall(function()
    local f = prefs_path()
    vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
    vim.fn.writefile({ vim.json.encode({ ui_lang = lang }) }, f)
  end)
end

return M
