-- filepath: lua/maxa/runtime/skills/fire.lua
--- maxa runtime SkillHook dispatch (phase-3 W6).
---
--- Event dispatch over the maxa event-bus semantics (mcp-skill-runtime
--- §SkillHook + events-status §SkillHook):
---   * `pre(event, payload, {stack, ...})` is SYNCHRONOUS: pre hooks required
---     for request composition run in deterministic order (priority desc,
---     then skill_id asc, then registration sequence) and injected messages
---     are persisted into the session message stack with provenance BEFORE
---     request composition proceeds;
---   * `post(event, payload, ...)` delivers observer hooks: each observer
---     receives an IMMUTABLE deep copy of the already-composed request; return
---     values are ignored; nothing is injected; listener failures are isolated
---     and typed (they never corrupt the main flow);
---   * filters are pure payload predicates (markdown filter table or lua
---     filter function); a no-match hook is NOT invoked and NOT rendered;
---   * once/tombstone: a once hook that fired is skipped on later fires
---     (in-memory + durable tombstone/provenance restored by injector);
---   * firing an unknown event or an incomplete payload (missing session
---     identity) fails validation with a typed error.
---
--- The downstream `util/skill_hooks/fire.lua` used vim autocmd User SkillHook*
--- dispatch; maxa dispatches through `skills.registry` entries directly and
--- projects lifecycle onto the maxa events bus (`skill.hook_fired` /
--- `skill.hook_failed`).
---
--- Dependencies: `maxa.runtime.skills.registry`, `maxa.runtime.skills.injector`,
--- `maxa.runtime.events`, `maxa.runtime.schema`. Never loads `codecompanion.*`
--- / `mcphub.*` / `lua/util/hooks/*`.

local events_mod = require("maxa.runtime.events")
local injector_mod = require("maxa.runtime.skills.injector")
local schema = require("maxa.runtime.schema")

local M = {}

M.name = "skills.fire"
M.VERSION = 1

-------------------------------------------------------------------------------
-- Filter engine (pure payload predicates, downstream filter.lua semantics)
-------------------------------------------------------------------------------

