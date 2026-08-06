-- filepath: lua/maxa/runtime/status/spine.lua
--- Immutable spine reducer (phase-5 W2). Pure library: no nvim side effects,
--- no timers, no global state. Headless-testable by calling the functions
--- directly with hand-built envelopes or with a real events bus.
---
--- Contract source: .supermax/specs/runtime-fixture-contract.md
--- §Events, spine, spinner and lualine; events-status spec §Spine and lualine /
--- §Status reduction.
---
--- Snapshot shape (contract fields + internal bookkeeping):
---
---   active_session_id:  string|nil  most-recently active session (event-driven)
---   display_session_id: string|nil  UI display identity (service-set, INDEPENDENT
---                                   of active_session_id; deleting a view does
---                                   not delete session state)
---   running_sessions:   integer     sessions with at least one live request
---   active_requests:    integer     live requests (started, not yet terminal)
---   warmup_tasks:       integer     optional MCP warmup/startup task count
---   provider_id:        string|nil  last provider seen on request.started payload
---   model:              string|nil  last model seen on request.started payload
---   usage:              table|nil   normalized usage (schema.usage shape) from
---                                   usage.updated / terminal payloads
---   context_limit:      integer|nil usage.context_limit (schema.usage field)
---   retry:              {}          { kind, reason, key, count, max, at } from
---                                   continuation.decided / watchdog.retry
---   notification:       {}          { level, message, event_id } last user-facing
---                                   notification (error/cancel/soft-stop)
---   terminal:           {}          { state, reason, at } most recent terminal
---                                   state; cleared by the next request.started
---   revision:           integer     immutable version; +1 on every applied event
---
--- Internal fields (underscore-prefixed, not part of the contract surface):
---
---   _sessions: [sid] = { running=bool, active_requests=integer, phases={...} }
---   _reconcile: { stale=table[], at=integer } last reconcile diagnostic
---
--- Session phase timestamps (inside _sessions[sid].phases):
---
---   request_started_at:  ms of the latest request.started
---   response_started_at: ms of the latest response.started
---   tool_args_at:        ms of the latest tool_call.started/delta/completed
---   tool_exec_at:        ms of the latest tool_batch.started
---   retry_at:            ms of the latest retry (watchdog.retry or
---                        continuation.decided kind=retry); cleared by the next
---                        request.started
---
--- Event lifecycle (count semantics, recorded decision):
---
---   request.started            active_requests+1, session running, clears
---                              terminal/notification/retry_at
---   response.started           phase.response_started_at only
---   usage.updated              usage + context_limit
---   tool_call.started|delta|completed
---                              phase.tool_args_at only
---   tool_batch.started         phase.tool_exec_at only
---   response.completed         WITHOUT tool_calls (text path) => request
---                              terminal: counts -1, terminal recorded;
---                              WITH tool_calls (tool path) => counts stay (the
---                              request is still live inside the ToolBatch;
---                              the terminal is decided by continuation.decided)
---   response.failed/cancelled  request terminal: counts -1, terminal +
---                              notification recorded
---   continuation.decided       kind wait|fail|terminate => request terminal
---                              (counts -1; tool path has no response.*
---                              terminal event); kind retry => retry phase;
---                              continue/repair/compaction => no count change
---   watchdog.retry             retry record + phase.retry_at
---   chat.soft_stop_requested   notification (requested=true) / clear
---                              (requested=false)
---   chat.soft_stop_completed   notification info
---   chat.closed                session teardown: counts zeroed for that session
---   mcp.server_state           warmup_tasks +/- (starting/connecting +1;
---                              running/ready/stopped/error/failed -1 clamped)
---   spine.reconcile            internal: repair stale running sessions against
---                              a live views list (payload { views, at })
---
--- Unknown events return the SAME snapshot reference (revision unchanged).
--- Every applied event returns a NEW table; the input snapshot is never
--- mutated (structural sharing: only the changed paths are re-allocated).

