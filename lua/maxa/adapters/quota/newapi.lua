local M = {}

local DEFAULT_POLL_INTERVAL = 5 * 60 * 1000 -- 5 minutes in ms
local DEFAULT_INITIAL_DELAY = 10 * 1000 -- Delay first network fetch to avoid slowing down Neovim startup
local DEFAULT_QUOTA_UNIT = 500000 -- New API internal quota unit -> USD-compatible credit value

local function trim_trailing_slashes(value)
  return tostring(value or ""):gsub("/+$", "")
end

local function quota_value(value, quota_unit)
  value = tonumber(value)
  if not value then
    return nil
  end
  return value / quota_unit
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
  if not ok or type(json) ~= "table" or json.success == false then
    return nil
  end
  return json
end

local function pick_subscription(data)
  if type(data) ~= "table" then
    return nil
  end

  local candidates = {}
  local function add_items(items)
    if type(items) ~= "table" then
      return
    end
    for _, item in ipairs(items) do
      local sub = item and (item.subscription or item)
      if type(sub) == "table" and sub.status == "active" then
        table.insert(candidates, sub)
      end
    end
  end

  -- New API frontends commonly expose subscriptions/all_subscriptions from /api/subscription/self.
  add_items(data.subscriptions)
  add_items(data.all_subscriptions)

  if #candidates == 0 then
    return nil
  end

  -- Prefer the active subscription with the latest end_time.
  table.sort(candidates, function(a, b)
    return (tonumber(a.end_time) or 0) > (tonumber(b.end_time) or 0)
  end)
  return candidates[1]
end

local Provider = {}
Provider.__index = Provider

local function normalize_config(config)
  config = config or {}
  local api_base = trim_trailing_slashes(config.api_base)
  return {
    api_base = api_base,
    access_token = config.access_token,
    user_id = config.user_id,
    quota_unit = tonumber(config.quota_unit) or DEFAULT_QUOTA_UNIT,
    poll_interval = tonumber(config.poll_interval) or DEFAULT_POLL_INTERVAL,
    initial_delay = tonumber(config.initial_delay) or DEFAULT_INITIAL_DELAY,
    paths = vim.tbl_extend("force", {
      user = "/api/user/self",
      subscription = "/api/subscription/self",
    }, type(config.paths) == "table" and config.paths or {}),
    headers = type(config.headers) == "table" and config.headers or {},
  }
end

local function validate_config(config)
  return type(config.api_base) == "string"
    and config.api_base ~= ""
    and type(config.access_token) == "string"
    and config.access_token ~= ""
    and type(config.user_id) == "string"
    and config.user_id ~= ""
end

function Provider:_build_curl_cmd(path)
  local headers = {
    "Authorization: Bearer " .. self.config.access_token,
    "New-Api-User: " .. self.config.user_id,
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
  table.insert(args, vim.fn.shellescape(self.config.api_base .. path))
  table.insert(args, "2>/dev/null")

  return table.concat(args, " ")
end

function Provider:_snapshot_from_responses(user_json, sub_json)
  local user = user_json and user_json.data or {}
  local balance = quota_value(user.quota, self.config.quota_unit)
  if not balance then
    return nil
  end

  local snapshot = { balance = balance }
  local sub = sub_json and pick_subscription(sub_json.data)
  if sub then
    local total = quota_value(sub.amount_total, self.config.quota_unit)
    local used = quota_value(sub.amount_used, self.config.quota_unit)
    if total and used then
      snapshot.subscription = {
        remaining = math.max(total - used, 0),
        total = total,
        used = used,
      }
    end
  end

  return snapshot
end

function Provider:_poll()
  if self.polling or not self.valid then
    return
  end
  self.polling = true

  local results = {}
  local remaining = 2

  local function done()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    self.polling = false

    if results.user then
      local snapshot = self:_snapshot_from_responses(results.user, results.subscription)
      if snapshot then
        self.cache = snapshot
        self.cache_updated_at = os.time()
      end
    end

    redraw_statusline()
  end

  local function start_request(name, path)
    vim.fn.jobstart(self:_build_curl_cmd(path), {
      stdout_buffered = true,
      on_stdout = function(_, data)
        local body = data and table.concat(data, "") or ""
        results[name] = decode_json(body)
      end,
      on_exit = function()
        done()
      end,
    })
  end

  start_request("user", self.config.paths.user)
  start_request("subscription", self.config.paths.subscription)
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

return M
