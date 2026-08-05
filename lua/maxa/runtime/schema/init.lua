-- filepath: lua/maxa/runtime/schema/init.lua
--- maxa runtime schema primitives + normalized payload schemas (phase-1 W2).
---
--- Aligned to `codecompanion/schema.lua` semantics (get_default / validate /
--- get_ordered_keys), but operating on *payload* field definitions rather than a
--- provider adapter. It never requires `codecompanion.*`; upstream is only a
--- read-only alignment reference.
---
--- Shared contract (see .supermax/drafts/phase1-implementation-plan.md §4.4):
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
---
--- W2 switch (message-context-target spec §Normalized records): messages carry a
--- `content` list of content parts (no string-content compatibility layer), usage
--- uses the full normalized snapshot with explicit `null` for unknown token fields,
--- and the typed-error code table covers configuration/authentication/rate-limit/
--- quota/context-limit/request/provider/network/tool/persistence failures.
local M = {}

local islist = vim.islist or vim.tbl_islist

--- Typed-error codes (schema.ERROR.*). Phase-0 codes are kept verbatim for
--- compatibility; W2 adds the granular provider/request failure families used by
--- the transport class mapping and the orchestrator terminal classification.
M.ERROR = {
  -- phase-0 codes (compatibility, never renamed)
  INVALID_ARGUMENT = "invalid_argument", -- invalid caller-supplied argument
  PROVIDER = "provider", -- upstream provider failed
  CANCELLED = "cancelled", -- work was cancelled
  PROTOCOL = "protocol", -- protocol / stream parsing error
  TIMEOUT = "timeout", -- request timed out
  INTERNAL = "internal", -- runtime-internal failure
  -- W2 granular codes
  CONFIGURATION = "configuration", -- runtime/config schema or binding failure
  AUTHENTICATION = "authentication", -- bad/missing credentials (401/403)
  PERMISSION_POLICY = "permission-policy", -- permission/policy denial (403)
  RATE_LIMITED = "rate_limited", -- provider rate limit (429)
  QUOTA = "quota", -- provider quota exhausted
  CONTEXT_LIMIT = "context_limit", -- context window exceeded / no resolvable limit
  INVALID_REQUEST = "invalid_request", -- provider rejected the request payload
  PROVIDER_UNAVAILABLE = "provider_unavailable", -- provider 5xx / unavailable
  NETWORK = "network", -- transport/network failure (DNS, connect)
  TOOL = "tool", -- tool definition/execution failure
  PERSISTENCE = "persistence", -- history/session persistence failure
}
--- Codes that make an error record terminal (state transition is final). A
--- terminal error event MUST be emitted only once for the same request.
--- Phase-0 set kept; W2 request-level failure families are terminal by default.
--- `invalid_argument` stays non-terminal by default (caller-fixable; rejection
--- paths pass an explicit terminal flag when the session must not continue).
M.TERMINAL_CODES = {
  [M.ERROR.CANCELLED] = true,
  [M.ERROR.TIMEOUT] = true,
  [M.ERROR.INTERNAL] = true,
  [M.ERROR.PROVIDER] = true,
  [M.ERROR.CONFIGURATION] = true,
  [M.ERROR.AUTHENTICATION] = true,
  [M.ERROR.PERMISSION_POLICY] = true,
  [M.ERROR.RATE_LIMITED] = true,
  [M.ERROR.QUOTA] = true,
  [M.ERROR.CONTEXT_LIMIT] = true,
  [M.ERROR.INVALID_REQUEST] = true,
  [M.ERROR.PROVIDER_UNAVAILABLE] = true,
  [M.ERROR.NETWORK] = true,
  [M.ERROR.TOOL] = true,
  [M.ERROR.PERSISTENCE] = true,
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

--- Current wall-clock in milliseconds (mirrors events.now_ms).
---@return integer
local function now_ms()
  if vim and vim.uv and vim.uv.hrtime then
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  return os.time() * 1000
end

--- 4.4 normalized content-part schema (message-context-target §Normalized records).
--- A part is a flat object whose `type` selects the semantically relevant fields;
--- per-type required fields are enforced by M.validate_content_part below.
M.content_part = {
  type = {
    type = "enum",
    optional = false,
    choices = { "text", "reasoning", "image", "tool_call", "tool_result", "context_ref" },
  },
  -- text: UTF-8 text + optional language/media metadata
  text = str(true, nil),
  language = str(true, nil),
  media = map(true, nil),
  -- reasoning: content + provider round-trip metadata, separate from visible text
  content = str(true, nil),
  signature = str(true, nil),
  provider = str(true, nil),
  retained = boolean(true, nil),
  -- image: MIME + runtime-owned blob reference (payload expiry must not invalidate
  -- a committed message; the committed part stores the reference, not the bytes)
  mime = str(true, nil),
  blob_ref = str(true, nil),
  source = map(true, nil),
  -- tool_call: runtime call id + optional provider id/provenance + name + encoded args
  call_id = str(true, nil),
  provider_id = str(true, nil),
  name = str(true, nil),
  arguments = str(true, nil),
  -- tool_result: paired call id + status + provider-facing content
  -- W5 (additive): "cancelled" added for synthetic restore/repair results
  -- (restore-agent-loop injects cancelled results for orphan tool calls).
  status = { type = "enum", optional = true, choices = { "success", "error", "cancelled" } },
  is_error = boolean(true, nil),
  -- context_ref: stable context item id + snapshot/hash (never a live buffer ptr)
  item_id = str(true, nil),
  snapshot = str(true, nil),
  hash = str(true, nil),
  kind = str(true, nil),
}

--- Type-specific required fields per content-part type. Used by
--- M.validate_content_part to give exact per-type diagnostics.
M.CONTENT_PART_REQUIRED = {
  text = { "text" },
  reasoning = { "content" },
  image = { "mime", "blob_ref" },
  tool_call = { "call_id", "name", "arguments" },
  tool_result = { "call_id", "status", "content" },
  context_ref = { "item_id" },
}

--- Validate a single content part (per-type required fields + shared schema).
---@param part any
---@return boolean ok
---@return string|nil err exact diagnostic
function M.validate_content_part(part)
  if type(part) ~= "table" then
    return false, "content part must be a table"
  end
  local verr = M.validate(M.content_part, part)
  if verr then
    return false, ("content part: %s"):format(vim.inspect(verr))
  end
  local ptype = part.type
  local required = M.CONTENT_PART_REQUIRED[ptype]
  if required then
    for _, field in ipairs(required) do
      local v = part[field]
      if v == nil or (type(v) == "string" and v == "") then
        return false, ("content part type %q: required field %q is missing"):format(ptype, field)
      end
    end
  end
  return true, nil
end

--- Validate a whole `content` list (message-context-target §Normalized records).
--- Every entry must be a valid content part; the list itself is positional.
---@param content any
---@return boolean ok
---@return string|nil err exact diagnostic (index + field)
function M.validate_content(content)
  if type(content) ~= "table" or not islist(content) then
    return false, "message content must be a list of content parts"
  end
  for i, part in ipairs(content) do
    local ok, err = M.validate_content_part(part)
    if not ok then
      return false, ("content[%d]: %s"):format(i, err)
    end
  end
  return true, nil
end

--- 4.4 normalized message schema (message-context-target §Normalized records).
--- Full switch to content parts: `content` is a list, there is NO string-content
--- compatibility layer. `_meta` stays an optional identity record (index/cycle for
--- stack regeneration; id is mirrored at the top level for the normalized shape).
M.message = {
  id = str(false, nil), -- stable message id, immutable once set
  turn_id = str(false, nil), -- provider-neutral turn id (stable across retries)
  role = {
    type = "enum",
    optional = false,
    choices = { "system", "project", "user", "assistant", "tool" },
  },
  content = {
    type = "list",
    optional = false,
    default = function()
      return {}
    end,
  }, -- content_part[] (empty list is legal: e.g. placeholder tool messages)
  visibility = {
    type = "enum",
    optional = false,
    choices = { "visible", "hidden" },
    default = "visible",
  },
  provenance = map(true, {}), -- source/creation provenance for the record
  created_at = integer(false, nil), -- wall-clock ms when the record was created
  -- identity block (optional, phase-0 compatibility): index monotonic, cycle =
  -- regeneration generation for the same index; id mirrors the top-level id.
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
}

--- 4.6 normalized usage snapshot (streaming-usage spec §Usage).
--- Unknown token counts are `nil` (null), never 0. `source` records who filled
--- the fields: provider-reported or local estimate/restored.
M.usage = {
  input_tokens = integer(true, nil),
  output_tokens = integer(true, nil),
  total_tokens = integer(true, nil),
  cached_input_tokens = integer(true, nil),
  cache_creation_input_tokens = integer(true, nil),
  reasoning_tokens = integer(true, nil),
  tool_tokens = integer(true, nil),
  provider_reported_total = integer(true, nil),
  context_limit = integer(true, nil),
  context_percent = integer(true, nil),
  source = {
    type = "enum",
    optional = false,
    choices = { "provider_final", "provider_delta", "local_estimate", "restored" },
    default = "local_estimate",
  },
  final = boolean(false, false),
  updated_at = integer(false, nil), -- wall-clock ms of this snapshot
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
      M.ERROR.CONFIGURATION,
      M.ERROR.AUTHENTICATION,
      M.ERROR.PERMISSION_POLICY,
      M.ERROR.RATE_LIMITED,
      M.ERROR.QUOTA,
      M.ERROR.CONTEXT_LIMIT,
      M.ERROR.INVALID_REQUEST,
      M.ERROR.PROVIDER_UNAVAILABLE,
      M.ERROR.NETWORK,
      M.ERROR.TOOL,
      M.ERROR.PERSISTENCE,
    },
  },
  message = str(false, nil),
  cause = map(true, nil),
  terminal = boolean(false, false),
}

--- Named schema registry for downstream modules / smoke tests.
M.schemas = {
  content_part = M.content_part,
  message = M.message,
  usage = M.usage,
  session = M.session,
  error = M.error,
}

M.islist = islist

--- Exported wall-clock helper (ms) for modules that timestamp normalized records.
M.now_ms = now_ms

return M
