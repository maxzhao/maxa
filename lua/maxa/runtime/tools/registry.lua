-- filepath: lua/maxa/runtime/tools/registry.lua
--- Phase-3 W1: tool registry (tool-runtime spec §Tool definition).
---
--- A registered definition record:
---   {
---     id = "server-id/tool-name",   -- unique, immutable
---     name = "tool-name",           -- provider-facing call name
---     description = string,
---     input_schema = object,        -- normalized exactly once (tools.schema)
---     execution = { mode = "sync"|"async", timeout_ms = integer|null,
---                   cancellable = boolean,
---                   side_effect = none|read|write|process|network|external,
---                   concurrency = integer (>=1, default 1; batch-level
---                     declaration per tool-runtime §Batch and concurrency
---                     policy; the executor still runs sequentially this wave) },
---     result = { durable = boolean, display = summary|markdown|hidden },
---     hash = string,                -- immutable definition hash
---     -- runtime bindings (NOT part of the definition hash):
---     run = fun(args, ctx, task)|nil,
---     cancel = fun()|nil,
---   }
---
--- Rules:
---   * IDs are unique and use the `server-id/tool-name` form. Duplicate
---     registration with the SAME definition hash is idempotent (returns the
---     existing definition); a different hash is a typed error
---     (schema.ERROR.TOOL, cause.reason = "duplicate_registration").
---   * input_schema is normalized once at registration and never weakened;
---     provider adaptation always happens on a per-provider copy
---     (schema_for).
---   * resolve(name) matches the full id first, then the tool name; a name
---     shared by several servers is ambiguous and resolves to a typed error.
---   * make_handler(name) bridges a definition to the executor handler
---     contract: { mode, run, cancel, schema, timeout_ms, cancellable }.
---
--- It never loads codecompanion.* / mcphub.* / lua/util/hooks/*.

local schema_mod = require("maxa.runtime.schema")
local jschema = require("maxa.runtime.tools.schema")

local M = {}

M.name = "tools.registry"

M.DEFAULT_EXECUTION = {
  mode = "sync",
  timeout_ms = nil,
  cancellable = true,
  side_effect = "none",
  concurrency = 1,
}

M.DEFAULT_RESULT = {
  durable = true,
  display = "summary",
}

M.VALID_MODES = {
  sync = true,
  async = true,
}

M.VALID_SIDE_EFFECTS = {
  none = true,
  read = true,
  write = true,
  process = true,
  network = true,
  external = true,
}

M.VALID_DISPLAYS = {
  summary = true,
  markdown = true,
  hidden = true,
}

local ID_PATTERN = "^[%w][%w._%-]*/[%w][%w._%-]*$"

-------------------------------------------------------------------------------
-- Canonical serialization + definition hash
-------------------------------------------------------------------------------

