local M = {}

local ADAPTER_LIMITS = {}

-- Ordered, most-specific rules first. Keep model capabilities here so request
-- adapters and status/reporting code use the same source of truth.
local MODEL_LIMITS = {
  -- DeepSeek V4
  { pattern = "^deepseek%-v4%-flash$", context_window = 500000, max_output_tokens = 384000 },
  { pattern = "^deepseek%-v4%-pro$", context_window = 500000, max_output_tokens = 384000 },
  { pattern = "^deepseek%-", context_window = 1000000 },

  -- Claude
  { pattern = "^claude%-", context_window = 1000000 },

  -- GPT
  { pattern = "^gpt%-4o", context_window = 128000 },
  { pattern = "^gpt%-4", context_window = 128000 },
  { pattern = "^gpt%-5", context_window = 280000 * 1.5, warning_threshold = 280000 * 1.8 },
  { pattern = "^gpt%-6", context_window = 280000 * 1.5, warning_threshold = 280000 * 1.8 },
  { pattern = "^chatgpt%-4o", context_window = 128000 },

  -- OpenAI reasoning
  { pattern = "^o[1-9]", context_window = 200000 },
  { pattern = "^codex%-", context_window = 200000 },

  -- Other model families
  { pattern = "^gemini%-", context_window = 1000000 },
  { pattern = "^qwen", context_window = 131072 },
  { pattern = "^glm%-", context_window = 128000 },
  { pattern = "^grok%-", context_window = 131072 },
  { pattern = "^goldeneye", context_window = 128000 },
}

local function as_number(value)
  local number = type(value) == "number" and value or type(value) == "string" and tonumber(value) or nil
  return number and number > 0 and number or nil
end

local function normalize_model_name(model_name)
  if type(model_name) ~= "string" then
    return nil
  end
  local normalized = model_name:lower():gsub("^%s+", ""):gsub("%s+$", "")
  return normalized ~= "" and normalized or nil
end

local function resolve_adapter_limits(adapter_name)
  if type(adapter_name) ~= "string" or adapter_name == "" then
    return nil
  end
  local limits = require("maxa.config").runtime().model_limits.adapter_overrides[adapter_name]
    or ADAPTER_LIMITS[adapter_name]
  if limits then
    return limits
  end
  return nil
end

function M.get_model_name(adapter)
  if type(adapter) ~= "table" then
    return nil
  end
  if type(adapter.model) == "table" and type(adapter.model.name) == "string" and adapter.model.name ~= "" then
    return adapter.model.name
  end
  local schema_model = adapter.schema and adapter.schema.model
  local default = schema_model and schema_model.default
  if type(default) == "function" then
    local ok, value = pcall(default, adapter)
    default = ok and value or nil
  end
  return type(default) == "string" and default ~= "" and default or nil
end

function M.resolve(model_name, adapter_name)
  local normalized = normalize_model_name(model_name)
  if not normalized then
    return nil
  end

  local resolved
  local configured = require("maxa.config").runtime().model_limits.model_overrides
  for _, entry in ipairs(configured) do
    if type(entry.pattern) == "string" and normalized:match(entry.pattern) then
      resolved = vim.deepcopy(entry)
      resolved.pattern = nil
      break
    end
  end
  for _, entry in ipairs(MODEL_LIMITS) do
    if resolved then
      break
    end
    if normalized:match(entry.pattern) then
      resolved = vim.deepcopy(entry)
      resolved.pattern = nil
      break
    end
  end
  local model = require("maxa.config").runtime().models[normalized]
  if type(model) == "table" then
    resolved = resolved or {}
    for _, key in ipairs({ "context_window", "warning_threshold", "max_output_tokens" }) do
      local number = as_number(model[key])
      if number then
        resolved[key] = number
      end
    end
  end
  if not resolved or vim.tbl_isempty(resolved) then
    return nil
  end

  local adapter_limits = resolve_adapter_limits(adapter_name)
  if adapter_limits then
    for key, value in pairs(adapter_limits) do
      if resolved[key] then
        resolved[key] = math.min(resolved[key], value)
      else
        resolved[key] = value
      end
    end
  end
  return resolved
end

function M.get_context_window(model_name, adapter_name)
  local limits = M.resolve(model_name, adapter_name)
  return limits and limits.context_window or nil
end

function M.get_warning_threshold(model_name, adapter_name)
  local limits = M.resolve(model_name, adapter_name)
  return limits and (limits.warning_threshold or limits.context_window) or nil
end

function M.get_max_output_tokens(model_name, adapter_name)
  local limits = M.resolve(model_name, adapter_name)
  return limits and limits.max_output_tokens or nil
end

function M.resolve_adapter(adapter)
  if type(adapter) ~= "table" then
    return nil
  end
  return M.resolve(M.get_model_name(adapter), adapter.name)
end

function M.set_adapter_limit(adapter_name, key, limit)
  local number = as_number(limit)
  if type(adapter_name) ~= "string" or adapter_name == "" or type(key) ~= "string" or not number then
    return false
  end
  ADAPTER_LIMITS[adapter_name] = ADAPTER_LIMITS[adapter_name] or {}
  ADAPTER_LIMITS[adapter_name][key] = number
  return true
end

function M.set_model_limit(pattern, limits)
  if type(pattern) ~= "string" or pattern == "" or type(limits) ~= "table" then
    return false
  end
  local entry = { pattern = pattern }
  for _, key in ipairs({ "context_window", "warning_threshold", "max_output_tokens" }) do
    local number = as_number(limits[key])
    if number then
      entry[key] = number
    end
  end
  if not entry.context_window and not entry.warning_threshold and not entry.max_output_tokens then
    return false
  end
  table.insert(MODEL_LIMITS, 1, entry)
  return true
end

return M
