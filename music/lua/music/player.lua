---@mod music.player Python daemon backend (progress / volume / seek)
--- One long-lived `scripts/player.py` process; JSON-lines over stdin/stdout.
--- Not ffplay/mpv fire-and-forget — full control of position and volume.
local M = {}

local default_cfg = {
  backend = "python", ---@type "python"|"auto"
  volume = 70,
  loop = false,
  python = "python",
}

local cfg = vim.deepcopy(default_cfg)

---@class MusicPlayerState
---@field backend string|nil
---@field status "idle"|"playing"|"paused"|"stopped"
---@field path string|nil
---@field title string|nil
---@field volume number
---@field loop boolean
---@field position number
---@field duration number|nil
---@field job_id number|nil

local state = {
  backend = nil,
  status = "idle",
  path = nil,
  title = nil,
  volume = 70,
  loop = false,
  position = 0,
  duration = nil,
  job_id = nil,
}

---@type fun()|nil
local on_ended_cb = nil
---@type fun()|nil
local on_status_cb = nil

--- Serialize outgoing requests; avoid interleaved stdin writes
local send_queue = {}
local sending = false

local function basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function fire_status()
  if on_status_cb then
    vim.schedule(on_status_cb)
  end
end

local function fire_ended()
  if on_ended_cb then
    vim.schedule(on_ended_cb)
  end
end

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function player_script()
  return plugin_root() .. "/scripts/player.py"
end

local function apply_payload(msg)
  if type(msg) ~= "table" then
    return
  end
  if msg.ok == false then
    if msg.error then
      vim.schedule(function()
        vim.notify("music: " .. tostring(msg.error), vim.log.levels.ERROR)
      end)
    end
    return
  end

  if msg.backend then
    state.backend = msg.backend
  end
  if msg.path ~= nil then
    state.path = msg.path
    if msg.path and msg.path ~= "" then
      state.title = basename(msg.path)
    end
  end
  if msg.status then
    state.status = msg.status
  end
  if type(msg.position) == "number" then
    state.position = msg.position
  end
  if type(msg.duration) == "number" then
    state.duration = msg.duration
  elseif msg.duration == nil and msg.event == "status" then
    -- keep previous
  end
  if type(msg.volume) == "number" then
    state.volume = msg.volume
  end
  if msg.loop ~= nil then
    state.loop = not not msg.loop
  end

  if msg.event == "ended" then
    state.status = "stopped"
    fire_status()
    fire_ended()
    return
  end

  if msg.event == "status" or msg.event == "ready" or msg.event == "pong" then
    fire_status()
  end
end

local function on_stdout(_, data, _)
  if type(data) ~= "table" then
    return
  end
  for _, line in ipairs(data) do
    if line and line ~= "" then
      local ok, msg = pcall(vim.json.decode, line)
      if ok and type(msg) == "table" then
        apply_payload(msg)
      end
    end
  end
end

local function kill_job()
  if state.job_id and state.job_id > 0 then
    pcall(vim.fn.jobstop, state.job_id)
  end
  state.job_id = nil
end

local function ensure_daemon()
  if state.job_id and state.job_id > 0 then
    return true, nil
  end

  local script = player_script()
  if vim.fn.filereadable(script) ~= 1 then
    return false, "missing " .. script
  end

  local py = cfg.python or "python"
  local job = vim.fn.jobstart({ py, "-X", "utf8", "-u", script }, {
    cwd = plugin_root(),
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = on_stdout,
    on_stderr = function(_, data, _)
      if type(data) ~= "table" then
        return
      end
      local msg = table.concat(data, "\n")
      -- ignore pygame/setuptools noise
      if msg:match("UserWarning") or msg:match("pkg_resources") or msg:match("Hello from the pygame") then
        return
      end
      if msg:match("%S") then
        vim.schedule(function()
          vim.notify("music(python): " .. msg:gsub("%s+$", ""), vim.log.levels.WARN)
        end)
      end
    end,
    on_exit = function()
      state.job_id = nil
      if state.status == "playing" or state.status == "paused" then
        state.status = "stopped"
        fire_status()
      end
    end,
  })

  if not job or job <= 0 then
    return false, "无法启动 Python 播放进程（检查 python / pygame）"
  end
  state.job_id = job
  state.backend = "python"
  return true, nil
end

