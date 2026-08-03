-- filepath: lua/maxa/runtime/session/init.lua
--- maxa runtime session module: minimal session + request state machine (phase 0).
---
--- Scope (see .supermax/drafts/phase0-development-plan.md §5.6): this phase ships a
--- minimal Session entity plus a request lifecycle (`submit -> stream -> terminal`)
--- as pure state machine logic. It does NOT drive providers itself; that is the
--- orchestrator's job (lua/maxa/runtime/orchestrator). It never loads
--- codecompanion.* / mcphub.* / lua/util/hooks/*.
---
--- Alignment (read-only): upstream `interactions/chat/init.lua` `Chat:new` fields
--- and `current_request` guard, and `.supermax/specs/chat-runtime-state/spec.md`
--- entity schemas. Entity identities are immutable; generation increments when an
--- identity's async authority is superseded; terminal transitions are idempotent.
---
--- State model (simplified phase-0 subset of chat-runtime-state):
---   session.state:        "idle" | "busy" | "closed"
---     idle                no active request, ready to accept a submit
---     busy                exactly one active request (submitted/streaming)
---     closed              explicit session close; no further requests accepted
---   request.state:        "submitted" | "streaming" | "completed" | "failed" | "cancelled"
---
--- Invariants enforced here:
---   - A second start_request while busy is rejected (no second request identity);
---     caller receives a typed INVALID_ARGUMENT error.
---   - finish_request is idempotent per request id and only accepts legal terminal
---     states (completed|failed|cancelled); the first terminal transition wins and
---     later calls are ignored (terminal-race safety).
---   - A terminal call for an already-superseded request (stale callback) is a no-op
---     and must not mutate the current session generation.
---
--- Events (emit through the global events bus, injected for test isolation):
---   "session.created"  on session construction (.supermax plan §4.7)

local schema = require("maxa.runtime.schema")
local events = require("maxa.runtime.events")

local M = {}

M.name = "session"

--- Session-level states (phase-0 subset).
M.states = {
  idle = "idle",
  busy = "busy",
  closed = "closed",
}

--- Request-level states.
M.request_states = {
  submitted = "submitted",
  streaming = "streaming",
  completed = "completed",
  failed = "failed",
  cancelled = "cancelled",
}

--- Legal terminal request states (first one wins; finish is idempotent).
M.TERMINAL_STATES = {
  [M.request_states.completed] = true,
  [M.request_states.failed] = true,
  [M.request_states.cancelled] = true,
}

------------------------------------------------------------
-- Identity helpers
------------------------------------------------------------
-- Request/session identity generators are trivial stable-string allocators; they
-- are intentionally NOT content-derived (session id is per-Chat lifetime stable,
-- request id is per-submit — plan §4.4).
local id_counter = 0
local function make_id(prefix)
  id_counter = id_counter + 1
  return ("%s-%d-%d"):format(prefix, os.time(), id_counter)
end

------------------------------------------------------------
-- Session
------------------------------------------------------------
local Session = {}
Session.__index = Session

--- Create a minimal session. Emits `session.created` with identity payload.
---@param opts? table {
---   session_id?: string stable id (default: generated unique); stable for lifetime,
---   project_id?: string, defaults to "local",
---   events?:     table event bus (defaults to the global events module),
---   emit?:       boolean, emit `session.created` (default true),
--- }
---@return table session
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    id = opts.session_id or make_id("session"),
    project_id = opts.project_id or "local",
    generation = 0, -- incremented each time a request supersedes the previous active one
    state = M.states.idle,
    active_request_id = nil,
    created_at = os.time(), -- diagnostic only
    events = opts.events or events,
    -- owned resources (phase-0: nothing beyond a cancel handle, held by orchestrator)
    _closed_at = nil,
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
  return self
end

--- Bind to a custom event bus (for isolated tests / session-scoped buses).
---@param bus table event bus exposing on/emit
function Session:set_events(bus)
  self.events = bus
end

---@return boolean true when the session can accept a new request.
function Session:is_idle()
  return self.state == M.states.idle
end

---@return boolean true when the session has an active request.
function Session:is_busy()
  return self.state == M.states.busy
end

---@return boolean true when the session is closed.
function Session:is_closed()
  return self.state == M.states.closed
end

--- Start a new request. Rejected with a typed error when a request is already in
--- progress or the session is closed (no second request identity).
---@param opts? table { request_id?: string, intent?: "manual"|"automatic"|"regenerate"|"restore"|"retry" }
---@return table|nil request record
---@return nil|table err typed error (§4.6) on rejection
function Session:start_request(opts)
  opts = opts or {}
  if self.state == M.states.closed then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s is closed; cannot start a request"):format(self.id),
        nil,
        true
      )
  end
  if self.state ~= M.states.idle then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s already has an active request; duplicate submit rejected (phase 0 policy)"):format(self.id),
        { active_request_id = self.active_request_id },
        false
      )
  end

  local request = {
    id = opts.request_id or make_id("req"),
    session_id = self.id,
    generation = self.generation + 1,
    intent = opts.intent or "manual",
    state = M.request_states.submitted,
    started_at = os.time(),
    terminal = nil,
  }
  -- Advance session authority: generation increments, session goes busy.
  self.generation = request.generation
  self.state = M.states.busy
  self.active_request_id = request.id
  return request, nil
end

--- Transition a request to a terminal state. Idempotent per request id: the first
--- legal terminal transition wins; later calls (including stale callbacks for a
--- superseded request) are no-ops.
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

  -- Terminal-race / stale-callback safety: only the CURRENT active request may
  -- transition the session. A terminal call for a superseded (older) request is a
  -- no-op and must never mutate the current generation (§4.4 / chat-runtime-state).
  if request.id ~= self.active_request_id then
    -- Already superseded: mark the record's own terminal flag for diagnostics but
    -- do not transition the session.
    if not request.terminal then
      request.terminal = { state = terminal_state, superseded = true }
    end
    return false, nil
  end

  -- Idempotent terminal: a request already terminal (or the session no longer busy
  -- with it) never transitions again.
  if request.terminal and request.terminal.state ~= nil then
    return false, nil
  end
  if self.state ~= M.states.busy then
    return false, nil
  end

  request.terminal = { state = terminal_state, at = os.time() }
  request.state = terminal_state
  -- Session returns to idle so the next submit can be accepted.
  self.state = M.states.idle
  self.active_request_id = nil
  return true, nil
end

--- Close the session: no further requests accepted. Idempotent.
---@return boolean changed
function Session:close()
  if self.state == M.states.closed then
    return false
  end
  self.state = M.states.closed
  self._closed_at = os.time()
  self.active_request_id = nil
  return true
end

--- Immutable snapshot of the session for consumers (host view / spine / tests).
---@return table snapshot
function Session:snapshot()
  return {
    id = self.id,
    project_id = self.project_id,
    generation = self.generation,
    state = self.state,
    active_request_id = self.active_request_id,
  }
end

M.Session = Session

--- Convenience constructor compatible with `M.new`.
M.create = M.new

return M
