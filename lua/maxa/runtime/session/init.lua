-- filepath: lua/maxa/runtime/session/init.lua
--- maxa runtime session module: explicit four-entity state model + legal transition
--- reducer (phase 2 W1) + submit-intent records with idempotent replay and
--- snapshot restore (phase 2 W3).
---
--- Scope (see .supermax/drafts/phase2-implementation-plan.md W1 and
--- .supermax/specs/modules/chat-runtime-state/spec.md): this module owns the four
--- runtime entities — Session, Request, ToolBatch, View — and the legal-transition
--- reducer. It does NOT drive providers itself; that is the orchestrator's job
--- (lua/maxa/runtime/orchestrator). It never loads codecompanion.* / mcphub.* /
--- lua/util/hooks/*.
---
--- Alignment (read-only): chat-runtime-state entity schemas + §Legal transition
--- ownership. Entity identities are immutable; generation increments when an
--- identity's async authority is superseded; terminal transitions are idempotent
--- (first terminal CAS wins); a terminal call for a superseded request/batch is
--- marked on the record but never mutates the current session.
---
--- State model (phase-2 W1 full set; `idle` is a compat alias of `ready`):
---   session.state:   created|ready|busy|waiting_for_user|completed|failed|stopped|closed
---     created          constructed; auto-transitions to ready (init succeeds)
---     ready            accepts a submit (compat name: idle)
---     busy             exactly one active request (submitted/streaming/...)
---     waiting_for_user request reached terminal; next submit accepted
---     completed        (enum value; reachable via future waves)
---     failed           (enum value; reachable via future waves)
---     stopped          explicit stop; work terminal, continuation suppressed
---     closed           explicit session close; final
---   request.state:     submitted|starting|streaming|tool_pending|completed|failed|cancelled
---   tool_batch.state:  pending|running|draining|completed|failed|cancelled
---   view.state:        attached|hidden|detached|closed
---
--- Reducer contract (chat-runtime-state §Legal transition ownership):
---   transition(entity, action, ctx) -> (ok, result, err)
---     ok=true, result={ changed=true, record=... }   transition performed
---     ok=true, result={ changed=false }              idempotent repeat / terminal-CAS
---                                                    no-op / superseded terminal call
---                                                    (marked on the record, session untouched)
---     ok=nil,  result=nil, err=typed error           illegal transition; a diagnostic
---                                                    event `session.transition_rejected`
---                                                    (additive) is emitted; state is NEVER
---                                                    mutated partially
---   Every performed transition records
---     { entity, entity_id, action, from, to, owner, event, reason, at, idempotent }
---   on the session's transition history. Effects run in the declared order:
---   validate -> mutate in-memory state -> record (W1 in-memory persist boundary;
---   durable keys arrive with W4/W5) -> emit (W1 emits only rejection diagnostics;
---   valid transitions are record-only to keep the W8 bus contract additive) ->
---   schedule (no scheduling in W1; W5 continuation wiring).
---
--- Compatibility (phase-0 surface kept verbatim):
---   M.new/M.states/M.request_states/M.TERMINAL_STATES/M.create/M.Session and
---   Session:start_request/finish_request/close/snapshot/is_idle/is_busy/is_closed/
---   set_events keep their call signatures and semantics:
---   - is_idle()  = ready|waiting_for_user (accepts a submit; old "idle" == "ready")
---   - is_busy()  = busy
---   - is_closed()= closed
---   - start_request rejects while busy/stopped/completed/failed/closed (typed
---     INVALID_ARGUMENT; closed keeps terminal=true)
---   - finish_request is idempotent per request; the first legal terminal state wins;
---     superseded requests are marked { state, superseded=true } without session
---     mutation; the session returns to waiting_for_user (snapshot.state changes
---     from "idle" to "waiting_for_user"; is_idle() still accepts the next submit)
---   - close() is idempotent and marks the active request/batch cancelled
--- New additive methods: Session:stop(), Session:transition(), Session:new_tool_batch(),
--- Session:new_view(), Session:transition_history(), module M.transition/M.TRANSITIONS,
--- M.request_states (starting/tool_pending added), M.tool_batch_states, M.view_states,
--- M.TERMINAL_BATCH_STATES, M.Request/M.ToolBatch/M.View.
---
--- Timestamps: transition/terminal records use `at` (ms, deterministic via the
--- optional `opts.clock.now_ms` seam for W2); legacy diagnostic fields
--- created_at/started_at keep their phase-0 os.time() seconds.

local schema = require("maxa.runtime.schema")
local events = require("maxa.runtime.events")

local M = {}

M.name = "session"

--- Session-level states (chat-runtime-state full set; `idle` is a compat alias of
--- `ready` — both resolve to the string "ready", so `state == M.states.idle` keeps
--- working while the canonical state is "ready").
M.states = {
  created = "created",
  ready = "ready",
  idle = "ready", -- compat alias: old phase-0 "idle" state is now "ready"
  busy = "busy",
  waiting_for_user = "waiting_for_user",
  completed = "completed",
  failed = "failed",
  stopped = "stopped",
  closed = "closed",
}

--- Request-level states.
M.request_states = {
  submitted = "submitted",
  starting = "starting",
  streaming = "streaming",
  tool_pending = "tool_pending",
  completed = "completed",
  failed = "failed",
  cancelled = "cancelled",
}

--- ToolBatch-level states.
M.tool_batch_states = {
  pending = "pending",
  running = "running",
  draining = "draining",
  completed = "completed",
  failed = "failed",
  cancelled = "cancelled",
}

--- View-level states.
M.view_states = {
  attached = "attached",
  hidden = "hidden",
  detached = "detached",
  closed = "closed",
}
--- AgentLoop states (W5 minimal state machine; request-orchestrator
--- §Continuation decision). `armed` permits an automatic continuation after a
--- completed tool batch; `waiting_for_user` parks the loop (no continuation,
--- next manual submit re-arms it).
M.loop_states = {
  armed = "armed",
  waiting_for_user = "waiting_for_user",
}

--- Legal terminal request states (first one wins; finish is idempotent).
M.TERMINAL_STATES = {
  [M.request_states.completed] = true,
  [M.request_states.failed] = true,
  [M.request_states.cancelled] = true,
}

--- Legal terminal tool-batch states (first one wins; barrier CAS).
M.TERMINAL_BATCH_STATES = {
  [M.tool_batch_states.completed] = true,
  [M.tool_batch_states.failed] = true,
  [M.tool_batch_states.cancelled] = true,
}

--- Submit-intent kinds (request-orchestrator §Submit intent and idempotency).
--- Intent identity fields (id/session_id/turn_id/kind/expected_generation/
--- input_revision/context_revision/config_snapshot_id) are immutable once
--- created; only `state` and `decision` mutate (pending -> in_flight/rejected/
--- completed). Replaying the same intent_id returns the recorded decision and
--- never starts a second provider request.
M.intent_kinds = {
  manual = "manual",
  automatic = "automatic",
  regenerate = "regenerate",
  restore = "restore",
  retry = "retry",
}

--- Diagnostic event name (additive W1 name; never emitted for valid transitions).
M.EVENTS = {
  transition_rejected = "session.transition_rejected",
}

--- Transition history cap (records beyond this are dropped oldest-first).
M.HISTORY_CAP = 1024

--- Terminal event names per entity kind, for transition records.
local TERMINAL_EVENTS = {
  request = {
    completed = "request.completed",
    failed = "request.failed",
    cancelled = "request.cancelled",
  },
  tool_batch = {
    completed = "tool_batch.completed",
    failed = "tool_batch.failed",
    cancelled = "tool_batch.cancelled",
  },
}

--- Default wall-clock in milliseconds (mirrors events/schema now_ms).
---@return integer
local function now_ms()
  if vim and vim.uv and vim.uv.hrtime then
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  return os.time() * 1000
end

------------------------------------------------------------
-- Identity helpers
------------------------------------------------------------
-- Request/session/tool-batch/view identity generators are trivial stable-string
-- allocators; they are intentionally NOT content-derived (session id is per-Chat
-- lifetime stable, request id is per-submit — plan §4.4).
local id_counter = 0
local function make_id(prefix)
  id_counter = id_counter + 1
  return ("%s-%d-%d"):format(prefix, os.time(), id_counter)
end

------------------------------------------------------------
-- Entity classes
------------------------------------------------------------
local Session = {}
Session.__index = Session

local Request = {}
Request.__index = Request

local ToolBatch = {}
ToolBatch.__index = ToolBatch

local View = {}
View.__index = View

--- Resolve a session-owned transition history/record owner for an entity.
---@param entity table entity record
---@param ctx table transition context (session)
---@return table|nil session
local function record_owner(entity, ctx)
  if entity._kind == "session" then
    return entity
  end
  return ctx.session
end

--- Find an entity record by id inside a session-owned list (stop/close cancellation).
---@param list table[] entity records
---@param id string|nil
---@return table|nil
local function find_by_id(list, id)
  if not id then
    return nil
  end
  for _, rec in ipairs(list) do
    if rec.id == id then
      return rec
    end
  end
  return nil
end

--- Resolve the deterministic ms timestamp for a transition (W2 clock seam).
---@param session table|nil session record
---@return integer
local function stamp(session)
  local clock = session and session._clock
  if clock and clock.now_ms then
    return clock.now_ms()
  end
  return now_ms()
end

--- Append a transition record to a session's history (capped).
---@param session table
---@param record table
local function append_record(session, record)
  local history = session.transitions
  history[#history + 1] = record
  if #history > M.HISTORY_CAP then
    table.remove(history, 1)
  end
end

--- Mark an active request/batch terminal as cancelled during session stop/close.
--- Does NOT transition the session (stop/close own the session move); the record
--- is appended for traceability.
---@param session table
---@param kind string "request"|"tool_batch"
---@param record table|nil entity record
---@param reason string
local function mark_cancelled(session, kind, record, reason)
  if not record or record.terminal then
    return
  end
  local from = record.state
  local to = kind == "request" and M.request_states.cancelled or M.tool_batch_states.cancelled
  local at = stamp(session)
  record.state = to
  record.terminal = { state = to, at = at, reason = reason }
  append_record(session, {
    entity = kind,
    entity_id = record.id,
    action = "terminal",
    from = from,
    to = to,
    owner = "session control",
    event = TERMINAL_EVENTS[kind][to],
    reason = reason,
    at = at,
    idempotent = true,
  })
end

--- Effect of session stop/close: cancel active request + batch, clear active ids.
---@param entity table session
---@param ctx table transition context
---@param rule table transition rule
local function cancel_active_effect(entity, ctx, rule)
  local reason = ctx.reason or rule.reason or "session control"
  local req = find_by_id(entity.requests, entity.active_request_id)
  local batch = find_by_id(entity.tool_batches, entity.active_tool_batch_id)
  mark_cancelled(entity, "request", req, reason)
  mark_cancelled(entity, "tool_batch", batch, reason)
  entity.active_request_id = nil
  entity.active_tool_batch_id = nil
end

------------------------------------------------------------
-- Legal transition table (chat-runtime-state §Legal transition ownership)
------------------------------------------------------------
-- Each rule: { from = <state set>, to = <target>, owner, event, reason,
--              idempotent = <repeat with from==to is a no-op>, effect = <optional>,
--              terminal = <true for CAS rules requiring ctx.to>, states = <terminal set> }
-- Terminal rules (request/tool_batch) perform the first-terminal-wins CAS and
-- mark superseded calls without mutating the current session.
M.TRANSITIONS = {
  session = {
    ready = {
      from = { created = true },
      to = M.states.ready,
      owner = "session",
      event = "session.ready",
      reason = "initialization/configuration succeeds",
      idempotent = true,
    },
    accept_submit = {
      from = { ready = true, waiting_for_user = true },
      to = M.states.busy,
      owner = "orchestrator",
      event = "session.busy",
      reason = "orchestrator accepts one submit intent",
    },
    continue = {
      from = { busy = true },
      to = M.states.busy,
      owner = "orchestrator",
      event = "session.continue",
      reason = "orchestrator chooses one automatic continuation with a new request",
    },
    wait_for_user = {
      from = { busy = true },
      to = M.states.waiting_for_user,
      owner = "orchestrator",
      event = "session.waiting_for_user",
      reason = "no continuation / soft stop / recoverable failure",
      idempotent = true,
    },
    stop = {
      from = {
        created = true,
        ready = true,
        busy = true,
        waiting_for_user = true,
        completed = true,
        failed = true,
      },
      to = M.states.stopped,
      owner = "control",
      event = "session.stopped",
      reason = "explicit stop makes current work terminal and suppresses continuation",
      idempotent = true,
      effect = cancel_active_effect,
    },
    close = {
      from = {
        created = true,
        ready = true,
        busy = true,
        waiting_for_user = true,
        completed = true,
        failed = true,
        stopped = true,
      },
      to = M.states.closed,
      owner = "explicit close",
      event = "session.closed",
      reason = "explicit session close; all owned work cancelled/cleaned",
      idempotent = true,
      effect = cancel_active_effect,
    },
  },
  request = {
    start = {
      from = { submitted = true },
      to = M.request_states.starting,
      owner = "provider runtime",
      event = "request.starting",
      reason = "provider stream starts",
    },
    stream = {
      from = { starting = true },
      to = M.request_states.streaming,
      owner = "provider runtime",
      event = "request.streaming",
      reason = "response-start; may skip content but occurs once",
    },
    tool_pending = {
      from = { streaming = true },
      to = M.request_states.tool_pending,
      owner = "orchestrator",
      event = "request.tool_pending",
      reason = "normalized completed response contains tool calls",
    },
    terminal = {
      from = {
        submitted = true,
        starting = true,
        streaming = true,
        tool_pending = true,
      },
      terminal = true,
      states = M.TERMINAL_STATES,
      owner = "orchestrator/provider runtime",
      reason = "request terminal (one compare-and-set)",
    },
  },
  tool_batch = {
    run = {
      from = { pending = true },
      to = M.tool_batch_states.running,
      owner = "tool runtime",
      event = "tool_batch.running",
      reason = "batch execution starts",
    },
    drain = {
      from = { running = true },
      to = M.tool_batch_states.draining,
      owner = "tool runtime",
      event = "tool_batch.draining",
      reason = "stop/soft-stop drains the remaining calls",
    },
    terminal = {
      from = {
        pending = true,
        running = true,
        draining = true,
      },
      terminal = true,
      states = M.TERMINAL_BATCH_STATES,
      owner = "tool runtime",
      reason = "batch terminal (barrier)",
    },
  },
  view = {
    hide = {
      from = { attached = true },
      to = M.view_states.hidden,
      owner = "view",
      event = "view.hidden",
      reason = "window hidden",
      idempotent = true,
    },
    show = {
      from = { hidden = true },
      to = M.view_states.attached,
      owner = "view",
      event = "view.attached",
      reason = "window shown again",
      idempotent = true,
    },
    detach = {
      from = { attached = true, hidden = true },
      to = M.view_states.detached,
      owner = "buffer/window deletion",
      event = "view.detached",
      reason = "buffer/window deleted; the session remains",
      idempotent = true,
    },
    close = {
      from = { attached = true, hidden = true, detached = true },
      to = M.view_states.closed,
      owner = "explicit view close",
      event = "view.closed",
      reason = "explicit view close",
      idempotent = true,
    },
  },
}

--- Emit the rejection diagnostic + build the typed error. Never throws on a
--- failing bus (the rejection itself must not be masked).
---@param bus table|nil event bus
---@param entity table|nil entity record
---@param action string
---@param from any
---@param to any
---@param message string
---@return nil, nil, table typed INVALID_ARGUMENT error
local function reject(bus, entity, action, from, to, message)
  local err = schema.new_error(schema.ERROR.INVALID_ARGUMENT, message, {
    entity = entity and entity._kind,
    entity_id = entity and entity.id,
    action = action,
    from = from,
    to = to,
  }, false)
  if bus then
    -- bus.emit is a plain closure (events.new), not a colon method: call without
    -- an explicit self.
    local name = bus.events and bus.events.session_transition_rejected or M.EVENTS.transition_rejected
    pcall(bus.emit, name, {
      session_id = (entity and entity._kind == "session" and entity.id) or nil,
      entity = entity and entity._kind,
      entity_id = entity and entity.id,
      action = action,
      from = from,
      to = to,
      error = { code = err.code, message = err.message },
    })
  end
  return nil, nil, err
end

--- Build a transition record for a performed transition.
---@param rule table transition rule
---@param entity table entity record
---@param action string
---@param from string
---@param to string
---@param ctx table transition context
---@param at integer ms timestamp
---@return table
local function record_for(rule, entity, action, from, to, ctx, at)
  local event = ctx.event or rule.event
  if rule.terminal then
    event = event or TERMINAL_EVENTS[entity._kind] and TERMINAL_EVENTS[entity._kind][to]
  end
  return {
    entity = entity._kind,
    entity_id = entity.id,
    action = action,
    from = from,
    to = to,
    owner = rule.owner,
    event = event,
    reason = ctx.reason or rule.reason or "state machine",
    at = at,
    idempotent = rule.idempotent,
  }
end

--- Reducer: apply a legal transition to an entity. See module header for the
--- return contract and effect order (validate -> mutate -> record -> emit ->
--- schedule; W1 records in-memory, emits only rejection diagnostics, schedules
--- nothing).
---@param entity table entity record (session/request/tool_batch/view)
---@param action string transition action (see M.TRANSITIONS)
---@param ctx? table {
---   session?: table,        session record (required for request/tool_batch/view)
---   to?:      string,       terminal state for terminal rules
---   reason?:  string,       transition reason (recorded)
---   event?:   string|nil,   event-name override (recorded)
--- }
---@return boolean|nil ok true when processed (changed may be false); nil on rejection
---@return table|nil result { changed = boolean, record = table|nil }
---@return table|nil err typed error on rejection
function M.transition(entity, action, ctx)
  ctx = ctx or {}
  local kind = type(entity) == "table" and entity._kind
  local rules = kind and M.TRANSITIONS[kind]
  local rule = rules and rules[action]
  local from = entity and entity.state
  local bus = (entity and entity._kind == "session" and entity.events) or (ctx.session and ctx.session.events)

  if not kind or not rule then
    return reject(
      bus,
      entity,
      action,
      from,
      nil,
      ("unknown transition: entity=%s action=%q"):format(tostring(kind or "?"), tostring(action))
    )
  end

  local to = rule.to
  if rule.terminal then
    to = ctx.to
    if not to or not rule.states[to] then
      return reject(
        bus,
        entity,
        action,
        from,
        to,
        ("illegal terminal state %q for %s %s"):format(tostring(ctx.to), kind, tostring(entity.id))
      )
    end
  end

  -- Terminal-CAS no-op: an already-terminal entity (state completed/failed/
  -- cancelled is never in the terminal from-set) is checked BEFORE the
  -- legal-from-state check so a repeat terminal call is a no-op, not a
  -- rejection (terminal-race safety).
  if rule.terminal and entity.terminal then
    return true, { changed = false }
  end

  -- Idempotent repeat of a fixed-target transition: no-op (terminal-CAS safety).
  if rule.idempotent and not rule.terminal and from == to then
    return true, { changed = false }
  end

  -- Legal-from-state check (never mutates partially on failure).
  if not (rule.from[from] or rule.from.any) then
    return reject(
      bus,
      entity,
      action,
      from,
      to,
      ("illegal transition: %s %s %s -> %s via %q"):format(
        kind,
        tostring(entity.id),
        tostring(from),
        tostring(to),
        action
      )
    )
  end

  local at = stamp(record_owner(entity, ctx))

  -- Request terminal: one compare-and-set; superseded calls are marked but never
  -- mutate the current session.
  if kind == "request" and rule.terminal then
    if entity.terminal then
      return true, { changed = false }
    end
    local session = ctx.session
    if not session then
      return reject(bus, entity, action, from, to, "request terminal transition requires ctx.session")
    end
    if entity.id ~= session.active_request_id then
      entity.terminal = { state = to, at = at, superseded = true, reason = ctx.reason or "superseded request" }
      return true, { changed = false }
    end
    if session.state ~= M.states.busy then
      -- Defensive parity with phase-0 finish_request: no mutation, silent no-op.
      return true, { changed = false }
    end
    entity.state = to
    entity.terminal = { state = to, at = at, reason = ctx.reason or rule.reason }
    local record = record_for(rule, entity, action, from, to, ctx, at)
    append_record(session, record)
    -- Session effect: one request terminal returns the session to waiting_for_user.
    session.active_request_id = nil
    local sok = M.transition(session, "wait_for_user", {
      session = session,
      reason = ("request %s reached terminal %s"):format(entity.id, to),
    })
    if not sok then
      -- Unreachable (busy is in the wait_for_user from-set); keep the session
      -- consistent anyway instead of leaving a busy session without a request.
      session.state = M.states.waiting_for_user
    end
    return true, { changed = true, record = record }
  end

  -- ToolBatch terminal: same CAS semantics, scoped to the active batch.
  if kind == "tool_batch" and rule.terminal then
    if entity.terminal then
      return true, { changed = false }
    end
    local session = ctx.session
    if not session then
      return reject(bus, entity, action, from, to, "tool_batch terminal transition requires ctx.session")
    end
    if entity.id ~= session.active_tool_batch_id then
      entity.terminal = { state = to, at = at, superseded = true, reason = ctx.reason or "superseded tool batch" }
      return true, { changed = false }
    end
    entity.state = to
    entity.terminal = { state = to, at = at, reason = ctx.reason or rule.reason }
    session.active_tool_batch_id = nil
    local record = record_for(rule, entity, action, from, to, ctx, at)
    append_record(session, record)
    return true, { changed = true, record = record }
  end

  -- Generic path (session + view + non-terminal request/tool_batch moves).
  local owner = record_owner(entity, ctx)
  if not owner then
    return reject(bus, entity, action, from, to, ("%s transition requires ctx.session"):format(kind))
  end
  entity.state = to
  local record = record_for(rule, entity, action, from, to, ctx, at)
  append_record(owner, record)
  if rule.effect then
    rule.effect(entity, ctx, rule)
  end
  return true, { changed = true, record = record }
end

------------------------------------------------------------
-- Session
------------------------------------------------------------

--- Create a session. Emits `session.created` (phase-0 verbatim) and performs the
--- `created -> ready` transition (record-only; no bus event, keeps the W8 bus
--- contract additive).
---@param opts? table {
---   session_id?: string stable id (default: generated unique); stable for lifetime,
---   project_id?: string, defaults to "local",
---   events?:     table event bus (defaults to the global events module),
---   emit?:       boolean, emit `session.created` (default true),
---   clock?:      table|nil { now_ms = fun(): integer } deterministic clock (W2 seam),
--- }
---@return table session
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    id = opts.session_id or make_id("session"),
    project_id = opts.project_id or "local",
    generation = 0, -- incremented each time a request supersedes the previous active one
    state = M.states.created,
    active_request_id = nil,
    active_tool_batch_id = nil,
    -- AgentLoop minimal state (W5; request-orchestrator §Continuation decision):
    --   enabled         boolean, loop permits automatic continuations (default true,
    --                   keeps the W4 pass-through behaviour)
    --   state           M.loop_states: armed (continuation allowed) |
    --                   waiting_for_user (parked; next manual submit re-arms)
    --   iteration       automatic continuation counter
    --   decision_key    durable key of the most recent loop decision
    --   decisions       decision_key -> decision record (durable-key dedup:
    --                   the same key is decided exactly once)
    loop = {
      enabled = true,
      state = M.loop_states.armed,
      iteration = 0,
      decision_key = nil,
      decisions = {},
    },
    views = {}, -- View entity records (attached/hidden/detached/closed)
    requests = {}, -- Request entity records (audit/recovery)
    tool_batches = {}, -- ToolBatch entity records (audit/recovery)
    transitions = {}, -- transition history (capped at M.HISTORY_CAP)
    intents = {}, -- submit-intent records (W3: idempotent replay + audit)
    _intent_by_id = {}, -- intent_id -> intent record (W3)
    created_at = os.time(), -- diagnostic only
    _closed_at = nil,
    _clock = opts.clock, -- optional deterministic clock (W2)
    events = opts.events or events,
    _kind = "session",
  }, Session)
  local bus = self.events
  local payload = {
    session_id = self.id,
    project_id = self.project_id,
    generation = self.generation,
    state = self.state,
  }
  if opts.emit ~= false then
    bus.emit(bus.events and bus.events.session_created or "session.created", payload)
  end
  -- created -> ready: initialization succeeded. Recorded; no bus event in W1.
  M.transition(self, "ready", { session = self, reason = "session initialized" })
  return self
end

--- Bind to a custom event bus (for isolated tests / session-scoped buses).
---@param bus table event bus exposing on/emit
function Session:set_events(bus)
  self.events = bus
end

---@return boolean true when the session can accept a new request
---(ready = old idle compat; waiting_for_user also accepts a submit).
function Session:is_idle()
  return self.state == M.states.ready or self.state == M.states.waiting_for_user
end

---@return boolean true when the session has an active request.
function Session:is_busy()
  return self.state == M.states.busy
end

---@return boolean true when the session is closed.
function Session:is_closed()
  return self.state == M.states.closed
end

--- Convenience wrapper over the module reducer for the session entity itself.
---@param action string transition action (see M.TRANSITIONS.session)
---@param ctx? table { to?, reason?, event?, session? }
---@return boolean|nil ok
---@return table|nil result
---@return table|nil err
function Session:transition(action, ctx)
  ctx = ctx or {}
  ctx.session = ctx.session or self
  return M.transition(self, action, ctx)
end

--- Start a new request. Rejected with a typed error when a request is already in
--- progress, the session is stopped/completed/failed, or the session is closed
--- (no second request identity). The session moves ready|waiting_for_user -> busy
--- through the reducer (accept_submit).
---@param opts? table { request_id?: string, turn_id?: string, intent?: "manual"|"automatic"|"regenerate"|"restore"|"retry" }
---@return table|nil request record
---@return nil|table err typed error (§4.6) on rejection
function Session:start_request(opts)
  opts = opts or {}
  if opts.intent ~= nil and not M.intent_kinds[opts.intent] then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("illegal request intent %q (must be one of %s)"):format(
          tostring(opts.intent),
          table.concat(vim.tbl_keys(M.intent_kinds), "|")
        ),
        nil,
        false
      )
  end
  if self.state == M.states.closed then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s is closed; cannot start a request"):format(self.id),
        nil,
        true
      )
  end
  if self.state == M.states.stopped then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s is stopped; cannot start a request"):format(self.id),
        nil,
        true
      )
  end
  if self.state ~= M.states.ready and self.state ~= M.states.waiting_for_user then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s already has an active request; duplicate submit rejected (phase 0 policy)"):format(self.id),
        { active_request_id = self.active_request_id },
        false
      )
  end

  local request = setmetatable({
    id = opts.request_id or make_id("req"),
    session_id = self.id,
    turn_id = opts.turn_id or opts.request_id or make_id("turn"),
    generation = self.generation + 1,
    intent = opts.intent or "manual",
    retry_of = opts.retry_of, -- W3: linked failed request (retry intent)
    state = M.request_states.submitted,
    started_at = os.time(),
    terminal = nil,
    _kind = "request",
  }, Request)

  -- Session effect: ready|waiting_for_user -> busy (validated above; rejection is
  -- unreachable here, the transition path still owns the record).
  local ok, _, terr = M.transition(self, "accept_submit", {
    session = self,
    reason = ("start_request(%s)"):format(request.id),
  })
  if not ok then
    return nil, terr
  end

  -- Advance session authority: generation increments, session went busy.
  self.generation = request.generation
  self.active_request_id = request.id
  self.requests[#self.requests + 1] = request
  return request, nil
end

--- Transition a request to a terminal state. Idempotent per request id: the first
--- legal terminal transition wins; later calls (including stale callbacks for a
--- superseded request) are no-ops (the stale record is marked superseded).
---@param request table request record from start_request
---@param terminal_state "completed"|"failed"|"cancelled"
---@return boolean changed true when this call performed the terminal transition
---@return nil|table err typed error on illegal terminal state
function Session:finish_request(request, terminal_state)
  assert(request and request.id, "session.finish_request: request record required")
  if not M.TERMINAL_STATES[terminal_state] then
    return false,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("illegal terminal state %q for request %s"):format(tostring(terminal_state), request.id),
        nil,
        false
      )
  end
  local ok, result, err = M.transition(request, "terminal", {
    session = self,
    to = terminal_state,
    reason = ("finish_request(%s)"):format(terminal_state),
  })
  if not ok then
    return false, err
  end
  if not result or not result.changed then
    return false, nil
  end
  return true, nil
end

--- Create a submit-intent record (request-orchestrator §Submit intent and
--- idempotency). Identity fields are immutable; the orchestrator records the
--- decision later through set_intent_decision. Duplicate intent_id is rejected.
---@param opts? table {
---   intent_id?:           string, immutable id (default: generated),
---   turn_id?:             string, provider-neutral turn identity,
---   kind?:                "manual"|"automatic"|"regenerate"|"restore"|"retry",
---   expected_generation?: integer, session generation the intent expects,
---   input_revision?:      string|integer, captured input revision,
---   context_revision?:    string|integer, captured context revision,
---   config_snapshot_id?:  string|nil, configuration snapshot id,
--- }
---@return table|nil intent
---@return nil|table err typed error on invalid kind / duplicate id
function Session:new_intent(opts)
  opts = opts or {}
  local kind = opts.kind or "manual"
  if not M.intent_kinds[kind] then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("illegal submit intent kind %q (must be one of %s)"):format(
          tostring(kind),
          table.concat(vim.tbl_keys(M.intent_kinds), "|")
        ),
        nil,
        false
      )
  end
  local id = opts.intent_id or make_id("intent")
  if self._intent_by_id[id] then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("intent %s already recorded in session %s"):format(id, self.id),
        nil,
        false
      )
  end
  local intent = {
    id = id,
    session_id = self.id,
    turn_id = opts.turn_id or id,
    kind = kind,
    expected_generation = opts.expected_generation or self.generation,
    input_revision = opts.input_revision or 0,
    context_revision = opts.context_revision or 0,
    config_snapshot_id = opts.config_snapshot_id or nil,
    state = "pending",
    decision = nil,
    created_at = os.time(),
    _kind = "intent",
  }
  self.intents[#self.intents + 1] = intent
  self._intent_by_id[id] = intent
  return intent, nil
end

--- Look up a recorded intent by its immutable id (idempotent replay source).
---@param intent_id string
---@return table|nil intent
function Session:find_intent(intent_id)
  if type(intent_id) ~= "string" then
    return nil
  end
  return self._intent_by_id[intent_id]
end

--- Look up a request record by id (audit/retry linkage).
---@param request_id string
---@return table|nil request
function Session:find_request(request_id)
  return find_by_id(self.requests, request_id)
end

--- Record the decision for a submit intent (last write wins; a rejection is
--- terminal — no later terminal callback exists for a rejected intent).
---@param intent table intent record from new_intent
---@param decision table { state="in_flight"|"rejected"|"completed"|"failed"|"cancelled", ... }
---@return boolean ok
---@return nil|table err typed error when the intent does not belong to this session
function Session:set_intent_decision(intent, decision)
  if not intent or intent._kind ~= "intent" or intent.session_id ~= self.id then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        "session.set_intent_decision: intent does not belong to this session",
        nil,
        false
      )
  end
  intent.decision = decision
  intent.state = (decision and decision.state) or "completed"
  return true, nil
end

--- Look up a recorded AgentLoop continuation decision by its durable key
--- (request-orchestrator §Continuation decision table: a durable key
--- `(session_generation, source_request_id, tool_batch_id|none, decision_kind)`
--- prevents duplicate decisions after callback races or recovery).
---@param key string durable continuation key
---@return table|nil decision record
function Session:find_loop_decision(key)
  if type(key) ~= "string" then
    return nil
  end
  return self.loop.decisions[key]
end

--- Record an AgentLoop continuation decision under its durable key. The first
--- record for a key wins; a second decision for the same key is rejected
--- (returns the existing record, no mutation) — the core terminal-race and
--- restore dedup guarantee.
---@param key string durable continuation key
---@param record table decision record { key, kind, session_generation,
---   source_request_id, tool_batch_id|nil, at, request_id|nil, intent_id|nil }
---@return boolean|nil ok
---@return table result { changed=boolean, record=table } changed=false when the
---   key was already decided (existing record returned)
---@return nil|table err typed error on malformed key/record
function Session:record_loop_decision(key, record)
  if type(key) ~= "string" or key == "" then
    return nil,
      nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        "session.record_loop_decision: durable continuation key must be a non-empty string",
        nil,
        false
      )
  end
  if type(record) ~= "table" then
    return nil,
      nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        "session.record_loop_decision: decision record must be a table",
        nil,
        false
      )
  end
  local existing = self.loop.decisions[key]
  if existing then
    return true, { changed = false, record = existing }, nil
  end
  self.loop.decisions[key] = record
  return true, { changed = true, record = record }, nil
end

--- Copy a loop record for snapshotting/restoring. Decisions are nested records:
--- they are copied per-entry so the snapshot/restored loop never shares
--- decision identity with the source session (durable-key dedup must survive a
--- restore round-trip without aliasing the source session's records).
---@param loop table session.loop
---@return table copy
local function copy_loop(loop)
  local out = {}
  for k, v in pairs(loop or {}) do
    if k == "decisions" and type(v) == "table" then
      local decisions = {}
      for dk, dv in pairs(v) do
        local record = {}
        for rk, rv in pairs(dv) do
          record[rk] = rv
        end
        decisions[dk] = record
      end
      out.decisions = decisions
    else
      out[k] = v
    end
  end
  return out
end
--- Restore session/loop state from an in-memory snapshot (restore-agent-loop
--- prerequisite). The snapshot aligns with Session:snapshot(); only an idle
--- boundary (ready|waiting_for_user) is restorable — busy/stopped/closed
--- sessions reject the restore. Request/tool-batch/intent audit lists are NOT
--- replaced (append-only; a full audit restore is a later wave).
---@param snapshot table session snapshot (Session:snapshot() output)
---@return boolean ok
---@return nil|table err typed error on non-idle state / malformed snapshot
function Session:restore(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.id) ~= "string" or type(snapshot.state) ~= "string" then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        "session.restore: snapshot must carry id and state (Session:snapshot() output)",
        nil,
        false
      )
  end
  local state = snapshot.state
  if state ~= M.states.ready and state ~= M.states.waiting_for_user then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session.restore: cannot restore a %s session; restore-agent-loop requires an idle boundary (ready|waiting_for_user)"):format(
          state
        ),
        { state = state },
        false
      )
  end
  self.id = snapshot.id
  self.project_id = snapshot.project_id or self.project_id
  self.generation = snapshot.generation or self.generation
  self.state = state
  self.active_request_id = snapshot.active_request_id or nil
  self.active_tool_batch_id = snapshot.active_tool_batch_id or nil
  -- Full loop copy (incl. per-entry decisions) so restored loop/decisions match
  -- the snapshot exactly and never alias the source session (W5 durable-key dedup).
  self.loop = copy_loop(snapshot.loop)
  self.views = {}
  if type(snapshot.views) == "table" then
    for _, v in ipairs(snapshot.views) do
      self.views[#self.views + 1] = v
    end
  end
  return true, nil
end

--- Stop the session: current work becomes terminal (active request/batch marked
--- cancelled) and continuation is suppressed. Idempotent; closed sessions are
--- unaffected (use close()).
---@param reason? string diagnostic reason (default "explicit stop")
---@return boolean changed
function Session:stop(reason)
  if self.state == M.states.closed or self.state == M.states.stopped then
    return false
  end
  local ok, result = M.transition(self, "stop", {
    session = self,
    reason = reason or "explicit stop",
  })
  return ok and result and result.changed or false
end

--- Close the session: no further requests accepted; active request/batch marked
--- cancelled. Idempotent.
---@return boolean changed
function Session:close()
  if self.state == M.states.closed then
    return false
  end
  local ok, result = M.transition(self, "close", {
    session = self,
    reason = "explicit session close",
  })
  if ok and result and result.changed then
    self._closed_at = os.time()
    return true
  end
  return false
end

--- Create a ToolBatch entity bound to the current active request. Rejected with a
--- typed error when no request is active (batches belong to a request).
---@param opts? table {
---   batch_id?: string stable id (default: generated),
---   calls?:    table[] initial call records (W4 fills from tool_calls),
--- }
---@return table|nil batch
---@return nil|table err typed error on rejection
function Session:new_tool_batch(opts)
  opts = opts or {}
  if not self.active_request_id then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s has no active request; cannot create a tool batch"):format(self.id),
        nil,
        false
      )
  end
  local request_id = self.active_request_id
  local ordinal = 1
  for _, b in ipairs(self.tool_batches) do
    if b.request_id == request_id and b.ordinal >= ordinal then
      ordinal = b.ordinal + 1
    end
  end
  local batch = setmetatable({
    id = opts.batch_id or make_id("batch"),
    request_id = request_id,
    state = M.tool_batch_states.pending,
    calls = opts.calls or {},
    ordinal = ordinal,
    created_at = os.time(),
    terminal = nil,
    _kind = "tool_batch",
  }, ToolBatch)
  self.active_tool_batch_id = batch.id
  self.tool_batches[#self.tool_batches + 1] = batch
  return batch, nil
end

--- Create a View entity bound to this session. Views are NOT the session identity:
--- a detached/closed view never closes the session by itself.
---@param opts? table {
---   view_id?: string stable id (default: generated),
---   bufnr?:   integer|nil buffer number,
---   state?:   string one of M.view_states (default "attached"),
--- }
---@return table|nil view
---@return nil|table err typed error on invalid state
function Session:new_view(opts)
  opts = opts or {}
  local state = opts.state or M.view_states.attached
  if not M.view_states[state] then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("illegal view state %q (must be one of %s)"):format(
          tostring(opts.state),
          table.concat(vim.tbl_keys(M.view_states), "|")
        ),
        nil,
        false
      )
  end
  local view = setmetatable({
    id = opts.view_id or make_id("view"),
    session_id = self.id,
    generation = self.generation,
    bufnr = opts.bufnr or nil,
    state = state,
    created_at = os.time(),
    _kind = "view",
  }, View)
  self.views[#self.views + 1] = view
  return view, nil
end

--- Detach a view entity (attached|hidden -> detached; W8 async-lifecycle
--- §Cancellation and cleanup: "Buffer deletion detaches the view and preserves
--- the session unless close was requested"). Idempotent: an already
--- detached/closed view is a no-op. The session and any in-flight request
--- continue unaffected; only the view attachment is released.
---@param view table view entity from new_view (must belong to this session)
---@param reason? string diagnostic reason (default "buffer/window deleted")
---@return boolean changed true when this call performed the detach
function Session:detach_view(view, reason)
  if not view or view._kind ~= "view" or view.session_id ~= self.id then
    return false
  end
  -- A closed view is terminal: repeated detach is a silent no-op (idempotent
  -- cleanup, not an illegal transition).
  if view.state == M.view_states.closed then
    return false
  end
  local ok, result = M.transition(view, "detach", {
    session = self,
    reason = reason or "buffer/window deleted",
  })
  return ok and result and result.changed or false
end

--- Close a view entity (attached|hidden|detached -> closed; W8). Idempotent:
--- an already-closed view is a no-op. Closing a view never closes the session.
---@param view table view entity from new_view (must belong to this session)
---@param reason? string diagnostic reason (default "explicit view close")
---@return boolean changed true when this call performed the close
function Session:close_view(view, reason)
  if not view or view._kind ~= "view" or view.session_id ~= self.id then
    return false
  end
  if view.state == M.view_states.closed then
    return false -- already closed: silent no-op (idempotent cleanup)
  end
  local ok, result = M.transition(view, "close", {
    session = self,
    reason = reason or "explicit view close",
  })
  return ok and result and result.changed or false
end

--- Immutable snapshot of the session for consumers (host view / spine / tests).
--- Phase-0 fields kept verbatim; W1 adds active_tool_batch_id/loop/views.
---@return table snapshot
function Session:snapshot()
  local loop = copy_loop(self.loop)
  local views = {}
  for i, v in ipairs(self.views) do
    views[i] = v
  end
  return {
    id = self.id,
    project_id = self.project_id,
    generation = self.generation,
    state = self.state,
    active_request_id = self.active_request_id,
    active_tool_batch_id = self.active_tool_batch_id,
    loop = loop,
    views = views,
  }
end

--- Copy of the session transition history (diagnostics/tests).
---@return table[] transition records
function Session:transition_history()
  local out = {}
  for i = 1, #self.transitions do
    out[i] = self.transitions[i]
  end
  return out
end

M.Session = Session
M.Request = Request
M.ToolBatch = ToolBatch
M.View = View

--- Convenience constructor compatible with `M.new`.
M.create = M.new

return M
