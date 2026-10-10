-- GenAI adapter resolution, capability validation, defaults merge, and endpoints.
local config = require("maxa.mcphub.native_servers.genai.config")
local registry = require("maxa.mcphub.native_servers.genai.capability_registry")
local utils = require("maxa.mcphub.native_servers.genai.image.utils")
local M = {}

local ENDPOINTS = {
  models = "/models", responses = "/responses", generations = "/images/generations", edits = "/images/edits",
  speech = "/audio/speech", video_create = "/videos", video_retrieve = "/videos/{id}", video_content = "/videos/{id}/content",
}
local MEDIUM = { image = "image", tts = "tts", video = "video" }
local function absent(value) return value == nil or value == vim.NIL or (type(value) == "string" and vim.trim(value) == "") end
local function resolve_value(value, owner)
  if type(value) ~= "function" then return value end
  local ok, result = pcall(value, owner)
  return ok and result or nil
end

function M.merge(defaults, params)
  local result = vim.deepcopy(defaults or {})
  for key, value in pairs(params or {}) do if not absent(value) then result[key] = value end end
  return result
end

function M.endpoint(adapter, key, id, capability)
  local endpoints = (capability and capability.endpoints) or {}
  local capability_key = ({ video_create = "create", video_retrieve = "retrieve", video_content = "content" })[key] or key
  local path = endpoints[capability_key] or (key == "speech" and capability and capability.endpoint) or ENDPOINTS[key]
  if not path then return nil end
  if id then path = path:gsub("{id}", tostring(id)) end
  return utils.join_url(adapter.api_root, path)
end

function M.capability(adapter, name)
  local capability = adapter and adapter[name]
  if not capability then return nil, string.format("Adapter '%s' does not provide %s capability.", tostring(adapter and adapter.name or "<unknown>"), name) end
  return vim.deepcopy(capability)
end

function M.get_adapter(name, medium)
  if not MEDIUM[medium] then return nil, nil, "medium must be one of: image, tts, video" end
  local adapter_name = absent(name) and config.default_adapters[medium] or name
  if absent(adapter_name) then return nil, nil, "no default adapter is configured for " .. medium end
  local declaration = registry.get(adapter_name)
  if not declaration or not declaration.capabilities[medium] then
    return nil, nil, string.format("Adapter '%s' does not provide %s capability.", tostring(adapter_name), medium)
  end

  local provided = require("maxa.provider_config").media(adapter_name, medium)
  if not provided then
    return nil, nil, string.format("Adapter '%s' has no provider-declared %s capability.", adapter_name, medium)
  end
  local attached = provided.capabilities[medium]
  local api_root = provided.api_root
  if absent(api_root) then return nil, nil, "Adapter '" .. adapter_name .. "' does not define backend.api_root" end
  local api_key = resolve_value(attached.api_key) or provided.api_key
  if absent(api_key) then return nil, nil, "API key is missing for adapter '" .. adapter_name .. "'" end

  local capability = vim.deepcopy(attached)
  if medium == "video" and capability.defaults and capability.defaults.preset ~= nil then
    capability.defaults.generation_preset = capability.defaults.generation_preset or capability.defaults.preset
    capability.defaults.preset = nil
  end
  capability.defaults = M.merge(config.defaults[medium], capability.defaults)
  capability.endpoints = vim.deepcopy(capability.endpoints or {})
  capability.request = vim.deepcopy(capability.request or {})
  local service = {
    name = adapter_name,
    adapter = nil,
    api_root = api_root,
    api_key = api_key,
    proxy = function()
      return require("maxa.adapters.proxy").resolve({ backend = { id = provided.provider } })
    end,
    output_dir = capability.output_dir or config.output_dir,
  }
  service[medium] = capability
  return service, capability
end

function M.require_capability(name, medium) return M.get_adapter(name, medium) end
function M.default_endpoint(key) return ENDPOINTS[key] end
return M
