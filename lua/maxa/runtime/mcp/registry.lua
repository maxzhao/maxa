-- filepath: lua/maxa/runtime/mcp/registry.lua
--- maxa MCP server registry (phase-3 W3).
---
--- Contract (see `specs/modules/mcp-skill-runtime/spec.md` §Server registry and
--- lifecycle):
---   * every registered server carries an immutable ID and kind (`external` or
---     `native` — natives register through `Registry:register_native`), a
---     config snapshot, state, generation, capabilities revision, owned
---     requests and process handle (owned/process live on the server instance;
---     native servers have no process).
---   * reserved IDs are DYNAMIC, not a hard-coded business inventory: an ID
---     becomes reserved when a native server with that ID is registered
---     (register_native adds it to the instance-level reserved set; an optional
---     `reserved_ids` seed may pre-declare IDs). A project declaration whose ID
---     is reserved cannot shadow the native server: registering such a server
---     is a typed error recorded in the apply result; the remaining servers
---     load. Business-specific primitive names are owned by the phases that
---     implement them, never baked into this generic registry.
---   * config reload computes added/removed/changed/unchanged:
---       unchanged -> entry kept (generation preserved),
---       changed   -> server reloaded (stop + start with the new snapshot),
---       removed   -> stopped and dropped,
---       added     -> registered; enabled servers auto-start.
---   * one aggregate `mcp.server_state` event
---     { aggregate = true, reason = "config_reload", servers = snapshot } is
---     emitted exactly once per apply_config, after the transitions ran.
---
--- Dependencies: `maxa.runtime.schema`, `maxa.runtime.mcp.config`,
--- `maxa.runtime.mcp.server`, `maxa.runtime.clock`. Never loads
--- codecompanion.* / mcphub.* / lua/util/hooks/*.

local schema = require("maxa.runtime.schema")
local mcp_config = require("maxa.runtime.mcp.config")
local server_mod = require("maxa.runtime.mcp.server")
local clock_lib = require("maxa.runtime.clock")

local M = {}
M.name = "mcp.registry"

--- Server kinds.
M.KIND_EXTERNAL = "external"
M.KIND_NATIVE = "native"

---@param message string
---@param cause? table|nil
---@return table err
local function typed(message, cause)
  return schema.new_error(schema.ERROR.INVALID_ARGUMENT, message, cause)
end

local Registry = {}
Registry.__index = Registry

--- Create a server registry.
---@param opts table {
---   events?: table|nil event bus (aggregate mcp.server_state emission),
---   clock?: table|nil deterministic clock,
---   tool_registry?: table|nil tools registry (server capability registration),
---   process_factory?: fun(config)->process|nil (server spawn seam),
---   reserved_ids?: table|nil optional seed set of pre-reserved native IDs
---     (e.g. ids whose native primitives are registered by the caller before
---     any config apply; registration also reserves dynamically),
--- }
---@return table registry
function M.new(opts)
  opts = opts or {}
  local seeded = {}
  for id in pairs(opts.reserved_ids or {}) do
    seeded[id] = true
  end
  return setmetatable({
    events = opts.events,
    clock = opts.clock or clock_lib.default(),
    tool_registry = opts.tool_registry,
    process_factory = opts.process_factory,
    _reserved = seeded, -- id -> true (native IDs: seeded + registered natively)
    _entries = {}, -- id -> { id, kind, cfg, server|nil, unavailable_reason|nil }
    _snapshot_cfg = nil, -- last applied config (diff baseline)
    _errors = {}, -- last apply_config registration errors (id -> typed error)
  }, Registry)
end

---@param id string server id
---@return boolean true when the id is reserved (seeded or registered natively)
function Registry:is_reserved(id)
  return self._reserved[id] == true
end

---@param id string
---@return table|nil entry
function Registry:get(id)
  return self._entries[id]
end

---@return table[] entries (sorted by id)
function Registry:list()
  local out = {}
  for id, entry in pairs(self._entries) do
    out[#out + 1] = entry
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

---@param id string
---@return string|nil kind ("external"|"native") or nil for unknown ids
function Registry:kind_of(id)
  local entry = self._entries[id]
  return entry and entry.kind or nil
end

--- Current state snapshot of one entry (server instance is authoritative).
---@param entry table entry record
---@return table rec { kind, state, generation, capabilities_revision, revision }
local function entry_snapshot(entry)
  local server = entry.server
  return {
    kind = entry.kind,
    state = server and server.state or entry.state or server_mod.STATES.unavailable,
    generation = server and server.generation or 0,
    capabilities_revision = server and server.capabilities_revision or 0,
    revision = server and server.state_revision or 0,
    unavailable_reason = entry.unavailable_reason,
  }
end

--- Redacted registry snapshot (used by the aggregate event and UI projections).
---@return table servers { [id] = entry_snapshot }
function Registry:snapshot()
  local servers = {}
  for id, entry in pairs(self._entries) do
    servers[id] = entry_snapshot(entry)
  end
  return servers
end

--- Register one external server from a normalized config record. IDs reserved
--- by a registered native server are rejected with a typed error (recorded in
--- `errors`); the remaining servers load.
---@param cfg table full loaded config (unavailable lookup)
---@param server_cfg table normalized per-server record
---@param errors table id -> typed error (mutated)
---@return table|nil entry
function Registry:_register_one(cfg, server_cfg, errors)
  local id = server_cfg.id
  if self:is_reserved(id) then
    local err = typed(
      ("server id %q is reserved for a native server and cannot be shadowed by a project declaration"):format(id),
      { reason = "reserved_native_id", id = id }
    )
    errors[id] = err
    self._errors[id] = err
    return nil
  end
  local reason = cfg.unavailable and cfg.unavailable[id]
  local entry = { id = id, kind = M.KIND_EXTERNAL, cfg = server_cfg, server = nil, unavailable_reason = reason }
  if reason then
    entry.state = server_mod.STATES.unavailable
  else
    entry.server = server_mod.new({
      cfg = server_cfg,
      events = self.events,
      clock = self.clock,
      tool_registry = self.tool_registry,
      process_factory = self.process_factory,
    })
    if server_cfg.enabled then
      entry.server:start()
    end
  end
  self._entries[id] = entry
  return entry
end

--- Register a native server instance. Registration is generic: ANY id may be
--- registered natively, and the id becomes reserved on registration (a project
--- declaration cannot shadow it afterwards). A duplicate registration
--- deterministically returns the existing entry while recording a typed error
--- (no duplicate capability entries — capabilities only come from the server's
--- own publish).
---@param server table native server instance (mcp.native.native_server)
---@return table|nil entry registered entry (existing entry on duplicates)
---@return table|nil err typed error (duplicate_native_registration)
function Registry:register_native(server)
  local id = server.id
  local entry = self._entries[id]
  if entry then
    local err = typed(("native server %q is already registered"):format(id), {
      reason = "duplicate_native_registration",
      id = id,
    })
    self._errors[id] = err
    return entry, err
  end
  local rec = { id = id, kind = M.KIND_NATIVE, cfg = nil, server = server, unavailable_reason = nil }
  self._entries[id] = rec
  self._reserved[id] = true -- registration reserves the id against project shadowing
  return rec, nil
end

--- Apply a loaded configuration: diff against the previous snapshot, run the
--- transitions (added/removed/changed), emit ONE aggregate mcp.server_state
--- event after the transitions, and store the new diff baseline.
---@param cfg table loaded config (mcp.config.load result)
---@return table result {
---   added = string[], removed = string[], changed = string[], unchanged = string[],
---   errors = { [id] = typed error },
--- }
function Registry:apply_config(cfg)
  local old = self._snapshot_cfg or { servers = {} }
  local diff = mcp_config.diff(old, cfg)
  local errors = {}
  self._errors = errors

  -- Removed: stop (drains/cancels + removes capabilities) and drop.
  for id, _ in pairs(diff.removed) do
    local entry = self._entries[id]
    if entry and entry.server then
      entry.server:stop()
    end
    self._entries[id] = nil
  end

  -- Changed: reload under one operation owner (unchanged entries keep their
  -- server instance, hence their generation).
  for id, info in pairs(diff.changed) do
    local entry = self._entries[id]
    if entry and entry.server then
      entry.server:reload(info.new)
      entry.cfg = info.new
    else
      -- Previously unavailable/disabled entry without a server: re-register.
      self._entries[id] = nil
      self:_register_one(cfg, info.new, errors)
    end
  end

  -- Added: register; enabled servers auto-start.
  for id, server_cfg in pairs(diff.added) do
    self:_register_one(cfg, server_cfg, errors)
  end

  -- Unchanged: keep entries untouched (generation preserved).

  self._snapshot_cfg = cfg
  self:_emit_aggregate("config_reload")

  local function keys(t)
    local out = {}
    for k in pairs(t) do
      out[#out + 1] = k
    end
    table.sort(out)
    return out
  end
  return {
    added = keys(diff.added),
    removed = keys(diff.removed),
    changed = keys(diff.changed),
    unchanged = keys(diff.unchanged),
    errors = errors,
  }
end

--- Emit the aggregate `mcp.server_state` update exactly once per reload.
---@param reason string aggregate reason
function Registry:_emit_aggregate(reason)
  if not self.events then
    return
  end
  -- The events bus methods are plain closures (no self parameter).
  pcall(self.events.emit, self.events.events.mcp_server_state, {
    aggregate = true,
    reason = reason,
    servers = self:snapshot(),
  })
end

--- Emit the aggregate `mcp.server_state` update exactly once (public wrapper;
--- phase-3 W4 uses it for native enable/disable transition batches).
---@param reason string aggregate reason
function Registry:emit_aggregate(reason)
  self:_emit_aggregate(reason)
end

---@param id string server id
---@return table|nil entry
---@return table|nil err typed error for unknown/disabled/unavailable servers
function Registry:restart(id)
  local entry = self._entries[id]
  if not entry then
    return nil, typed(("unknown mcp server %q"):format(tostring(id)))
  end
  if not entry.server then
    return nil, typed(("mcp server %q cannot restart (state=%s)"):format(id, entry.state or "unavailable"))
  end
  if entry.server.state == server_mod.STATES.disabled then
    return nil, typed(("mcp server %q is disabled and cannot restart"):format(id))
  end
  local res, err = entry.server:restart()
  return res, err
end

---@param id string server id
---@return table|nil result
---@return table|nil err typed error for unknown servers
function Registry:stop(id)
  local entry = self._entries[id]
  if not entry then
    return nil, typed(("unknown mcp server %q"):format(tostring(id)))
  end
  if entry.server then
    return entry.server:stop(), nil
  end
  return { joined = false, already = true, state = entry.state }, nil
end

--- Stop every registered server (shutdown path; no aggregate emission).
function Registry:stop_all()
  for _, entry in pairs(self._entries) do
    if entry.server then
      pcall(entry.server.stop, entry.server)
    end
  end
end

---@return table|nil last apply errors { [id] = typed error }
function Registry:last_errors()
  return self._errors
end

return M
