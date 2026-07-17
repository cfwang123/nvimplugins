---@mod nvimplugins.deps 启动时检测 pip 依赖并提示安装
---无 npm 依赖。可选系统命令（chafa 等）仅作提示，不自动装。
---启动默认只提示「必需」缺失；推荐包需 :NvimpluginsDeps 或 force。
local M = {}

---@class nvimplugins.DepPkg
---@field import string
---@field pip string
---@field optional? boolean

---@class nvimplugins.DepGroup
---@field any nvimplugins.DepPkg[]
---@field prefer? string
---@field or_bin? string

---@class nvimplugins.PluginDeps
---@field plugin string
---@field title string
---@field python? boolean
---@field win_only? boolean
---@field required? (nvimplugins.DepPkg|nvimplugins.DepGroup)[]
---@field recommended? nvimplugins.DepPkg[]

local SPECS = {
  music = {
    plugin = "music",
    title = "music",
    python = true,
    required = {
      {
        any = {
          { import = "just_playback", pip = "just_playback" },
          { import = "pygame", pip = "pygame" },
        },
        prefer = "just_playback",
      },
    },
    recommended = {
      { import = "mutagen", pip = "mutagen", optional = true },
    },
  },
  videobuf = {
    plugin = "videobuf",
    title = "videobuf",
    python = true,
    required = {
      {
        any = {
          { import = "av", pip = "av" },
          { import = "cv2", pip = "opencv-python" },
        },
        prefer = "av",
      },
      {
        any = {
          { import = "just_playback", pip = "just_playback" },
          { import = "pygame", pip = "pygame" },
        },
        prefer = "just_playback",
      },
    },
  },
  pdfview = {
    plugin = "pdfview",
    title = "pdfview",
    python = true,
    required = {
      { import = "fitz", pip = "pymupdf" },
    },
    recommended = {
      { import = "PIL", pip = "Pillow", optional = true },
    },
  },
  xlsview = {
    plugin = "xlsview",
    title = "xlsview",
    python = true,
    required = {
      { import = "openpyxl", pip = "openpyxl" },
    },
  },
  tts = {
    plugin = "tts",
    title = "tts",
    python = true,
    win_only = true,
    required = {
      { import = "win32com", pip = "pywin32" },
    },
  },
  mdview = {
    plugin = "mdview",
    title = "mdview",
    python = true,
    recommended = {
      { import = "PIL", pip = "Pillow", optional = true },
    },
  },
  imgbuf = {
    plugin = "imgbuf",
    title = "imgbuf",
    python = true,
    required = {
      {
        any = {
          { import = "PIL", pip = "Pillow" },
        },
        prefer = "Pillow",
        or_bin = "chafa",
      },
    },
  },
  mixer = {
    plugin = "mixer",
    title = "mixer",
    python = true,
    required = {
      { import = "numpy", pip = "numpy" },
      { import = "pygame", pip = "pygame" },
    },
    recommended = {
      { import = "mido", pip = "mido", optional = true },
    },
  },
}

local state = {
  checked = {}, ---@type table<string, boolean>
  skipped_session = false,
  busy = false,
  python = nil, ---@type string|nil
  python_argv = nil, ---@type string[]|nil  实际调用前缀，如 {"py","-3"} 或 {"python"}
  pending = {}, ---@type table<string, boolean>
  coalesce_scheduled = false,
  coalesce_opts = {}, ---@type table
  ---已忽略的推荐包（持久化）
  dismissed_rec = nil, ---@type table<string, boolean>|nil
  install_buf = nil, ---@type integer|nil
  install_win = nil, ---@type integer|nil
}

local function is_zh()
  if vim.g.nvimplugins_lang == "zh" then
    return true
  end
  if vim.g.nvimplugins_lang == "en" then
    return false
  end
  local cands = {
    vim.v.lang,
    vim.env.LC_ALL,
    vim.env.LC_MESSAGES,
    vim.env.LANG,
    vim.o.langmenu,
  }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" then
      local low = c:lower()
      if low:match("^zh") or low:find("chinese", 1, true) then
        return true
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
    if ok and type(out) == "string" and out:lower():match("^zh") then
      return true
    end
  end
  return false
end

local function msg(zh, en)
  return is_zh() and zh or en
end

local function data_path()
  return vim.fn.stdpath("data") .. "/nvimplugins_deps.json"
end