--- Deterministic canonical serialization of a definition's serializable
--- fields (sorted keys; string escaping via vim.json). Never receives
--- functions: run/cancel are excluded from hashing by construction.
---@param v any
---@return string
local function canonical_encode(v)
  if v == vim.NIL then
    return "null"
  end
  local t = type(v)
  if t == "string" then
    return vim.json.encode(v)
  end
  if t == "number" then
    if v % 1 == 0 then
      return ("%d"):format(v)
    end
    return tostring(v)
  end
  if t == "boolean" then
    return v and "true" or "false"
  end
  if t == "table" then
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = vim.json.encode(k) .. ":" .. canonical_encode(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return vim.json.encode(tostring(v))
end

--- FNV-1a 32-bit over a string (exact modular arithmetic via split
--- multiply; deterministic across sessions on the same runtime).
---@param s string
---@return string hex
local function fnv1a_32(s)
  local hash = 2166136261
  local prime = 16777619
  local mask = 4294967296
  for i = 1, #s do
    hash = bit.bxor(hash, string.byte(s, i))
    local hi = math.floor(hash / 256)
    local lo = hash % 256
    hash = (((hi * prime) % mask) * 256 + lo * prime) % mask
  end
  return ("%08x"):format(hash)
end

--- Compute the immutable definition hash over the serializable definition
--- fields (id/name/description/input_schema/execution/result). Runtime
--- bindings (run/cancel) are intentionally excluded.
---@param def table definition record
---@return string hash
function M.definition_hash(def)
  local payload = {
    id = def.id,
    name = def.name,
    description = def.description,
    input_schema = def.input_schema,
    execution = def.execution,
    result = def.result,
  }
  return fnv1a_32(canonical_encode(payload))
end

--- Provider-safe unique call name for a definition (W1 real path): the
--- registry id with every character outside `[A-Za-z0-9_-]` replaced by `-`.
--- OpenAI Chat Completions / OpenAI Responses / Anthropic Messages / Gemini
--- all restrict function names to `^[a-zA-Z0-9_-]+$` (or narrower), so the
--- `server-id/tool-name` id (which contains `/`, and may contain `.`) cannot
--- be sent verbatim. The encoding is deterministic, so the same definition
--- always advertises the same wire name across requests/adapters. Execution
--- resolves the wire name back to the registry id through the caller's
--- provider-name -> id map (orchestrator `provider_tool_ids`, passed to the
--- executor) — collisions in the encoded space are a documented edge case
--- beyond this wave's id space.
---@param def table definition record
---@return string provider_name
function M.provider_name(def)
  return (def.id or ""):gsub("[^%w_-]", "-")
end

-------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------

local Registry = {}
Registry.__index = Registry

--- Create a tool registry instance.
---@return table reg
function M.new()
  return setmetatable({
    _by_id = {}, -- id -> definition
    _by_name = {}, -- name -> definition[]
    _order = {}, -- registration order (list())
  }, Registry)
end

---@param message string
---@param cause? table
---@return table err typed error (schema.ERROR.TOOL)
local function tool_error(message, cause)
  return schema_mod.new_error(schema_mod.ERROR.TOOL, message, cause, false)
end

---@param message string
---@return table err typed error (schema.ERROR.INVALID_ARGUMENT)
local function invalid_error(message)
  return schema_mod.new_error(schema_mod.ERROR.INVALID_ARGUMENT, message, nil, false)
end

--- Normalize + validate a raw definition (registry-internal; exported for
--- tests and future bridges).
---@param def table raw definition
---@return table|nil normalized definition
---@return nil|table err typed error
function M.normalize_definition(def)
  if type(def) ~= "table" then
    return nil, invalid_error("tool definition must be a table")
  end
  for _, field in ipairs({ "id", "name", "description", "input_schema" }) do
    if def[field] == nil then
      return nil, invalid_error(("tool definition missing required field %q"):format(field))
    end
  end
  if type(def.id) ~= "string" or not def.id:match(ID_PATTERN) then
    return nil, invalid_error(("tool id %q must match server-id/tool-name"):format(tostring(def.id)))
  end
  if type(def.name) ~= "string" or def.name == "" then
    return nil, invalid_error(("tool name must be a non-empty string (id %q)"):format(tostring(def.id)))
  end
  if type(def.description) ~= "string" then
    return nil, invalid_error(("tool description must be a string (id %q)"):format(tostring(def.id)))
  end

  local snorm, serr = jschema.normalize(def.input_schema)
  if not snorm then
    return nil, invalid_error(("tool %q input_schema invalid: %s"):format(def.id, tostring(serr)))
  end

  local execution = vim.tbl_extend("force", {}, M.DEFAULT_EXECUTION, def.execution or {})
  if type(execution.mode) ~= "string" or not M.VALID_MODES[execution.mode] then
    return nil, invalid_error(("tool %q execution.mode must be sync or async"):format(def.id))
  end
  if execution.timeout_ms ~= nil then
    if type(execution.timeout_ms) ~= "number" or execution.timeout_ms <= 0 or execution.timeout_ms % 1 ~= 0 then
      return nil, invalid_error(("tool %q execution.timeout_ms must be a positive integer or null"):format(def.id))
    end
  end
  if type(execution.cancellable) ~= "boolean" then
    return nil, invalid_error(("tool %q execution.cancellable must be a boolean"):format(def.id))
  end
  if type(execution.side_effect) ~= "string" or not M.VALID_SIDE_EFFECTS[execution.side_effect] then
    return nil,
      invalid_error(
        ("tool %q execution.side_effect must be one of none|read|write|process|network|external"):format(def.id)
      )
  end
  -- W7: batch-level concurrency declaration (tool-runtime §Batch and concurrency
  -- policy). Default = sequential (1); >1 is reserved for the future parallel
  -- executor and is validated but NOT activated this wave.
  if type(execution.concurrency) ~= "number" or execution.concurrency < 1 or execution.concurrency % 1 ~= 0 then
    return nil, invalid_error(("tool %q execution.concurrency must be a positive integer (default 1)"):format(def.id))
  end

  local result = vim.tbl_extend("force", {}, M.DEFAULT_RESULT, def.result or {})
  if type(result.durable) ~= "boolean" then
    return nil, invalid_error(("tool %q result.durable must be a boolean"):format(def.id))
  end
  if type(result.display) ~= "string" or not M.VALID_DISPLAYS[result.display] then
    return nil, invalid_error(("tool %q result.display must be one of summary|markdown|hidden"):format(def.id))
  end

  if def.run ~= nil and type(def.run) ~= "function" then
    return nil, invalid_error(("tool %q run must be a function"):format(def.id))
  end
  if def.cancel ~= nil and type(def.cancel) ~= "function" then
    return nil, invalid_error(("tool %q cancel must be a function"):format(def.id))
  end

  local norm = {
    id = def.id,
    name = def.name,
    description = def.description,
    input_schema = snorm,
    execution = execution,
    result = result,
    run = def.run,
    cancel = def.cancel,
  }
  norm.hash = M.definition_hash(norm)
  return norm, nil
end

--- Register a tool definition.
---@param def table raw definition (see module header)
---@return table def registered (normalized) definition
---@return nil|table err typed error on invalid/conflicting registration
function Registry:register(def)
  local norm, nerr = M.normalize_definition(def)
  if not norm then
    return nil, nerr
  end
  local existing = self._by_id[norm.id]
  if existing then
    if existing.hash == norm.hash then
      -- Same immutable definition: idempotent, keep the existing record.
      return existing, nil
    end
    return nil,
      tool_error(
        ("duplicate tool registration id=%q with a different definition hash (existing %s, new %s)"):format(
          norm.id,
          existing.hash,
          norm.hash
        ),
        { reason = "duplicate_registration", id = norm.id }
      )
  end
  self._by_id[norm.id] = norm
  self._order[#self._order + 1] = norm
  local byname = self._by_name[norm.name] or {}
  byname[#byname + 1] = norm
  self._by_name[norm.name] = byname
  return norm, nil
end

--- Unregister a tool definition by full id (additive, phase-3 W3: used by the
--- MCP server layer to remove capabilities on stop/reload). Removes the
--- definition from the id map, the registration order, and the name index.
--- Unknown ids are a no-op.
---@param id string full id ("server-id/tool-name")
---@return table|nil def removed definition (nil when unknown)
function Registry:unregister(id)
  local def = self._by_id[id]
  if not def then
    return nil
  end
  self._by_id[id] = nil
  for i, d in ipairs(self._order) do
    if d == def then
      table.remove(self._order, i)
      break
    end
  end
  local byname = self._by_name[def.name]
  if byname then
    for i, d in ipairs(byname) do
      if d == def then
        table.remove(byname, i)
        break
      end
    end
    if #byname == 0 then
      self._by_name[def.name] = nil
    end
  end
  return def
end

--- Resolve a tool by full id or by tool name.
---@param name string id ("server-id/tool-name") or tool name
---@return table|nil def
---@return nil|table err typed error when the name is ambiguous
function Registry:resolve(name)
  if type(name) ~= "string" or name == "" then
    return nil, invalid_error("resolve: name must be a non-empty string")
  end
  local by_id = self._by_id[name]
  if by_id then
    return by_id, nil
  end
  local byname = self._by_name[name]
  if not byname or #byname == 0 then
    return nil, nil
  end
  if #byname == 1 then
    return byname[1], nil
  end
  return nil,
    tool_error(
      ("ambiguous tool name %q registered by %d servers (use the full server-id/tool-name id)"):format(name, #byname),
      { reason = "ambiguous_name", name = name }
    )
end

---@return table[] definitions in registration order (shallow copy)
function Registry:list()
  local out = {}
  for i, def in ipairs(self._order) do
    out[i] = def
  end
  return out
end

---@return integer number of registered definitions
function Registry:count()
  return #self._order
end

--- Provider-facing schema table: every registered tool's normalized
--- input_schema as a per-provider deep copy (identity adaptation for W1;
--- provider-specific transforms are applied by the caller on the copy and
--- never touch the normalized definition). The provider argument is accepted
--- now so future adaptation can branch on it without an API change.
---@param provider string|nil provider id (informational in W1)
---@return table map tool id -> adapted schema copy
function Registry:schema_for(provider)
  local out = {}
  for _, def in ipairs(self._order) do
    out[def.id] = jschema.copy(def.input_schema)
  end
  return out
end

--- Bridge a definition to the executor handler contract. Returns nil for
--- unknown/ambiguous tools (the executor keeps its standard unknown-tool
--- error path).
---@param name string tool name or id
---@return table|nil handler {
---   mode="sync"|"async", run=fun(args, ctx, task), cancel=fun()|nil,
---   schema=table, timeout_ms=integer|nil, cancellable=boolean }
function Registry:make_handler(name)
  local def = self:resolve(name)
  if not def then
    return nil
  end
  local handler = {
    mode = def.execution.mode,
    schema = def.input_schema,
    timeout_ms = def.execution.timeout_ms,
    cancellable = def.execution.cancellable,
    run = function(args, ctx, task)
      if type(def.run) == "function" then
        return def.run(args, ctx, task)
      end
      error(("tool %s has no executable handler (registered without run)"):format(def.id), 0)
    end,
  }
  if type(def.cancel) == "function" then
    handler.cancel = def.cancel
  end
  return handler
end

return M
