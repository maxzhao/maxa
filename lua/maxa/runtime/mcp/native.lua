-- filepath: lua/maxa/runtime/mcp/native.lua
--- maxa native MCP primitive registration (generic mechanism, phase-3 W4).
---
--- Contract (see `specs/modules/mcp-skill-runtime/spec.md` §Native registration
--- and lifecycle, `specs/runtime-fixture-contract.md` §MCP lifecycle):
---   * this module is the GENERIC native-primitive mechanism: any caller may
---     register a native server from a definition (id + tool definitions). The
---     id becomes reserved on registration (`Registry:register_native`), so a
---     project `.maxa/mcp/servers.yaml` declaration cannot shadow it.
---   * NO business-specific primitive names live here (no mcpx/cc_history/
---     genai/json_artifact/subagent inventory, no capability annotations).
---     Business primitives are registered by the phases that implement them;
---     this generic layer never hard-codes future business into the runtime.
---   * `diagnostics/echo` is the only built-in tool: an explicitly named
---     diagnostic primitive replacing the removed `misc` bucket (spec: expose
---     an explicitly named diagnostic primitive rather than a miscellaneous
---     capability bucket). It is complete and returns a standard success
---     result.
---   * lifecycle: a native server has NO external process, so its state machine
---     is the two-state enabled gate `stopped -> connected -> stopped`
---     (enable = start, disable = stop; idempotent by state). Every transition
---     emits the per-server `mcp.server_state` event exactly once (same payload
---     shape as W3, kind = "native", generation stays 0); each enable()/disable()
---     call that performs a transition emits exactly ONE aggregate
---     `mcp.server_state` { aggregate = true,
---     reason = "native_enable"|"native_disable", servers = snapshot } through
---     the W3 registry aggregate mechanism. Idempotent no-ops emit nothing.
---   * duplicate registration deterministically returns the existing server and
---     records a typed error (no duplicate capability entries); invalid
---     definitions fail closed.
---
--- Dependencies: `maxa.runtime.schema`, `maxa.runtime.clock`,
--- `maxa.runtime.mcp.server` (state constants), `maxa.runtime.mcp.registry`
--- (interface). Never loads codecompanion.* / mcphub.* / lua/util/hooks/*.

local schema = require("maxa.runtime.schema")
local clock_lib = require("maxa.runtime.clock")
local server_mod = require("maxa.runtime.mcp.server")

local M = {}
M.name = "mcp.native"

--- Native states (subset of the W3 external state vocabulary; no process, so no
--- starting/stopping/failed/reconnecting transitions).
M.STATES = {
  stopped = server_mod.STATES.stopped,
  connected = server_mod.STATES.connected,
}

--- Max recorded diagnostics (bounded memory; same cap as the external server).
local DIAG_CAP = 256

---@param code string schema.ERROR.*
---@param message string
---@param cause? table|nil
---@return table err
local function typed(code, message, cause)
  return schema.new_error(code, message, cause)
end

--- Validate a native primitive definition (generic; no business fields).
---@param def table { id, name?, description?, tools = table[] }
---@return table|nil err typed error
local function validate_definition(def)
  if type(def) ~= "table" then
    return typed(schema.ERROR.INVALID_ARGUMENT, "native primitive definition must be a table", {
      reason = "invalid_definition",
    })
  end
  if type(def.id) ~= "string" or def.id == "" or not def.id:match("^[%w][%w._%-]*$") then
    return typed(schema.ERROR.INVALID_ARGUMENT, ("invalid native primitive id %q"):format(tostring(def.id)), {
      reason = "invalid_id",
      id = def.id,
    })
  end
  if def.tools ~= nil and type(def.tools) ~= "table" then
    return typed(schema.ERROR.INVALID_ARGUMENT, ("native primitive %q tools must be a list"):format(def.id), {
      reason = "invalid_tools",
      id = def.id,
    })
  end
  return nil
end

--- Explicit diagnostic primitives (replaces the removed `misc` bucket): plain
--- tools registered directly into the tool registry (not servers). `echo` is
--- complete and returns a standard success result; the schema validator's
--- supported subset has no minimum/maximum keywords, so the handler clamps
--- repeat_count defensively (1..100, matching the removed misc echo bounds).
M.DIAGNOSTIC_TOOLS = {
  {
    id = "diagnostics/echo",
    name = "echo",
    description = "Explicit diagnostic primitive: echo a message back as a typed result (replaces the removed misc/echo bucket).",
    input_schema = {
      type = "object",
      properties = {
        message = { type = "string" },
        repeat_count = { type = "integer" },
      },
      required = { "message" },
      additionalProperties = false,
    },
    execution = { mode = "sync", timeout_ms = nil, cancellable = false, side_effect = "none" },
    result = { durable = true, display = "summary" },
    run = function(args)
      local message = args and args.message or ""
      local n = args and args.repeat_count or 1
      if type(n) ~= "number" or n < 1 then
        n = 1
      elseif n > 100 then
        n = 100
      end
      return string.rep(message, n)
    end,
  },
}

--------------------------------------------------------------------------------
-- NativeServer (no external process: two-state enabled gate)
--------------------------------------------------------------------------------

local NativeServer = {}
NativeServer.__index = NativeServer

--- Create a native server instance for one primitive definition.
---@param opts table {
---   definition: table primitive definition { id, name?, description?, tools = table[] },
---   events?: table|nil event bus (events.new() instance),
---   clock?: table|nil deterministic clock,
---   tool_registry?: table|nil tools registry (capability registration),
--- }
---@return table server
function M.native_server(opts)
  assert(type(opts) == "table" and type(opts.definition) == "table", "mcp.native.native_server: definition required")
  local def = opts.definition
  return setmetatable({
    id = def.id,
    kind = "native",
    definition = def,
    events = opts.events,
    clock = opts.clock or clock_lib.default(),
    tool_registry = opts.tool_registry,
    -- No external process: the state machine is the two-state enabled gate.
    state = M.STATES.stopped,
    state_revision = 0,
    generation = 0, -- no process spawn; stays 0 (W3 semantics: per-spawn counter)
    capabilities = {},
    capabilities_revision = 0,
    accepting_calls = true,
    _registered_tools = {},
    diagnostics = {},
  }, NativeServer)
end

--- Record a bounded diagnostic (server-level; mirrors the external server).
---@param kind string
---@param info table|nil
function NativeServer:_record_diagnostic(kind, info)
  self.diagnostics[#self.diagnostics + 1] = { kind = kind, info = info or {}, at_ms = self.clock.now_ms() }
  if #self.diagnostics > DIAG_CAP then
    table.remove(self.diagnostics, 1)
  end
end

--- State transition: set state, bump the monotonic state revision, and emit
--- `mcp.server_state` exactly once per transition (same payload shape as W3).
---@param state string M.STATES.*
---@param reason string transition reason (start/stop/restart)
function NativeServer:_set_state(state, reason)
  self.state = state
  self.state_revision = self.state_revision + 1
  if self.events then
    -- The events bus methods are plain closures (no self parameter).
    pcall(self.events.emit, self.events.events.mcp_server_state, {
      server_id = self.id,
      state = state,
      revision = self.state_revision,
      reason = reason,
      kind = "native",
      generation = self.generation,
      capabilities_revision = self.capabilities_revision,
    })
  end
end

--- Publish the primitive's tools into the tool registry (connected gate).
--- Individual invalid/conflicting definitions are recorded as diagnostics; a
--- missing tool registry is fail-closed (typed error, no transition).
---@return table|nil err typed error
function NativeServer:_publish_capabilities()
  if not self.tool_registry then
    return typed(schema.ERROR.INTERNAL, ("native server %q: no tool registry bound"):format(self.id))
  end
  local tools = {}
  for _, tool in ipairs(self.definition.tools or {}) do
    local registered, rerr = self.tool_registry:register(tool)
    if rerr then
      self:_record_diagnostic("tool_register_error", { name = tool.name, err = rerr.message })
    else
      self._registered_tools[registered.id] = true
      tools[#tools + 1] = registered
    end
  end
  self.capabilities = { tools = tools }
  self.capabilities_revision = self.capabilities_revision + 1
  return nil
end

--- Remove capabilities: unregister every registered tool, clear the snapshot.
--- The revision counter is NOT reset (it counts publishes).
function NativeServer:_remove_capabilities()
  for id in pairs(self._registered_tools) do
    if self.tool_registry and type(self.tool_registry.unregister) == "function" then
      self.tool_registry:unregister(id)
    end
  end
  self._registered_tools = {}
  self.capabilities = {}
end

--- Enable/start the native server: publish capabilities, transition to
--- connected (exactly one per-server event). Idempotent while connected.
---@return table result { joined=boolean, already=boolean|nil, state=string }
---@return table|nil err typed error (fail-closed publish)
function NativeServer:enable()
  if self.state == M.STATES.connected then
    return { joined = false, already = true, state = self.state }, nil
  end
  local perr = self:_publish_capabilities()
  if perr then
    return nil, perr
  end
  self:_set_state(M.STATES.connected, "start")
  return { joined = false, state = self.state }, nil
end

--- Disable/stop the native server: remove capabilities, transition to stopped
--- (exactly one per-server event). Idempotent while stopped.
---@return table result { joined=boolean, already=boolean|nil, state=string }
function NativeServer:disable()
  if self.state == M.STATES.stopped then
    return { joined = false, already = true, state = self.state }, nil
  end
  self:_remove_capabilities()
  self:_set_state(M.STATES.stopped, "stop")
  return { joined = false, state = self.state }, nil
end

--- Alias of enable() (registry/server surface compatibility).
function NativeServer:start()
  return self:enable()
end

--- Alias of disable() (registry stop/stop_all surface compatibility).
function NativeServer:stop()
  return self:disable()
end

--- Restart the native server (stop + start under one call; no async process).
---@return table result { joined=boolean, ok=boolean, state=string }
---@return table|nil err typed error (fail-closed publish)
function NativeServer:restart()
  if self.state == M.STATES.connected then
    self:_remove_capabilities()
    self:_set_state(M.STATES.stopped, "restart")
  end
  local perr = self:_publish_capabilities()
  if perr then
    return nil, perr
  end
  self:_set_state(M.STATES.connected, "start")
  return { joined = false, ok = true, state = self.state }, nil
end

--------------------------------------------------------------------------------
-- NativeManager (registration + enable/disable + teardown facade)
--------------------------------------------------------------------------------

local NativeManager = {}
NativeManager.__index = NativeManager

--- Create a native primitive manager bound to a server registry (W3 registry
--- instance; the registry owns entries/snapshot/aggregate emission).
---@param opts table { registry: table mcp.registry instance }
---@return table manager
function M.new(opts)
  assert(type(opts) == "table" and type(opts.registry) == "table", "mcp.native.new: registry required")
  return setmetatable({ registry = opts.registry }, NativeManager)
end

--- Register one native primitive as a server from a caller-supplied definition.
--- Generic: any id may be registered; the id becomes reserved on registration
--- (project declarations cannot shadow it afterwards). Duplicate registration
--- deterministically returns the existing server while recording a typed error
--- (no duplicate capability entries).
---@param def table primitive definition { id, name?, description?, tools = table[] }
---@return table|nil server
---@return table|nil err typed error (invalid definition / duplicate)
function NativeManager:register(def)
  local verr = validate_definition(def)
  if verr then
    return nil, verr
  end
  local server = M.native_server({
    definition = def,
    events = self.registry.events,
    clock = self.registry.clock,
    tool_registry = self.registry.tool_registry,
  })
  local entry, rerr = self.registry:register_native(server)
  if not entry then
    return nil, rerr
  end
  if entry.server ~= server then
    -- Duplicate: the registry returned the existing entry and recorded the error.
    return entry.server, rerr
  end
  return server, nil
end

--- Register the explicit diagnostic primitives (e.g. diagnostics/echo) into the
--- tool registry. Idempotent (same-hash registration returns the existing tool).
---@return table out { tools = { [id] = def|nil }, errors = { [id] = typed error } }
function NativeManager:register_diagnostics()
  local out = { tools = {}, errors = {} }
  local tr = self.registry.tool_registry
  if not tr or type(tr.register) ~= "function" then
    for _, tool in ipairs(M.DIAGNOSTIC_TOOLS) do
      out.errors[tool.id] = typed(schema.ERROR.INTERNAL, "mcp.native: no tool registry bound")
    end
    return out
  end
  for _, tool in ipairs(M.DIAGNOSTIC_TOOLS) do
    local registered, err = tr:register(tool)
    if err then
      out.errors[tool.id] = err
    else
      out.tools[tool.id] = registered
    end
  end
  return out
end

--- Enable (start) a registered native server and emit exactly ONE aggregate
--- `mcp.server_state` after the transition (idempotent no-ops emit nothing).
---@param id string native server id
---@return table|nil result
---@return table|nil err typed error (unknown/not-native server, fail-closed publish)
function NativeManager:enable(id)
  local entry = self.registry:get(id)
  if not entry or entry.kind ~= "native" then
    return nil,
      typed(schema.ERROR.INVALID_ARGUMENT, ("unknown native server %q"):format(tostring(id)), {
        reason = "unknown_native_server",
        id = id,
      })
  end
  local res, err = entry.server:enable()
  if err then
    return nil, err
  end
  if not res.already then
    self.registry:emit_aggregate("native_enable")
  end
  return res, nil
end

--- Disable (stop) a registered native server and emit exactly ONE aggregate
--- `mcp.server_state` after the transition (idempotent no-ops emit nothing).
---@param id string native server id
---@return table|nil result
---@return table|nil err typed error (unknown/not-native server)
function NativeManager:disable(id)
  local entry = self.registry:get(id)
  if not entry or entry.kind ~= "native" then
    return nil,
      typed(schema.ERROR.INVALID_ARGUMENT, ("unknown native server %q"):format(tostring(id)), {
        reason = "unknown_native_server",
        id = id,
      })
  end
  local res, err = entry.server:disable()
  if err then
    return nil, err
  end
  if not res.already then
    self.registry:emit_aggregate("native_disable")
  end
  return res, nil
end

--- Teardown: stop every registered native server and unregister the diagnostic
--- primitives (shutdown path; no aggregate emission, no UI dependency).
--- Idempotent: repeated teardown is a no-op.
function NativeManager:teardown()
  for _, entry in ipairs(self.registry:list()) do
    if entry.kind == "native" and entry.server then
      pcall(entry.server.stop, entry.server)
    end
  end
  local tr = self.registry.tool_registry
  if tr and type(tr.unregister) == "function" then
    for _, tool in ipairs(M.DIAGNOSTIC_TOOLS) do
      tr:unregister(tool.id)
    end
  end
  return true
end

---@return table|nil last registration/apply errors { [id] = typed error } (registry view)
function NativeManager:errors()
  return self.registry:last_errors()
end

return M