local M = {}

M.name = "status.spine"

--- Internal reconcile event name (service-level; not a bus event).
M.RECONCILE_EVENT = "spine.reconcile"

--- Spinner phase names (deterministic precedence, see spinner_phase()).
M.PHASES = {
  idle = "idle",
  request_start = "request_start",
  response_start = "response_start",
  tool_args = "tool_args",
  tool_exec = "tool_exec",
  retry = "retry",
  terminal = "terminal",
}

--- Default spinner debounce (ms) when no config.ui.spinner_delay is present.
M.DEFAULT_SPINNER_DELAY = 300

--- Shallow-copy a table (nil-safe).
---@param t table|nil
---@return table
local function copy(t)
  local out = {}
  if t then
    for k, v in pairs(t) do
      out[k] = v
    end
  end
  return out
end

---@return table initial immutable snapshot
function M.initial_snapshot()
  return {
    active_session_id = nil,
    display_session_id = nil,
    running_sessions = 0,
    active_requests = 0,
    warmup_tasks = 0,
    provider_id = nil,
    model = nil,
    usage = nil,
    context_limit = nil,
    retry = {},
    notification = {},
    terminal = {},
    revision = 0,
    _sessions = {},
    _reconcile = { stale = {}, at = nil },
  }
end

--- Read the session record (defaults when absent). Read-only accessor: the
--- returned record must never be mutated by callers (reducers re-allocate).
---@param snapshot table
---@param sid string
---@return table session record
local function session(snapshot, sid)
  return snapshot._sessions[sid] or { running = false, active_requests = 0, phases = {} }
end

--- Replace one session record inside a snapshot copy.
---@param snapshot table snapshot to copy (unchanged)
---@param sid string
---@param record table new session record
---@return table new _sessions map
local function with_session(snapshot, sid, record)
  local sessions = copy(snapshot._sessions)
  sessions[sid] = record
  return sessions
end

--- Identity fields shared by most event payloads.
---@param payload table
---@return string|nil sid
local function payload_session(payload)
  local sid = payload.session_id
  return type(sid) == "string" and sid or nil
end

--- Emitted-at timestamp (ms), tolerant of hand-built envelopes.
---@param envelope table
---@return integer
local function emitted_at(envelope)
  local at = envelope.emitted_at
  return type(at) == "number" and at or 0
end

--- Clamp a counter so it never goes negative.
---@param n integer
---@return integer
local function clamp(n)
  return math.max(0, n or 0)
end

--- Terminal closure for a session: decrement per-session and global counters,
--- mark the session not running, record terminal/notification. Returns a new
--- snapshot or the input reference when the session is unknown.
---@param snapshot table
---@param envelope table
---@param state string "completed"|"failed"|"cancelled"|"stopped"
---@param reason string|nil
---@param notify table|nil { level, message }
---@return table
local function close_request(snapshot, envelope, state, reason, notify)
  local payload = envelope.payload or {}
  local sid = payload_session(payload)
  if not sid then
    return snapshot
  end
  local sess = session(snapshot, sid)
  if not sess.running and (sess.active_requests or 0) == 0 then
    -- Nothing live for this session: record the terminal state only.
    local s = copy(snapshot)
    s.terminal = { state = state, reason = reason or nil, at = emitted_at(envelope) }
    if notify then
      s.notification = { level = notify.level, message = notify.message, event_id = envelope.event_id }
    end
    return s
  end
  local nsess = copy(sess)
  local was_running = nsess.running
  nsess.active_requests = clamp((nsess.active_requests or 0) - 1)
  nsess.running = nsess.active_requests > 0
  local s = copy(snapshot)
  s._sessions = with_session(snapshot, sid, nsess)
  s.active_requests = clamp((snapshot.active_requests or 0) - 1)
  if was_running and not nsess.running then
    s.running_sessions = clamp((snapshot.running_sessions or 0) - 1)
  end
  s.terminal = { state = state, reason = reason or nil, at = emitted_at(envelope) }
  if notify then
    s.notification = { level = notify.level, message = notify.message, event_id = envelope.event_id }
  end
  return s
