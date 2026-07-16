---@mod music.player Audio backends (mpv preferred, ffplay fallback)
local M = {}

local default_cfg = {
  backend = "auto", ---@type "auto"|"mpv"|"ffplay"
  volume = 70,
  loop = false,
  mpv_path = "mpv",
  ffplay_path = "ffplay",
  ffprobe_path = "ffprobe",
  ipc_name = "nvim-music-mpv",
}

local cfg = vim.deepcopy(default_cfg)

---@class MusicPlayerState
---@field backend "mpv"|"ffplay"|nil
---@field status "idle"|"playing"|"paused"|"stopped"
---@field path string|nil
---@field title string|nil
---@field volume number
---@field loop boolean
---@field position number seconds
---@field duration number|nil
---@field job_id number|nil
---@field mpv_socket string|nil
---@field started_at number|nil monotonic for ffplay estimate
---@field base_pos number position at start/resume for ffplay

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
  mpv_socket = nil,
  started_at = nil,
  base_pos = 0,
}

---@type fun()|nil
local on_ended_cb = nil
---@type fun()|nil
local on_status_cb = nil

local function is_win()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

local function executable(name)
  return name and name ~= "" and vim.fn.executable(name) == 1
end

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

local function now_sec()
  return vim.uv.hrtime() / 1e9
end

local function mpv_socket_path()
  if is_win() then
    return "\\\\.\\pipe\\" .. cfg.ipc_name
  end
  local dir = vim.fn.stdpath("cache")
  vim.fn.mkdir(dir, "p")
  return dir .. "/music-mpv.sock"
end

---@return "mpv"|"ffplay"|nil, string|nil
function M.resolve_backend()
  if cfg.backend == "mpv" then
    if executable(cfg.mpv_path) then
      return "mpv", nil
    end
    return nil, "backend=mpv 但未找到 mpv"
  end
  if cfg.backend == "ffplay" then
    if executable(cfg.ffplay_path) then
      return "ffplay", nil
    end
    return nil, "backend=ffplay 但未找到 ffplay"
  end
  if executable(cfg.mpv_path) then
    return "mpv", nil
  end
  if executable(cfg.ffplay_path) then
    return "ffplay", nil
  end
  return nil, "未找到播放器：请安装 mpv（推荐）或 ffplay"
end

