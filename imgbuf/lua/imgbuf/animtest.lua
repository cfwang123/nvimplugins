---@mod imgbuf.animtest Full-screen redraw stress test (default 10 fps)
--- 模拟「视频预览」路径：每帧整屏重画 truecolor 色块，经 nvim_open_term 通道写出。
--- 用法：:ImgbufAnimTest [fps]
local M = {}

---@class AnimTestState
---@field buf integer
---@field win integer
---@field term_chan integer
---@field timer uv.uv_timer_t|nil
---@field frame integer
---@field running boolean
---@field paused boolean
---@field fps number
---@field cols number
---@field rows number
---@field last_ts number
---@field sum_dt number
---@field n_dt number
---@field last_draw_ms number
---@field avg_fps number
---@field aug integer|nil

---@type AnimTestState|nil
local state = nil
--- Neovim 0.9 只有 vim.loop；0.10+ 为 vim.uv
local uv = vim.uv or vim.loop

local function stop_timer()
  if not state or not state.timer then
    return
  end
  pcall(function()
    state.timer:stop()
    state.timer:close()
  end)
  state.timer = nil
end

local function cleanup()
  stop_timer()
  if state and state.aug then
    pcall(vim.api.nvim_del_augroup_by_id, state.aug)
  end
  if state and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state = nil
end