local function flush_send()
  if sending then
    return
  end
  if not state.job_id or state.job_id <= 0 then
    send_queue = {}
    return
  end
  local item = table.remove(send_queue, 1)
  if not item then
    return
  end
  sending = true
  local ok = pcall(vim.fn.chansend, state.job_id, item)
  sending = false
  if not ok then
    -- channel dead
    state.job_id = nil
    send_queue = {}
    return
  end
  -- schedule next
  if #send_queue > 0 then
    vim.schedule(flush_send)
  end
end

---@param obj table
local function send(obj)
  local ok_d, err = ensure_daemon()
  if not ok_d then
    return false, err
  end
  local payload = vim.json.encode(obj) .. "\n"
  table.insert(send_queue, payload)
  flush_send()
  return true, nil
end

---@param user_cfg table|nil
function M.setup(user_cfg)
  cfg = vim.tbl_deep_extend("force", default_cfg, user_cfg or {})
  state.volume = cfg.volume
  state.loop = cfg.loop
end

function M.get_config()
  return cfg
end

function M.get_state()
  return state
end

function M.on_ended(cb)
  on_ended_cb = cb
end

function M.on_status(cb)
  on_status_cb = cb
end

---@return string|nil
function M.resolve_backend()
  return "python"
end

function M.backend_name()
  return state.backend or "python"
end

---@param path string
---@param start_pos number|nil
---@return boolean, string|nil
function M.play(path, start_pos)
  if not path or path == "" then
    return false, "路径为空"
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    return false, "文件不存在: " .. path
  end
  state.path = path
  state.title = basename(path)
  local ok, err = send({
    cmd = "play",
    path = path,
    start = start_pos or 0,
    volume = state.volume,
    loop = state.loop,
  })
  if not ok then
    return false, err
  end
  state.status = "playing"
  state.position = start_pos or 0
  fire_status()
  return true, nil
end

function M.stop()
  state.status = "stopped"
  send({ cmd = "stop" })
  fire_status()
end

function M.pause()
  if state.status ~= "playing" then
    return false, "当前未在播放"
  end
  local ok, err = send({ cmd = "pause" })
  if ok then
    state.status = "paused"
    fire_status()
  end
  return ok, err
end

function M.resume()
  if state.status == "playing" then
    return true, nil
  end
  if state.path and (state.status == "stopped" or state.status == "idle") then
    return M.play(state.path, state.position or 0)
  end
  local ok, err = send({ cmd = "resume" })
  if ok then
    state.status = "playing"
    fire_status()
  end
  return ok, err
end

function M.toggle()
  if state.status == "playing" then
    return M.pause()
  end
  return M.resume()
end

---@param vol number
function M.set_volume(vol)
  vol = math.max(0, math.min(100, math.floor(vol + 0.5)))
  state.volume = vol
  send({ cmd = "volume", volume = vol })
  fire_status()
  return vol
end

function M.volume_up(step)
  return M.set_volume(state.volume + (step or 5))
end

function M.volume_down(step)
  return M.set_volume(state.volume - (step or 5))
end

function M.set_loop(on)
  if on == nil then
    state.loop = not state.loop
  else
    state.loop = not not on
  end
  send({ cmd = "loop", loop = state.loop })
  fire_status()
  return state.loop
end

---@param seconds number absolute
function M.seek_abs(seconds)
  seconds = math.max(0, seconds)
  if state.duration and seconds > state.duration then
    seconds = state.duration
  end
  state.position = seconds
  local ok, err = send({ cmd = "seek", position = seconds })
  fire_status()
  return ok, err
end

---@param delta number
function M.seek(delta)
  return M.seek_abs((state.position or 0) + delta)
end

---Ask daemon for fresh status (position/duration).
function M.poll()
  send({ cmd = "status" })
  return state
end

function M.is_active()
  return state.status == "playing" or state.status == "paused"
end

---Stop daemon process (hide buffer / leave nvim).
function M.shutdown()
  state.status = "stopped"
  if state.job_id and state.job_id > 0 then
    pcall(vim.fn.chansend, state.job_id, vim.json.encode({ cmd = "quit" }) .. "\n")
    vim.defer_fn(function()
      kill_job()
    end, 150)
  else
    kill_job()
  end
  send_queue = {}
  fire_status()
end

---Compat name used by older code paths
function M.kill_all_ffplay()
  -- no-op: python backend does not spawn ffplay
end

return M