local function load_persist()
  if state.dismissed_rec then
    return state.dismissed_rec
  end
  state.dismissed_rec = {}
  local path = data_path()
  if vim.fn.filereadable(path) == 1 then
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if ok and type(data) == "table" and type(data.dismissed_recommended) == "table" then
      for _, p in ipairs(data.dismissed_recommended) do
        if type(p) == "string" then
          state.dismissed_rec[p] = true
        end
      end
    end
  end
  return state.dismissed_rec
end

local function save_persist()
  local dismissed = {}
  for p, v in pairs(state.dismissed_rec or {}) do
    if v then
      table.insert(dismissed, p)
    end
  end
  table.sort(dismissed)
  local path = data_path()
  pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({
      vim.json.encode({
        dismissed_recommended = dismissed,
        python = state.python,
      }),
    }, path)
  end)
end

local function dismiss_recommended(pips)
  load_persist()
  for _, p in ipairs(pips or {}) do
    state.dismissed_rec[p] = true
  end
  save_persist()
end

---解析 python：返回显示名 + argv 前缀
---@param preferred? string
---@return string|nil name
---@return string[]|nil argv
function M.resolve_python(preferred)
  if state.python and state.python_argv then
    return state.python, state.python_argv
  end

  local function try_argv(argv)
    if not argv or #argv == 0 then
      return false
    end
    if vim.fn.executable(argv[1]) ~= 1 then
      return false
    end
    -- 验证能跑 -c
    local cmd = vim.list_extend({}, argv)
    vim.list_extend(cmd, { "-c", "import sys; print(sys.executable)" })
    local ok, out = pcall(vim.fn.system, cmd)
    if not ok or vim.v.shell_error ~= 0 then
      return false
    end
    out = vim.trim(tostring(out or ""))
    return out ~= ""
  end

  local candidates = {}
  local function add(name, argv)
    if name and argv then
      table.insert(candidates, { name = name, argv = argv })
    end
  end

  if preferred and preferred ~= "" then
    add(preferred, { preferred })
  end
  if type(vim.g.nvimplugins_python) == "string" and vim.g.nvimplugins_python ~= "" then
    add(vim.g.nvimplugins_python, { vim.g.nvimplugins_python })
  end
  if type(vim.g.python3_host_prog) == "string" and vim.g.python3_host_prog ~= "" then
    add(vim.g.python3_host_prog, { vim.g.python3_host_prog })
  end
  add("python", { "python" })
  add("python3", { "python3" })
  if vim.fn.has("win32") == 1 then
    add("py -3", { "py", "-3" })
    add("py", { "py" })
  end

  for _, c in ipairs(candidates) do
    if try_argv(c.argv) then
      state.python = c.name
      state.python_argv = c.argv
      return state.python, state.python_argv
    end
  end
  return nil, nil
end

---@param argv string[]
---@param extra string[]
---@return string[]
local function with_argv(argv, extra)
  local cmd = vim.list_extend({}, argv)
  vim.list_extend(cmd, extra)
  return cmd
end

---探测 import：写临时脚本 + JSON 结果，避免 -c 多行 / pygame 污染 stdout
---@param argv string[]
---@param imports string[]
---@return table<string, boolean>
local function probe_imports(argv, imports)
  local present = {}
  for _, n in ipairs(imports) do
    present[n] = false
  end
  if #imports == 0 then
    return present
  end

  local script = table.concat({
    "import importlib, json, os, sys",
    "os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'",
    "os.environ.setdefault('SDL_VIDEODRIVER', 'dummy')",
    "r = {}",
    "for n in sys.argv[1:]:",
    "    try:",
    "        importlib.import_module(n)",
    "        r[n] = True",
    "    except Exception:",
    "        r[n] = False",
    "sys.stdout.write(json.dumps(r))",
    "",
  }, "\n")

  local tmp = vim.fn.tempname() .. "_nvp_deps.py"
  local wr_ok = pcall(vim.fn.writefile, vim.split(script, "\n", { plain = true }), tmp)
  if not wr_ok then
    return present
  end

  local cmd = with_argv(argv, { "-X", "utf8", tmp })
  for _, n in ipairs(imports) do
    table.insert(cmd, n)
  end

  local out = ""
  if vim.system then
    local r = vim.system(cmd, { text = true }):wait()
    out = r.stdout or ""
  else
    local ok, result = pcall(vim.fn.system, cmd)
    if ok then
      out = tostring(result or "")
    end
  end
  pcall(vim.fn.delete, tmp)

  out = out:gsub("\r", "")
  local json_str = out:match("(%b{})")
  if not json_str then
    return present
  end
  local okj, data = pcall(vim.json.decode, json_str)
  if not okj or type(data) ~= "table" then
    return present
  end
  for _, n in ipairs(imports) do
    present[n] = data[n] == true
  end
  return present