---构建一帧 ANSI：全屏背景色块 + 底栏状态
---@param cols number
---@param rows number
---@param frame integer
---@param fps number
---@param avg_fps number
---@param draw_ms number
---@param paused boolean
---@return string
local function build_frame(cols, rows, frame, fps, avg_fps, draw_ms, paused)
  cols = math.max(8, cols)
  rows = math.max(4, rows)
  local content_rows = math.max(1, rows - 1)
  local parts = { "\27[H\27[0m" }

  -- 色波：sin 组合，视觉上能看出掉帧/卡顿
  local t = frame * 0.18
  for y = 0, content_rows - 1 do
    local line = {}
    local yf = y * 0.14
    for x = 0, cols - 1 do
      local v = math.sin((x * 0.09) + t)
        + math.sin((y * 0.11) - t * 0.7)
        + math.sin((x + y) * 0.05 + t * 0.4)
      local r = math.floor(128 + 120 * math.sin(v))
      local g = math.floor(128 + 120 * math.sin(v + 2.094))
      local b = math.floor(128 + 120 * math.sin(v + 4.189 + yf * 0.01))
      if r < 0 then
        r = 0
      elseif r > 255 then
        r = 255
      end
      if g < 0 then
        g = 0
      elseif g > 255 then
        g = 255
      end
      if b < 0 then
        b = 0
      elseif b > 255 then
        b = 255
      end
      line[#line + 1] = string.format("\27[48;2;%d;%d;%dm ", r, g, b)
    end
    line[#line + 1] = "\27[0m"
    if y < content_rows - 1 then
      line[#line + 1] = "\r\n"
    end
    parts[#parts + 1] = table.concat(line)
  end

  local cells = cols * content_rows
  local status = string.format(
    " #%d  target=%dfps  avg=%.1ffps  draw=%.1fms  %dx%d=%d  %s  [q]退出 [Space]暂停 ",
    frame,
    fps,
    avg_fps,
    draw_ms,
    cols,
    content_rows,
    cells,
    paused and "PAUSED" or "RUN"
  )
  local w = vim.fn.strwidth(status)
  if w < cols then
    status = status .. string.rep(" ", cols - w)
  else
    while vim.fn.strwidth(status) > cols and #status > 0 do
      status = vim.fn.strcharpart(status, 0, vim.fn.strchars(status) - 1)
    end
    local pad = cols - vim.fn.strwidth(status)
    if pad > 0 then
      status = status .. string.rep(" ", pad)
    end
  end
  parts[#parts + 1] = "\r\n\27[0m\27[7m" .. status .. "\27[0m"
  return table.concat(parts)
end

local function win_size(win)
  local cols = math.max(8, vim.api.nvim_win_get_width(win))
  local rows = math.max(4, vim.api.nvim_win_get_height(win))
  return cols, rows
end

local function draw_once()
  if not state or not state.running then
    return
  end
  if not vim.api.nvim_buf_is_valid(state.buf) or not vim.api.nvim_win_is_valid(state.win) then
    cleanup()
    return
  end
  if state.paused then
    return
  end

  local cols, rows = win_size(state.win)
  state.cols = cols
  state.rows = rows

  local now = uv.hrtime() / 1e6 -- ms
  if state.last_ts > 0 then
    local dt = now - state.last_ts
    if dt > 0 and dt < 2000 then
      state.sum_dt = state.sum_dt + dt
      state.n_dt = state.n_dt + 1
      if state.n_dt > 0 then
        state.avg_fps = 1000 / (state.sum_dt / state.n_dt)
      end
    end
  end
  state.last_ts = now

  local t0 = uv.hrtime()
  local payload = build_frame(
    cols,
    rows,
    state.frame,
    state.fps,
    state.avg_fps,
    state.last_draw_ms,
    state.paused
  )
  pcall(vim.api.nvim_chan_send, state.term_chan, payload)
  state.last_draw_ms = (uv.hrtime() - t0) / 1e6
  state.frame = state.frame + 1

  -- 滑动窗口：避免 avg 被启动阶段拖死
  if state.n_dt >= 60 then
    state.sum_dt = state.sum_dt * 0.5
    state.n_dt = math.floor(state.n_dt * 0.5)
  end
end

local function start_timer()
  stop_timer()
  if not state then
    return
  end
  local interval = math.max(16, math.floor(1000 / state.fps + 0.5))
  local timer = uv and uv.new_timer and uv.new_timer() or nil
  if not timer then
    vim.notify("imgbuf animtest: cannot create timer", vim.log.levels.ERROR)
    return
  end
  state.timer = timer
  timer:start(0, interval, function()
    vim.schedule(draw_once)
  end)
end

local function apply_win_opts(win, buf)
  pcall(function()
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "imgbuf_animtest"
    vim.bo[buf].scrollback = 1
  end)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldcolumn = "0"
      vim.wo[win].list = false
      vim.wo[win].cursorline = false
      vim.wo[win].wrap = false
      vim.wo[win].scrolloff = 0
      vim.wo[win].sidescrolloff = 0
      vim.wo[win].statuscolumn = ""
    end)
  end
end

local function map_keys(buf)
  local function stop_and_close()
    cleanup()
  end

  local function toggle_pause()
    if not state then
      return
    end
    state.paused = not state.paused
    if state.paused then
      -- 立刻画一帧 PAUSED 状态
      local cols, rows = win_size(state.win)
      local payload = build_frame(
        cols,
        rows,
        state.frame,
        state.fps,
        state.avg_fps,
        state.last_draw_ms,
        true
      )
      pcall(vim.api.nvim_chan_send, state.term_chan, payload)
    else
      state.last_ts = 0
    end
  end

  for _, mode in ipairs({ "n", "t" }) do
    pcall(vim.keymap.set, mode, "q", stop_and_close, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "imgbuf animtest: quit",
    })
    pcall(vim.keymap.set, mode, "<Space>", toggle_pause, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "imgbuf animtest: pause",
    })
    pcall(vim.keymap.set, mode, "<Esc>", stop_and_close, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "imgbuf animtest: quit",
    })
  end
  pcall(vim.keymap.set, "n", "i", "<Nop>", { buffer = buf, silent = true })
  pcall(vim.keymap.set, "n", "a", "<Nop>", { buffer = buf, silent = true })
end

---启动全刷屏动画测试
---@param opts? { fps?: number, win?: integer }
---@return integer|nil buf
function M.start(opts)
  opts = opts or {}
  if state and state.running then
    cleanup()
  end

  local fps = tonumber(opts.fps) or 10
  if fps < 1 then
    fps = 1
  elseif fps > 60 then
    fps = 60
  end

  local win = opts.win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_get_current_win()
  end

  local buf = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, buf, "imgbuf://animtest")
  vim.api.nvim_win_set_buf(win, buf)
  apply_win_opts(win, buf)

  local term_chan
  local open_ok, open_err = pcall(function()
    vim.api.nvim_win_call(win, function()
      term_chan = vim.api.nvim_open_term(buf, {
        on_input = function() end,
      })
    end)
  end)

  if not open_ok or not term_chan or term_chan <= 0 then
    vim.notify(
      "imgbuf animtest: open_term failed: " .. tostring(open_err or term_chan),
      vim.log.levels.ERROR
    )
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil
  end

  local cols, rows = win_size(win)
  state = {
    buf = buf,
    win = win,
    term_chan = term_chan,
    timer = nil,
    frame = 0,
    running = true,
    paused = false,
    fps = fps,
    cols = cols,
    rows = rows,
    last_ts = 0,
    sum_dt = 0,
    n_dt = 0,
    last_draw_ms = 0,
    avg_fps = 0,
    aug = nil,
  }

  map_keys(buf)
  vim.b[buf].imgbuf_animtest = true

  local aug = vim.api.nvim_create_augroup("ImgbufAnimTest_" .. buf, { clear = true })
  state.aug = aug
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = aug,
    buffer = buf,
    callback = function()
      stop_timer()
      state = nil
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = aug,
    callback = function()
      if state and state.running and vim.api.nvim_buf_is_valid(buf) then
        -- 下一帧用新尺寸即可
        state.last_ts = 0
      end
    end,
  })
  vim.api.nvim_create_autocmd("TermEnter", {
    group = aug,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        pcall(vim.cmd, "stopinsert")
      end)
    end,
  })

  start_timer()
  vim.schedule(function()
    pcall(vim.cmd, "stopinsert")
  end)

  vim.notify(
    string.format("imgbuf animtest: %dfps 全刷屏 (q 退出, Space 暂停)", fps),
    vim.log.levels.INFO
  )
  return buf
end

function M.stop()
  cleanup()
end

function M.is_running()
  return state ~= nil and state.running == true
end

return M
