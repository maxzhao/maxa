-- Image adapter capability loading and parameter handling.
local adapter_api = require("maxa.mcphub.native_servers.genai.adapter")
local M = {}

function M.is_absent(value)
  return value == nil or value == vim.NIL or (type(value) == "string" and vim.trim(value) == "")
end

function M.merge_params(defaults, params)
  local merged = vim.deepcopy(defaults or {})
  for key, value in pairs(params or {}) do if not M.is_absent(value) then merged[key] = value end end
  return merged
end

function M.get_adapter(name)
  if M.is_absent(name) then name = nil end
  local service, capability, err = adapter_api.require_capability(name, "image")
  if not service then return nil, err end
  local mode = capability.mode
  if mode ~= "codex" and mode ~= "compatible" then
    return nil, string.format("Adapter '%s' image.mode must be one of: codex, compatible", service.name)
  end
  service.driver = mode == "codex" and "openai_responses_image_generation" or "openai_compatible"
  service.defaults = vim.deepcopy(capability.defaults or {})
  service.endpoints = vim.deepcopy(capability.endpoints or {})
  service.multipart = {
    image_field = (capability.request and capability.request.image_field) or "image",
    mask_field = (capability.request and capability.request.mask_field) or "mask",
  }
  service.max_n = (capability.request and capability.request.max_n) or 15
  -- Streaming avoids long-running image requests timing out. Compatible adapters may explicitly opt out.
  service.force_stream = mode == "codex" or not (capability.request and capability.request.stream == false)
  return service
end

function M.get_driver(adapter)
  if not adapter then return nil, "image adapter is required" end
  if not adapter.driver or adapter.driver == "" then return nil, string.format("Image adapter '%s' is missing driver", adapter.name or "<unknown>") end
  local ok, driver = pcall(require, "maxa.mcphub.native_servers.genai.image.providers." .. adapter.driver)
  if not ok then return nil, string.format("Failed to load image driver '%s' for adapter '%s': %s", adapter.driver, adapter.name or "<unknown>", driver) end
  return driver
end

function M.build_request_params(adapter, params)
  local merged = M.merge_params(adapter.defaults or {}, params or {})
  if not adapter or adapter.force_stream ~= false then merged.stream = true end
  return merged
end

return M
