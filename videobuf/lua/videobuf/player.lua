---@mod videobuf.player Python videod backend (JSON-lines IPC)
local M = {}

local default_cfg = {
  python = "python",
  volume = 30,
  loop = false,
  fps = 10,
}

local cfg = vim.deepcopy(default_cfg)

---@class VideobufPlayerState
---@field status "idle"|"playing"|"paused"|"stopped"
---@field path string|nil
---@field title string|nil
---@field volume number
---@field loop boolean
---@field fps number
---@field position number
---@field duration number|nil
---@field cols number
---@field rows number
---@field scale string
---@field mode string
---@field width number|nil
---@field height number|nil
---@field audio string|nil
---@field backend string|nil
---@field job_id number|nil
---@field last_frame table|nil
---@field last_error string|nil

local state = {
  status = "idle",
  path = nil,
  title = nil,
  volume = 30,
  loop = false,
  fps = 10,
  position = 0,
  duration = nil,
  cols = 80,
  rows = 24,
  scale = "fill",
  mode = "half",
  width = nil,
  height = nil,
  audio = nil,
  backend = nil,
  job_id = nil,
  last_frame = nil,
  last_error = nil,
  lines_in = 0,
  frames_in = 0,
  last_stderr = "",
}

---@type fun()|nil
local on_status_cb = nil
---@type fun(frame: table)|nil
local on_frame_cb = nil
---@type fun()|nil
local on_ended_cb = nil

local send_queue = {}
local sending = false
--- jobstart may split a long JSON line across callbacks
local stdout_buf = ""
local file_buf = ""
--- Windows 上 stdout 常失效：用事件文件轮询
local event_path = nil ---@type string|nil
local event_pos = 0
local boot_log_path = nil ---@type string|nil
local last_frame_seq = 0
---@type uv.uv_timer_t|nil
local event_timer = nil

--- 前向声明（Lua local 不能在定义前被其它 local function 当 upvalue 用）
local apply_payload

