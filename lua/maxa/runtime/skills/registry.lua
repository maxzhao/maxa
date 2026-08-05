-- filepath: lua/maxa/runtime/skills/registry.lua
--- maxa runtime SkillHook registration registry (phase-3 W6).
---
--- Owns hook registration with the mcp-skill-runtime §SkillHook identity
--- `(skill_id, event_name, definition_hash, scope, owner_session|global)`:
---   * same-identity re-registration is deduplicated and the FIRST registration
---     provenance is preserved (registration order is the stable tie-break for
---     dispatch);
---   * scopes: `global` (no session binding), `session` (bound exactly to the
---     loading session), `cascade` (bound to the loading session AND inherited
---     by child sessions through an EXPLICIT parent-session lineage only —
---     unrelated sessions never inherit);
---   * custom SkillHook event names are registered from loaded definitions;
---     firing an unknown event is a validation failure (enforced by fire.lua);
---   * session close unregisters the session's session/cascade hooks and its
---     lineage records.
---
--- Unlike the downstream `util/skill_hooks/registry.lua` (vim autocmd
--- `User SkillHook*` + chat ids), the maxa registry is bus-native: entries are
--- dispatched by `skills.fire` over the maxa event bus semantics, and session
--- identity is the maxa `session_id` string (never a buffer).
---
--- Dependencies: `maxa.runtime.events` (bus + event constants),
--- `maxa.runtime.schema` (typed errors). Never loads `codecompanion.*` /
--- `mcphub.*` / `lua/util/hooks/*`.

local events_mod = require("maxa.runtime.events")
local schema = require("maxa.runtime.schema")

local M = {}

M.name = "skills.registry"
M.VERSION = 1

M.SCOPES = { global = true, session = true, cascade = true }

--- Build the dedup identity key.
---@param skill_id string
---@param event_name string
---@param definition_hash string
---@param scope string
---@param bound string|nil owner session or nil for global
---@return string
local function identity_key(skill_id, event_name, definition_hash, scope, bound)
  return table.concat({ skill_id, event_name, definition_hash, scope, bound or "global" }, "::")
end