--- Parse a single filter condition string into a matcher.
--- Semantics: `!` negation, `*` existence, `prefix:` prefix match,
--- `pattern:` Lua-pattern (with `|` as OR alternation), `a|b` exact OR,
--- otherwise exact match.
---@param cond_str string
---@return fun(val: any): boolean matcher
---@return string|nil err on ambiguous syntax
local function parse_condition(cond_str)
  local negated = false
  local cond = cond_str

  if cond:sub(1, 1) == "!" then
    negated = true
    cond = cond:sub(2)
  end
  if negated and cond:find("|") then
    return nil, ("ambiguous negation in filter condition %q (use separate array items)"):format(cond_str)
  end

  local matcher
  if cond == "*" then
    matcher = function(val)
      return val ~= nil
    end
  elseif cond:sub(1, 7) == "prefix:" then
    local prefix = cond:sub(8)
    local plen = #prefix
    matcher = function(val)
      return type(val) == "string" and val:sub(1, plen) == prefix
    end
  elseif cond:sub(1, 8) == "pattern:" then
    local pat = cond:sub(9)
    if pat:find("|", 1, true) then
      local patterns = {}
      for p in pat:gmatch("[^|]+") do
        patterns[#patterns + 1] = p
      end
      matcher = function(val)
        if type(val) ~= "string" then
          return false
        end
        for _, p in ipairs(patterns) do
          if val:find(p) ~= nil then
            return true
          end
        end
        return false
      end
    else
      matcher = function(val)
        return type(val) == "string" and val:find(pat) ~= nil
      end
    end
  elseif cond:find("|") then
    local values = {}
    for v in cond:gmatch("[^|]+") do
      values[v] = true
    end
    matcher = function(val)
      return val ~= nil and values[tostring(val)] ~= nil
    end
  else
    matcher = function(val)
      return val ~= nil and tostring(val) == cond
    end
  end

  if negated then
    local orig = matcher
    return function(val)
      return not orig(val)
    end
  end
  return matcher
end

--- Normalize a filter value into condition strings.
---@param filter_val any
---@return string[]
local function normalize_filter_val(filter_val)
  if type(filter_val) == "string" or type(filter_val) == "number" or type(filter_val) == "boolean" then
    return { tostring(filter_val) }
  end
  if type(filter_val) == "table" then
    local out = {}
    for _, item in ipairs(filter_val) do
      out[#out + 1] = tostring(item)
    end
    return out
  end
  return {}
end

--- Match a markdown filter table against a payload (fields AND, items AND,
--- `|` OR). nil/empty filter always matches; a parse error never matches.
---@param filter table|nil hook frontmatter filter
---@param data table payload
---@return boolean
function M.matches_filter(filter, data)
  if not filter or type(filter) ~= "table" or next(filter) == nil then
    return true
  end
  for field, filter_val in pairs(filter) do
    local conditions = normalize_filter_val(filter_val)
    local val = data[field]
    for _, cond in ipairs(conditions) do
      local ok, matcher = pcall(parse_condition, cond)
      if not ok then
        return false
      end
      if not matcher(val) then
        return false
      end
    end
  end
  return true
end

-------------------------------------------------------------------------------
-- Instance
-------------------------------------------------------------------------------

--- Create a fire dispatcher bound to a registry.
---@param opts table {
---   registry: table  skills.registry instance (required)
---   bus?:     table|nil events bus (default: registry bus)
---   injector?: table|nil injector instance (default: fresh on the same bus)
--- }
---@return table f
function M.new(opts)
  assert(type(opts) == "table" and opts.registry ~= nil, "skills.fire.new: opts.registry is required")
  local registry = opts.registry
  local bus = opts.bus or registry.bus
  local injector = opts.injector or injector_mod.new({ bus = bus })
  local f = {
    registry = registry,
    bus = bus,
    injector = injector,
  }
  local self = setmetatable({}, { __index = f })

  --- Validate the event name against the registry's known events.
  ---@param event_name string
  ---@return table|nil err typed validation error
  function self.validate_event(event_name)
    if type(event_name) ~= "string" or event_name == "" then
      return schema.new_error(schema.ERROR.INVALID_ARGUMENT, "skills.fire: event name must be a non-empty string")
    end
    if not registry.known_event(event_name) then
      return schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("skills.fire: unknown SkillHook event %q (custom events must be registered by a loaded definition)"):format(
          event_name
        )
      )
    end
    return nil
  end

  --- Validate payload completeness: a table payload and a session identity.
  ---@param event_name string
  ---@param payload any
  ---@param opts? table { session_id?: string }
  ---@return string|nil session_id
  ---@return table|nil err
  function self.validate_payload(event_name, payload, opts)
    opts = opts or {}
    if type(payload) ~= "table" then
      return nil,
        schema.new_error(schema.ERROR.INVALID_ARGUMENT, ("skills.fire: %s: payload must be a table"):format(event_name))
    end
    local session_id = opts.session_id or payload.session_id
    if type(session_id) ~= "string" or session_id == "" then
      return nil,
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("skills.fire: %s: incomplete payload (session_id required)"):format(event_name)
        )
    end
    return session_id, nil
  end

  --- Deterministic dispatch order: priority desc, skill_id asc, seq asc.
  ---@param entries table[]
  ---@return table[] sorted copy
  function self.sort_entries(entries)
    local sorted = {}
    for i, entry in ipairs(entries) do
      sorted[i] = entry
    end
    table.sort(sorted, function(a, b)
      if a.priority ~= b.priority then
        return a.priority > b.priority
      end
      if a.skill_id ~= b.skill_id then
        return a.skill_id < b.skill_id
      end
      return a.seq < b.seq
    end)
    return sorted
  end

  --- Build the lua-hook render ctx (maxa event payload only; no codecompanion
  --- objects).
  ---@param hook table parsed hook record
  ---@param payload table event payload (already copied)
  ---@param identity table { session_id, request_id, turn_id }
  ---@return table ctx
  function self.build_ctx(hook, payload, identity)
    return {
      event_name = hook.event_name,
      data = payload,
      session_id = identity.session_id,
      request_id = identity.request_id,
      turn_id = identity.turn_id,
      skill_id = hook.skill_id,
      hook_path = hook.path,
      skill_dir = hook.skill_dir,
    }
  end

  --- Apply a hook's filter (pure predicate). A failing lua filter function is
  --- an isolated typed failure (hook skipped).
  ---@param hook table parsed hook record
  ---@param ctx table lua ctx
  ---@param payload table payload
  ---@return boolean matched
  ---@return table|nil err typed failure (nil when no failure)
  function self.apply_filter(hook, ctx, payload)
    if hook.kind == "lua" and type(hook.filter) == "function" then
      local ok, matched = pcall(hook.filter, ctx)
      if not ok then
        return false,
          schema.new_error(
            schema.ERROR.INTERNAL,
            ("skills.fire: lua hook %s filter failed: %s"):format(hook.path, tostring(matched))
          )
      end
      return matched == true, nil
    end
    return M.matches_filter(hook.filter, payload), nil
  end

  --- Resolve a hook's prompts (markdown static / lua render with pcall).
  ---@param hook table parsed hook record
  ---@param ctx table lua ctx
  ---@return table|nil prompts
  ---@return table|nil err typed failure
  function self.resolve_prompts(hook, ctx)
    if hook.kind == "lua" then
      local ok, prompts = pcall(hook.render, ctx)
      if not ok then
        return nil,
          schema.new_error(
            schema.ERROR.INTERNAL,
            ("skills.fire: lua hook %s render failed: %s"):format(hook.path, tostring(prompts))
          )
      end
      return injector.normalize_prompts(prompts, hook)
    end
    return hook.prompts, nil
  end

  --- Emit the fired projection for one successful hook.
  ---@param identity table { session_id, request_id, turn_id }
  ---@param hook table parsed hook record
  ---@param phase string "pre"|"post"
  ---@param injected integer
  function self.emit_fired(identity, hook, phase, injected)
    bus.emit(events_mod.events.skill_hook_fired, {
      session_id = identity.session_id,
      request_id = identity.request_id,
      turn_id = identity.turn_id,
      skill_id = hook.skill_id,
      event_name = hook.event_name,
      phase = phase,
      ok = true,
      error = nil,
      injected = injected,
    })
  end

  --- Emit the failed projection for one failed hook.
  ---@param identity table
  ---@param hook table parsed hook record
  ---@param phase string
  ---@param err table typed error
  function self.emit_failed(identity, hook, phase, err)
    bus.emit(events_mod.events.skill_hook_failed, {
      session_id = identity.session_id,
      request_id = identity.request_id,
      turn_id = identity.turn_id,
      skill_id = hook.skill_id,
      event_name = hook.event_name,
      phase = phase,
      ok = false,
      error = err.message or tostring(err),
    })
  end

  --- Synchronous pre-submit dispatch. Injection completes before request
  --- composition; injected messages carry provenance and are persisted.
  ---@param event_name string
  ---@param payload table event payload (session_id required)
  ---@param opts? table {
  ---   stack?: table|nil conversation Stack required when a pre hook injects,
  ---   session_id?: string, request_id?: string, turn_id?: string
  --- }
  ---@return table result { ok, phase="pre", event_name, injected, skipped,
  ---   failures=table[], error=table|nil }
  function self.pre(event_name, payload, opts)
    opts = opts or {}
    local result =
      { ok = true, phase = "pre", event_name = event_name, injected = 0, skipped = 0, failures = {}, error = nil }

    local verr = self.validate_event(event_name)
    if verr then
      result.ok = false
      result.error = verr
      return result
    end
    local session_id, perr = self.validate_payload(event_name, payload, opts)
    if perr then
      result.ok = false
      result.error = perr
      return result
    end

    local identity = {
      session_id = session_id,
      request_id = opts.request_id or payload.request_id,
      turn_id = opts.turn_id or payload.turn_id,
    }

    local entries = {}
    for _, entry in ipairs(registry.entries(event_name)) do
      if entry.hook.inject_at == "pre" then
        entries[#entries + 1] = entry
      end
    end
    local sorted = self.sort_entries(entries)

    for _, entry in ipairs(sorted) do
      local hook = entry.hook
      if not registry.matches_session(entry, session_id) then
        result.skipped = result.skipped + 1
      else
        local ctx = self.build_ctx(hook, vim.deepcopy(payload), identity)
        local matched, ferr = self.apply_filter(hook, ctx, payload)
        if ferr then
          result.failures[#result.failures + 1] =
            { skill_id = hook.skill_id, event_name = hook.event_name, phase = "pre", error = ferr }
          self.emit_failed(identity, hook, "pre", ferr)
        elseif not matched then
          result.skipped = result.skipped + 1 -- no-match: no render, no injection
        else
          local is_once = hook.opts.once == true
          local once_key = injector.once_key(hook)
          if is_once and injector.fired_once(session_id, once_key) then
            result.skipped = result.skipped + 1
          else
            local prompts, rerr = self.resolve_prompts(hook, ctx)
            if rerr then
              result.failures[#result.failures + 1] =
                { skill_id = hook.skill_id, event_name = hook.event_name, phase = "pre", error = rerr }
              self.emit_failed(identity, hook, "pre", rerr)
            elseif not prompts then
              result.skipped = result.skipped + 1 -- render returned nothing to inject
            else
              if opts.stack == nil then
                local serr = schema.new_error(
                  schema.ERROR.INVALID_ARGUMENT,
                  ("skills.fire: %s: pre hook %s/%s matched but no opts.stack was provided"):format(
                    event_name,
                    hook.skill_id,
                    hook.event_name
                  )
                )
                result.ok = false
                result.error = serr
                return result
              end
              local injected = injector.inject(opts.stack, hook, prompts, {
                visible = hook.opts.visible == true,
                once = is_once,
                once_key = once_key,
                ephemeral = hook.opts.ephemeral == true,
              })
              if is_once then
                injector.mark_fired(session_id, once_key)
                if hook.opts.ephemeral == true then
                  injector.write_tombstone(opts.stack, hook, { once_key = once_key })
                end
              end
              result.injected = result.injected + injected.injected
              self.emit_fired(identity, hook, "pre", injected.injected)
            end
          end
        end
      end
    end

    result.ok = #result.failures == 0 and result.error == nil
    return result
  end

  --- Post/observer dispatch. Observers receive an immutable deep copy of the
  --- payload (already-sent request cannot be mutated); return values are
  --- ignored; failures are isolated and typed. Synchronous by default (the
  --- "asynchronous observer" property = never on the composition path, never
  --- mutating the sent request); `opts.async=true` schedules the dispatch.
  ---@param event_name string
  ---@param payload table event payload (session_id required)
  ---@param opts? table { session_id?: string, request_id?: string,
  ---   turn_id?: string, async?: boolean }
  ---@return table result
  function self.post(event_name, payload, opts)
    opts = opts or {}
    if opts.async == true then
      vim.schedule(function()
        self.post(
          event_name,
          payload,
          { session_id = opts.session_id, request_id = opts.request_id, turn_id = opts.turn_id }
        )
      end)
      return {
        ok = true,
        phase = "post",
        event_name = event_name,
        scheduled = true,
        injected = 0,
        observers = 0,
        skipped = 0,
        failures = {},
        error = nil,
      }
    end

    local result = {
      ok = true,
      phase = "post",
      event_name = event_name,
      observers = 0,
      injected = 0,
      skipped = 0,
      failures = {},
      error = nil,
    }

    local verr = self.validate_event(event_name)
    if verr then
      result.ok = false
      result.error = verr
      return result
    end
    local session_id, perr = self.validate_payload(event_name, payload, opts)
    if perr then
      result.ok = false
      result.error = perr
      return result
    end

    local identity = {
      session_id = session_id,
      request_id = opts.request_id or payload.request_id,
      turn_id = opts.turn_id or payload.turn_id,
    }

    local entries = {}
    for _, entry in ipairs(registry.entries(event_name)) do
      if entry.hook.inject_at == "post" then
        entries[#entries + 1] = entry
      end
    end
    local sorted = self.sort_entries(entries)

    for _, entry in ipairs(sorted) do
      local hook = entry.hook
      if not registry.matches_session(entry, session_id) then
        result.skipped = result.skipped + 1
      else
        -- Immutable observer view: each observer gets its own deep copy.
        local ctx = self.build_ctx(hook, vim.deepcopy(payload), identity)
        local matched, ferr = self.apply_filter(hook, ctx, payload)
        if ferr then
          result.failures[#result.failures + 1] =
            { skill_id = hook.skill_id, event_name = hook.event_name, phase = "post", error = ferr }
          self.emit_failed(identity, hook, "post", ferr)
        elseif not matched then
          result.skipped = result.skipped + 1
        else
          local is_once = hook.opts.once == true
          local once_key = injector.once_key(hook)
          if is_once and injector.fired_once(session_id, once_key) then
            result.skipped = result.skipped + 1
          else
            if hook.kind == "lua" then
              -- Observer: render may run (own side effects) but the result is
              -- ignored; nothing is injected after a request was composed.
              local _, rerr = self.resolve_prompts(hook, ctx)
              if rerr then
                result.failures[#result.failures + 1] =
                  { skill_id = hook.skill_id, event_name = hook.event_name, phase = "post", error = rerr }
                self.emit_failed(identity, hook, "post", rerr)
              else
                if is_once then
                  injector.mark_fired(session_id, once_key) -- in-memory only (nothing durable injected)
                end
                result.observers = result.observers + 1
                self.emit_fired(identity, hook, "post", 0)
              end
            else
              -- Markdown observer: pure payload predicate already matched; no
              -- side effect exists.
              if is_once then
                injector.mark_fired(session_id, once_key)
              end
              result.observers = result.observers + 1
              self.emit_fired(identity, hook, "post", 0)
            end
          end
        end
      end
    end

    result.ok = #result.failures == 0 and result.error == nil
    return result
  end

  return self
end

return M
