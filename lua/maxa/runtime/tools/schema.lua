-- filepath: lua/maxa/runtime/tools/schema.lua
--- Phase-3 W1: lightweight JSON Schema subset validator (draft-07 common
--- subset) for tool input schemas.
---
--- Supported keywords:
---   type (string or array), required, properties, items (single-schema
---   form), enum, additionalProperties (boolean or schema), oneOf (exactly-one
---   match), plus boolean schemas (true/false, draft-07).
---
--- Unknown keywords are annotations and ignored (JSON Schema semantics).
--- Malformed schema definitions FAIL CLOSED: validate_schema_definition /
--- normalize reject them; validating a value against a malformed schema fails
--- with a ".schema" diagnostic instead of silently passing.
---
--- Error convention: validation errors carry an exact field path relative to
--- the validated root plus the failing constraint, e.g.
---   "path.required"                 (missing required property "path" at root)
---   "path.type"                     (property "path" failed its type check)
---   "items[2].type"                 (second array element failed type check)
---   "extra.additionalProperties"    (disallowed extra property)
---   "oneOf"                         (exactly-one constraint violated at root)
--- At the root (path ""), only the constraint kind is returned ("type",
--- "oneOf", "enum", ...). Callers that validate tool-call arguments prefix the
--- root variable name ("args") to produce e.g. "args.path.required".
---
--- Lua/JSON note: vim.json decodes both `{}` and `[]` to an empty Lua table,
--- so an empty table matches both "object" and "array" types. "number" also
--- matches integral values; "integer" accepts integral numbers only.
---
--- It never loads codecompanion.* / mcphub.* / lua/util/hooks/*.

local M = {}

M.name = "tools.schema"

local islist = vim.islist or vim.tbl_islist

M.VALID_TYPES = {
  object = true,
  string = true,
  number = true,
  integer = true,
  boolean = true,
  array = true,
  null = true,
}

-------------------------------------------------------------------------------
-- Type helpers
-------------------------------------------------------------------------------

--- JSON type of a decoded value. Empty tables are ambiguous ({} vs []) and
--- resolve to "object"; type matching additionally accepts empty tables for
--- "array" (see type_matches).
---@param v any decoded JSON value (vim.NIL is JSON null)
---@return string "object"|"string"|"number"|"boolean"|"array"|"null"
local function json_type(v)
  if v == nil or v == vim.NIL then
    return "null"
  end
  local t = type(v)
  if t == "number" then
    return "number"
  end
  if t == "table" then
    return (islist(v) and next(v) ~= nil) and "array" or "object"
  end
  return t -- "string" | "boolean"
end

---@param types string|string[] declared type keyword(s)
---@param v any decoded value
---@return boolean
local function type_matches(types, v)
  local list = type(types) == "table" and types or { types }
  local jt = json_type(v)
  for _, t in ipairs(list) do
    if t == jt then
      return true
    end
    if t == "integer" and jt == "number" and type(v) == "number" and v % 1 == 0 then
      return true
    end
    -- Empty Lua table matches both object and array (Lua/JSON ambiguity).
    if type(v) == "table" and next(v) == nil and (t == "object" or t == "array") then
      return true
    end
  end
  return false
end

--- Deep equality for enum members (plain JSON values).
---@param a any
---@param b any
---@return boolean
local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) == "table" and type(b) == "table" then
    local ka = vim.tbl_keys(a)
    local kb = vim.tbl_keys(b)
    if #ka ~= #kb then
      return false
    end
    for _, k in ipairs(ka) do
      if not deep_equal(a[k], b[k]) then
        return false
      end
    end
    return true
  end
  return false
end

--- Deep copy (plain tables; used for schema normalization + provider copies).
---@param v any
---@return any
local function deep_copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, val in pairs(v) do
    out[deep_copy(k)] = deep_copy(val)
  end
  return out
end

---@param path string current path ("" at root)
---@param key string property key
---@return string
local function key_path(path, key)
  return path == "" and key or (path .. "." .. key)
end

-------------------------------------------------------------------------------
-- Schema definition validation (fail-closed)
-------------------------------------------------------------------------------

--- Validate a schema definition recursively. Any malformed keyword fails the
--- whole definition (fail-closed); unknown keywords are ignored.
---@param schema any
---@param errors string[]
---@param path string diagnostic path
local function def_errors(schema, errors, path)
  if schema == true or schema == false then
    return -- boolean schemas are valid
  end
  if type(schema) ~= "table" then
    errors[#errors + 1] = path .. ": schema must be an object or boolean"
    return
  end
  if schema.type ~= nil then
    local types = type(schema.type) == "table" and schema.type or { schema.type }
    if type(types) ~= "table" then
      errors[#errors + 1] = path .. ".type: must be a string or array of strings"
    else
      for _, t in ipairs(types) do
        if type(t) ~= "string" or not M.VALID_TYPES[t] then
          errors[#errors + 1] = path .. ".type: unknown type " .. tostring(t)
        end
      end
    end
  end
  if schema.properties ~= nil then
    if type(schema.properties) ~= "table" then
      errors[#errors + 1] = path .. ".properties: must be an object of schemas"
    else
      for k, sub in pairs(schema.properties) do
        def_errors(sub, errors, path .. ".properties." .. tostring(k))
      end
    end
  end
  if schema.required ~= nil then
    if type(schema.required) ~= "table" or not islist(schema.required) then
      errors[#errors + 1] = path .. ".required: must be an array of property names"
    else
      for _, r in ipairs(schema.required) do
        if type(r) ~= "string" then
          errors[#errors + 1] = path .. ".required: entries must be strings"
          break
        end
      end
    end
  end
  if schema.items ~= nil then
    if type(schema.items) == "table" and islist(schema.items) then
      -- Tuple form is out of the supported subset: fail-closed rather than
      -- silently validating with the wrong semantics.
      errors[#errors + 1] = path .. ".items: tuple form is not supported (single-schema form only)"
    elseif type(schema.items) == "table" then
      def_errors(schema.items, errors, path .. ".items")
    elseif type(schema.items) ~= "boolean" then
      errors[#errors + 1] = path .. ".items: must be a schema"
    end
  end
  if schema.enum ~= nil then
    if type(schema.enum) ~= "table" or not islist(schema.enum) or #schema.enum == 0 then
      errors[#errors + 1] = path .. ".enum: must be a non-empty array"
    end
  end
  if schema.oneOf ~= nil then
    if type(schema.oneOf) ~= "table" or not islist(schema.oneOf) or #schema.oneOf == 0 then
      errors[#errors + 1] = path .. ".oneOf: must be a non-empty array of schemas"
    else
      for i, sub in ipairs(schema.oneOf) do
        def_errors(sub, errors, path .. ".oneOf[" .. i .. "]")
      end
    end
  end
  if schema.additionalProperties ~= nil then
    if type(schema.additionalProperties) == "table" then
      def_errors(schema.additionalProperties, errors, path .. ".additionalProperties")
    elseif type(schema.additionalProperties) ~= "boolean" then
      errors[#errors + 1] = path .. ".additionalProperties: must be a boolean or a schema"
    end
  end
end

--- Validate a schema definition itself. Fail-closed: any malformed keyword
--- rejects the definition.
---@param schema any
---@return boolean ok
---@return string|nil err first definition error
function M.validate_schema_definition(schema)
  local errors = {}
  def_errors(schema, errors, "$")
  if #errors == 0 then
    return true, nil
  end
  return false, errors[1]
end

--- Normalize a schema: validate the definition (fail-closed) and return a deep
--- copy that the caller owns. The normalized schema is never weakened; it is
--- the single canonical form the registry stores.
---@param schema any
---@return table|nil normalized deep copy
---@return string|nil err definition error
function M.normalize(schema)
  local ok, derr = M.validate_schema_definition(schema)
  if not ok then
    return nil, derr
  end
  return deep_copy(schema), nil
end

---@param schema any
---@return any deep copy (provider adaptation surface)
function M.copy(schema)
  return deep_copy(schema)
end

-------------------------------------------------------------------------------
-- Value validation
-------------------------------------------------------------------------------

--- Validate a value against a schema, collecting errors (exact field paths).
---@param schema any
---@param value any decoded JSON value
---@param path string current path ("" at root)
---@param errors string[]
local function validate_impl(schema, value, path, errors)
  -- Boolean schemas (draft-07).
  if schema == true then
    return
  end
  if schema == false then
    errors[#errors + 1] = path == "" and "false" or (path .. ".false")
    return
  end
  if type(schema) ~= "table" then
    -- Malformed schema: fail-closed.
    errors[#errors + 1] = path == "" and "schema" or (path .. ".schema")
    return
  end

  local function fail(kind)
    errors[#errors + 1] = path == "" and kind or (path .. "." .. kind)
  end

  if schema.type ~= nil and not type_matches(schema.type, value) then
    fail("type")
  end

  if schema.enum ~= nil then
    local found = false
    for _, member in ipairs(schema.enum) do
      if deep_equal(member, value) then
        found = true
        break
      end
    end
    if not found then
      fail("enum")
    end
  end

  -- Object keywords (only for non-list tables; an EMPTY table is treated as an
  -- object shape here, matching the Lua/JSON ambiguity note — vim.tbl_islist
  -- classifies {} as a list, which would skip required/properties checks).
  local value_is_object = type(value) == "table" and (next(value) == nil or not islist(value))
  if value_is_object then
    if schema.properties ~= nil then
      for key, sub in pairs(schema.properties) do
        if value[key] ~= nil then
          validate_impl(sub, value[key], key_path(path, key), errors)
        end
      end
    end
    if schema.required ~= nil then
      for _, key in ipairs(schema.required) do
        if value[key] == nil then
          errors[#errors + 1] = key_path(path, key) .. ".required"
        end
      end
    end
    if schema.additionalProperties ~= nil then
      local ap = schema.additionalProperties
      for key, v in pairs(value) do
        if schema.properties == nil or schema.properties[key] == nil then
          if ap == false then
            errors[#errors + 1] = key_path(path, key) .. ".additionalProperties"
          elseif type(ap) == "table" then
            validate_impl(ap, v, key_path(path, key), errors)
          end
        end
      end
    end
  end

  -- Array keywords.
  if type(value) == "table" and islist(value) and schema.items ~= nil then
    for i, item in ipairs(value) do
      validate_impl(schema.items, item, path .. "[" .. i .. "]", errors)
    end
  end

  -- oneOf: exactly one subschema must match.
  if schema.oneOf ~= nil then
    local matches = 0
    for _, sub in ipairs(schema.oneOf) do
      local sub_errors = {}
      validate_impl(sub, value, "", sub_errors)
      if #sub_errors == 0 then
        matches = matches + 1
      end
    end
    if matches ~= 1 then
      fail("oneOf")
    end
  end
end

--- Validate a decoded value against a schema.
---@param schema any
---@param value any decoded JSON value
---@return boolean ok
---@return string|nil err first error path (e.g. "path.required", "type")
function M.validate(schema, value)
  local errors = {}
  validate_impl(schema, value, "", errors)
  if #errors == 0 then
    return true, nil
  end
  return false, errors[1]
end

--- Validate a decoded value and collect every error path.
---@param schema any
---@param value any decoded JSON value
---@return boolean ok
---@return string[] errors all error paths
function M.validate_all(schema, value)
  local errors = {}
  validate_impl(schema, value, "", errors)
  return #errors == 0, errors
end

return M
