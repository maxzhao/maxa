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
  -- W4 (phase-2): ToolBatch execution lifecycle. Additive; batch-scoped events
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
}

-- event -> array of callbacks (preserves registration order = dispatch order).
M.listeners = {}
-- Monotonic sequence counter; every emit assigns the next integer.
M._sequence = 0
-- Failure projection: emitted events whose callbacks errored. Never rethrown,
-- exposed for diagnostics/tests.
M.failures = {}

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
---@return table envelope the emitted envelope
function M.emit(event, payload)
  assert(type(event) == "string", "events.emit: event must be a string")

  local envelope = {
    event = event,
    sequence = M._sequence + 1,
    payload = payload or {},
    emitted_at = now_ms(),
  }
  M._sequence = envelope.sequence

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

--- Number of subscribers for an event (test/diagnostic helper).
---@param event string
---@return integer
function M.count(event)
  local list = M.listeners[event]
  return list and #list or 0
end

--- Reset bus state (subscribers, sequence, failure projection). Intended for
--- tests / cold-start isolation, not normal runtime usage.
function M.clear()
  M.listeners = {}
  M.failures = {}
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
---@return table a fresh bus exposing the same on/emit/once/count API
function M.new(opts)
  opts = opts or {}
  local bus = {
    listeners = {},
    failures = {},
    sequence = 0,
    events = M.events,
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
  function bus.emit(ev, payload)
    assert(type(ev) == "string", "events.emit: event must be a string")
    local envelope = {
      event = ev,
      sequence = bus.sequence + 1,
      payload = payload or {},
      emitted_at = bus_now(),
    }
    bus.sequence = envelope.sequence
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
  function bus.count(ev)
    local list = bus.listeners[ev]
    return list and #list or 0
  end
  function bus.clear()
    bus.listeners = {}
    bus.failures = {}
    bus.sequence = 0
  end
  return bus
end

return M