end

---@param item nvimplugins.DepPkg|nvimplugins.DepGroup
---@param present table<string, boolean>
---@return string[]
local function missing_from_item(item, present)
  if item.any then
    if item.or_bin and vim.fn.executable(item.or_bin) == 1 then
      return {}
    end
    for _, p in ipairs(item.any) do
      if present[p.import] then
        return {}
      end
    end
    if item.prefer then
      return { item.prefer }
    end
    return { item.any[1].pip }
  end
  if item.import and not present[item.import] then
    return { item.pip }
  end
  return {}
end

---@param names string[]
---@param opts? { include_recommended?: boolean }
---@return { plugin: string, required: string[], recommended: string[] }[]
---@return string|nil python_name
local function collect_missing(names, opts)
  opts = opts or {}
  local include_rec = opts.include_recommended
  if include_rec == nil then
    include_rec = false -- 启动默认不查推荐
  end

  local py_name, argv = M.resolve_python()
  local results = {}
  local all_imports = {}
  local import_set = {}
  local active = {}

  for _, name in ipairs(names) do
    local spec = SPECS[name]
    if spec and not (spec.win_only and vim.fn.has("win32") ~= 1) then
      table.insert(active, spec)
      local lists = { "required" }
      if include_rec then
        table.insert(lists, "recommended")
      end
      for _, list_name in ipairs(lists) do
        for _, item in ipairs(spec[list_name] or {}) do
          if item.any then
            for _, p in ipairs(item.any) do
              if not import_set[p.import] then
                import_set[p.import] = true
                table.insert(all_imports, p.import)
              end
            end
          elseif item.import and not import_set[item.import] then
            import_set[item.import] = true
            table.insert(all_imports, item.import)
          end
        end
      end
    end
  end

  if #active == 0 then
    return results, py_name
  end

  if not argv then
    for _, spec in ipairs(active) do
      if spec.python then
        table.insert(results, {
          plugin = spec.plugin,
          required = { "__python__" },
          recommended = {},
        })
      end
    end
    return results, nil
  end

  local present = probe_imports(argv, all_imports)
  local dismissed = load_persist()

  for _, spec in ipairs(active) do
    local req, rec = {}, {}
    local seen = {}
    for _, item in ipairs(spec.required or {}) do
      for _, pip in ipairs(missing_from_item(item, present)) do
        if not seen[pip] then
          seen[pip] = true
          table.insert(req, pip)
        end
      end
    end
    if include_rec then
      for _, item in ipairs(spec.recommended or {}) do
        for _, pip in ipairs(missing_from_item(item, present)) do
          if not seen[pip] and not dismissed[pip] then
            seen[pip] = true
            table.insert(rec, pip)
          end
        end
      end
    end
    if #req > 0 or #rec > 0 then
      table.insert(results, {
        plugin = spec.plugin,
        required = req,
        recommended = rec,
      })
    end
  end
  return results, py_name
end

---安装日志预览窗
local function open_install_window(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = "nvimplugins-deps"
  pcall(vim.api.nvim_buf_set_name, buf, "nvimplugins://deps-install")

  local width = math.min(100, math.max(60, vim.o.columns - 8))
  local height = math.min(24, math.max(12, vim.o.lines - 8))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title or " nvimplugins pip ",
    title_pos = "center",
    zindex = 80,
  })
  pcall(function()
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = true
  end)

  state.install_buf = buf
  state.install_win = win

  vim.keymap.set("n", "q", function()
    if state.install_win and vim.api.nvim_win_is_valid(state.install_win) then
      pcall(vim.api.nvim_win_close, state.install_win, true)
    end
  end, { buffer = buf, silent = true, nowait = true, desc = "close install log" })
  vim.keymap.set("n", "<Esc>", function()
    if state.install_win and vim.api.nvim_win_is_valid(state.install_win) then
      pcall(vim.api.nvim_win_close, state.install_win, true)
    end
  end, { buffer = buf, silent = true, nowait = true })

  return buf, win
end

