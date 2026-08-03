-- filepath: lua/maxa/runtime/schema/init.lua
--- maxa runtime schema primitives + phase-0 minimal payload schemas.
---
--- Aligned to `codecompanion/schema.lua` semantics (get_default / validate /
--- get_ordered_keys), but operating on *payload* field definitions rather than a
--- provider adapter. It never requires `codecompanion.*`; upstream is only a
--- read-only alignment reference.
---
--- Shared contract (see .supermax/drafts/phase0-development-plan.md §4.2):
---   field = { type="string"|"number"|"integer"|"boolean"|"enum"|"list"|"map",
---             optional=<bool>, choices=<enum only, list>, default=<optional>,
---             enabled=<optional bool|fun>, validate=<optional fun>, order=<optional int> }
---
--- Key semantics:
---   - nil value is valid iff the field is `optional`.
---   - `enum` requires `choices` (list or function) and rejects out-of-range values.
---   - `list` must be a Lua list table; `map` must be a non-list table (empty table
---     stays an object).
---   - JSON/nonexistent keys with a field definition are validated as normal; keys
---     with no field definition are ignored (payload schemas are open by design in
---     phase 0).
---   - `get_default`/`get_ordered_keys` skip keys starting with `_` unless
---     `{ skip_underscore = false }` is passed (aligns schema.lua's internal-key
---     handling; message payloads must pass skip_underscore=false to see `_meta`).
local M = {}

local islist = vim.islist or vim.tbl_islist

M.ERROR = {
  INVALID_ARGUMENT = "invalid_argument", -- invalid caller-supplied argument
  PROVIDER = "provider", -- upstream provider failed
  CANCELLED = "cancelled", -- work was cancelled
  PROTOCOL = "protocol", -- protocol / stream parsing error
  TIMEOUT = "timeout", -- request timed out
  INTERNAL = "internal", -- runtime-internal failure
}
--- Codes that make an error record terminal (state transition is final). A
--- terminal error event MUST be emitted only once for the same request.
M.TERMINAL_CODES = {
  [M.ERROR.CANCELLED] = true,
  [M.ERROR.TIMEOUT] = true,
  [M.ERROR.INTERNAL] = true,
  [M.ERROR.PROVIDER] = true,
}

--- Build a typed error object (§4.6):
---   { code=ERROR.*, message=string, cause=table|nil, terminal=bool }
---@param code string one of M.ERROR.*
---@param message string human-readable failure detail
---@param cause? table|nil low-level cause (exception/table), optional
---@param terminal? boolean|nil explicit override; defaults from M.TERMINAL_CODES
---@return table error object
function M.new_error(code, message, cause, terminal)
  if terminal == nil then
    terminal = M.TERMINAL_CODES[code] or false
  end
  return {
    code = code,
    message = message,
    cause = cause,
    terminal = terminal,
  }
end

--- Resolve a field's default value.
---@param field table field definition
---@return any default (nil when none declared)
function M.resolve_default(field)
  if not field or field.default == nil then
    return nil
  end
  if type(field.default) == "function" then
    return field.default()
  end
  return field.default
end

---@param field table field definition
---@return boolean
function M.has_default(field)
  return not not (field and field.default ~= nil)
end

--- Whether a field is enabled given its `enabled` declaration.
---@param field table field definition
---@return boolean
local function field_enabled(field)
  if not field or field.enabled == nil then
    return true
  end
  if type(field.enabled) == "function" then
    return not not field.enabled()
  end
  return not not field.enabled
end

--- Type/constraint validation for a single value against a field definition.
---@param field table field definition
---@param value any
---@return boolean valid true when the value passes type/constraint checks
---@return nil|string error description when invalid
local function validate_type(field, value)
  local ptype = field.type or "string"
  if value == nil then
    return not not field.optional, nil
  elseif ptype == "enum" then
    local choices = field.choices
    if type(choices) == "function" then
      choices = choices()
    end
    if type(choices) == "table" then
      for _, c in ipairs(choices) do
        if c == value then
          return true, nil
        end
      end
      return false, ("must be one of %s"):format(table.concat(choices, ", "))
    end
    return true, nil
  elseif ptype == "list" then
    return type(value) == "table" and islist(value), nil
  elseif ptype == "map" then
    return type(value) == "table" and (vim.tbl_isempty(value) or not islist(value)), nil
  elseif ptype == "number" then
    return type(value) == "number", nil
  elseif ptype == "integer" then
    return type(value) == "number" and math.floor(value) == value, nil
  elseif ptype == "boolean" then
    return type(value) == "boolean", nil
  elseif ptype == "string" then
    return true, nil
  else
    error(("Unknown param type %q"):format(tostring(ptype)))
  end
end

--- Validate a single value against a field definition (type + custom validate).
---@param field table field definition
---@param value any
---@return boolean valid
---@return nil|string err
function M.validate_field(field, value)
  if not field_enabled(field) then
    return true, nil
  end
  local valid, err = validate_type(field, value)
  if not valid then
    return valid, err
  end
  if field.validate and value ~= nil then
    local ok, custom = field.validate(value)
    if not ok then
      return false, (type(custom) == "string" and custom) or nil
    end
  end
  return true, nil
end