end

--- request.started
---@param snapshot table
---@param envelope table
---@return table
local function on_request_started(snapshot, envelope)
  local payload = envelope.payload or {}
  local sid = payload_session(payload)
  if not sid then
    return snapshot
  end
  local sess = session(snapshot, sid)
  local nsess = copy(sess)
  nsess.phases = copy(sess.phases)
  nsess.phases.request_started_at = emitted_at(envelope)
  nsess.phases.retry_at = nil -- a fresh request ends the retry phase
  local was_running = sess.running
  nsess.running = true
  nsess.active_requests = (sess.active_requests or 0) + 1
  local s = copy(snapshot)
  s._sessions = with_session(snapshot, sid, nsess)
  s.active_requests = (snapshot.active_requests or 0) + 1
  if not was_running then
    s.running_sessions = (snapshot.running_sessions or 0) + 1
  end
  s.active_session_id = sid
  if type(payload.provider) == "string" then
    s.provider_id = payload.provider
  end
  if type(payload.model) == "string" then
    s.model = payload.model
  end
  -- New work starts: the previous terminal/notification state is stale.
  s.terminal = {}
  s.notification = {}
  return s
end

--- Update a phase timestamp for the payload's session (no count change).
---@param snapshot table
---@param envelope table
---@param phase string phase field name
---@return table
local function touch_phase(snapshot, envelope, phase)
  local payload = envelope.payload or {}
  local sid = payload_session(payload)
  if not sid then
    return snapshot
  end
  local sess = session(snapshot, sid)
  local nsess = copy(sess)
  nsess.phases = copy(sess.phases)
  nsess.phases[phase] = emitted_at(envelope)
  local s = copy(snapshot)
  s._sessions = with_session(snapshot, sid, nsess)
  s.active_session_id = sid
  return s
end

--- usage.updated (and terminal payload usage)
---@param snapshot table
---@param envelope table
---@return table
local function on_usage_updated(snapshot, envelope)
  local payload = envelope.payload or {}
  local sid = payload_session(payload)
  if type(payload.usage) ~= "table" and not sid then
    return snapshot
  end
  local s = copy(snapshot)
  if type(payload.usage) == "table" then
    s.usage = payload.usage
    local cl = payload.usage.context_limit
    s.context_limit = type(cl) == "number" and cl or s.context_limit
  end
  if type(payload.context_limit) == "number" then
    s.context_limit = payload.context_limit
  end
  if sid then
    s.active_session_id = sid
  end
  return s
end

--- response.completed: text path (no tool_calls) closes the request; tool path
--- (tool_calls non-empty) keeps the counts live until continuation.decided.
---@param snapshot table
---@param envelope table
---@return table
local function on_response_completed(snapshot, envelope)
  local payload = envelope.payload or {}
  local s = snapshot
  if type(payload.usage) == "table" then
    s = on_usage_updated(s, envelope)
  end
  local calls = payload.tool_calls
  if type(calls) == "table" and #calls > 0 then
    -- Tool path: provider response finished, request still live in the batch.
    if s == snapshot then
      local sid = payload_session(payload)
      if sid then
        s = touch_phase(s, envelope, "response_started_at") -- keep identity fresh
      end
    end
    return s
  end
  return close_request(s, envelope, "completed", payload.finish_reason, nil)
end

