---@mod mdview.paste_image
--- Markdown 源 buffer：剪贴板图片 → 保存到 md 旁 images/yyyyMMddHHmmss.png 并插入链接
local config = require("mdview.config")

local M = {}

---@return string|nil
local function python_cmd(cfg)
  local cands = {}
  local cfg_py = cfg and cfg.image and cfg.image.python
  if type(cfg_py) == "string" and cfg_py ~= "" then
    cands[#cands + 1] = cfg_py
  end
  -- 优先用户 nvim 的 Python（myinit 里常设 python3_host_prog）
  local host = vim.g.python3_host_prog
  if type(host) == "string" and host ~= "" then
    cands[#cands + 1] = host
  end
  cands[#cands + 1] = "python"
  cands[#cands + 1] = "python3"
  for _, py in ipairs(cands) do
    if vim.fn.executable(py) == 1 then
      return py
    end
    -- 完整路径有时 executable 为 0，再试可读
    if type(py) == "string" and py:find("[/\\]") and vim.fn.filereadable(py) == 1 then
      return py
    end
  end
  return nil
end

---运行外部命令，返回 exit, stdout, stderr
---@param cmd string[]
---@return integer, string, string
local function run_cmd(cmd)
  local code_exit, stdout, stderr = -1, "", ""
  if vim.system then
    local ok, result = pcall(function()
      return vim.system(cmd, { text = true }):wait()
    end)
    if ok and type(result) == "table" then
      return result.code or -1, result.stdout or "", result.stderr or ""
    end
  end
  local out = vim.fn.system(cmd)
  code_exit = vim.v.shell_error
  stdout = out or ""
  stderr = code_exit ~= 0 and (out or "") or ""
  return code_exit, stdout, stderr
end

---用 Pillow ImageGrab 将剪贴板图片写到 dest_path（PNG）
---@param dest_path string
---@param py string
---@return boolean ok, string|nil err
local function grab_clipboard_to(dest_path, py)
  local code = [[
import sys
try:
    from PIL import ImageGrab, Image
except ImportError:
    print("ERROR: Pillow required (pip install Pillow)", file=sys.stderr)
    sys.exit(2)
img = ImageGrab.grabclipboard()
if img is None:
    print("ERROR: clipboard has no image", file=sys.stderr)
    sys.exit(1)
if isinstance(img, list):
    if not img:
        print("ERROR: clipboard has no image", file=sys.stderr)
        sys.exit(1)
    try:
        img = Image.open(img[0])
    except Exception as e:
        print("ERROR: " + str(e), file=sys.stderr)
        sys.exit(1)
img.convert("RGBA").save(sys.argv[1], "PNG")
]]
  local exit_code, stdout, stderr = run_cmd({ py, "-X", "utf8", "-c", code, dest_path })
  if exit_code ~= 0 then
    local err = (stderr ~= "" and stderr) or stdout or "clipboard grab failed"
    return false, (err:gsub("%s+$", ""))
  end
  if vim.fn.filereadable(dest_path) == 0 then
    return false, "clipboard image not saved"
  end
  return true, nil
end

---仅探测剪贴板是否有图（不落盘；失败视为无图）
---@param py string
---@return boolean
function M.clipboard_has_image(py)
  local code = [[
import sys
try:
    from PIL import ImageGrab, Image
except ImportError:
    sys.exit(2)
img = ImageGrab.grabclipboard()
if img is None:
    sys.exit(1)
if isinstance(img, list):
    if not img:
        sys.exit(1)
sys.exit(0)
]]
  local exit_code = select(1, run_cmd({ py, "-X", "utf8", "-c", code }))
  return exit_code == 0
end

---@param dir_abs string
---@return string filename 相对文件名（含 .png）
local function unique_filename(dir_abs)
  local base = os.date("%Y%m%d%H%M%S")
  local name = base .. ".png"
  local full = dir_abs .. "/" .. name
  if vim.fn.filereadable(full) == 0 and vim.fn.isdirectory(full) == 0 then
    return name
  end
  local n = 2
  while n < 1000 do
    name = string.format("%s_%d.png", base, n)
    full = dir_abs .. "/" .. name
    if vim.fn.filereadable(full) == 0 and vim.fn.isdirectory(full) == 0 then
      return name
    end
    n = n + 1
  end
  local uv = vim.uv or vim.loop
  local stamp = (uv and uv.hrtime and uv.hrtime()) or os.time()
  return base .. "_" .. tostring(stamp) .. ".png"
end

---在光标处插入文本
---@param text string
---@param put "p"|"P"|nil p=光标后（默认）P=光标前；插入模式始终在光标处
local function insert_text_at_cursor(text, put)
  local mode = vim.api.nvim_get_mode().mode or "n"
  if mode:sub(1, 1) == "i" then
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { text })
    vim.api.nvim_win_set_cursor(0, { row, col + #text })
    return
  end
  -- normal：nvim_put 对齐 p / P
  local after = put ~= "P"
  vim.api.nvim_put({ text }, "c", after, true)
end

---@param cfg table|nil
---@return table
local function paste_cfg(cfg)
  cfg = cfg or config.get()
  local p = cfg.paste_image
  if type(p) ~= "table" then
    p = {}
  end
  return p
end

---保存剪贴板图片并在光标处插入 Markdown 链接
---@param opts { buf?: integer, notify?: boolean, put?: "p"|"P" }|nil
---@return boolean ok, string|nil err_or_rel
function M.paste(opts)
  opts = opts or {}
  local cfg = config.get()
  local pc = paste_cfg(cfg)
  if pc.enable == false then
    return false, "disabled"
  end

  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false, "invalid buffer"
  end

  local md_path = vim.api.nvim_buf_get_name(buf)
  if not md_path or md_path == "" then
    local msg = require("mdview.i18n").t("paste_need_file")
    if opts.notify ~= false then
      vim.notify(msg, vim.log.levels.WARN)
    end
    return false, msg
  end

  local py = python_cmd(cfg)
  if not py then
    local msg = require("mdview.i18n").t("paste_no_python")
    if opts.notify ~= false then
      vim.notify(msg, vim.log.levels.ERROR)
    end
    return false, msg
  end

  local subdir = (type(pc.dir) == "string" and pc.dir ~= "" and pc.dir) or "images"
  -- 禁止绝对路径 / 上级目录逃逸
  subdir = subdir:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
  if subdir:find("%.%.", 1, true) or subdir:match("^%a:[/\\]") then
    subdir = "images"
  end

  local md_dir = vim.fn.fnamemodify(md_path, ":p:h")
  local img_dir = vim.fn.fnamemodify(md_dir .. "/" .. subdir, ":p")
  -- 去掉末尾斜杠差异
  img_dir = img_dir:gsub("[/\\]+$", "")

  if vim.fn.isdirectory(img_dir) == 0 then
    local ok_mk = vim.fn.mkdir(img_dir, "p")
    if ok_mk == 0 and vim.fn.isdirectory(img_dir) == 0 then
      local msg = require("mdview.i18n").t("paste_mkdir_fail") .. img_dir
      if opts.notify ~= false then
        vim.notify(msg, vim.log.levels.ERROR)
      end
      return false, msg
    end
  end

  local filename = unique_filename(img_dir)
  local abs_path = img_dir .. "/" .. filename
  -- Windows 路径给 Python 用正斜杠也可
  local abs_for_py = abs_path:gsub("\\", "/")

  local ok_grab, err_grab = grab_clipboard_to(abs_for_py, py)
  if not ok_grab then
    local low = (err_grab or ""):lower()
    local msg
    if low:find("no image", 1, true) or low:find("clipboard has no", 1, true) then
      msg = require("mdview.i18n").t("paste_no_image")
    elseif low:find("pillow", 1, true) then
      msg = require("mdview.i18n").t("paste_need_pillow")
    else
      msg = require("mdview.i18n").t("paste_fail") .. tostring(err_grab)
    end
    if opts.notify ~= false then
      vim.notify(msg, vim.log.levels.WARN)
    end
    return false, msg
  end

  local rel = subdir .. "/" .. filename
  local alt = "image"
  if type(pc.alt) == "string" then
    alt = pc.alt
  end
  local link = string.format("![%s](%s)", alt, rel)
  local put = opts.put == "P" and "P" or "p"

  if vim.api.nvim_get_current_buf() ~= buf then
    -- 仍写入目标 buffer 光标处（若该 buffer 在某窗中）
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_win_call(win, function()
        insert_text_at_cursor(link, put)
      end)
    else
      -- 无窗：在 buffer 末尾追加
      local line_count = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { link })
    end
  else
    insert_text_at_cursor(link, put)
  end

  if opts.notify ~= false then
    vim.notify(require("mdview.i18n").t("paste_ok") .. rel, vim.log.levels.INFO)
  end
  return true, rel
end

---智能粘贴：剪贴板有图则存图插链接，否则返回 false（调用方做普通粘贴）
---@param opts { buf?: integer, put?: "p"|"P" }|nil
---@return boolean handled
function M.try_paste(opts)
  opts = opts or {}
  local cfg = config.get()
  local pc = paste_cfg(cfg)
  if pc.enable == false then
    return false
  end

  local py = python_cmd(cfg)
  if not py then
    return false
  end

  -- 先快速探测，避免无图时每次都报错
  if not M.clipboard_has_image(py) then
    return false
  end

  -- 剪贴板有图：只走贴图路径（成功或失败都算已处理，避免再粘贴无意义文本）
  M.paste(vim.tbl_extend("force", opts, { notify = true }))
  return true
end

---普通文本粘贴（系统剪贴板 +）
---@param mode "i"|"n"
---@param opts { put?: "p"|"P", reg?: string }|nil
local function fallback_text_paste(mode, opts)
  opts = opts or {}
  if mode == "i" then
    local t = vim.api.nvim_replace_termcodes("<C-r><C-o>+", true, false, true)
    vim.api.nvim_feedkeys(t, "n", false)
  else
    local put = opts.put == "P" and "P" or "p"
    local reg = opts.reg
    if not reg or reg == "" then
      reg = "+"
    end
    local count = vim.v.count1
    if count < 1 then
      count = 1
    end
    -- normal! 避免递归进 p/P 映射
    if reg == '"' then
      vim.cmd("normal! " .. count .. put)
    else
      vim.cmd("normal! " .. count .. '"' .. reg .. put)
    end
  end
end

---绑定到 keymap 的智能粘贴（图优先，否则文本）
---@param mode "i"|"n"
---@param opts { put?: "p"|"P", reg?: string }|nil  normal 模式 p=光标后 / P=光标前
function M.smart_paste(mode, opts)
  opts = opts or {}
  config.ensure_setup()
  local cfg = config.get()
  local pc = paste_cfg(cfg)
  if pc.enable == false then
    fallback_text_paste(mode, opts)
    return
  end

  -- 有图：插链接；无图：正常粘贴文本
  if M.try_paste({
    buf = vim.api.nvim_get_current_buf(),
    put = opts.put,
  }) then
    return
  end
  fallback_text_paste(mode, opts)
end

---@param r string
---@return boolean
local function reg_has_text(r)
  local ok, t = pcall(vim.fn.getreg, r)
  return ok and type(t) == "string" and t ~= ""
end

---p / P 拦截：剪贴板寄存器贴图
---注意：nmap Q "+p 进 Lua 映射时，vim.v.register 经常丢失变成 '"'，不能只认 +/*
---@param put "p"|"P"
function M.put_with_register(put)
  config.ensure_setup()
  local reg = vim.v.register
  if reg == nil or reg == "" then
    reg = '"'
  end
  put = put == "P" and "P" or "p"

  local cfg = config.get()
  local pc = paste_cfg(cfg)
  local try_img = false
  if pc.enable ~= false then
    if reg == "+" or reg == "*" then
      try_img = true
    elseif reg == '"' then
      -- 兼容 Q→"+p：register 变成 " 时，若默认寄存器无文本仍尝试剪贴板图
      if not reg_has_text('"') then
        try_img = true
      end
    end
  end

  if try_img then
    if M.try_paste({
      buf = vim.api.nvim_get_current_buf(),
      put = put,
    }) then
      return
    end
  end

  -- register 丢失时，无文本的 " 改走 +（系统剪贴板）
  local paste_reg = reg
  if reg == '"' and not reg_has_text('"') then
    paste_reg = "+"
  end
  fallback_text_paste("n", { put = put, reg = paste_reg })
end

---仅粘贴图片（无图则提示，不插入文本）
function M.paste_image_only()
  config.ensure_setup()
  M.paste({ buf = vim.api.nvim_get_current_buf(), notify = true })
end

return M
