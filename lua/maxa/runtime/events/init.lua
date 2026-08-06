-- filepath: lua/maxa/runtime/events/init.lua
--- Phase-0 minimal typed event bus for the maxa runtime.
---
--- Scope: this phase ships a single dedicated event bus used by the
--- horizontal skeleton and the minimal runnable Chat (mock provider). It must
--- remain self-contained: it depends on no other runtime module and never
--- loads codecompanion.*/mcphub.*/lua/util/hooks/*.
---
--- Contract (see .supermax/drafts/phase0-development-plan.md §4.7):
---   * on(event, cb)  -> idempotent subscribe; same (event, cb) registered once;
---                      returns an unsubscribe function.
---   * emit(event, payload) -> sequential dispatch over the event's callbacks,
---                      each guarded by pcall so a single failing callback never
---                      aborts the others; failures are recorded, not rethrown.
---                      Every emit produces an envelope
---                        { event, sequence, payload, emitted_at }
---                      with a strictly monotonic per-bus `sequence`.
---   * Sequence only has to be monotonic in this phase; idempotent/durable
---      consumption, session scoping and event_id identity are later stages.
---
--- Upstream semantics aligned (read-only) with CodeCompanion chat
---   `init.lua::add_callback` / `dispatch` (idempotent-on, sequential dispatch,
---   per-callback pcall isolation). No code is copied; this is a typed,
---   sequence-tagged, self-contained rewrite.
---
--- Phase-5 W1 additions (events-status spec §Event envelope / §Status reduction;
--- additive only, legacy fields/API kept verbatim):
---   * Envelope now carries the full identity contract: event_id, type,
---     timestamp, project_id, session_id, request_id, turn_id, tool_batch_id,
---     tool_call_id, task_id, view_id, generation, sequence, session_seq,
---     reason, payload. Legacy `event` / `emitted_at` remain.
---   * event_id is stable: an explicit `payload.event_id` wins (external replay
---     ids); otherwise `<session_id or "global">:<sequence>`.
---   * session_seq is a per-session monotonic sub-sequence (keyed by the
---     payload's session_id); `sequence` stays globally monotonic.
---   * Transactional reducers: `register_reducer(fn)` registers in order;
---     reducers run synchronously BEFORE observers on every emit. A reducer
---     failure is a declared transactional failure (recorded with
---     phase="reducer") and never interrupts observer dispatch.
---   * Idempotency: an already-seen event_id has no second reducer effect.
---     `replay(events, opts)` re-applies reducers only (observers opt in via
---     opts.observers) and skips seen ids; `seen_event_ids()` returns a copy of
---     the idempotency table.

local M = {}

M.name = "events"

--- Minimal event name set (plan §4.7; W8 extends with the streaming parts
--- events). Callers should use these constants rather than bare strings so
--- misspellings fail fast. Phase-0 names are kept verbatim for compatibility;
--- W8 only ADDS names (never renames/removes).
M.events = {
  session_created = "session.created",
  request_submitted = "request.submitted",
  -- W8: provider stream actually started (first content-bearing event).
  request_started = "request.started",
  response_started = "response.started",
  message_delta = "message.delta",
  -- W8: reasoning accumulation (visible only per ui.show_reasoning policy).
  reasoning_delta = "reasoning.delta",
  -- W8: tool-call lifecycle (recorded only; execution is a phase-2 concern).
  tool_call_started = "tool_call.started",
  tool_call_delta = "tool_call.delta",
  tool_call_completed = "tool_call.completed",
  -- W8: normalized usage snapshots (streaming-usage spec).
  usage_updated = "usage.updated",
  response_completed = "response.completed",
  response_failed = "response.failed",
  response_cancelled = "response.cancelled",
  chat_stop_requested = "chat.stop_requested",
  chat_closed = "chat.closed",
  -- W1 (phase-2): state-machine diagnostic. Additive; emitted only when a legal
  -- transition is rejected (never for valid transitions, which are record-only
  -- until later waves add their batch/decision/stop events).
  session_transition_rejected = "session.transition_rejected",
  -- W4 (phase-2): ToolBatch lifecycle. Additive; batch-scoped events
  -- emitted by the tools executor (lua/maxa/runtime/tools/init.lua). The
  -- session's transition records keep their own names (tool_batch.completed /
  -- failed / cancelled) for audit; these bus events are the runtime projections.
  -- `tool_call.finished` is distinct from `tool_call.completed` (provider-side
  -- argument accumulation): it fires once per executed call after its result is
  -- persisted, with the runtime result status.
  tool_batch_started = "tool_batch.started",
  tool_batch_draining = "tool_batch.draining",
  tool_batch_finished = "tool_batch.finished",
  tool_call_finished = "tool_call.finished",
  -- W5 (phase-2): continuation decision point. Additive; emitted exactly once
  -- per durable continuation key, after the batch terminal event and before the
  -- scheduled next intent (request-orchestrator §Persistence/event order:
  -- "emit batch terminal -> persist continuation decision -> schedule next
  -- intent"). Carries the durable continuation key so consumers can dedupe
  -- late/duplicate terminal callbacks and restore replays.
  continuation_decided = "continuation.decided",
  -- W6 (phase-2): soft-stop request state. Additive; emitted when a soft stop
  -- is requested (requested=true) or toggled off (requested=false). `source`
  -- distinguishes a manual request ("manual") from a context-stop trigger
  -- ("context_stop"). The soft stop itself never cancels the provider/tools:
  -- the drain then suppresses the next automatic continuation through the
  -- decision table (soft_stop/context_stop input slots -> wait).
  soft_stop_requested = "chat.soft_stop_requested",
  -- W6 (phase-2): soft-stop completion boundary. Additive; emitted exactly once
  -- at the drain boundary (text-only response terminal or the W5 continuation
  -- decision point) when a pending soft-stop request (manual or context-stop
  -- trigger) was consumed. Payload: { session_id, request_id, generation,
  -- turn_id, tool_batch_id|nil, reason = "soft_stop"|"context_stop" }. The
  -- session boundary is observable via `continuation.decided`
  -- (decision_kind=wait, decision_reason) plus session waiting_for_user.
  soft_stop_completed = "chat.soft_stop_completed",
  -- W7 (phase-2): watchdog retry reservation (additive; exactly once per retry
  -- reservation; exhaustion is carried by the terminal response.failed with
  -- reason "watchdog_exhausted" + counters). Payload: { session_id, request_id,
  -- generation, retry_count, max_retries, reason = "no_message"|"no_progress" }.
  watchdog_retry = "watchdog.retry",
  -- W3 (phase-3): external MCP server lifecycle projection (additive). Emitted
  -- once per server state transition with payload { server_id, state, revision,
  -- reason, kind, generation } (revision = per-server monotonic state revision);
  -- after a registry config reload the registry emits exactly one aggregate
  -- update: { aggregate = true, reason = "config_reload",
  --   servers = { [id] = { kind, state, revision, generation,
  --                        capabilities_revision } } }.
  mcp_server_state = "mcp.server_state",
  -- W6 (phase-3): SkillHook lifecycle projections (additive). Emitted by the
  -- SkillHook machinery (skills/registry.lua, skills/fire.lua,
  -- skills/injector.lua) through the same bus; payload follows the
  -- events-status §SkillHook envelope: session_id/request_id/turn_id (where
  -- applicable), skill_id, event_name, phase, ok, error.
  --   * skill.hook_registered: phase = hook load phase ("startup"|"on_load");
  --   * skill.hook_fired / skill.hook_failed: phase = inject_at ("pre"|"post");
  --     hook_fired carries `injected` (pre) or 0 (post observer);
  --   * skill.hook_restored: phase = "restore", carries `restored` count.
  skill_hook_registered = "skill.hook_registered",
  skill_hook_fired = "skill.hook_fired",
  skill_hook_failed = "skill.hook_failed",
  skill_hook_restored = "skill.hook_restored",
  -- W3 (phase-4): session trace subsystem projections (additive). Emitted by the
  -- history service (lua/maxa/runtime/history/init.lua) after trace operations;
  -- the trace module itself is a pure storage/query library and never emits.
  --   * trace.turn_recorded: one visible natural turn event appended
  --     (payload { root_trace_id, event_id, kind });
  --   * trace.backfilled: backfill_chat completed (payload { root_trace_id, result });
  --   * trace.archive_created / trace.compression_applied: compaction archive
  --     projections emitted by the history service since W4 (compaction wave):
  --     payload { root_trace_id, event_id, kind } / { root_trace_id, event_id, action }.
  trace_turn_recorded = "trace.turn_recorded",
  trace_backfilled = "trace.backfilled",
  trace_archive_created = "trace.archive_created",
  trace_compression_applied = "trace.compression_applied",
  -- W4 (phase-4): history service lifecycle projections (additive). Emitted by the
  -- history service (lua/maxa/runtime/history/init.lua) after save/restore/title/
  -- compact operations; the service guards absent buses (never raises).
  --   * history.saved: one session envelope durably committed
  --     (payload { save_id, session_id, status, generation });
  --   * history.save_failed: any non-index persistence failure
  --     (payload { save_id?, session_id, code, error });
  --   * history.saved_index_stale: session file committed but index update failed
  --     (payload { save_id, session_id, code, error }); rebuild_index() recovers;
  --   * history.restored: restore_bundle/open returned a recovery bundle
  --     (payload { save_id, session_id });
  --   * history.title_changed: a title generation/refresh result was applied and
  --     persisted (payload { save_id, session_id, title, is_refresh });
  --   * history.compacted: compaction applied (payload { save_id, session_id,
  --     action, generation, truncated_count, archived }).
  history_saved = "history.saved",
  history_save_failed = "history.save_failed",
  history_saved_index_stale = "history.saved_index_stale",
  history_restored = "history.restored",
  history_title_changed = "history.title_changed",
  history_compacted = "history.compacted",
  -- W1 (phase-5): chat view / action lifecycle names (additive). Emitted by
  -- the host view and the action layer; consumers dedupe on event_id.
  chat_hidden = "chat.hidden",
  chat_reattached = "chat.reattached",
  view_closed = "view.closed",
  action_started = "action.started",
  action_completed = "action.completed",
  action_failed = "action.failed",
}

-- event -> array of callbacks (preserves registration order = dispatch order).
M.listeners = {}
-- Monotonic sequence counter; every emit assigns the next integer.
M._sequence = 0
-- Failure projection: emitted events whose callbacks errored. Never rethrown,
-- exposed for diagnostics/tests. Reducer failures carry phase="reducer";
-- observer failures keep the legacy shape (no phase).
M.failures = {}
-- Transactional reducers: run (in registration order) before observers on
-- every emit and during replay. Failures are recorded with phase="reducer".
M.reducers = {}
-- Per-session monotonic sub-sequences (session_id -> integer).
M._session_seq = {}
-- Idempotency table: event_id -> true once reducers have been applied (live
-- emit or replay). Re-applying a seen id is a no-op for reducers.
M._seen_event_ids = {}

-- Identity fields copied from the payload onto every envelope (nil when the
-- payload lacks the key), plus the standalone `reason` contract field.
local IDENTITY_KEYS = {
  "project_id",
  "session_id",
  "request_id",
  "turn_id",
  "tool_batch_id",
  "tool_call_id",
  "task_id",
  "view_id",
  "generation",
  "reason",
}

--- Wall-clock timestamp (milliseconds) for the envelope's `emitted_at`.
--- Prefers the nvim monotonic-adjacent clock when available, else os.time()*1000.
---@return integer
local function now_ms()
  if vim and vim.uv and vim.uv.hrtime then
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  return os.time() * 1000
end

--- Subscribe a callback to an event (idempotent for the same (event, cb)).
---@param event string event name (see M.events)
---@param cb function callback(payload, envelope)
---@return function unsubscribe: calling it removes this exact subscription
function M.on(event, cb)
  assert(type(event) == "string", "events.on: event must be a string")
  assert(type(cb) == "function", "events.on: cb must be a function")

  local list = M.listeners[event]
  if not list then
    list = {}
    M.listeners[event] = list
  else
    -- Idempotent registration: same (event, cb) must not be registered twice.
    for _, existing in ipairs(list) do
      if existing == cb then
        -- Return a no-op unsubscribe that still maps to this subscription.
        return function() end
      end
    end
  end
  list[#list + 1] = cb

  local unsubscribed = false
  return function()
    if unsubscribed then
      return
    end
    unsubscribed = true
    local l = M.listeners[event]
    if not l then
      return
    end
    for i = #l, 1, -1 do
      if l[i] == cb then
        table.remove(l, i)
      end
    end
    if #l == 0 then
      M.listeners[event] = nil
    end
  end
end

--- Convenience: register a one-shot callback (fires on the next matching emit).
---@param event string
---@param cb function
function M.once(event, cb)
  local off
  off = M.on(event, function(payload, envelope)
    off()
    cb(payload, envelope)
  end)
  return off
end

--- Dispatch an event to its subscribers. The listeners are snapshotted so a
--- callback that unsubscribes (itself or others) during dispatch cannot skip a
--- still-registered sibling. Sequence is incremented before delivery.
---@param event string
---@param payload table|nil
---@param opts? table { reducer_only?: boolean } when true, reducers run but
---  observers are skipped (replay-style pre-application, no side effects)
---@return table envelope the emitted envelope
function M.emit(event, payload, opts)
  assert(type(event) == "string", "events.emit: event must be a string")
  opts = (type(opts) == "table") and opts or {}
  payload = payload or {}

  local sequence = M._sequence + 1
  M._sequence = sequence

  local session_id = payload.session_id
  local event_id = payload.event_id or ("%s:%d"):format(session_id or "global", sequence)
  local session_seq
  if session_id ~= nil then
    session_seq = (M._session_seq[session_id] or 0) + 1
    M._session_seq[session_id] = session_seq
  end

  local emitted_at = now_ms()
  local envelope = {
    event = event,
    type = event,
    timestamp = emitted_at,
    emitted_at = emitted_at,
    event_id = event_id,
    sequence = sequence,
    session_seq = session_seq,
    payload = payload,
  }
  for _, key in ipairs(IDENTITY_KEYS) do
    envelope[key] = payload[key]
  end

  -- Transactional phase: reducers run synchronously before observers, exactly
  -- once per event_id (idempotency). A failing reducer is recorded as a typed
  -- transactional failure and never aborts sibling reducers or observers.
  if not M._seen_event_ids[event_id] then
    M._seen_event_ids[event_id] = true
    for _, reducer in ipairs(M.reducers) do
      local ok, err = pcall(reducer, envelope.payload, envelope)
      if not ok then
        local errs = M.failures[event]
        if not errs then
          errs = {}
          M.failures[event] = errs
        end
        errs[#errs + 1] = {
          phase = "reducer",
          event = event,
          sequence = envelope.sequence,
          err = tostring(err),
          emitted_at = envelope.emitted_at,
        }
      end
    end
  end

  if opts.reducer_only then
    return envelope
  end

  local list = M.listeners[event]
  if not list or #list == 0 then
    return envelope
  end

  -- Snapshot to keep delivery order stable and isolate unsubscribes.
  local snapshot = {}
  for i = 1, #list do
    snapshot[i] = list[i]
  end

  for _, cb in ipairs(snapshot) do
    local ok, err = pcall(cb, envelope.payload, envelope)
    if not ok then
      -- Isolate a single callback failure; record it, do not abort the rest.
      local errs = M.failures[event]
      if not errs then
        errs = {}
        M.failures[event] = errs
      end
      errs[#errs + 1] = {
        sequence = envelope.sequence,
        err = tostring(err),
        emitted_at = envelope.emitted_at,
      }
    end
  end

  return envelope
end

--- Register a transactional reducer. Reducers run in registration order,
--- synchronously before observers on every emit (and during replay). A reducer
--- receives (payload, envelope); it may throw to declare a transactional
--- failure, which is recorded (phase="reducer") without interrupting dispatch.
---@param fn function reducer(payload, envelope)
---@return function unsubscribe
function M.register_reducer(fn)
  assert(type(fn) == "function", "events.register_reducer: fn must be a function")
  M.reducers[#M.reducers + 1] = fn
  return function()
    for i = #M.reducers, 1, -1 do
      if M.reducers[i] == fn then
        table.remove(M.reducers, i)
      end
    end
  end
end

--- Re-apply a persisted event stream to the transactional reducers without
--- running observers (side-effect free) unless opts.observers is true. Events
--- whose event_id is already in the idempotency table are skipped. Reducer
--- failures are recorded like live emit (phase="reducer") and do not abort the
--- remaining stream.
---@param events table[] persisted envelopes (event_id required)
---@param opts? table { observers?: boolean } run observers too (default false)
---@return integer number of events whose reducers were applied
function M.replay(events, opts)
  assert(type(events) == "table", "events.replay: events must be a table")
  opts = (type(opts) == "table") and opts or {}
  local applied = 0
  for _, envelope in ipairs(events) do
    if type(envelope) == "table" and envelope.event_id and not M._seen_event_ids[envelope.event_id] then
      M._seen_event_ids[envelope.event_id] = true
      local event = envelope.event or envelope.type
      local payload = envelope.payload or {}
      for _, reducer in ipairs(M.reducers) do
        local ok, err = pcall(reducer, payload, envelope)
        if not ok then
          local errs = M.failures[event or ""]
          if not errs then
            errs = {}
            M.failures[event or ""] = errs
          end
          errs[#errs + 1] = {
            phase = "reducer",
            event = event,
            sequence = envelope.sequence,
            err = tostring(err),
            emitted_at = envelope.timestamp or envelope.emitted_at,
          }
        end
      end
      applied = applied + 1
      if opts.observers and type(event) == "string" then
        local list = M.listeners[event]
        if list and #list > 0 then
          local snapshot = {}
          for i = 1, #list do
            snapshot[i] = list[i]
          end
          for _, cb in ipairs(snapshot) do
            local ok, err = pcall(cb, payload, envelope)
            if not ok then
              local errs = M.failures[event]
              if not errs then
                errs = {}
                M.failures[event] = errs
              end
              errs[#errs + 1] = {
                sequence = envelope.sequence,
                err = tostring(err),
                emitted_at = envelope.timestamp or envelope.emitted_at,
              }
            end
          end
        end
      end
    end
  end
  return applied
end

--- Copy of the current idempotency table (event_id -> true). Callers must not
--- mutate the bus's internal table directly.
---@return table copy
function M.seen_event_ids()
  local copy = {}
  for id in pairs(M._seen_event_ids) do
    copy[id] = true
  end
  return copy
end

--- Number of subscribers for an event (test/diagnostic helper).
---@param event string
---@return integer
function M.count(event)
  local list = M.listeners[event]
  return list and #list or 0
end

--- Reset bus state (subscribers, sequence, failure projection, reducers,
--- per-session counters and the idempotency table). Intended for tests /
--- cold-start isolation, not normal runtime usage.
function M.clear()
  M.listeners = {}
  M.failures = {}
  M.reducers = {}
  M._session_seq = {}
  M._seen_event_ids = {}
  M._sequence = 0
end

--- Create a new isolated bus instance. Useful in later phases for session
--- scoping; phase 0 uses the default singleton exports above.
---@param opts? table {
---   clock?: table|nil deterministic clock (W2): { now_ms = fun(): integer };
---     when provided the envelope `emitted_at` uses clock.now_ms() instead of
---     the wall clock. Tests inject a fake clock (tests/state/lib/fake_clock.lua)
---     so R-STATE fixtures assert exact, reproducible timestamps.
--- }
---@return table a fresh bus exposing the same on/emit/once/count API plus
---  register_reducer/replay/seen_event_ids with instance-level idempotency
function M.new(opts)
  opts = opts or {}
  local bus = {
    listeners = {},
    failures = {},
    sequence = 0,
    events = M.events,
    reducers = {},
    _session_seq = {},
    _seen_event_ids = {},
  }
  local function bus_now()
    if opts.clock and opts.clock.now_ms then
      return opts.clock.now_ms()
    end
    return now_ms()
  end
  function bus.on(ev, cb)
    assert(type(ev) == "string", "events.on: event must be a string")
    assert(type(cb) == "function", "events.on: cb must be a function")
    local list = bus.listeners[ev]
    if not list then
      list = {}
      bus.listeners[ev] = list
    else
      for _, existing in ipairs(list) do
        if existing == cb then
          return function() end
        end
      end
    end
    list[#list + 1] = cb
    local done = false
    return function()
      if done then
        return
      end
      done = true
      local l = bus.listeners[ev]
      if not l then
        return
      end
      for i = #l, 1, -1 do
        if l[i] == cb then
          table.remove(l, i)
        end
      end
      if #l == 0 then
        bus.listeners[ev] = nil
      end
    end
  end
  function bus.once(ev, cb)
    local off
    off = bus.on(ev, function(payload, envelope)
      off()
      cb(payload, envelope)
    end)
    return off
  end
  function bus.emit(ev, payload, opts)
    assert(type(ev) == "string", "events.emit: event must be a string")
    opts = (type(opts) == "table") and opts or {}
    payload = payload or {}

    local sequence = bus.sequence + 1
    bus.sequence = sequence

    local session_id = payload.session_id
    local event_id = payload.event_id or ("%s:%d"):format(session_id or "global", sequence)
    local session_seq
    if session_id ~= nil then
      session_seq = (bus._session_seq[session_id] or 0) + 1
      bus._session_seq[session_id] = session_seq
    end

    local emitted_at = bus_now()
    local envelope = {
      event = ev,
      type = ev,
      timestamp = emitted_at,
      emitted_at = emitted_at,
      event_id = event_id,
      sequence = sequence,
      session_seq = session_seq,
      payload = payload,
    }
    for _, key in ipairs(IDENTITY_KEYS) do
      envelope[key] = payload[key]
    end

    -- Transactional phase: reducers run synchronously before observers, exactly
    -- once per event_id (idempotency); failures are typed, never rethrown.
    if not bus._seen_event_ids[event_id] then
      bus._seen_event_ids[event_id] = true
      for _, reducer in ipairs(bus.reducers) do
        local ok, err = pcall(reducer, envelope.payload, envelope)
        if not ok then
          local errs = bus.failures[ev]
          if not errs then
            errs = {}
            bus.failures[ev] = errs
          end
          errs[#errs + 1] = {
            phase = "reducer",
            event = ev,
            sequence = envelope.sequence,
            err = tostring(err),
            emitted_at = envelope.emitted_at,
          }
        end
      end
    end

    if opts.reducer_only then
      return envelope
    end

    local list = bus.listeners[ev]
    if not list or #list == 0 then
      return envelope
    end
    local snapshot = {}
    for i = 1, #list do
      snapshot[i] = list[i]
    end
    for _, cb in ipairs(snapshot) do
      local ok, err = pcall(cb, envelope.payload, envelope)
      if not ok then
        local errs = bus.failures[ev]
        if not errs then
          errs = {}
          bus.failures[ev] = errs
        end
        errs[#errs + 1] = {
          sequence = envelope.sequence,
          err = tostring(err),
          emitted_at = envelope.emitted_at,
        }
      end
    end
    return envelope
  end
  function bus.register_reducer(fn)
    assert(type(fn) == "function", "events.register_reducer: fn must be a function")
    bus.reducers[#bus.reducers + 1] = fn
    return function()
      for i = #bus.reducers, 1, -1 do
        if bus.reducers[i] == fn then
          table.remove(bus.reducers, i)
        end
      end
    end
  end
  function bus.replay(events, opts)
    assert(type(events) == "table", "events.replay: events must be a table")
    opts = (type(opts) == "table") and opts or {}
    local applied = 0
    for _, envelope in ipairs(events) do
      if type(envelope) == "table" and envelope.event_id and not bus._seen_event_ids[envelope.event_id] then
        bus._seen_event_ids[envelope.event_id] = true
        local event = envelope.event or envelope.type
        local payload = envelope.payload or {}
        for _, reducer in ipairs(bus.reducers) do
          local ok, err = pcall(reducer, payload, envelope)
          if not ok then
            local errs = bus.failures[event or ""]
            if not errs then
              errs = {}
              bus.failures[event or ""] = errs
            end
            errs[#errs + 1] = {
              phase = "reducer",
              event = event,
              sequence = envelope.sequence,
              err = tostring(err),
              emitted_at = envelope.timestamp or envelope.emitted_at,
            }
          end
        end
        applied = applied + 1
        if opts.observers and type(event) == "string" then
          local list = bus.listeners[event]
          if list and #list > 0 then
            local snapshot = {}
            for i = 1, #list do
              snapshot[i] = list[i]
            end
            for _, cb in ipairs(snapshot) do
              local ok, err = pcall(cb, payload, envelope)
              if not ok then
                local errs = bus.failures[event]
                if not errs then
                  errs = {}
                  bus.failures[event] = errs
                end
                errs[#errs + 1] = {
                  sequence = envelope.sequence,
                  err = tostring(err),
                  emitted_at = envelope.timestamp or envelope.emitted_at,
                }
              end
            end
          end
        end
      end
    end
    return applied
  end
  function bus.seen_event_ids()
    local copy = {}
    for id in pairs(bus._seen_event_ids) do
      copy[id] = true
    end
    return copy
  end
  function bus.count(ev)
    local list = bus.listeners[ev]
    return list and #list or 0
  end
  function bus.clear()
    bus.listeners = {}
    bus.failures = {}
    bus.reducers = {}
    bus._session_seq = {}
    bus._seen_event_ids = {}
    bus.sequence = 0
  end
  return bus
end

return M