--- Create a registry instance.
---@param opts? table {
---   bus?: table|nil isolated events bus (default: the maxa events singleton)
--- }
---@return table r
function M.new(opts)
  opts = opts or {}
  local bus = opts.bus or events_mod
  local r = {
    bus = bus,
    entries_by_event = {}, -- event_name -> entry[]
    cascade_hooks = {}, -- session_id -> { [identity_key]=hook } (declared cascade)
    parent_chain = {}, -- session_id -> { list=string[], set={ [id]=true } }
    known = {}, -- event_name -> true (built-in + registered customs)
    custom = {}, -- event_name -> skill_id that declared it (diagnostics)
    seq = 0, -- registration sequence (stable dispatch tie-break)
  }

  -- Built-in event names come from the maxa event constants table.
  for _, name in pairs(events_mod.events) do
    r.known[name] = true
  end

  local self = setmetatable({}, { __index = r })

  --- Whether an event name is known (built-in or registered custom).
  ---@param event_name string
  ---@return boolean
  function self.known_event(event_name)
    return r.known[event_name] ~= nil
  end

  --- Register a custom SkillHook event name from a loaded definition.
  ---@param event_name string
  ---@param skill_id string
  ---@return boolean newly added (false when already known)
  function self.register_custom_event(event_name, skill_id)
    if type(event_name) ~= "string" or event_name == "" then
      return false
    end
    if r.known[event_name] then
      return false
    end
    r.known[event_name] = true
    r.custom[event_name] = skill_id
    return true
  end

  --- All known event names (sorted, diagnostics).
  ---@return string[]
  function self.known_events()
    local out = {}
    for name in pairs(r.known) do
      out[#out + 1] = name
    end
    table.sort(out)
    return out
  end

  --- Register a parsed hook definition.
  ---@param hook table parsed hook record (skills.parser)
  ---@param opts? table {
  ---   owner_session?: string|nil session id for session/cascade scopes
  --- }
  ---@return table result { ok=boolean, deduped=boolean, entry=table|nil, err=table|nil }
  function self.register(hook, opts)
    opts = opts or {}
    local err_prefix = "skills.registry.register"

    if type(hook) ~= "table" then
      return {
        ok = false,
        deduped = false,
        entry = nil,
        err = schema.new_error(schema.ERROR.INVALID_ARGUMENT, err_prefix .. ": hook must be a table"),
      }
    end
    for _, field in ipairs({ "skill_id", "event_name", "definition_hash", "load", "scope", "inject_at", "kind" }) do
      if type(hook[field]) ~= "string" or hook[field] == "" then
        return {
          ok = false,
          deduped = false,
          entry = nil,
          err = schema.new_error(
            schema.ERROR.INVALID_ARGUMENT,
            ("%s: hook.%s must be a non-empty string"):format(err_prefix, field)
          ),
        }
      end
    end
    if not M.SCOPES[hook.scope] then
      return {
        ok = false,
        deduped = false,
        entry = nil,
        err = schema.new_error(
          schema.ERROR.CONFIGURATION,
          ("%s: invalid scope %q"):format(err_prefix, tostring(hook.scope))
        ),
      }
    end

    -- Custom event names become known through the loaded definition.
    if not r.known[hook.event_name] then
      self.register_custom_event(hook.event_name, hook.skill_id)
    end

    local bound = nil
    if hook.scope == "session" or hook.scope == "cascade" then
      if type(opts.owner_session) ~= "string" or opts.owner_session == "" then
        return {
          ok = false,
          deduped = false,
          entry = nil,
          err = schema.new_error(
            schema.ERROR.INVALID_ARGUMENT,
            ("%s: scope %q requires opts.owner_session"):format(err_prefix, hook.scope)
          ),
        }
      end
      bound = opts.owner_session
    end

    local key = identity_key(hook.skill_id, hook.event_name, hook.definition_hash, hook.scope, bound)
    if r.entries_by_event[hook.event_name] then
      for _, entry in ipairs(r.entries_by_event[hook.event_name]) do
        if entry.key == key then
          return { ok = true, deduped = true, entry = entry, err = nil } -- first provenance preserved
        end
      end
    end

    r.seq = r.seq + 1
    local entry = {
      key = key,
      skill_id = hook.skill_id,
      event_name = hook.event_name,
      definition_hash = hook.definition_hash,
      scope = hook.scope,
      bound_session = bound, -- nil = global
      hook = hook,
      priority = type(hook.priority) == "number" and hook.priority or 0,
      seq = r.seq,
    }
    r.entries_by_event[hook.event_name] = r.entries_by_event[hook.event_name] or {}
    table.insert(r.entries_by_event[hook.event_name], entry)

    if hook.scope == "cascade" and bound then
      r.cascade_hooks[bound] = r.cascade_hooks[bound] or {}
      r.cascade_hooks[bound][key] = hook
    end

    -- Lifecycle projection (events-status §SkillHook envelope; phase = load phase).
    bus.emit(events_mod.events.skill_hook_registered, {
      session_id = bound,
      skill_id = hook.skill_id,
      event_name = hook.event_name,
      phase = hook.load, -- "startup" | "on_load"
      scope = hook.scope,
      definition_hash = hook.definition_hash,
      ok = true,
      error = nil,
    })

    return { ok = true, deduped = false, entry = entry, err = nil }
  end

  --- Entries registered for an event (dispatch order = registration order).
  ---@param event_name string
  ---@return table[] entries
  function self.entries(event_name)
    return r.entries_by_event[event_name] or {}
  end

  --- Record an explicit parent-session lineage edge. Cascade hooks declared by
  --- `parent` then apply to `child` and any explicit descendant of `child`.
  ---@param parent_session_id string
  ---@param child_session_id string
  function self.register_parent_chain(parent_session_id, child_session_id)
    if type(parent_session_id) ~= "string" or parent_session_id == "" then
      error("skills.registry.register_parent_chain: parent_session_id required")
    end
    if type(child_session_id) ~= "string" or child_session_id == "" then
      error("skills.registry.register_parent_chain: child_session_id required")
    end
    local parent = r.parent_chain[parent_session_id]
    local list = { parent_session_id }
    local set = { [parent_session_id] = true }
    if parent then
      for _, ancestor in ipairs(parent.list) do
        list[#list + 1] = ancestor
        set[ancestor] = true
      end
    end
    r.parent_chain[child_session_id] = { list = list, set = set }
  end

  --- Whether `ancestor` is an explicit ancestor of `session_id` (lineage only).
  ---@param ancestor string
  ---@param session_id string
  ---@return boolean
  function self.is_ancestor(ancestor, session_id)
    if type(session_id) ~= "string" then
      return false
    end
    local chain = r.parent_chain[session_id]
    return chain ~= nil and chain.set[ancestor] == true
  end

  --- Scope filter at dispatch time: does this entry apply to `session_id`?
  ---   global  -> always
  ---   session -> only the bound session
  ---   cascade -> bound session or any explicit descendant lineage
  ---@param entry table registered entry
  ---@param session_id string firing session id
  ---@return boolean
  function self.matches_session(entry, session_id)
    if entry.scope == "global" then
      return true
    end
    if entry.scope == "session" then
      return entry.bound_session == session_id
    end
    if entry.scope == "cascade" then
      return entry.bound_session == session_id or self.is_ancestor(entry.bound_session, session_id)
    end
    return false
  end

  --- Copy-register the parent session's session-scoped hooks into a child
  --- session (subagent fork semantics: a child fully inherits the parent's
  --- session hooks). Dedup identity naturally keeps this idempotent.
  ---@param parent_session_id string
  ---@param child_session_id string
  ---@return integer newly registered count
  function self.inherit_session_hooks(parent_session_id, child_session_id)
    local count = 0
    for _, entries in pairs(r.entries_by_event) do
      for _, entry in ipairs(entries) do
        if entry.scope == "session" and entry.bound_session == parent_session_id then
          local res = self.register(entry.hook, { owner_session = child_session_id })
          if res.ok and not res.deduped then
            count = count + 1
          end
        end
      end
    end
    return count
  end

  --- Unregister every session/cascade entry bound to a session plus its
  --- lineage records (session close).
  ---@param session_id string
  function self.unregister_session(session_id)
    for event_name, entries in pairs(r.entries_by_event) do
      local kept = {}
      for _, entry in ipairs(entries) do
        if entry.bound_session ~= session_id then
          kept[#kept + 1] = entry
        end
      end
      if #kept > 0 then
        r.entries_by_event[event_name] = kept
      else
        r.entries_by_event[event_name] = nil
      end
    end
    r.cascade_hooks[session_id] = nil
    r.parent_chain[session_id] = nil
  end

  --- Cascade hook records declared by a session and its explicit ancestors
  --- (diagnostics / tests).
  ---@param session_id string
  ---@return table[] hooks
  function self.cascade_hooks_for(session_id)
    local out = {}
    local seen = {}
    local function collect(sid)
      for _, hook in pairs(r.cascade_hooks[sid] or {}) do
        if not seen[hook.definition_hash .. hook.skill_id] then
          seen[hook.definition_hash .. hook.skill_id] = true
          out[#out + 1] = hook
        end
      end
    end
    collect(session_id)
    local chain = r.parent_chain[session_id]
    if chain then
      for _, ancestor in ipairs(chain.list) do
        collect(ancestor)
      end
    end
    return out
  end

  --- Snapshot for diagnostics/tests.
  ---@return table state
  function self.state()
    local entries = {}
    local total = 0
    for event_name, list in pairs(r.entries_by_event) do
      entries[event_name] = #list
      total = total + #list
    end
    local chains = {}
    for sid, chain in pairs(r.parent_chain) do
      chains[sid] = chain.list
    end
    return {
      entries = entries,
      total = total,
      seq = r.seq,
      cascade_sessions = vim.tbl_keys(r.cascade_hooks),
      parent_chain = chains,
      custom_events = vim.deepcopy(r.custom),
      known_events = self.known_events(),
    }
  end

  --- Reset instance state (tests / cold-start isolation). Built-in event names
  --- survive; custom registrations and entries are dropped.
  function self.reset()
    r.entries_by_event = {}
    r.cascade_hooks = {}
    r.parent_chain = {}
    r.known = {}
    r.custom = {}
    r.seq = 0
    for _, name in pairs(events_mod.events) do
      r.known[name] = true
    end
  end

  return self
end

return M
