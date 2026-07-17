if vim.g.loaded_qrbuf then
  return
end
vim.g.loaded_qrbuf = true

local function get_mod()
  local ok, m = pcall(require, "qrbuf")
  if not ok then
    vim.notify("qrbuf: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

get_mod()

vim.api.nvim_create_user_command("QrBuf", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local text = opts.args
  if text and text ~= "" then
    m.open({ text = text })
    return
  end
  -- 带 range（可视选区 :'<,'>QrBuf 或 :QrBuf 行范围）
  if opts.range and opts.range > 0 then
    local mode = vim.fn.visualmode()
    if mode == "v" or mode == "\22" then
      m.open({
        line1 = opts.line1,
        line2 = opts.line2,
        col1 = vim.fn.col("'<"),
        col2 = vim.fn.col("'>"),
        visual = mode,
      })
    else
      m.open({
        line1 = opts.line1,
        line2 = opts.line2,
      })
    end
    return
  end
  m.open({})
end, {
  nargs = "*",
  range = true,
  desc = "qrbuf: show QR code for args / selection / current line",
})

vim.api.nvim_create_user_command("QR", function(opts)
  vim.cmd("QrBuf " .. (opts.args or ""))
end, {
  nargs = "*",
  range = true,
  desc = "qrbuf: alias of QrBuf",
})
