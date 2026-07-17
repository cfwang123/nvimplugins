if vim.g.loaded_weather then
  return
end
vim.g.loaded_weather = true

local function get_mod()
  local ok, m = pcall(require, "weather")
  if not ok then
    vim.notify("weather: " .. tostring(m), vim.log.levels.ERROR)
    return nil
  end
  m.ensure_setup()
  return m
end

-- 自动 setup：状态栏缓存 + 小时刷新
get_mod()

vim.api.nvim_create_user_command("Weather", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local arg = vim.trim(opts.args or "")
  if arg ~= "" then
    m.set_city(arg)
  end
  m.open()
end, {
  nargs = "?",
  desc = "weather: 10-day forecast popup; optional city name",
})

vim.api.nvim_create_user_command("WeatherCity", function(opts)
  local m = get_mod()
  if not m then
    return
  end
  local arg = vim.trim(opts.args or "")
  if arg == "" then
    vim.notify("weather: usage :WeatherCity <city>", vim.log.levels.WARN)
    return
  end
  m.set_city(arg)
end, {
  nargs = 1,
  desc = "weather: set city and refresh",
})

vim.api.nvim_create_user_command("WeatherRefresh", function()
  local m = get_mod()
  if m then
    m.refresh(true)
  end
end, { desc = "weather: force refresh (bypass cache)" })
