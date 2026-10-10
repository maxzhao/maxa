local M = {}

local DEFAULT_POLL_INTERVAL = 5 * 60 * 1000 -- 5 minutes in ms
local DEFAULT_INITIAL_DELAY = 10 * 1000 -- Delay first network fetch to avoid slowing down Neovim startup
local DEFAULT_PATH = "/auth/accounts"

local function trim_trailing_slashes(value)
  return tostring(value or ""):gsub("/+$", "")
end

local function normalize_path(path)
  path = tostring(path or DEFAULT_PATH)
  if path == "" then
    return DEFAULT_PATH
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return path
end

local function normalize_api_base(api_base, path)
  local base = trim_trailing_slashes(api_base)
  if base == "" then
    return ""
  end

  -- codex-proxy exposes dashboard/account routes at the site root, while its
  -- OpenAI-compatible Responses endpoint normally uses a .../v1 base URL.
  if path == DEFAULT_PATH and base:match("/v1$") then
    return base:sub(1, -4)
  end
  return base
end

local function as_percent(value)
  local number = type(value) == "number" and value or tonumber(value)
  if not number or number ~= number then
    return nil
  end
  return math.max(0, math.min(100, number))
end

local function redraw_statusline()
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus!")
    local ok, lualine = pcall(require, "lualine")
    if ok and type(lualine.refresh) == "function" then
      pcall(lualine.refresh, { place = { "statusline" } })
    end
  end)
end

local function decode_json(body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local ok, json = pcall(vim.json.decode, body)
  if not ok or type(json) ~= "table" then
    return nil
  end
  return json
end

local function remaining_percent(limit)
  if type(limit) ~= "table" then
    return nil
  end
  local remaining = as_percent(limit.remaining_percent)
  if remaining ~= nil then
    return remaining
  end
  local used = as_percent(limit.used_percent)
  if used ~= nil then
    return 100 - used
  end
  return nil
end

local Provider = {}
Provider.__index = Provider

local function normalize_config(config)
  config = config or {}
  local path = normalize_path(config.path)
  return {
    api_base = normalize_api_base(config.api_base or config.base_url, path),
    api_key = config.api_key,
    path = path,
    poll_interval = tonumber(config.poll_interval) or DEFAULT_POLL_INTERVAL,
    initial_delay = tonumber(config.initial_delay) or DEFAULT_INITIAL_DELAY,
    headers = type(config.headers) == "table" and config.headers or {},
  }
end

local function validate_config(config)
  return type(config.api_base) == "string" and config.api_base ~= ""
end

function Provider:_build_curl_cmd()
  local headers = { "Accept: application/json" }
  if type(self.config.api_key) == "string" and self.config.api_key ~= "" then
    table.insert(headers, "Authorization: Bearer " .. self.config.api_key)
  end
  for name, value in pairs(self.config.headers) do
    if type(name) == "string" and name ~= "" and value ~= nil then
      table.insert(headers, name .. ": " .. tostring(value))
    end
  end

  local args = { "curl", "-sS", "--max-time", "8" }
  require("maxa.adapters.proxy").apply_shell_curl(args, self.adapter)
  for _, header in ipairs(headers) do
    table.insert(args, "-H")
    table.insert(args, vim.fn.shellescape(header))
  end
  table.insert(args, vim.fn.shellescape(self.config.api_base .. self.config.path))
  table.insert(args, "2>/dev/null")
  return table.concat(args, " ")
end

function Provider:_snapshot_from_response(json)
  if type(json) ~= "table" or type(json.accounts) ~= "table" then
    return nil
  end

  local remaining_total = 0
  local account_count = 0
  for _, account in ipairs(json.accounts) do
    if type(account) == "table" and (account.status == nil or account.status == "active") and type(account.quota) == "table" then
      local primary = remaining_percent(account.quota.rate_limit)
      local secondary = remaining_percent(account.quota.secondary_rate_limit)
      local remaining = primary
      if secondary ~= nil and (remaining == nil or secondary < remaining) then
        remaining = secondary
      end
      if remaining ~= nil then
        remaining_total = remaining_total + remaining
        account_count = account_count + 1
      end
    end
  end

  if account_count == 0 then
    return nil
  end

  local total = account_count * 100
  return {
    subscription = {
      remaining = remaining_total,
      total = total,
      used = total - remaining_total,
    },
  }
end

function Provider:_poll()
  if self.polling or not self.valid then
    return
  end
  self.polling = true

  vim.fn.jobstart(self:_build_curl_cmd(), {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local body = data and table.concat(data, "") or ""
      local snapshot = self:_snapshot_from_response(decode_json(body))
      if snapshot then
        self.cache = snapshot
        self.cache_updated_at = os.time()
      end
    end,
    on_exit = function()
      self.polling = false
      redraw_statusline()
    end,
  })
end

function Provider:_ensure_timer()
  if self.timer or not self.valid then
    return
  end
  self.timer = vim.uv.new_timer()
  if not self.timer then
    return
  end
  self.timer:start(self.config.initial_delay, self.config.poll_interval, vim.schedule_wrap(function()
    self:_poll()
  end))
end

function Provider:snapshot()
  self:_ensure_timer()
  return self.cache
end

function Provider:refresh()
  self:_ensure_timer()
  self:_poll()
end

function Provider:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  self.polling = false
end

function M.new(config, adapter)
  local provider = setmetatable({
    config = normalize_config(config),
    adapter = adapter,
    cache = nil,
    cache_updated_at = nil,
    timer = nil,
    polling = false,
    valid = false,
  }, Provider)
  provider.valid = validate_config(provider.config)
  return provider
end

function M._normalize_config(config)
  return normalize_config(config)
end

function M._snapshot_from_response(json)
  local provider = setmetatable({ config = normalize_config({}) }, Provider)
  return provider:_snapshot_from_response(json)
end

return M
