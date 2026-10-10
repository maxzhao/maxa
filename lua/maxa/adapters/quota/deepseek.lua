local M = {}

local DEFAULT_POLL_INTERVAL = 5 * 60 * 1000 -- 5 minutes in ms
local DEFAULT_INITIAL_DELAY = 10 * 1000 -- Delay first network fetch to avoid slowing down Neovim startup
local DEFAULT_PATH = "/user/balance"

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

  -- Accept both the DeepSeek site root and an OpenAI-compatible base (.../v1).
  if path == DEFAULT_PATH and base:match("/v1$") then
    return base:sub(1, -4)
  end
  return base
end

local function as_number(value)
  if type(value) == "number" and value == value then
    return value
  end
  if type(value) == "string" then
    local number = tonumber(value)
    if number and number == number then
      return number
    end
  end
  return nil
end

local function non_negative(value)
  local number = as_number(value)
  if not number then
    return nil
  end
  return math.max(number, 0)
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
  return type(config.api_base) == "string"
    and config.api_base ~= ""
    and type(config.api_key) == "string"
    and config.api_key ~= ""
end

function Provider:_build_curl_cmd()
  local headers = {
    "Authorization: Bearer " .. self.config.api_key,
    "Accept: application/json",
  }

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
  if type(json) ~= "table" or type(json.balance_infos) ~= "table" then
    return nil
  end

  -- DeepSeek may return multiple currencies and does not guarantee their
  -- order. Currency is intentionally ignored; select the largest reported
  -- total so a leading zero-balance currency does not hide an available one.
  local balance
  for _, balance_info in ipairs(json.balance_infos) do
    if type(balance_info) == "table" then
      local candidate = non_negative(balance_info.total_balance)
      if candidate and (balance == nil or candidate > balance) then
        balance = candidate
      end
    end
  end

  if balance then
    return { balance = balance }
  end

  return nil
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
