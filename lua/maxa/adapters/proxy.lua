-- One provider-owned policy for Chat, model discovery, quota and GenAI requests.
local M = {}
local configured_proxy

local function address(value, label)
  if value == nil then return nil end
  assert(type(value) == "string" and value:match("%S"), label .. " must return a nonempty proxy address or nil")
  return value
end

function M.get_proxy()
  return configured_proxy
end

function M.configure(value)
  assert(value == nil or value == false or type(value) == "function" or (type(value) == "string" and value:match("%S")),
    "maxa.proxy must be false, 'env', a nonempty proxy address or function")
  configured_proxy = value
end

local function provider_for(adapter)
  local id = type(adapter) == "table" and adapter.backend and adapter.backend.id
  if type(id) ~= "string" then return nil end
  return require("maxa.provider_config").provider(id)
end

function M.needs_proxy(adapter)
  local provider = provider_for(adapter)
  return provider ~= nil and provider.proxy ~= nil and provider.proxy ~= false
end

--- Resolve the provider policy anew for each outbound request.
--- @param adapter table|nil A provider-built adapter or { backend = { id = provider_id } }.
--- @return string|nil
function M.resolve(adapter)
  local provider = provider_for(adapter)
  if not provider then return nil end
  local choice = provider.proxy
  if choice == nil or choice == false then return nil end
  if choice == true then
    choice = configured_proxy
    if choice == false then return nil end
    if choice == "env" then choice = require("maxa.utils.env").proxy() end
  end
  if type(choice) == "function" then choice = choice(provider) end
  return address(choice, "proxy for provider " .. provider.id)
end

--- Explicit direct routing avoids curl's inherited proxy environment when policy returns nil.
function M.apply_curl(args, adapter)
  local resolved = M.resolve(adapter)
  if resolved then
    table.insert(args, "--proxy")
    table.insert(args, resolved)
  else
    table.insert(args, "--noproxy")
    table.insert(args, "*")
  end
  return args
end

function M.apply_shell_curl(args, adapter)
  local resolved = M.resolve(adapter)
  if resolved then
    table.insert(args, "--proxy")
    table.insert(args, vim.fn.shellescape(resolved))
  else
    table.insert(args, "--noproxy")
    table.insert(args, vim.fn.shellescape("*"))
  end
  return args
end

return M
