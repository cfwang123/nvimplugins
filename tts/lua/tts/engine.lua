---@mod tts.engine SAPI Python daemon client
local M = {}

local cfg = {
  python = "python",
  volume = 80,
  rate = 0,
}

local state = {
  status = "idle", ---@type string
  index = 0,
  total = 0,
  volume = 80,
  rate = 0,
  voice = "",
  text = "",
  voices = {}, ---@type table[]
  job_id = nil,
  segments = {}, ---@type string[]
  --- 与 daemon speak 世代对齐；忽略旧线程迟到事件，防止高亮乱跳
  gen = 0,
}

local on_status ---@type fun()|nil
local on_segment ---@type fun(i:number,total:number,text:string)|nil
local on_ended ---@type fun()|nil

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function script_path()
  return plugin_root() .. "/scripts/sapi_tts.py"
end

local function python_cmd()
  local py = cfg.python or "python"
  if vim.fn.executable(py) == 1 then
    return py
  end
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  return nil
end

local function apply(msg)
  if type(msg) ~= "table" then
    return
  end
  if msg.ok == false then
    if msg.error then
      vim.schedule(function()
        vim.notify("tts: " .. tostring(msg.error), vim.log.levels.ERROR)
      end)
    end
    return
  end
  local ev = msg.event

  -- 播放相关事件带 gen：丢弃旧会话迟到的 segment/status/ended
  local playback_ev = (ev == "segment" or ev == "status" or ev == "ended")
  if playback_ev and type(msg.gen) == "number" then
    if msg.gen < state.gen then
      return
    end
    if msg.gen > state.gen then
      state.gen = msg.gen
    end
  end

  if ev == "ready" or ev == "voices" then
    if ev == "ready" then
      -- daemon 进程重启后世代从 0 计
      state.gen = 0
    end
    if type(msg.voices) == "table" then
      state.voices = msg.voices
    end
    if msg.voice then
      state.voice = msg.voice
    end
  end
  if msg.status then
    state.status = msg.status
  end
  if type(msg.index) == "number" then
    state.index = msg.index
  end
  if type(msg.total) == "number" then
    state.total = msg.total
  end
  if type(msg.volume) == "number" then
    state.volume = msg.volume
  end
  if type(msg.rate) == "number" then
    state.rate = msg.rate
  end
  if msg.voice then
    state.voice = msg.voice
  end
  if msg.text then
    state.text = msg.text
  end

  if ev == "segment" then
    if on_segment then
      local idx = msg.index or 0
      local total = msg.total or 0
      local text = msg.text or ""
      vim.schedule(function()
        on_segment(idx, total, text)
      end)
    end
  end
  if ev == "ended" then
    if on_ended then
      vim.schedule(on_ended)
    end
  end
  if on_status and (ev == "status" or ev == "segment" or ev == "ended" or ev == "ready") then
    vim.schedule(on_status)
  end
end

local function on_stdout(_, data)
  if type(data) ~= "table" then
    return
  end
  for _, line in ipairs(data) do
    if line and line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        apply(msg)
      end
    end
  end
end

function M.setup(user)
  cfg = vim.tbl_deep_extend("force", cfg, user or {})
  state.volume = cfg.volume or 80
  state.rate = cfg.rate or 0
end

function M.get_state()
  return state
end

function M.on_status(cb)
  on_status = cb
end

function M.on_segment(cb)
  on_segment = cb
end

function M.on_ended(cb)
  on_ended = cb
end

function M.ensure()
  if state.job_id and vim.fn.jobwait({ state.job_id }, 0)[1] == -1 then
    return true
  end
  local py = python_cmd()
  if not py then
    vim.notify(require("tts.ui").t("py_missing"), vim.log.levels.ERROR)
    return false
  end
  local script = script_path()
  if vim.fn.filereadable(script) ~= 1 then
    vim.notify(require("tts.ui").t("script_missing") .. script, vim.log.levels.ERROR)
    return false
  end
  local jid = vim.fn.jobstart({ py, "-X", "utf8", script }, {
    rpc = false,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = on_stdout,
    on_stderr = function(_, data)
      if type(data) == "table" then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            vim.schedule(function()
              vim.notify("tts: " .. line, vim.log.levels.WARN)
            end)
          end
        end
      end
    end,
    on_exit = function()
      state.job_id = nil
      state.status = "idle"
    end,
  })
  if not jid or jid <= 0 then
    vim.notify(require("tts.ui").t("daemon_fail"), vim.log.levels.ERROR)
    return false
  end
  state.job_id = jid
  return true
end

function M.send(obj)
  if not M.ensure() then
    return false
  end
  local line = vim.json.encode(obj) .. "\n"
  local ok = pcall(vim.fn.chansend, state.job_id, line)
  return ok
end

---@param segments string[]
---@param opts? { voice?: string, volume?: number, rate?: number, start?: number }
function M.speak(segments, opts)
  opts = opts or {}
  state.segments = segments or {}
  -- 先抬高本地 gen，避免旧线程在新 speak 发出前的迟到事件改高亮
  state.gen = (state.gen or 0) + 1
  state.index = opts.start or 0
  state.total = #(segments or {})
  state.status = "playing"
  M.send({
    cmd = "speak",
    segments = segments,
    voice = opts.voice,
    volume = opts.volume or state.volume or cfg.volume,
    rate = opts.rate or state.rate or cfg.rate,
    start = opts.start or 0,
  })
end

function M.stop()
  M.send({ cmd = "stop" })
end

function M.pause()
  M.send({ cmd = "pause" })
end

function M.resume()
  M.send({ cmd = "resume" })
end

function M.toggle()
  M.send({ cmd = "toggle" })
end

function M.goto_index(i)
  M.send({ cmd = "goto", index = i })
end

function M.set_volume(v)
  state.volume = v
  M.send({ cmd = "volume", volume = v })
end

function M.set_rate(r)
  state.rate = r
  M.send({ cmd = "rate", rate = r })
end

function M.set_voice(name)
  M.send({ cmd = "voice", voice = name })
end

function M.list_voices()
  M.send({ cmd = "voices" })
end

function M.shutdown()
  if state.job_id then
    pcall(vim.fn.chansend, state.job_id, vim.json.encode({ cmd = "quit" }) .. "\n")
    pcall(vim.fn.jobstop, state.job_id)
    state.job_id = nil
  end
end

---按语言选发音人（模糊匹配）
---@param lang "zh"|"en"
---@param voices table[]|nil
---@return string|nil
function M.pick_voice(lang, voices)
  voices = voices or state.voices
  if not voices or #voices == 0 then
    return nil
  end
  local prefer
  if lang == "zh" then
    prefer = { "huihui", "yaoyao", "kangkang", "chinese", "zh%-cn", "zh.cn" }
  else
    prefer = { "zira", "david", "mark", "hazel", "english", "en%-us", "en.us" }
  end
  for _, key in ipairs(prefer) do
    for _, v in ipairs(voices) do
      local name = (v.name or ""):lower()
      local cult = (v.culture or ""):lower()
      if name:find(key, 1, true) or cult:find(key, 1, true) then
        return v.name
      end
    end
  end
  -- culture 含 Chinese / English
  local needle = lang == "zh" and "chinese" or "english"
  for _, v in ipairs(voices) do
    local blob = ((v.name or "") .. " " .. (v.culture or "")):lower()
    if blob:find(needle, 1, true) then
      return v.name
    end
  end
  return voices[1] and voices[1].name or nil
end

return M
