-- Shared adapter resolution helpers for genai image providers.

local M = {}

function M.resolve_adapter(provider)
  local adapter_name = provider and provider.adapter
  if not adapter_name or adapter_name == "" then
    return nil, "adapter is required for image provider '" .. tostring(provider and provider.name or "<unknown>") .. "'"
  end

  local ok, adapter = pcall(function()
    return require("maxa.adapters").resolve(adapter_name)
  end)
  if not ok or not adapter then
    return nil, "Failed to resolve Maxa AI adapter '" .. tostring(adapter_name) .. "': " .. tostring(adapter)
  end

  return adapter, nil
end

function M.resolve_adapter_env(adapter, key)
  local env = adapter and adapter.env or {}
  local value = env[key]
  if type(value) == "function" then
    value = value(adapter)
  end
  return value
end

function M.normalize_optional_string(value)
  if value == nil or value == vim.NIL or value == "" then
    return nil
  end
  return value
end

function M.resolve_proxy(adapter)
  return require("maxa.adapters.proxy").resolve(adapter)
end

function M.resolve_adapter_model(adapter)
  local model = adapter and adapter.schema and adapter.schema.model and adapter.schema.model.default
  if type(model) == "function" then
    model = model(adapter)
  end
  if not model or model == "" then
    model = adapter and adapter.model and adapter.model.name
  end
  return model
end

function M.resolve_adapter_settings(provider)
  local adapter, err = M.resolve_adapter(provider)
  if not adapter then
    return nil, err
  end

  local url = adapter.url
  if type(url) == "function" then
    url = url(adapter)
  end
  if not url or url == "" then
    return nil, "adapter '" .. tostring(provider.adapter) .. "' does not define url"
  end

  local api_key = M.normalize_optional_string(M.resolve_adapter_env(adapter, "image_api_key"))
    or M.normalize_optional_string(M.resolve_adapter_env(adapter, "api_key"))

  return {
    adapter = adapter,
    url = url,
    api_key = api_key,
    model = M.resolve_adapter_model(adapter),
    proxy = M.resolve_proxy(adapter),
  }, nil
end

function M.resolve_static_settings(provider)
  local api_key = provider and provider.api_key
  if type(api_key) == "function" then
    api_key = api_key(provider)
  end
  api_key = M.normalize_optional_string(api_key)

  local model = provider and provider.defaults and provider.defaults.model
  if type(model) == "function" then
    model = model(provider)
  end

  return {
    adapter = nil,
    url = provider and provider.base_url,
    api_key = api_key,
    model = model,
  }, nil
end

function M.resolve_provider_settings(provider)
  if provider and provider.api_root and provider.api_root ~= "" and provider.api_key and provider.api_key ~= "" then
    return {
      adapter = provider.adapter,
      url = provider.driver == "openai_responses_image_generation"
          and require("maxa.mcphub.native_servers.genai.image.utils").join_url(provider.api_root, (provider.endpoints and provider.endpoints.responses) or "/responses")
        or provider.api_root,
      api_key = provider.api_key,
      model = provider.defaults and provider.defaults.model,
      proxy = provider.proxy,
    }, nil
  end
  return nil, "resolved GenAI adapter settings are required"
end

return M