local function append_log(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  local clean = {}
  for _, l in ipairs(lines) do
    if l ~= nil then
      table.insert(clean, tostring(l):gsub("\r", ""))
    end
  end
  if #clean == 0 then
    return
  end
  vim.bo[buf].modifiable = true
  local count = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1]
  if count == 1 and (last == nil or last == "") then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, clean)
  else
    vim.api.nvim_buf_set_lines(buf, count, count, false, clean)
  end
  -- 滚到底
  if state.install_win and vim.api.nvim_win_is_valid(state.install_win) then
    local n = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, state.install_win, { n, 0 })
  end
end

---@param pips string[]
---@param on_done fun(ok: boolean, detail: string)
local function pip_install(pips, on_done)
  local py_name, argv = M.resolve_python()
  if not argv then
    on_done(false, msg("未找到 python", "python not found"))
    return
  end
  if #pips == 0 then
    on_done(true, "ok")
    return
  end

  local cmd = with_argv(argv, { "-m", "pip", "install", "--user" })
  for _, p in ipairs(pips) do
    table.insert(cmd, p)
  end

  local title = msg(" pip 安装 ", " pip install ")
  local buf = open_install_window(title)
  local cmd_str = table.concat(cmd, " ")
  append_log(buf, {
    msg("nvimplugins 依赖安装日志", "nvimplugins dependency install log"),
    string.rep("─", 48),
    msg("Python: ", "Python: ") .. tostring(py_name),
    msg("命令: ", "Command: ") .. cmd_str,
    string.rep("─", 48),
    "",
  })

  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      vim.schedule(function()
        append_log(buf, data)
      end)
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      vim.schedule(function()
        append_log(buf, data)
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local ok = code == 0
        append_log(buf, {
          "",
          string.rep("─", 48),
          ok and msg("✓ 安装结束：成功 (exit 0)", "✓ finished: success (exit 0)")
            or msg("✗ 安装结束：失败 (exit " .. tostring(code) .. ")", "✗ finished: failed (exit " .. tostring(code) .. ")"),
          msg("按 q 关闭此窗口", "press q to close"),
        })
        -- 安装后复检
        state.python = nil
        state.python_argv = nil
        local import_for_pip = {
          just_playback = "just_playback",
          pygame = "pygame",
          mutagen = "mutagen",
          av = "av",
          ["opencv-python"] = "cv2",
          pymupdf = "fitz",
          Pillow = "PIL",
          openpyxl = "openpyxl",
          pywin32 = "win32com",
          numpy = "numpy",
          mido = "mido",
        }
        local recheck_imports = {}
        for _, pip in ipairs(pips) do
          table.insert(recheck_imports, import_for_pip[pip] or pip)
        end
        local _, argv2 = M.resolve_python()
        local still = {}
        if argv2 then
          local present = probe_imports(argv2, recheck_imports)
          for i, imp in ipairs(recheck_imports) do
            if not present[imp] then
              table.insert(still, pips[i])
            end
          end
        end
        if ok and #still == 0 then
          vim.notify(
            msg(
              "nvimplugins: 安装成功 — " .. table.concat(pips, " "),
              "nvimplugins: install OK — " .. table.concat(pips, " ")
            ),
            vim.log.levels.INFO
          )
        elseif ok and #still > 0 then
          vim.notify(
            msg(
              "nvimplugins: pip 退出 0，但仍无法 import: "
                .. table.concat(still, " ")
                .. "（可能装到了别的 Python）",
              "nvimplugins: pip exit 0 but still cannot import: "
                .. table.concat(still, " ")
                .. " (maybe wrong Python)"
            ),
            vim.log.levels.WARN
          )
          append_log(buf, {
            msg("警告: 下列包仍无法 import: ", "WARN: still not importable: ") .. table.concat(still, " "),
          })
          ok = false
        else
          vim.notify(
            msg(
              "nvimplugins: 安装失败 (exit " .. tostring(code) .. ")",
              "nvimplugins: install failed (exit " .. tostring(code) .. ")"
            ),
            vim.log.levels.ERROR
          )
        end
        state.busy = false
        for k in pairs(state.checked) do
          state.checked[k] = nil
        end
        on_done(ok, ok and "ok" or ("exit " .. tostring(code)))
      end)
    end,
  })
  if job <= 0 then
    append_log(buf, { msg("无法启动 pip 进程", "failed to start pip job") })
    state.busy = false
    on_done(false, "jobstart failed")
  end
end

