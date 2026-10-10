local M = {}

local providers = {}
local quota_configs = {}
local quota_adapters = {}

local default_registered = false

local function normalize_adapter_name(adapter_name)
  if type(adapter_name) ~= "string" or adapter_name == "" then
    return nil
  end
  return adapter_name:lower()
end

local function adapter_names(chat)
  if type(chat) ~= "table" then
    return {}
  end

  local names = {}
  if type(chat.adapter_name) == "string" then
    table.insert(names, chat.adapter_name)
  end
  if type(chat.adapter_display_name) == "string" then
    table.insert(names, chat.adapter_display_name)
  end
  if type(chat.adapter) == "table" then
    table.insert(names, chat.adapter.name)
    table.insert(names, chat.adapter.formatted_name)
  end

  return names
end

local function get_adapter_quota_config(chat)
  if type(chat) == "table" and type(chat.adapter) == "table" and type(chat.adapter.quota) == "table" then
    return chat.adapter.quota
  end

  for _, name in ipairs(adapter_names(chat)) do
    local normalized = normalize_adapter_name(name)
    if normalized and quota_configs[normalized] then
      return quota_configs[normalized]
    end
  end

  return nil
end

local function provider_key_for_chat(chat)
  local adapter = type(chat) == "table" and chat.adapter or nil
  local id = type(adapter) == "table" and adapter.backend and adapter.backend.id
  if type(id) == "string" and id ~= "" then return "provider:" .. id:lower() end
  for _, name in ipairs(adapter_names(chat)) do
    local normalized = normalize_adapter_name(name)
    if normalized then
      return normalized
    end
  end
  return nil
end

local function instantiate_provider(config, adapter)
  if type(config) ~= "table" then
    return nil
  end

  if config.provider == "newapi" then
    if config.access_token == nil or config.user_id == nil then
      return nil
    end
    local ok, newapi_quota = pcall(require, "maxa.adapters.quota.newapi")
    if not ok or type(newapi_quota) ~= "table" or type(newapi_quota.new) ~= "function" then
      return nil
    end
    return newapi_quota.new(config, adapter)
  end

  if config.provider == "sub2api" then
    if config.api_key == nil then
      return nil
    end
    local ok, sub2api_quota = pcall(require, "maxa.adapters.quota.sub2api")
    if not ok or type(sub2api_quota) ~= "table" or type(sub2api_quota.new) ~= "function" then
      return nil
    end
    return sub2api_quota.new(config, adapter)
  end

  if config.provider == "deepseek" then
    if config.api_key == nil then
      return nil
    end
    local ok, deepseek_quota = pcall(require, "maxa.adapters.quota.deepseek")
    if not ok or type(deepseek_quota) ~= "table" or type(deepseek_quota.new) ~= "function" then
      return nil
    end
    return deepseek_quota.new(config, adapter)
  end

  if config.provider == "local" then
    local ok, local_quota = pcall(require, "maxa.adapters.quota.local")
    if not ok or type(local_quota) ~= "table" or type(local_quota.new) ~= "function" then
      return nil
    end
    return local_quota.new(config, adapter)
  end

  return nil
end

local function provider_for_chat(chat)
  local key = provider_key_for_chat(chat)
  if key and providers[key] then
    return providers[key]
  end

  local config = get_adapter_quota_config(chat)
  local adapter = type(chat) == "table" and type(chat.adapter) == "table" and chat.adapter or quota_adapters[key]
  local provider = instantiate_provider(config, adapter)
  if provider and key then
    providers[key] = provider
  end
  return provider
end

local function call_provider(provider, method, chat)
  if type(provider) ~= "table" then
    return nil
  end

  local fn = provider[method]
  if type(fn) ~= "function" then
    return nil
  end

  local ok, result = pcall(fn, provider, chat)
  if ok then
    return result
  end
  return nil
end

local function as_number(value)
  if type(value) == "number" and value >= 0 then
    return value
  end
  if type(value) == "string" then
    local n = tonumber(value)
    if n and n >= 0 then
      return n
    end
  end
  return nil
end

local function format_money(value)
  local n = as_number(value)
  if not n then
    return nil
  end
  return string.format("%.2f", n)
end

local function format_short(value)
  local n = as_number(value)
  if not n then
    return nil
  end
  if n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return string.format("%.0f", n)
end

local function parts_from_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return {}
  end

  local balance = as_number(snapshot.balance)
  local parts = {
    balance_value = balance,
    balance_text = format_money(balance),
  }

  local subscription = snapshot.subscription
  if type(subscription) == "table" then
    local remaining = as_number(subscription.remaining)
    local total = as_number(subscription.total)
    local used = as_number(subscription.used)
    if remaining and total then
      parts.subscription_remaining = remaining
      parts.subscription_total = total
      parts.subscription_used = used
      parts.subscription_text = format_short(remaining) .. "/" .. format_short(total)
    end
  end

  return parts
end

function M.register(adapter_name, provider)
  local normalized = normalize_adapter_name(adapter_name)
  if not normalized or provider == nil then
    return false
  end
  providers[normalized] = provider
  return true
end

function M.unregister(adapter_name)
  local normalized = normalize_adapter_name(adapter_name)
  if not normalized then
    return false
  end
  local adapter = quota_adapters[normalized]
  local group = adapter and adapter.backend and adapter.backend.id
  local cache_key = type(group) == "string" and group ~= "" and ("provider:" .. group:lower()) or normalized
  for _, key in ipairs(cache_key == normalized and { normalized } or { normalized, cache_key }) do
    local provider = providers[key]
    if type(provider) == "table" and type(provider.stop) == "function" then
      pcall(provider.stop, provider)
    end
    providers[key] = nil
  end
  quota_configs[normalized] = nil
  quota_adapters[normalized] = nil
  return true
end

function M.register_adapter_quota(adapter_name, quota_config, adapter)
  local normalized = normalize_adapter_name(adapter_name)
  if not normalized or type(quota_config) ~= "table" then
    return false
  end
  quota_configs[normalized] = quota_config
  quota_adapters[normalized] = type(adapter) == "table" and adapter or nil

  local group = adapter and adapter.backend and adapter.backend.id
  local cache_key = type(group) == "string" and group ~= "" and ("provider:" .. group:lower()) or normalized
  local old_provider = providers[cache_key]
  if type(old_provider) == "table" and type(old_provider.stop) == "function" then
    pcall(old_provider.stop, old_provider)
  end
  providers[cache_key] = nil
  return true
end

function M.snapshot(chat)
  local provider = provider_for_chat(chat)
  return call_provider(provider, "snapshot", chat)
end

function M.parts(chat)
  return parts_from_snapshot(M.snapshot(chat))
end

function M.refresh(chat)
  local provider = provider_for_chat(chat)
  call_provider(provider, "refresh", chat)
end

function M.has_provider(chat)
  return provider_for_chat(chat) ~= nil
end

function M.register_defaults()
  if default_registered then
    return
  end
  default_registered = true
end

function M._providers()
  return providers
end

function M._quota_configs()
  return quota_configs
end

return M