---@param path string
---@return number|nil
function M.probe_duration(path)
  if not path or path == "" or not executable(cfg.ffprobe_path) then
    return nil
  end
  local out = vim.fn.system({
    cfg.ffprobe_path,
    "-v",
    "error",
    "-show_entries",
    "format=duration",
    "-of",
    "default=noprint_wrappers=1:nokey=1",
    path,
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local n = tonumber((out or ""):match("([%d%.]+)"))
  if n and n > 0 then
    return n
  end
  return nil
end

---Kill a process tree (Windows needs /T; jobstop alone often leaves ffplay alive).
---@param pid number|nil
local function kill_pid_tree(pid)
  if not pid or pid <= 0 then
    return
  end
  if is_win() then
    vim.fn.system({ "taskkill", "/PID", tostring(pid), "/T", "/F" })
  else
    pcall(vim.fn.system, { "kill", "-TERM", "--", "-" .. tostring(pid) })
    pcall(vim.fn.system, { "kill", "-KILL", tostring(pid) })
  end
end

local function kill_job()
  if state.job_id and state.job_id > 0 then
    local pid = nil
    pcall(function()
      pid = vim.fn.jobpid(state.job_id)
    end)
    pcall(vim.fn.jobstop, state.job_id)
    -- jobstop is sometimes soft; force-kill the tree
    kill_pid_tree(pid)
  end
  state.job_id = nil
end

---Kill every ffplay process on the machine (used on Neovim exit / emergency silence).
function M.kill_all_ffplay()
  if is_win() then
    -- /T kills child tree; ignore "not found"
    vim.fn.system("taskkill /IM ffplay.exe /F /T >nul 2>&1")
  else
    vim.fn.system("pkill -x ffplay >/dev/null 2>&1; killall -q ffplay >/dev/null 2>&1; true")
  end
end

---Send JSON IPC command to mpv.
---@param command table
---@return boolean
---@return string|nil
local function mpv_cmd(command)
  if not state.mpv_socket then
    return false, "no socket"
  end
  local payload = vim.json.encode({ command = command }) .. "\n"
  if is_win() then
    local ps = string.format(
      [[$n='%s'; $p=New-Object System.IO.Pipes.NamedPipeClientStream('.', $n, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None, [System.Security.Principal.TokenImpersonationLevel]::Impersonation); try { $p.Connect(600); $w=New-Object System.IO.StreamWriter($p); $w.AutoFlush=$true; $r=New-Object System.IO.StreamReader($p); $w.Write(%s); $line=$r.ReadLine(); $w.Dispose(); $r.Dispose(); $p.Dispose(); Write-Output $line } catch { exit 1 }]],
      cfg.ipc_name,
      vim.fn.json_encode(payload)
    )
    local out = vim.fn.system({ "powershell", "-NoProfile", "-Command", ps })
    if vim.v.shell_error ~= 0 then
      return false, out
    end
    return true, vim.trim(out or "")
  end

  if executable("socat") then
    local out = vim.fn.system({
      "sh",
      "-c",
      string.format("printf %%s %s | socat - %s", vim.fn.shellescape(payload), vim.fn.shellescape(state.mpv_socket)),
    })
    if vim.v.shell_error ~= 0 then
      return false, out
    end
    return true, vim.trim(out or "")
  end

  local py = [[
import socket,sys
s=socket.socket(socket.AF_UNIX)
s.settimeout(1.0)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode())
data=s.recv(8192).decode(errors='replace')
print(data.splitlines()[0] if data else '', end='')
s.close()
]]
  local out = vim.fn.system({ "python", "-c", py, state.mpv_socket, payload })
  if vim.v.shell_error ~= 0 then
    return false, out
  end
  return true, vim.trim(out or "")
end

local function mpv_get_property(name)
  local ok, resp = mpv_cmd({ "get_property", name })
  if not ok or not resp or resp == "" then
    return nil
  end
  local decoded = nil
  pcall(function()
    decoded = vim.json.decode(resp)
  end)
  if type(decoded) == "table" and decoded.error == "success" then
    return decoded.data
  end
  return nil
end

local function stop_backend_silent()
  if state.backend == "mpv" and state.mpv_socket then
    pcall(mpv_cmd, { "quit" })
  end
  kill_job()
  if state.mpv_socket and not is_win() then
    pcall(vim.fn.delete, state.mpv_socket)
  end
  state.mpv_socket = nil
  state.started_at = nil
end

---Stop managed player and force-kill leftover ffplay (Neovim exit).
function M.shutdown()
  state.status = "stopped"
  stop_backend_silent()
  M.kill_all_ffplay()
  fire_status()
end

---@param path string
---@param start_pos number|nil
local function start_mpv(path, start_pos)
  stop_backend_silent()
  local sock = mpv_socket_path()
  state.mpv_socket = sock
  state.backend = "mpv"
  start_pos = start_pos or 0

  local args = {
    cfg.mpv_path,
    "--no-video",
    "--force-window=no",
    "--idle=once",
    "--really-quiet",
    "--input-ipc-server=" .. sock,
    "--volume=" .. tostring(state.volume),
    "--start=" .. string.format("%.3f", start_pos),
    path,
  }
  if state.loop then
    table.insert(args, #args, "--loop-file=inf")
  end

  local job = vim.fn.jobstart(args, {
    detach = false,
    on_exit = function()
      state.job_id = nil
      if state.status == "playing" or state.status == "paused" then
        state.status = "stopped"
        state.position = state.duration or state.position or 0
        fire_status()
        fire_ended()
      end
    end,
  })
  if job <= 0 then
    state.mpv_socket = nil
    state.backend = nil
    return false, "无法启动 mpv"
  end
  state.job_id = job
  state.status = "playing"
  state.path = path
  state.title = basename(path)
  state.duration = M.probe_duration(path)
  state.position = start_pos
  fire_status()
  return true, nil
end

---@param path string
---@param start_pos number|nil
local function start_ffplay(path, start_pos)
  stop_backend_silent()
  state.backend = "ffplay"
  start_pos = start_pos or 0

  -- Keep args conservative: very old ffplay rejects -volume / -loop and exits.
  local args = {
    cfg.ffplay_path,
    "-nodisp",
    "-autoexit",
    "-loglevel",
    "quiet",
  }
  if start_pos > 0.05 then
    table.insert(args, "-ss")
    table.insert(args, string.format("%.3f", start_pos))
  end
  table.insert(args, path)

  local job = vim.fn.jobstart(args, {
    detach = false,
    on_exit = function()
      state.job_id = nil
      if state.status == "playing" then
        state.status = "stopped"
        if state.duration then
          state.position = state.duration
        end
        fire_status()
        if not state.loop then
          fire_ended()
        end
      end
    end,
  })
  if job <= 0 then
    state.backend = nil
    return false, "无法启动 ffplay"
  end
  state.job_id = job
  state.status = "playing"
  state.path = path
  state.title = basename(path)
  state.duration = M.probe_duration(path)
  state.position = start_pos
  state.base_pos = start_pos
  state.started_at = now_sec()
  fire_status()
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
  local backend, err = M.resolve_backend()
  if not backend then
    return false, err
  end
  start_pos = start_pos or 0
  if backend == "mpv" then
    return start_mpv(path, start_pos)
  end
  return start_ffplay(path, start_pos)
end

function M.stop()
  -- mark stopped first so on_exit won't treat it as natural end / auto-next
  state.status = "stopped"
  stop_backend_silent()
  fire_status()
end

function M.pause()
  if state.status ~= "playing" then
    return false, "当前未在播放"
  end
  if state.backend == "mpv" then
    M.poll()
    local ok = mpv_cmd({ "set_property", "pause", true })
    if ok then
      state.status = "paused"
      fire_status()
      return true, nil
    end
    return false, "mpv 暂停失败"
  end
  -- ffplay: kill process, keep position estimate
  M.poll()
  local pos = state.position or 0
  kill_job()
  state.status = "paused"
  state.position = pos
  state.started_at = nil
  state.base_pos = pos
  fire_status()
  return true, nil
end

function M.resume()
  if state.status == "playing" then
    return true, nil
  end
  if not state.path then
    return false, "没有曲目"
  end
  if state.status == "paused" and state.backend == "mpv" and state.job_id and state.job_id > 0 then
    local ok = mpv_cmd({ "set_property", "pause", false })
    if ok then
      state.status = "playing"
      fire_status()
      return true, nil
    end
  end
  local pos = state.position or 0
  return M.play(state.path, pos)
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
  if state.backend == "mpv" and (state.status == "playing" or state.status == "paused") then
    mpv_cmd({ "set_property", "volume", vol })
  end
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
  if state.backend == "mpv" and (state.status == "playing" or state.status == "paused") then
    mpv_cmd({ "set_property", "loop-file", state.loop and "inf" or "no" })
  end
  fire_status()
  return state.loop
end

---Seek to absolute seconds.
---@param seconds number
function M.seek_abs(seconds)
  seconds = math.max(0, seconds)
  if state.duration and seconds > state.duration then
    seconds = state.duration
  end
  if not state.path then
    return false, "没有曲目"
  end
  if state.backend == "mpv" and (state.status == "playing" or state.status == "paused") then
    local ok = mpv_cmd({ "seek", seconds, "absolute" })
    if ok then
      state.position = seconds
      fire_status()
      return true, nil
    end
  end
  -- ffplay or dead mpv: restart from position
  local was_paused = state.status == "paused"
  local ok, err = M.play(state.path, seconds)
  if not ok then
    return false, err
  end
  if was_paused then
    M.pause()
  end
  return true, nil
end

---@param delta number
function M.seek(delta)
  M.poll()
  return M.seek_abs((state.position or 0) + delta)
end

function M.poll()
  if state.backend == "mpv" and (state.status == "playing" or state.status == "paused") then
    local pos = mpv_get_property("time-pos")
    local dur = mpv_get_property("duration")
    if type(pos) == "number" then
      state.position = pos
    end
    if type(dur) == "number" and dur > 0 then
      state.duration = dur
    end
  elseif state.backend == "ffplay" and state.status == "playing" and state.started_at then
    local elapsed = now_sec() - state.started_at
    state.position = (state.base_pos or 0) + elapsed
    if state.duration and state.position > state.duration then
      state.position = state.duration
    end
  end
  return state
end

function M.is_active()
  return state.status == "playing" or state.status == "paused"
end

function M.backend_name()
  local b = M.resolve_backend()
  return b
end

return M