---@param missing { plugin: string, required: string[], recommended: string[] }[]
---@param opts? table
local function prompt_and_install(missing, opts)
  opts = opts or {}
  if #missing == 0 then
    return
  end

  local req_set, rec_set = {}, {}
  local req_list, rec_list = {}, {}
  local lines = {}
  local py_name = select(1, M.resolve_python())

  for _, m in ipairs(missing) do
    if m.required[1] == "__python__" then
      table.insert(lines, string.format("  [%s] %s", m.plugin, msg("需要 Python3（未在 PATH 中找到）", "needs Python3 (not on PATH)")))
    else
      if #m.required > 0 then
        table.insert(
          lines,
          string.format("  [%s] %s: %s", m.plugin, msg("必需", "required"), table.concat(m.required, ", "))
        )
        for _, p in ipairs(m.required) do
          if not req_set[p] then
            req_set[p] = true
            table.insert(req_list, p)
          end
        end
      end
      if #m.recommended > 0 then
        table.insert(
          lines,
          string.format("  [%s] %s: %s", m.plugin, msg("推荐", "recommended"), table.concat(m.recommended, ", "))
        )
        for _, p in ipairs(m.recommended) do
          if not rec_set[p] and not req_set[p] then
            rec_set[p] = true
            table.insert(rec_list, p)
          end
        end
      end
    end
  end

  if #req_list == 0 and #rec_list == 0 then
    local only_py = false
    for _, m in ipairs(missing) do
      if m.required[1] == "__python__" then
        only_py = true
      end
    end
    if only_py then
      vim.notify(
        msg(
          "nvimplugins: 未找到 Python3，请安装并加入 PATH。",
          "nvimplugins: Python3 not found on PATH."
        ),
        vim.log.levels.WARN
      )
    end
    return
  end

  local header = msg("nvimplugins: 缺少 Python 包", "nvimplugins: missing Python packages")
  if py_name then
    header = header .. " (" .. py_name .. ")"
  end
  local body = table.concat(lines, "\n")

  local function do_install(pips)
    if #pips == 0 then
      return
    end
    state.busy = true
    pip_install(pips, function() end)
  end

  if opts.auto or vim.g.nvimplugins_auto_install_deps then
    do_install(vim.list_extend(vim.list_extend({}, req_list), rec_list))
    return
  end

  local headless = (#(vim.api.nvim_list_uis() or {}) == 0)
  if headless or opts.notify_only then
    local all = vim.list_extend(vim.list_extend({}, req_list), rec_list)
    local _, argv = M.resolve_python()
    local prefix = argv and table.concat(argv, " ") or "python"
    vim.notify(
      header
        .. "\n"
        .. body
        .. "\n"
        .. msg("安装: ", "Install: ")
        .. prefix
        .. " -m pip install --user "
        .. table.concat(all, " "),
      vim.log.levels.WARN
    )
    return
  end

  local choices = {}
  if #req_list > 0 then
    table.insert(choices, {
      id = "req",
      label = msg("安装必需 (" .. table.concat(req_list, " ") .. ")", "Install required (" .. table.concat(req_list, " ") .. ")"),
      pips = req_list,
    })
  end
  if #rec_list > 0 or #req_list > 0 then
    local all = vim.list_extend(vim.list_extend({}, req_list), rec_list)
    if #all > 0 and not (#req_list > 0 and #rec_list == 0) then
      table.insert(choices, {
        id = "all",
        label = msg(
          #req_list > 0 and ("安装必需+推荐 (" .. table.concat(all, " ") .. ")")
            or ("安装推荐 (" .. table.concat(rec_list, " ") .. ")"),
          #req_list > 0 and ("Install required+recommended (" .. table.concat(all, " ") .. ")")
            or ("Install recommended (" .. table.concat(rec_list, " ") .. ")")
        ),
        pips = all,
      })
    end
  end
  table.insert(choices, {
    id = "skip",
    label = msg("本次跳过", "Skip this time"),
  })
  if #rec_list > 0 and #req_list == 0 then
    table.insert(choices, {
      id = "dismiss_rec",
      label = msg("忽略这些推荐包（不再提示）", "Dismiss recommended (don't ask again)"),
    })
  end
  table.insert(choices, {
    id = "never",
    label = msg("本会话不再检查依赖", "Don't check deps this session"),
  })

  -- 单行 notify，减少 hit-enter
  vim.notify(header .. " — " .. body:gsub("\n", " | "), vim.log.levels.WARN)

  vim.ui.select(choices, {
    prompt = msg("nvimplugins 依赖", "nvimplugins deps"),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.id == "never" then
      state.skipped_session = true
      vim.g.nvimplugins_skip_deps = true
      return
    end
    if choice.id == "skip" then
      return
    end
    if choice.id == "dismiss_rec" then
      dismiss_recommended(rec_list)
      vim.notify(
        msg("已忽略推荐包: " .. table.concat(rec_list, " "), "Dismissed recommended: " .. table.concat(rec_list, " ")),
        vim.log.levels.INFO
      )
      return
    end
    if choice.pips and #choice.pips > 0 then
      do_install(choice.pips)
    end
  end)
end

local function run_ensure(names, opts)
  opts = opts or {}
  if state.busy then
    return
  end

  local todo = {}
  for _, n in ipairs(names) do
    if opts.force or not state.checked[n] then
      if SPECS[n] then
        table.insert(todo, n)
      end
    end
  end
  if #todo == 0 then
    return
  end

  for _, n in ipairs(todo) do
    state.checked[n] = true
  end

  -- force / 手动检查：含推荐；启动自动：仅必需
  local include_rec = opts.include_recommended
  if include_rec == nil then
    include_rec = opts.force == true or opts.silent_ok == false
  end

  local missing = collect_missing(todo, { include_recommended = include_rec })
  if #missing == 0 then
    if opts.silent_ok == false then
      local py = select(1, M.resolve_python()) or "?"
      vim.notify(
        msg("nvimplugins: Python 依赖已就绪 (" .. py .. ")", "nvimplugins: Python deps OK (" .. py .. ")"),
        vim.log.levels.INFO
      )
    end
    return
  end

  -- 若只有推荐、且非 force：启动时静默（不再弹窗）
  if not include_rec then
    local only_rec = true
    for _, m in ipairs(missing) do
      if #m.required > 0 then
        only_rec = false
        break
      end
    end
    if only_rec then
      return
    end
  end

  prompt_and_install(missing, opts)
end

---@param plugins? string|string[]
---@param opts? { force?: boolean, auto?: boolean, silent_ok?: boolean, immediate?: boolean, include_recommended?: boolean }
function M.ensure(plugins, opts)
  opts = opts or {}
  if vim.g.nvimplugins_skip_deps and not opts.force then
    return
  end
  if state.skipped_session and not opts.force then
    return
  end

  local names
  if plugins == nil then
    names = {}
    for k in pairs(SPECS) do
      table.insert(names, k)
    end
    table.sort(names)
  elseif type(plugins) == "string" then
    names = { plugins }
  else
    names = plugins
  end

  if opts.immediate or opts.force then
    run_ensure(names, opts)
    return
  end

  for _, n in ipairs(names) do
    state.pending[n] = true
  end
  if opts.silent_ok == false then
    state.coalesce_opts.silent_ok = false
  end
  if opts.auto then
    state.coalesce_opts.auto = true
  end
  if opts.include_recommended then
    state.coalesce_opts.include_recommended = true
  end
  if opts.force then
    state.coalesce_opts.force = true
  end
  if state.coalesce_scheduled then
    return
  end
  state.coalesce_scheduled = true
  vim.defer_fn(function()
    state.coalesce_scheduled = false
    local batch = {}
    for n in pairs(state.pending) do
      table.insert(batch, n)
    end
    state.pending = {}
    local copts = state.coalesce_opts
    state.coalesce_opts = {}
    table.sort(batch)
    run_ensure(batch, copts)
  end, 200)
end

function M.ensure_loaded(opts)
  local names = {}
  for name in pairs(SPECS) do
    if vim.g["loaded_" .. name] then
      table.insert(names, name)
    end
  end
  table.sort(names)
  if #names == 0 then
    M.ensure(nil, opts)
    return
  end
  M.ensure(names, opts)
end

function M.specs()
  return SPECS
end

function M.reset()
  state.checked = {}
  state.skipped_session = false
  state.python = nil
  state.python_argv = nil
  state.dismissed_rec = nil
end

---调试：打印探测结果
function M.debug_probe()
  local py, argv = M.resolve_python()
  local imports = {
    "PIL",
    "mido",
    "fitz",
    "openpyxl",
    "just_playback",
    "numpy",
    "pygame",
    "av",
    "cv2",
    "win32com",
    "mutagen",
  }
  local present = argv and probe_imports(argv, imports) or {}
  local lines = { "python=" .. tostring(py), "argv=" .. vim.inspect(argv) }
  for _, n in ipairs(imports) do
    table.insert(lines, n .. "=" .. tostring(present[n]))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  return present
end

return M