--- Validate a set of values against a schema (schema.lua `M.validate` semantics).
---@param schema table keys -> field definitions
---@param values table value map
---@param opts? table { skip_underscore=false|true } (default false: validate all keys)
---@return nil|table<string,string> nil on success, or key->error message map
function M.validate(schema, values, opts)
  local skip_underscore = opts and opts.skip_underscore or false
  local errors = {}
  for k, field in pairs(schema) do
    local key = k
    if skip_underscore and type(k) == "string" and k:sub(1, 1) == "_" then
      goto continue
    end
    local valid, err = M.validate_field(field, values and values[key])
    if not valid then
      errors[key] = err or ("Not a valid %s"):format(tostring(field.type))
    end
    ::continue::
  end
  if not vim.tbl_isempty(errors) then
    return errors
  end
  return nil
end

--- Build the default values snapshot for a schema, honoring explicit `defaults`
--- overrides (schema.lua `M.get_default` semantics).
---@param schema table keys -> field definitions
---@param defaults? table explicit values that override schema defaults
---@param opts? table { skip_underscore=true|false } (default true: mirror schema.lua)
---@return table<string,any>
function M.get_default(schema, defaults, opts)
  local skip_underscore = opts == nil or opts.skip_underscore ~= false
  local ret = {}
  for k, field in pairs(schema) do
    if field_enabled(field) then
      if not (skip_underscore and type(k) == "string" and k:sub(1, 1) == "_") then
        if defaults and defaults[k] ~= nil then
          ret[k] = defaults[k]
        else
          ret[k] = M.resolve_default(field)
        end
      end
    end
  end
  return ret
end

--- Order the schema keys (schema.lua `M.get_ordered_keys` semantics):
--- order asc, then non-optional before optional, then name.
---@param schema table keys -> field definitions
---@param opts? table { skip_underscore=true|false } (default true: mirror schema.lua)
---@return string[]
function M.get_ordered_keys(schema, opts)
  local skip_underscore = opts == nil or opts.skip_underscore ~= false
  local keys = {}
  for k in pairs(schema) do
    if type(k) == "string" then
      if not (skip_underscore and k:sub(1, 1) == "_") then
        keys[#keys + 1] = k
      end
    end
  end
  table.sort(keys, function(a, b)
    local af, bf = schema[a], schema[b]
    if af.order or bf.order then
      local ao, bo = af.order, bf.order
      if ao and bo then
        if ao ~= bo then
          return ao < bo
        end
      elseif ao then
        return true
      elseif bo then
        return false
      end
    end
    if (af.optional == true) ~= (bf.optional == true) then
      return bf.optional
    end
    return a < b
  end)
  return keys
end

---@return table field definition
local function str(optional, default)
  return { type = "string", optional = optional or false, default = default }
end
local function integer(optional, default)
  return { type = "integer", optional = optional or false, default = default }
end
local function boolean(optional, default)
  return { type = "boolean", optional = optional or false, default = default }
end
local function map(optional, default)
  return { type = "map", optional = optional or false, default = default }
end
local function list(optional, default)
  return { type = "list", optional = optional or false, default = default }
end

--- 4.3 normalized message schema.
--- Shadowed / later-stage fields (context, reasoning, content-parts) are marked
--- optional placeholders; tool-only assistant content may be nil.
M.message = {
  role = {
    type = "enum",
    optional = false,
    choices = { "user", "assistant", "system", "tool" },
  },
  content = str(true, nil),
  tools = { type = "map", optional = true, default = { calls = {} } },
  opts = { type = "map", optional = true, default = {} },
  -- identity block (idempotent, immutable when set): id stable, index monotonic,
  -- cycle = regeneration generation for the same index.
  _meta = {
    type = "map",
    optional = true,
    default = nil,
    validate = function(value)
      if type(value) ~= "table" then
        return false, "_meta must be a table"
      end
      if value.id ~= nil and type(value.id) ~= "string" then
        return false, "_meta.id must be a string"
      end
      if value.index ~= nil and not (type(value.index) == "number" and math.floor(value.index) == value.index) then
        return false, "_meta.index must be an integer"
      end
      if value.cycle ~= nil and not (type(value.cycle) == "number" and math.floor(value.cycle) == value.cycle) then
        return false, "_meta.cycle must be an integer"
      end
      return true
    end,
  },
  context = map(true, nil),
  reasoning = map(true, nil),
}

--- 4.5 usage minimal schema.
M.usage = {
  prompt_tokens = integer(false, 0),
  completion_tokens = integer(false, 0),
  total_tokens = integer(false, 0),
  source = {
    type = "enum",
    optional = false,
    choices = { "provider", "synthetic" },
    default = "synthetic",
  },
  final = boolean(false, false),
}

--- 4.4 session-envelope minimal schema (identity contract).
M.session = {
  id = str(false, nil), -- stable session id, immutable for the chat lifetime
  project_id = str(false, nil),
  generation = integer(false, 0),
  active_request_id = str(true, nil),
}

--- 4.6 typed-error schema (code=ERROR.* + message + optional cause + terminal).
M.error = {
  code = {
    type = "enum",
    optional = false,
    choices = {
      M.ERROR.INVALID_ARGUMENT,
      M.ERROR.PROVIDER,
      M.ERROR.CANCELLED,
      M.ERROR.PROTOCOL,
      M.ERROR.TIMEOUT,
      M.ERROR.INTERNAL,
    },
  },
  message = str(false, nil),
  cause = map(true, nil),
  terminal = boolean(false, false),
}

--- Named schema registry for downstream modules / smoke tests.
M.schemas = {
  message = M.message,
  usage = M.usage,
  session = M.session,
  error = M.error,
}

M.islist = islist

return M