--- response.failed / response.cancelled
---@param snapshot table
---@param envelope table
---@param state string
---@return table
local function on_response_terminal(snapshot, envelope, state)
  local payload = envelope.payload or {}
  local err = payload.error
  local reason
  if type(err) == "table" then
    reason = err.message
  elseif state == "cancelled" then
    reason = "cancelled"
  end
  local notify
  if state == "failed" then
    notify = { level = "error", message = reason or "request failed" }
  else
    notify = { level = "info", message = "request cancelled" }
  end
  local s = close_request(snapshot, envelope, state, reason, notify)
  if s ~= snapshot and type(payload.usage) == "table" then
    s = on_usage_updated(s, envelope)
  end
  return s
end

--- continuation.decided: wait|fail|terminate close the (tool-path) request;
--- retry records the retry phase; continue/repair/compaction change nothing.
---@param snapshot table
---@param envelope table
---@return table
local function on_continuation_decided(snapshot, envelope)
  local payload = envelope.payload or {}
  local kind = payload.decision_kind
  if kind == "wait" or kind == "fail" or kind == "terminate" then
    local state = kind == "wait" and "completed" or (kind == "fail" and "failed" or "stopped")
    local notify
    if kind == "fail" then
      notify = { level = "error", message = payload.decision_reason or "request failed" }
    end
    local s = close_request(snapshot, envelope, state, payload.decision_reason, notify)
    return s
  end
  if kind == "retry" then
    local s = touch_phase(snapshot, envelope, "retry_at")
    s.retry = {
      kind = "retry",
      reason = payload.decision_reason or nil,
      key = payload.decision_key or nil,
      at = emitted_at(envelope),
    }
    return s
  end
  -- continue / repair / compaction: no count change, record the decision.
  local s = copy(snapshot)
  s.retry = {
    kind = kind,
    reason = payload.decision_reason or nil,
    key = payload.decision_key or nil,
    at = emitted_at(envelope),
  }
  local sid = payload_session(payload)
  if sid then
    s.active_session_id = sid
  end
  return s
end

--- watchdog.retry
---@param snapshot table
---@param envelope table
---@return table
local function on_watchdog_retry(snapshot, envelope)
  local payload = envelope.payload or {}
  local s = touch_phase(snapshot, envelope, "retry_at")
  s.retry = {
    kind = "retry",
    reason = payload.reason or nil,
    count = payload.retry_count or nil,
    max = payload.max_retries or nil,
    at = emitted_at(envelope),
  }
  return s
end

--- chat.soft_stop_requested
---@param snapshot table
---@param envelope table
---@return table
local function on_soft_stop_requested(snapshot, envelope)
  local payload = envelope.payload or {}
  local s = copy(snapshot)
  if payload.requested == false then
    s.notification = {}
  else
    s.notification = {
      level = "info",
      message = "soft stop requested",
      event_id = envelope.event_id,
    }
  end
  return s
end

--- chat.soft_stop_completed
---@param snapshot table
---@param envelope table
---@return table
local function on_soft_stop_completed(snapshot, envelope)
  local payload = envelope.payload or {}
  local s = copy(snapshot)
  s.notification = {
    level = "info",
    message = ("soft stop completed (%s)"):format(payload.reason or "soft_stop"),
    event_id = envelope.event_id,
  }
  return s
end

--- chat.closed: zero the session's counters (teardown). Active identity is
--- cleared only when it pointed at the closed session; display identity and
--- session state survive (deleting a view does not delete session state).
---@param snapshot table
---@param envelope table
---@return table
local function on_chat_closed(snapshot, envelope)
  local payload = envelope.payload or {}
  local sid = payload_session(payload)
  if not sid then
    return snapshot
  end
  local sess = session(snapshot, sid)
  local live = (sess.active_requests or 0)
  local was_running = sess.running
  if live == 0 and not was_running then
    local s = copy(snapshot)
    if s.active_session_id == sid then
      s.active_session_id = nil
    end
    return s
  end
  local nsess = { running = false, active_requests = 0, phases = copy(sess.phases) }
  local s = copy(snapshot)
  s._sessions = with_session(snapshot, sid, nsess)
  s.active_requests = clamp((snapshot.active_requests or 0) - live)
  if was_running then
    s.running_sessions = clamp((snapshot.running_sessions or 0) - 1)
  end
  if s.active_session_id == sid then
    s.active_session_id = nil
  end
  return s
