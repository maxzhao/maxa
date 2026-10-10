-- filepath: lua/maxa/mcphub/native_servers/shared/params.lua
-- Shared helpers for normalizing MCP/JSON parameters.
-- JSON null may enter Neovim Lua as vim.NIL; Lua treats vim.NIL as truthy,
-- so handlers must normalize it before defaulting or validation.

local M = {}

---Return true when a value should be treated as “not provided”.
---@param value any
---@return boolean
function M.is_absent(value)
  return value == nil or value == vim.NIL
end

---Recursively convert vim.NIL values to nil in tables.
---This mutates the table in place and also returns it.
---@param value any
---@return any
function M.null_to_nil(value)
  if value == vim.NIL then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end
  for k, v in pairs(value) do
    value[k] = M.null_to_nil(v)
  end
  return value
end

---Return a normalized shallow/deep copy of request params.
---@param params table|nil
---@return table
function M.normalize(params)
  if type(params) ~= "table" then
    return {}
  end
  return M.null_to_nil(vim.deepcopy(params))
end

---Get a boolean option with a default.
---@param value any
---@param default boolean|nil
---@return boolean
function M.boolean(value, default)
  if M.is_absent(value) then
    return default == true
  end
  return value == true
end

---Get a value or default when absent.
---@param value any
---@param default any
---@return any
function M.default(value, default)
  if M.is_absent(value) then
    return default
  end
  return value
end

---Validate a required non-empty string.
---@param value any
---@param name string
---@return string|nil value
---@return string|nil error
function M.required_string(value, name)
  if M.is_absent(value) or type(value) ~= "string" or vim.trim(value) == "" then
    return nil, name .. " is required"
  end
  return value, nil
end

---Validate an optional string; absent/empty returns default.
---@param value any
---@param default string|nil
---@return string|nil value
function M.optional_string(value, default)
  if M.is_absent(value) then
    return default
  end
  return value
end

return M
