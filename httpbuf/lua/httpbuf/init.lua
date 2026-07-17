---@mod httpbuf 轻量 HTTP 请求编辑与响应查看
local i18n = require("httpbuf.i18n")

local M = {}

local default_config = {
  python = "python",
  timeout = 30,
  ui_lang = "auto",
  keys_open = "<leader>http",
  border = "rounded",
  ---优先 curl，否则 Python urllib
  prefer_curl = true,
}

local config = vim.deepcopy(default_config)
local setup_done = false
local keys_applied = {}

local state = {
  req_buf = nil,
  res_buf = nil,
  req_win = nil,
  res_win = nil,
  status = "",
  busy = false,
}

local NS = vim.api.nvim_create_namespace("httpbuf")

local function ensure_hl()
  pcall(vim.api.nvim_set_hl, 0, "HttpbufNormal", { fg = "#111111", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "HttpbufTitle", { fg = "#111111", bg = "#ffffff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "HttpbufHelp", { fg = "#666666", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "HttpbufBorder", { fg = "#4488cc", bg = "#ffffff", force = true })
  pcall(vim.api.nvim_set_hl, 0, "HttpbufStatus", { fg = "#006600", bg = "#ffffff", bold = true, force = true })
  pcall(vim.api.nvim_set_hl, 0, "HttpbufErr", { fg = "#aa0000", bg = "#ffffff", bold = true, force = true })
end

local function script_path()
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local root = vim.fn.fnamemodify(src, ":p:h:h:h")
  return root .. "/scripts/http_req.py"
end

local function resolve_python()
  local cands = { config.python, "python", "python3" }
  if vim.fn.has("win32") == 1 then
    table.insert(cands, "py")
  end
  for _, c in ipairs(cands) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      if c == "py" then
        return { "py", "-3" }
      end
      return { c }
    end
  end
  return nil
end

---解析 HTTP 文本块
---首行: METHOD URL
---随后 header 行 Key: Value，空行后 body
---@param lines string[]
---@return { method: string, url: string, headers: table<string,string>, body: string }|nil
---@return string|nil err
local function parse_request(lines)
  local clean = {}
  for _, l in ipairs(lines or {}) do
    clean[#clean + 1] = l:gsub("\r$", "")
  end
  -- 跳过前导空行
  local i = 1
  while i <= #clean and vim.trim(clean[i]) == "" do
    i = i + 1
  end
  if i > #clean then
    return nil, "empty"
  end
  local first = vim.trim(clean[i])
  local method, url = first:match("^(%S+)%s+(%S+)")
  if not method or not url then
    -- 仅 URL，默认 GET
    if first:match("^https?://") then
      method, url = "GET", first
    else
      return nil, "no_url"
    end
  end
  method = method:upper()
  i = i + 1
  local headers = {}
  while i <= #clean do
    local line = clean[i]
    if vim.trim(line) == "" then
      i = i + 1
      break
    end
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k and k ~= "" then
      headers[vim.trim(k)] = v or ""
    end
    i = i + 1
  end
  local body_lines = {}
  while i <= #clean do
    body_lines[#body_lines + 1] = clean[i]
    i = i + 1
  end
  local body = table.concat(body_lines, "\n")
  -- 去掉 body 末尾多余空行影响
  if body:match("^%s*$") then
    body = ""
  end
  return {
    method = method,
    url = url,
    headers = headers,
    body = body,
  }, nil
end

---@param req table
---@param on_done fun(ok: boolean, result: table)
local function send_with_curl(req, on_done)
  local args = { "curl", "-sS", "-i", "-X", req.method, "--max-time", tostring(config.timeout or 30) }
  for k, v in pairs(req.headers or {}) do
    table.insert(args, "-H")
    table.insert(args, k .. ": " .. v)
  end
  if req.body and req.body ~= "" and req.method ~= "GET" and req.method ~= "HEAD" then
    table.insert(args, "--data-binary")
    table.insert(args, req.body)
  end
  table.insert(args, req.url)

  if vim.system then
    vim.system(args, { text = true }, function(r)
      vim.schedule(function()
        local out = (r.stdout or "") .. (r.stderr or "")
        if (r.code or 0) ~= 0 and out == "" then
          on_done(false, { error = "curl exit " .. tostring(r.code) })
          return
        end
        on_done(true, { raw = out, via = "curl" })
      end)
    end)
  else
    local out = vim.fn.system(args)
    on_done(vim.v.shell_error == 0, { raw = out, via = "curl" })
  end
end

---@param req table
---@param on_done fun(ok: boolean, result: table)
local function send_with_python(req, on_done)
  local py = resolve_python()
  if not py then
    on_done(false, { error = "no python" })
    return
  end
  local script = script_path()
  if vim.fn.filereadable(script) ~= 1 then
    on_done(false, { error = "missing " .. script })
    return
  end
  local meta = {
    method = req.method,
    url = req.url,
    headers = req.headers,
    body = req.body,
    timeout = config.timeout or 30,
  }
  local tmp = vim.fn.tempname() .. "_httpbuf.json"
  pcall(vim.fn.writefile, { vim.json.encode(meta) }, tmp)
  local cmd = vim.list_extend({}, py)
  vim.list_extend(cmd, { "-X", "utf8", script, "--meta", tmp })
  if vim.system then
    vim.system(cmd, { text = true }, function(r)
      vim.schedule(function()
        pcall(vim.fn.delete, tmp)
        local out = (r.stdout or ""):gsub("^\239\187\191", "")
        local okj, data = pcall(vim.json.decode, vim.trim(out))
        if not okj or type(data) ~= "table" then
          on_done(false, { error = out ~= "" and out or ("exit " .. tostring(r.code)) })
          return
        end
        on_done(data.ok ~= false or data.status ~= nil, data)
      end)
    end)
  else
    local out = vim.fn.system(cmd)
    pcall(vim.fn.delete, tmp)
    out = tostring(out):gsub("^\239\187\191", "")
    local okj, data = pcall(vim.json.decode, vim.trim(out))
    if not okj then
      on_done(false, { error = out })
      return
    end
    on_done(true, data)
  end
end

local function format_response(data)
  local lines = {}
  if data.raw then
    -- curl -i 原始输出
    for s in (data.raw .. "\n"):gmatch("(.-)\n") do
      lines[#lines + 1] = s
    end
    return lines
  end
  if data.error and not data.status then
    return { "ERROR: " .. tostring(data.error) }
  end
  lines[#lines + 1] = string.format(
    "HTTP %s %s  (%s ms)",
    tostring(data.status or "?"),
    tostring(data.reason or ""),
    tostring(data.ms or "?")
  )
  lines[#lines + 1] = ""
  if type(data.headers) == "table" then
    local keys = {}
    for k in pairs(data.headers) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      lines[#lines + 1] = k .. ": " .. tostring(data.headers[k])
    end
  end
  lines[#lines + 1] = ""
  local body = data.body or ""
  for s in (body .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = s
  end
  return lines
end

local function set_res_lines(lines, hl)
  if not state.res_buf or not vim.api.nvim_buf_is_valid(state.res_buf) then
    return
  end
  local head = {
    i18n.t("res_title") .. "  ·  " .. (state.status or ""),
    i18n.t("help"),
    string.rep("─", 48),
  }
  local all = {}
  for _, l in ipairs(head) do
    all[#all + 1] = l
  end
  for _, l in ipairs(lines or {}) do
    all[#all + 1] = l
  end
  vim.bo[state.res_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.res_buf, 0, -1, false, all)
  vim.bo[state.res_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.res_buf, NS, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, state.res_buf, NS, 0, 0, {
    end_col = #all[1],
    hl_group = hl or "HttpbufStatus",
  })
  pcall(vim.api.nvim_buf_set_extmark, state.res_buf, NS, 1, 0, {
    end_col = #all[2],
    hl_group = "HttpbufHelp",
  })
end

function M.send()
  if state.busy then
    return
  end
  if not state.req_buf or not vim.api.nvim_buf_is_valid(state.req_buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(state.req_buf, 0, -1, false)
  local req, err = parse_request(lines)
  if not req then
    if err == "empty" then
      vim.notify(i18n.t("empty"), vim.log.levels.WARN)
    else
      vim.notify(i18n.t("no_url"), vim.log.levels.WARN)
    end
    return
  end
  state.busy = true
  state.status = i18n.t("sending")
  set_res_lines({ "…" }, "HttpbufHelp")

  local function finish(ok, data)
    state.busy = false
    if not ok and data and data.error then
      state.status = i18n.t("fail")
      set_res_lines({ tostring(data.error) }, "HttpbufErr")
      return
    end
    state.status = i18n.t("done")
      .. (data.status and ("  HTTP " .. tostring(data.status)) or "")
      .. (data.ms and ("  " .. tostring(data.ms) .. "ms") or "")
      .. (data.via and ("  via " .. data.via) or "")
    set_res_lines(format_response(data), ok and "HttpbufStatus" or "HttpbufErr")
    vim.notify(i18n.t("sent") .. req.method .. " " .. req.url, vim.log.levels.INFO)
  end

  local use_curl = config.prefer_curl ~= false and vim.fn.executable("curl") == 1
  if use_curl then
    send_with_curl(req, function(ok, data)
      if ok then
        finish(true, data)
      else
        -- fallback python
        vim.notify(i18n.t("curl_miss"), vim.log.levels.WARN)
        send_with_python(req, finish)
      end
    end)
  else
    if not resolve_python() then
      state.busy = false
      vim.notify(i18n.t("py_miss"), vim.log.levels.ERROR)
      return
    end
    send_with_python(req, finish)
  end
end

local function close_ui()
  for _, w in ipairs({ state.req_win, state.res_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for _, b in ipairs({ state.req_buf, state.res_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  state.req_buf, state.res_buf, state.req_win, state.res_win = nil, nil, nil, nil
  state.busy = false
end

local function bind_common(buf)
  local o = { buffer = buf, silent = true, nowait = true, noremap = true }
  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, vim.tbl_extend("force", o, { desc = "httpbuf: " .. desc }))
  end
  map("n", "q", close_ui, "close")
  map("n", "<Esc>", close_ui, "close")
  map("n", "r", M.send, "send")
  map("n", "<C-CR>", M.send, "send")
  map("i", "<C-CR>", function()
    vim.cmd("stopinsert")
    M.send()
  end, "send")
  map("n", "L", function()
    local l = i18n.toggle()
    vim.notify(l == "en" and i18n.t("lang_to_en") or i18n.t("lang_to_zh"), vim.log.levels.INFO)
    -- 刷新 help 行
    if state.res_buf and vim.api.nvim_buf_is_valid(state.res_buf) then
      local cur = vim.api.nvim_buf_get_lines(state.res_buf, 3, -1, false)
      set_res_lines(cur, "HttpbufStatus")
    end
  end, "lang")
  map("n", "y", function()
    if not state.res_buf or not vim.api.nvim_buf_is_valid(state.res_buf) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(state.res_buf, 3, -1, false)
    local text = table.concat(lines, "\n")
    pcall(vim.fn.setreg, "+", text)
    pcall(vim.fn.setreg, "*", text)
    vim.notify(i18n.t("copied"), vim.log.levels.INFO)
  end, "copy response")
  map("n", "e", function()
    if state.req_win and vim.api.nvim_win_is_valid(state.req_win) then
      vim.api.nvim_set_current_win(state.req_win)
    end
  end, "focus request")
end

---@param opts? { lines?: string[], text?: string }
function M.open(opts)
  opts = opts or {}
  M.ensure_setup()
  ensure_hl()
  close_ui()

  local req_buf = vim.api.nvim_create_buf(false, true)
  local res_buf = vim.api.nvim_create_buf(false, true)
  for _, b in ipairs({ req_buf, res_buf }) do
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
  end
  vim.bo[req_buf].filetype = "httpbuf"
  vim.bo[req_buf].modifiable = true
  vim.bo[res_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, req_buf, "httpbuf://request")
  pcall(vim.api.nvim_buf_set_name, res_buf, "httpbuf://response")

  local text = opts.text
  local init_lines
  if type(opts.lines) == "table" then
    init_lines = opts.lines
  elseif type(text) == "string" and text ~= "" then
    init_lines = vim.split(text, "\n", { plain = true })
  else
    init_lines = vim.split(i18n.t("template"), "\n", { plain = true })
  end
  vim.api.nvim_buf_set_lines(req_buf, 0, -1, false, init_lines)

  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.7)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local half = math.floor(width / 2) - 1

  local req_win = vim.api.nvim_open_win(req_buf, true, {
    relative = "editor",
    width = half,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = config.border or "rounded",
    title = " " .. i18n.t("req_title") .. " ",
    title_pos = "center",
    zindex = 55,
  })
  local res_win = vim.api.nvim_open_win(res_buf, false, {
    relative = "editor",
    width = width - half - 2,
    height = height,
    row = row,
    col = col + half + 2,
    style = "minimal",
    border = config.border or "rounded",
    title = " " .. i18n.t("res_title") .. " ",
    title_pos = "center",
    zindex = 55,
  })
  for _, w in ipairs({ req_win, res_win }) do
    pcall(function()
      vim.wo[w].wrap = true
      vim.wo[w].number = false
      vim.wo[w].signcolumn = "no"
      vim.wo[w].winhighlight =
        "Normal:HttpbufNormal,NormalFloat:HttpbufNormal,FloatBorder:HttpbufBorder,FloatTitle:HttpbufTitle"
    end)
  end

  state.req_buf = req_buf
  state.res_buf = res_buf
  state.req_win = req_win
  state.res_win = res_win
  state.status = ""
  bind_common(req_buf)
  bind_common(res_buf)
  set_res_lines({ i18n.t("help") }, "HttpbufHelp")
end

local function apply_keys()
  for _, lhs in ipairs(keys_applied) do
    pcall(vim.keymap.del, "n", lhs)
  end
  keys_applied = {}
  local lhs = config.keys_open
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, function()
      M.open({})
    end, { silent = true, desc = "httpbuf: open" })
    keys_applied[#keys_applied + 1] = lhs
  end
end

function M.setup(user)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), user or {})
  local lang = config.ui_lang
  if user and (user.ui_lang == "zh" or user.ui_lang == "en" or user.ui_lang == "auto") then
    lang = user.ui_lang
  end
  if lang == "zh" or lang == "en" then
    i18n.setup(lang)
  else
    i18n.setup("auto")
  end
  apply_keys()
  setup_done = true
  return config
end

function M.ensure_setup()
  if not setup_done then
    M.setup({})
  end
  return config
end

---供命令：对当前 buffer 当请求发送
function M.send_current_buf()
  M.ensure_setup()
  if not state.req_buf or not vim.api.nvim_buf_is_valid(state.req_buf) then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    M.open({ lines = lines })
  end
  vim.schedule(function()
    M.send()
  end)
end

return M