end

--- mcp.server_state: optional warmup projection. starting/connecting count as
--- warmup tasks; running/ready/stopped/error/failed decrement (clamped).
---@param snapshot table
---@param envelope table
---@return table
local function on_mcp_server_state(snapshot, envelope)
  local payload = envelope.payload or {}
  local state = payload.state
  if type(state) ~= "string" then
    return snapshot
  end
  local s = copy(snapshot)
  if state == "starting" or state == "connecting" then
    s.warmup_tasks = (snapshot.warmup_tasks or 0) + 1
  elseif state == "running" or state == "ready" or state == "stopped" or state == "error" or state == "failed" then
    s.warmup_tasks = clamp((snapshot.warmup_tasks or 0) - 1)
  end
  return s
end

--- spine.reconcile: repair stale running sessions against a live views list.
--- payload: { views = { { session_id, busy } }, at = ms }.
--- A session is stale when it is running but no live view reports it busy;
--- stale sessions are closed (counts zeroed) and recorded in _reconcile.
---@param snapshot table
---@param envelope table
---@return table
local function on_reconcile(snapshot, envelope)
  local payload = envelope.payload or {}
  local views = payload.views
  if type(views) ~= "table" then
    return snapshot
  end
  local busy = {}
  for _, v in ipairs(views) do
    if type(v) == "table" and type(v.session_id) == "string" then
      busy[v.session_id] = v.busy == true
    end
  end
  local stale = {}
  local sessions = snapshot._sessions or {}
  local nsessions = copy(sessions)
  local active = snapshot.active_requests or 0
  local running = snapshot.running_sessions or 0
  local changed = false
  for sid, sess in pairs(sessions) do
    if sess.running and not busy[sid] then
      stale[#stale + 1] = { session_id = sid, active_requests = sess.active_requests }
      nsessions[sid] = { running = false, active_requests = 0, phases = copy(sess.phases) }
      active = clamp(active - (sess.active_requests or 0))
      running = clamp(running - 1)
      changed = true
    end
  end
  if not changed then
    return snapshot
  end
  local s = copy(snapshot)
  s._sessions = nsessions
  s.active_requests = active
  s.running_sessions = running
  s._reconcile = { stale = stale, at = payload.at or emitted_at(envelope) }
  return s
end

--- Event dispatch table (string match; unknown events return the input ref).
local HANDLERS = {
  ["request.started"] = on_request_started,
  ["response.started"] = function(snapshot, envelope)
    return touch_phase(snapshot, envelope, "response_started_at")
  end,
  ["usage.updated"] = on_usage_updated,
  ["tool_call.started"] = function(snapshot, envelope)
    return touch_phase(snapshot, envelope, "tool_args_at")
  end,
  ["tool_call.delta"] = function(snapshot, envelope)
    return touch_phase(snapshot, envelope, "tool_args_at")
  end,
  ["tool_call.completed"] = function(snapshot, envelope)
    return touch_phase(snapshot, envelope, "tool_args_at")
  end,
  ["tool_batch.started"] = function(snapshot, envelope)
    return touch_phase(snapshot, envelope, "tool_exec_at")
  end,
  ["tool_batch.draining"] = nil, -- no count/phase change (kept for parity)
  ["tool_batch.finished"] = nil, -- request terminal is decided elsewhere
  ["tool_call.finished"] = nil,
  ["response.completed"] = on_response_completed,
  ["response.failed"] = function(snapshot, envelope)
    return on_response_terminal(snapshot, envelope, "failed")
  end,
  ["response.cancelled"] = function(snapshot, envelope)
    return on_response_terminal(snapshot, envelope, "cancelled")
  end,
  ["continuation.decided"] = on_continuation_decided,
  ["watchdog.retry"] = on_watchdog_retry,
  ["chat.soft_stop_requested"] = on_soft_stop_requested,
  ["chat.soft_stop_completed"] = on_soft_stop_completed,
  ["chat.closed"] = on_chat_closed,
  ["mcp.server_state"] = on_mcp_server_state,
  [M.RECONCILE_EVENT] = on_reconcile,
}

--- Pure reducer: apply one event envelope to a snapshot and return a NEW
--- snapshot (the input is never mutated). Unknown events return the same
--- reference (revision unchanged). Applied events bump `revision` by 1.
---
--- Envelope compatibility: `envelope.event` (bus shape) or a bare event-name
--- string. Payload defaults to {}; emitted_at defaults to 0.
---@param snapshot table immutable snapshot (see initial_snapshot())
---@param envelope table|string event envelope { event, payload, emitted_at, ... }
---@return table new snapshot (same reference when the event is unknown)
function M.reducer(snapshot, envelope)
  local event
  if type(envelope) == "string" then
    event = envelope
    envelope = { event = envelope, payload = {} }
  else
    event = envelope and envelope.event
  end
  if type(event) ~= "string" then
    return snapshot
  end
  local handler = HANDLERS[event]
  if not handler then
    return snapshot
  end
  local next_snapshot = handler(snapshot, envelope)
  if next_snapshot == snapshot then
    return snapshot
  end
  next_snapshot.revision = (snapshot.revision or 0) + 1
  return next_snapshot
end

--- Determine the deterministic spinner phase for `now_ms` with the configured
--- debounce. Precedence (highest first):
---   terminal > tool_exec > retry > tool_args > response_start >
---   request_start (debounced) > idle
---
--- The debounce only gates the request_start phase: a request whose
--- request.started is younger than `delay_ms` yields "idle" until the debounce
--- elapses or a higher-precedence phase appears.
---
--- The phase is computed for the active session (snapshot.active_session_id);
--- when no session is active, the first running session (stable order) is used.
---@param snapshot table immutable snapshot
---@param now_ms integer current clock time (ms)
---@param delay_ms integer|nil spinner debounce (nil => DEFAULT_SPINNER_DELAY)
---@return string phase (M.PHASES value)
function M.spinner_phase(snapshot, now_ms, delay_ms)
  local delay = delay_ms or M.DEFAULT_SPINNER_DELAY
  if next(snapshot.terminal or {}) ~= nil then
    return M.PHASES.terminal
  end
  local sid = snapshot.active_session_id
  local sess = sid and snapshot._sessions[sid]
  if not sess or not sess.running then
    -- Fall back to the first running session (stable insertion order).
    for id, rec in pairs(snapshot._sessions or {}) do
      if rec.running then
        sid = id
        sess = rec
        break
      end
    end
  end
  if not sess or not sess.running then
    return M.PHASES.idle
  end
  local phases = sess.phases or {}
  if phases.tool_exec_at ~= nil then
    return M.PHASES.tool_exec
  end
  if phases.retry_at ~= nil then
    return M.PHASES.retry
  end
  if phases.tool_args_at ~= nil then
    return M.PHASES.tool_args
  end
  if phases.response_started_at ~= nil then
    return M.PHASES.response_start
  end
  if phases.request_started_at ~= nil then
    if (now_ms - phases.request_started_at) >= delay then
      return M.PHASES.request_start
    end
  end
  return M.PHASES.idle
end

--- Counter projection for tests / diagnostics: never negative.
---@param snapshot table
---@return table { active_requests=integer, running_sessions=integer, warmup_tasks=integer }
function M.counts_snapshot(snapshot)
  return {
    active_requests = clamp(snapshot.active_requests),
    running_sessions = clamp(snapshot.running_sessions),
    warmup_tasks = clamp(snapshot.warmup_tasks),
  }
end

return M
