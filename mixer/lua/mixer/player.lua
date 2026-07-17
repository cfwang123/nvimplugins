---@mod mixer.player Python winmm MIDI daemon client
local M = {}

local cfg = {
  python = "python",
  volume = 70,
}

local state = {
  status = "idle",
  title = "",
  volume = 70,
  position = 0,
  duration = 0,
  tracks = {},
  presets = {},
  preset = "",
  job_id = nil,
  ready = false,
  --- 加载完成后自动 play
  pending_play = false,
}

local on_status ---@type fun()|nil

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function script_path()
  return plugin_root() .. "/scripts/midi_synth.py"
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
        vim.notify("mixer: " .. tostring(msg.error), vim.log.levels.ERROR)
      end)
    end
    return
  end
  if msg.event == "ready" or msg.event == "presets" then
    state.ready = true
    if type(msg.presets) == "table" then
      state.presets = msg.presets
    end
  end
  if msg.status then
    state.status = msg.status
  end
  if msg.title then
    state.title = msg.title
  end
  if type(msg.volume) == "number" then
    state.volume = msg.volume
  end
  if type(msg.position) == "number" then
    state.position = msg.position
  end
  if type(msg.duration) == "number" then
    state.duration = msg.duration
  end
  if type(msg.tracks) == "table" then
    state.tracks = msg.tracks
  end
  if msg.preset then
    state.preset = msg.preset
  end
  -- 加载完成 → 若请求了自动播放（不依赖 duration，部分 MCI 长度可能为 0）
  if state.pending_play and msg.event == "status" and msg.status == "stopped" and (msg.title or "") ~= "" then
    state.pending_play = false
    vim.schedule(function()
      M.send({ cmd = "play" })
    end)
  end
  if on_status and (msg.event == "status" or msg.event == "ready" or msg.event == "ended" or msg.event == "presets") then
    vim.schedule(on_status)
  end
end

local function on_stdout(_, data)
  if type(data) ~= "table" then
    return
  end
  for _, line in ipairs(data) do
    if line and line ~= "" then
      -- 忽略非 JSON 行（pygame 等）
      if line:sub(1, 1) == "{" then
        local ok, msg = pcall(vim.json.decode, line)
        if ok then
          apply(msg)
        end
      end
    end
  end
end

function M.setup(user)
  cfg = vim.tbl_deep_extend("force", cfg, user or {})
  state.volume = cfg.volume or 70
end

function M.get_state()
  return state
end

function M.on_status(cb)
  on_status = cb
end

function M.ensure()
  if state.job_id and vim.fn.jobwait({ state.job_id }, 0)[1] == -1 then
    return true
  end
  local py = python_cmd()
  if not py then
    vim.notify(require("mixer.i18n").t("py_missing"), vim.log.levels.ERROR)
    return false
  end
  local script = script_path()
  if vim.fn.filereadable(script) ~= 1 then
    vim.notify(require("mixer.i18n").t("script_missing") .. script, vim.log.levels.ERROR)
    return false
  end
  state.ready = false
  local jid = vim.fn.jobstart({ py, "-X", "utf8", script }, {
    rpc = false,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = on_stdout,
    on_stderr = function(_, data)
      if type(data) ~= "table" then
        return
      end
      for _, line in ipairs(data) do
        if line and line ~= "" then
          if line:lower():find("error", 1, true) or line:lower():find("traceback", 1, true) then
            vim.schedule(function()
              vim.notify("mixer: " .. line, vim.log.levels.WARN)
            end)
          end
        end
      end
    end,
    on_exit = function()
      state.job_id = nil
      state.ready = false
      state.status = "idle"
    end,
  })
  if not jid or jid <= 0 then
    vim.notify(require("mixer.i18n").t("daemon_fail"), vim.log.levels.ERROR)
    return false
  end
  state.job_id = jid
  -- 短等 ready（预热后几乎立刻）
  vim.wait(600, function()
    return state.ready
  end, 15)
  return true
end

---后台预热 daemon，避免首次打开卡 10s
function M.warmup()
  vim.defer_fn(function()
    pcall(M.ensure)
  end, 200)
end

function M.send(obj)
  if not M.ensure() then
    return false
  end
  local line = vim.json.encode(obj) .. "\n"
  return pcall(vim.fn.chansend, state.job_id, line)
end

---@param name string
---@param play_after? boolean
function M.load_preset(name, play_after)
  if play_after then
    state.pending_play = true
  end
  M.send({ cmd = "load_preset", name = name })
end

---@param path string
---@param play_after? boolean
function M.load_path(path, play_after)
  if play_after then
    state.pending_play = true
  end
  M.send({ cmd = "load", path = path })
end

function M.play()
  state.pending_play = false
  M.send({ cmd = "play" })
end

function M.pause()
  M.send({ cmd = "pause" })
end

function M.toggle()
  M.send({ cmd = "toggle" })
end

function M.stop()
  M.send({ cmd = "stop" })
end

function M.set_volume(v)
  state.volume = v
  M.send({ cmd = "volume", volume = v })
end

function M.list_presets()
  M.send({ cmd = "presets" })
end

function M.shutdown()
  if state.job_id then
    pcall(vim.fn.chansend, state.job_id, vim.json.encode({ cmd = "quit" }) .. "\n")
    pcall(vim.fn.jobstop, state.job_id)
    state.job_id = nil
  end
end

return M
