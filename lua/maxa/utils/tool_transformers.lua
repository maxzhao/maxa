-- Utility functions to transform tool schemas between different formats.
local M = {}

---Convert the OpenAI schema to Anthropic's schema.
---@param schema table
---@return table
function M.to_anthropic(schema)
  local function_def = schema["function"]
  return {
    name = function_def.name,
    description = function_def.description,
    input_schema = {
      type = function_def.parameters.type,
      properties = function_def.parameters.properties,
      required = function_def.parameters.required,
    },
  }
end

return M
