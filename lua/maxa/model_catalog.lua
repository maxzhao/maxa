-- One effective view of model facts already owned by protocol adapters and model_limits.
-- User overrides extend that view; they never mutate adapter prototypes.
local M = {}

local PROTOCOLS = {
  openai_responses = "openai_responses",
  anthropic_messages = "anthropic",
  openai_compatible = "openai_compatible",
  gemini = "gemini",
}

function M.protocols()
  return vim.deepcopy(PROTOCOLS)
end

function M.choices(protocol)
  local module = PROTOCOLS[protocol]
  if not module then return nil, "unsupported LLM protocol: " .. tostring(protocol) end
  local base = require("maxa.adapters.http." .. module)
  local builtin = base.schema and base.schema.model and base.schema.model.choices
  local choices = type(builtin) == "table" and vim.deepcopy(builtin) or {}
  local configured = require("maxa.config").runtime().models or {}
  for id, definition in pairs(configured) do
    local settings = type(definition) == "table" and definition.llm and definition.llm[protocol]
    if type(settings) == "table" then
      choices[id] = vim.tbl_deep_extend("force", choices[id] or {}, vim.deepcopy(settings))
    end
  end
  return choices
end

function M.get(model, protocol, adapter)
  local choices, err = M.choices(protocol)
  if not choices then return nil, err end
  local info = vim.deepcopy(choices[model] or {})
  local limits = require("maxa.session.model_limits").resolve(model, adapter)
  if limits then info.limits = limits end
  return info
end

return M
