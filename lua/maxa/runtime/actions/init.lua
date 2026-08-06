-- filepath: lua/maxa/runtime/actions/init.lua
--- Phase-5 W4 Action/Command registry for the maxa runtime.
---
--- Contract (spec: .supermax/specs/modules/actions-commands-target/spec.md):
---   * register(def): validates the required contract fields; a duplicate id
---     with the same definition hash is idempotent, a duplicate id with a
---     different hash is rejected (typed error).
---   * discover(context): deterministic ordering (category/order/id) filtered by
---     the optional `condition(context)` predicate; handlers are never invoked.
---   * dispatch(id, input, context): input-schema validation + idle-request
---     snapshot check -> `action.started` event -> pcall(handler) ->
---     `action.completed` / `action.failed` event + typed result. Handler
---     failures never lock the caller: dispatch remains usable afterwards.
---
--- Extension registration is explicit and idempotent; dispatch failures produce
--- typed events and do not leave the Chat/request state locked.
---
--- The registry is self-contained: it depends only on the typed event bus and
--- never loads codecompanion.*/mcphub.*/lua/util/hooks/*.

local M = {}

M.name = "actions"

--- Typed dispatch-result codes (returned inside `{ok=false, code=...}`).
M.CODES = {
  NOT_FOUND = "not_found",
  BUSY = "busy",
  INVALID_INPUT = "invalid_input",
  HANDLER_FAILED = "handler_failed",
  MISSING_FIELD = "missing_field",
  INVALID_DEF = "invalid_def",
  DUPLICATE_HASH = "duplicate_hash",
}

--- Required contract fields of a registry item (spec registry contract).
local REQUIRED_FIELDS = {
  "id",
  "kind",
  "title",
  "input_schema",
  "contexts",
  "mutates",
  "requires_idle_request",
  "persistence",
  "handler",
}

local KINDS = { action = true, command = true }
local CONTEXTS = { global = true, project = true, session = true, view = true, selection = true }
local MUTATES = {
  none = true,
  view = true,
  session = true,
  project_config = true,
  history = true,
  filesystem = true,
  external = true,
}
local PERSISTENCE = { none = true, session = true, project = true, external = true }

--- Build a typed error object (same shape as maxa.runtime.schema.new_error).
---@param code string one of M.CODES
---@param message string human-readable failure detail
---@param cause? any low-level cause
---@return table error object
local function typed_error(code, message, cause)
  return { code = code, message = message, cause = cause, terminal = false }
end

--- Deterministic stable serialization used for definition hashes.
--- Object keys are sorted; arrays are dense-only. Output is stable across runs
--- and does not depend on vim.json iteration order.
---@param v any
---@return string
local function stable_encode(v)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return "null"
    end
    return string.format("%.17g", v)
  end
  if t == "boolean" then
    return tostring(v)
  end
  if t == "table" then
    if v[1] ~= nil then
      local parts = {}
      local i = 1
      while v[i] ~= nil do
        parts[#parts + 1] = stable_encode(v[i])
        i = i + 1
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = string.format("%q", k) .. ":" .. stable_encode(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

--- Sorted copy of an array (deterministic hash input for unordered lists).
---@param t table
---@return table
local function sorted_list(t)
  local out = {}
  for _, v in ipairs(t) do
    out[#out + 1] = v
  end
  table.sort(out)
  return out
end

--- Stable definition hash: id + title + kind + mutates + requires_idle_request
--- + persistence. Two definitions with the same id must have the same hash to
--- be considered identical (idempotent re-registration).
---@param def table validated definition
---@return string
local function definition_hash(def)
  local payload = {
    id = def.id,
    title = def.title,
    kind = def.kind,
    mutates = sorted_list(def.mutates),
    requires_idle_request = def.requires_idle_request,
    persistence = def.persistence,
  }
  return stable_encode(payload)
end

--- Validate a definition against the registry contract.
---@param def any
---@return nil|table typed error when invalid
local function validate_definition(def)
  if type(def) ~= "table" then
    return typed_error(M.CODES.INVALID_DEF, "definition must be a table")
  end
  for _, field in ipairs(REQUIRED_FIELDS) do
    if def[field] == nil then
      return typed_error(M.CODES.MISSING_FIELD, ("definition missing required field %q"):format(field))
    end
  end
  if type(def.id) ~= "string" or def.id == "" then
    return typed_error(M.CODES.INVALID_DEF, "id must be a non-empty string")
  end
  if not KINDS[def.kind] then
    return typed_error(M.CODES.INVALID_DEF, ("kind must be one of action|command, got %q"):format(tostring(def.kind)))
  end
  if type(def.title) ~= "string" or def.title == "" then
    return typed_error(M.CODES.INVALID_DEF, "title must be a non-empty string")
  end
  if type(def.input_schema) ~= "table" then
    return typed_error(M.CODES.INVALID_DEF, "input_schema must be a table")
  end
  if type(def.contexts) ~= "table" or #def.contexts == 0 then
    return typed_error(M.CODES.INVALID_DEF, "contexts must be a non-empty array")
  end
  for _, c in ipairs(def.contexts) do
    if not CONTEXTS[c] then
      return typed_error(M.CODES.INVALID_DEF, ("contexts contains unknown value %q"):format(tostring(c)))
    end
  end
  if type(def.mutates) ~= "table" or #def.mutates == 0 then
    return typed_error(M.CODES.INVALID_DEF, "mutates must be a non-empty array")
  end
  for _, m in ipairs(def.mutates) do
    if not MUTATES[m] then
      return typed_error(M.CODES.INVALID_DEF, ("mutates contains unknown value %q"):format(tostring(m)))
    end
  end
  if type(def.requires_idle_request) ~= "boolean" then
    return typed_error(M.CODES.INVALID_DEF, "requires_idle_request must be a boolean")
  end
  if not PERSISTENCE[def.persistence] then
    return typed_error(
      M.CODES.INVALID_DEF,
      ("persistence must be one of none|session|project|external, got %q"):format(tostring(def.persistence))
    )
  end
  if type(def.handler) ~= "function" then
    return typed_error(M.CODES.INVALID_DEF, "handler must be a function")
  end
  return nil
end

--- Validate dispatch input against a declared input_schema.
--- Minimal object schema: { type="object", required={...},
--- properties={ field = { type = "string"|"number"|"boolean"|"table"|"any" } } }.
--- An empty schema `{}` performs no validation.
---@param schema table
---@param input table
---@return boolean valid
---@return nil|string error description
local function validate_input(schema, input)
  if not schema or next(schema) == nil then
    return true, nil
  end
  if type(input) ~= "table" then
    return false, "input must be a table"
  end
  local required = schema.required
  if type(required) == "table" then
    for _, key in ipairs(required) do
      if input[key] == nil then
        return false, ("missing required input field %q"):format(tostring(key))
      end
    end
  end
  local properties = schema.properties
  if type(properties) == "table" then
    for key, spec in pairs(properties) do
      if
        input[key] ~= nil
        and type(spec) == "table"
        and spec.type
        and spec.type ~= "any"
        and type(input[key]) ~= spec.type
      then
        return false, ("input field %q must be %s, got %s"):format(tostring(key), spec.type, type(input[key]))
      end
    end
  end
  return true, nil
end

--- Public (read-only) projection of a stored definition: contract fields plus
--- optional category/order metadata; handler and condition are never exposed.
---@param entry table { hash=string, def=table }
---@return table
local function public_item(entry)
  local def = entry.def
  local item = {
    id = def.id,
    kind = def.kind,
    title = def.title,
    input_schema = def.input_schema,
    contexts = def.contexts,
    mutates = def.mutates,
    requires_idle_request = def.requires_idle_request,
    persistence = def.persistence,
  }
  if def.category ~= nil then
    item.category = def.category
  end
  if def.order ~= nil then
    item.order = def.order
  end
  return item
end

--- Deterministic discovery order: category, then order, then id.
---@param a table public item
---@param b table public item
---@return boolean
local function item_sort(a, b)
  local ca, cb = a.category or "", b.category or ""
  if ca ~= cb then
    return ca < cb
  end
  local oa, ob = a.order or 0, b.order or 0
  if oa ~= ob then
    return oa < ob
  end
  return a.id < b.id
end

--- Event names with additive fallback: the events bus constants may not contain
--- the action_* names yet, so string defaults keep dispatch usable.
---@param bus table event bus (singleton or instance)
---@return table { started=string, completed=string, failed=string }
local function event_names(bus)
  local evs = bus and bus.events
  return {
    started = evs and evs.action_started or "action.started",
    completed = evs and evs.action_completed or "action.completed",
    failed = evs and evs.action_failed or "action.failed",
  }
end

local Registry = {}
Registry.__index = Registry

--- Create a fresh registry instance.
---@param opts? table { events?: table|nil event bus (defaults to the runtime
---   singleton); inject a fresh bus for test isolation }
---@return table registry
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _defs = {}, -- id -> { hash=string, def=table }
    events = opts.events or require("maxa.runtime.events"),
  }, Registry)
end

--- Register (or idempotently re-register) an action/command definition.
---@param def table registry-contract definition
---@return boolean true on success (also when the same id+hash was already
---   registered)
---@return nil|table typed error {code,message,cause,terminal} on invalid def or
---   duplicate id with a different definition hash
function Registry:register(def)
  local verr = validate_definition(def)
  if verr then
    return nil, verr
  end
  local hash = definition_hash(def)
  local existing = self._defs[def.id]
  if existing then
    if existing.hash == hash then
      return true
    end
    return nil,
      typed_error(M.CODES.DUPLICATE_HASH, ("action %q already registered with a different definition"):format(def.id))
  end
  self._defs[def.id] = { hash = hash, def = def }
  return true
end

--- Deterministic discovery: category/order/id sorted, filtered by optional
--- `condition(context)` predicates. Handlers are never invoked.
---@param context table|nil dispatch/UI context snapshot for predicates
---@return table[] read-only public items (no handler/condition fields)
function Registry:discover(context)
  local items = {}
  for _, entry in pairs(self._defs) do
    local def = entry.def
    if not def.condition or def.condition(context) == true then
      items[#items + 1] = public_item(entry)
    end
  end
  table.sort(items, item_sort)
  return items
end

--- All registered items in deterministic order (no condition filtering).
---@return table[]
function Registry:list()
  local items = {}
  for _, entry in pairs(self._defs) do
    items[#items + 1] = public_item(entry)
  end
  table.sort(items, item_sort)
  return items
end

--- Look up a public item by id.
---@param id string
---@return table|nil public item (no handler/condition fields)
function Registry:get(id)
  local entry = self._defs[id]
  if not entry then
    return nil
  end
  return public_item(entry)
end

--- Dispatch an operation: input validation + context snapshot check -> started
--- event -> handler pcall -> completed/failed event + typed result.
---
--- Return shapes:
---   success:           { ok=true,  result=any }
---   lookup/validation: { ok=false, code="not_found"|"invalid_input"|"busy" }
---   handler failure:   { ok=false, code="handler_failed", error=string }
---
--- Handler exceptions never lock the caller: they surface as typed results and
--- subsequent dispatches run normally.
---@param id string registered operation id
---@param input table|nil operation input (defaults to {})
---@param context table|nil context snapshot; `context.request_busy` gates
---   requires_idle_request operations
---@return table typed dispatch result
function Registry:dispatch(id, input, context)
  input = input or {}
  local entry = self._defs[id]
  if not entry then
    return { ok = false, code = M.CODES.NOT_FOUND, error = ("action %q not registered"):format(tostring(id)) }
  end
  local def = entry.def

  local vok, verr = validate_input(def.input_schema, input)
  if not vok then
    return { ok = false, code = M.CODES.INVALID_INPUT, error = verr }
  end

  if def.requires_idle_request and context and context.request_busy then
    return { ok = false, code = M.CODES.BUSY, error = ("action %q requires an idle request"):format(def.id) }
  end

  local names = event_names(self.events)
  self.events.emit(names.started, {
    action_id = def.id,
    kind = def.kind,
    title = def.title,
    input = input,
    contexts = def.contexts,
    mutates = def.mutates,
  })

  local ok, res = pcall(def.handler, input, context)
  if not ok then
    self.events.emit(names.failed, { action_id = def.id, kind = def.kind, error = tostring(res) })
    return { ok = false, code = M.CODES.HANDLER_FAILED, error = tostring(res) }
  end

  self.events.emit(names.completed, { action_id = def.id, kind = def.kind, result = res })
  return { ok = true, result = res }
end

--- Module-level default registry singleton. The later host wave wires built-in
--- families (actions.builtin.register_all) into this instance.
M.default = M.new()

return M