local function basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function ingest_line(line)
  if not line or line == "" then
    return
  end
  state.lines_in = (state.lines_in or 0) + 1
  local ok, msg = pcall(vim.json.decode, line)
  if ok and type(msg) == "table" then
    apply_payload(msg)
  else
    state.last_error = "json decode fail len=" .. tostring(#line)
    vim.schedule(function()
      pcall(function()
        require("videobuf").set_info("JSON解析失败 len=" .. tostring(#line))
      end)
    end)
  end
end

local function drain_buf(which)
  local buf = which == "file" and file_buf or stdout_buf
  while true do
    local nl = buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = buf:sub(1, nl - 1):gsub("\r$", "")
    buf = buf:sub(nl + 1)
    ingest_line(line)
  end
  if which == "file" then
    file_buf = buf
  else
    stdout_buf = buf
  end
end

--- 从事件文件增量读取（Windows 主 IPC 通道）
local function poll_event_file()
  if not event_path or event_path == "" then
    return
  end
  local f = io.open(event_path, "rb")
  if not f then
    return
  end
  f:seek("set", event_pos)
  local chunk = f:read("*a")
  local newpos = f:seek("cur")
  f:close()
  if not chunk or chunk == "" then
    return
  end
  event_pos = newpos or (event_pos + #chunk)
  file_buf = file_buf .. chunk
  drain_buf("file")
end

local function stop_event_timer()
  if event_timer then
    pcall(function()
      event_timer:stop()
      event_timer:close()
    end)
    event_timer = nil
  end
end

local function start_event_timer()
  stop_event_timer()
  event_timer = vim.uv.new_timer()
  if not event_timer then
    return
  end
  -- 50ms 轮询事件文件
  event_timer:start(50, 50, function()
    vim.schedule(poll_event_file)
  end)
end

local function resolve_python()
  local cands = { cfg.python, "python", "python3", "py" }
  for _, c in ipairs(cands) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      local full = vim.fn.exepath(c)
      if full and full ~= "" then
        return full
      end
      return c
    end
  end
  return cfg.python or "python"
end

local function fire_status()
  if on_status_cb then
    vim.schedule(on_status_cb)
  end
end

local function fire_frame(frame)
  if on_frame_cb then
    vim.schedule(function()
      on_frame_cb(frame)
    end)
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

local function daemon_script()
  return plugin_root() .. "/scripts/videod.py"
end

apply_payload = function(msg)
  if type(msg) ~= "table" then
    return
  end
  if msg.ok == false then
    if msg.error then
      state.last_error = tostring(msg.error)
      vim.schedule(function()
        vim.notify("videobuf: " .. tostring(msg.error), vim.log.levels.ERROR)
        pcall(function()
          require("videobuf").set_info("ERROR: " .. tostring(msg.error))
        end)
      end)
    end
    return
  end

  if msg.event == "frame" then
    -- 去重（stdout + 文件双通道）
    local seq = tonumber(msg.seq) or 0
    if seq > 0 and seq <= last_frame_seq then
      return
    end
    if seq > 0 then
      last_frame_seq = seq
    end
    local data = nil
    if type(msg.data) == "string" and msg.data ~= "" then
      data = msg.data
    end
    if (not data or data == "") and type(msg.b64) == "string" and msg.b64 ~= "" then
      if vim.base64 and vim.base64.decode then
        local okb, raw = pcall(vim.base64.decode, msg.b64)
        if okb and type(raw) == "string" then
          data = raw
        end
      end
    end
    if (not data or data == "") and type(msg.file) == "string" and msg.file ~= "" then
      local path = msg.file
      -- 兼容 / 与 \ 
      local candidates = { path, path:gsub("/", "\\"), path:gsub("\\", "/") }
      for _, p in ipairs(candidates) do
        local f = io.open(p, "rb")
        if f then
          local raw = f:read("*a")
          f:close()
          if raw and #raw > 0 then
            data = raw
            break
          end
        end
      end
      if not data then
        local ok_r, lines = pcall(vim.fn.readfile, path)
        if ok_r and type(lines) == "table" and #lines > 0 then
          data = table.concat(lines, "\n")
        end
      end
    end
    if data and #data > 0 then
      data = data:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\r\n")
      msg.data = data
    end
    state.last_frame = msg
    if type(msg.position) == "number" then
      state.position = msg.position
    end
    if type(msg.data) == "string" and #msg.data > 0 then
      state.frames_in = (state.frames_in or 0) + 1
      fire_frame(msg)
    else
      state.last_error = "empty frame file=" .. tostring(msg.file or "")
      vim.schedule(function()
        pcall(function()
          require("videobuf").set_info(
            "读帧失败 file=" .. tostring(msg.file or "?") .. " bytes=" .. tostring(msg.bytes or 0)
          )
        end)
      end)
    end
    return
  end

  if msg.path ~= nil and msg.path ~= "" then
    state.path = msg.path
    state.title = basename(msg.path)
  end
  if msg.status then
    state.status = msg.status
  end
  if type(msg.position) == "number" then
    state.position = msg.position
  end
  if type(msg.duration) == "number" then
    state.duration = msg.duration
  end
  if type(msg.volume) == "number" then
    state.volume = msg.volume
  end
  if msg.loop ~= nil then
    state.loop = not not msg.loop
  end
  if type(msg.fps) == "number" then
    state.fps = msg.fps
  end
  if type(msg.cols) == "number" then
    state.cols = msg.cols
  end
  if type(msg.rows) == "number" then
    state.rows = msg.rows
  end
  if msg.scale then
    state.scale = msg.scale
  end
  if msg.mode then
    state.mode = msg.mode
  end
  if type(msg.width) == "number" then
    state.width = msg.width
  end
  if type(msg.height) == "number" then
    state.height = msg.height
  end
  if msg.audio then
    state.audio = msg.audio
  end
  if msg.backend then
    state.backend = msg.backend
  end
  if msg.event == "ready" and msg.backend then
    state.backend = msg.backend
  end

  if msg.event == "warn" and msg.error then
    state.last_error = tostring(msg.error)
    vim.schedule(function()
      vim.notify("videobuf: " .. tostring(msg.error), vim.log.levels.WARN)
      pcall(function()
        require("videobuf").set_info(tostring(msg.error))
      end)
    end)
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
  for _, chunk in ipairs(data) do
    if type(chunk) == "string" and chunk ~= "" then
      stdout_buf = stdout_buf .. chunk
    end
  end
  drain_buf("stdout")
end

local function kill_job()
  stop_event_timer()
  if state.job_id and state.job_id > 0 then
    pcall(vim.fn.jobstop, state.job_id)
  end
  state.job_id = nil
  stdout_buf = ""
  event_pos = 0
end

local function ensure_daemon()
  if state.job_id and state.job_id > 0 then
    return true, nil
  end
  local script = daemon_script()
  -- 统一路径分隔
  script = vim.fn.fnamemodify(script, ":p")
  if vim.fn.filereadable(script) ~= 1 then
    return false, "missing " .. script
  end

  local cache = vim.fn.stdpath("cache")
  vim.fn.mkdir(cache, "p")
  event_path = (cache .. "/videobuf_events.jsonl"):gsub("\\", "/")
  boot_log_path = (cache .. "/videobuf_boot.log"):gsub("\\", "/")
  -- 清空旧事件
  pcall(function()
    local f = io.open(event_path, "w")
    if f then
      f:close()
    end
  end)
  pcall(function()
    local f = io.open(boot_log_path, "w")
    if f then
      f:write("nvim ensure_daemon\n")
      f:close()
    end
  end)
  event_pos = 0
  stdout_buf = ""
  file_buf = ""
  last_frame_seq = 0
  state.lines_in = 0
  state.frames_in = 0

  local py = resolve_python()
  local env = vim.fn.environ()
  env.PYTHONUNBUFFERED = "1"
  env.PYTHONIOENCODING = "utf-8"
  env.VIDEOBUF_EVENTS = event_path
  env.VIDEOBUF_BOOT_LOG = boot_log_path

  local job = vim.fn.jobstart({ py, "-X", "utf8", "-u", script }, {
    cwd = plugin_root(),
    stdin = "pipe",
    env = env,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = on_stdout,
    on_stderr = function(_, data, _)
      if type(data) ~= "table" then
        return
      end
      local msg = table.concat(data, "\n")
      if msg:match("UserWarning") or msg:match("pkg_resources") or msg:match("Hello from the pygame") then
        return
      end
      if msg:match("%S") then
        state.last_stderr = msg:gsub("%s+$", ""):sub(1, 200)
        vim.schedule(function()
          vim.notify("videobuf(python): " .. state.last_stderr, vim.log.levels.WARN)
          pcall(function()
            require("videobuf").set_info("stderr: " .. state.last_stderr)
          end)
        end)
      end
    end,
    on_exit = function(_, code, _)
      state.job_id = nil
      stop_event_timer()
      if state.status == "playing" or state.status == "paused" then
        state.status = "stopped"
        fire_status()
      end
      vim.schedule(function()
        pcall(function()
          require("videobuf").set_info("daemon exit code=" .. tostring(code))
        end)
      end)
    end,
  })
  if not job or job <= 0 then
    return false, "无法启动 videod: " .. tostring(py) .. " " .. script
  end
  state.job_id = job
  state.backend = nil
  start_event_timer()
  -- 立刻轮询一次
  vim.defer_fn(function()
    poll_event_file()
  end, 100)
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
    state.job_id = nil
    send_queue = {}
    return
  end
  if #send_queue > 0 then
    vim.schedule(flush_send)
  end
end

local function send(obj)
  local ok_d, err = ensure_daemon()
  if not ok_d then
    return false, err
  end
  table.insert(send_queue, vim.json.encode(obj) .. "\n")
  flush_send()
  return true, nil
end

function M.setup(user_cfg)
  cfg = vim.tbl_deep_extend("force", default_cfg, user_cfg or {})
  state.volume = cfg.volume
  state.loop = cfg.loop
  state.fps = cfg.fps
end

function M.get_state()
  return state
end

function M.on_status(cb)
  on_status_cb = cb
end

function M.on_frame(cb)
  on_frame_cb = cb
end

function M.on_ended(cb)
  on_ended_cb = cb
end

---@param opts table
function M.open(opts)
  opts = opts or {}
  local path = opts.path
  if not path or path == "" then
    return false, "路径为空"
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    return false, "文件不存在: " .. path
  end
  state.path = path
  state.title = basename(path)
  state.fps = opts.fps or state.fps or cfg.fps
  state.volume = opts.volume or state.volume or cfg.volume
  state.loop = opts.loop
  if state.loop == nil then
    state.loop = cfg.loop
  end
  state.cols = math.min(200, opts.cols or state.cols or 80)
  state.rows = math.min(80, opts.rows or state.rows or 24)
  state.scale = opts.scale or state.scale or "fill"
  state.mode = opts.mode or state.mode or "half"
  state.status = "opening"
  state.position = opts.start or 0
  state.duration = nil
  state.frames_in = 0
  state.lines_in = 0
  state.last_error = nil
  -- 路径统一正斜杠给 Python（Windows 也认）
  local path_py = path:gsub("\\", "/")
  local auto_play = opts.auto_play
  if auto_play == nil then
    auto_play = true
  end
  local ok, err = send({
    cmd = "open",
    path = path_py,
    fps = state.fps,
    cols = state.cols,
    rows = state.rows,
    scale = state.scale,
    mode = state.mode,
    volume = state.volume,
    start = state.position,
    loop = state.loop,
    auto_play = not not auto_play,
  })
  fire_status()
  return ok, err
end

function M.diag()
  return {
    job_id = state.job_id,
    lines_in = state.lines_in or 0,
    frames_in = state.frames_in or 0,
    backend = state.backend,
    last_error = state.last_error,
    last_stderr = state.last_stderr,
    status = state.status,
    duration = state.duration,
    event_path = event_path,
    event_pos = event_pos,
    python = resolve_python(),
  }
end

function M.play()
  state.status = "playing"
  local ok, err = send({ cmd = "play" })
  fire_status()
  return ok, err
end

function M.pause()
  state.status = "paused"
  local ok, err = send({ cmd = "pause" })
  fire_status()
  return ok, err
end

function M.toggle()
  if state.status == "playing" then
    return M.pause()
  end
  return M.play()
end

function M.stop()
  state.status = "stopped"
  state.position = 0
  local ok, err = send({ cmd = "stop" })
  fire_status()
  return ok, err
end

function M.seek_abs(seconds)
  seconds = math.max(0, seconds or 0)
  if state.duration and seconds > state.duration then
    seconds = state.duration
  end
  state.position = seconds
  local ok, err = send({ cmd = "seek", position = seconds })
  fire_status()
  return ok, err
end

function M.seek(delta)
  return M.seek_abs((state.position or 0) + (delta or 0))
end

function M.set_volume(vol)
  vol = math.max(0, math.min(100, math.floor(vol + 0.5)))
  state.volume = vol
  send({ cmd = "volume", volume = vol })
  fire_status()
  return vol
end

function M.set_fps(fps)
  fps = math.max(1, math.min(30, math.floor(fps + 0.5)))
  state.fps = fps
  send({ cmd = "fps", fps = fps })
  fire_status()
  return fps
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

function M.resize(opts)
  opts = opts or {}
  if opts.cols then
    state.cols = opts.cols
  end
  if opts.rows then
    state.rows = opts.rows
  end
  if opts.scale then
    state.scale = opts.scale
  end
  if opts.mode then
    state.mode = opts.mode
  end
  return send({
    cmd = "resize",
    cols = state.cols,
    rows = state.rows,
    scale = state.scale,
    mode = state.mode,
  })
end

function M.poll()
  send({ cmd = "status" })
  return state
end

function M.shutdown()
  state.status = "stopped"
  if state.job_id and state.job_id > 0 then
    pcall(vim.fn.chansend, state.job_id, vim.json.encode({ cmd = "quit" }) .. "\n")
  end
  -- 立即停进程，避免再次 open 时双守护
  kill_job()
  send_queue = {}
  stdout_buf = ""
  state.last_frame = nil
  fire_status()
end

function M.event_path()
  return event_path
end

return M
