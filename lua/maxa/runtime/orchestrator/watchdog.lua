-- filepath: lua/maxa/runtime/orchestrator/watchdog.lua
--- maxa runtime request watchdog (phase-2 W7): bounded-retry observation of a
--- request that produces no expected progress (request-orchestrator spec
--- §Progress and recovery / §Error and retry policy).
---
--- Scope: this module owns ONLY the observation state machine (timing, progress
--- resets, local-tool / drain suppression, retry budget counters). The
--- orchestrator owns the consequences of a fire (terminate the stuck request,
--- route through the continuation decision table, schedule the retry backoff).
--- That split keeps the timer engine deterministic and unit-testable while the
--- orchestrator keeps the single continuation decision point.
---
--- Detection classes (downstream chat_request_watchdog alignment):
---   * no_message — request submitted, no progress event within timeout_ms;
---   * no_progress — at least one progress event, then silence for timeout_ms.
--- Both share one re-armed timer: every progress event (message.delta /
--- reasoning.delta / tool_call.* / usage.updated / response.started) resets the
--- observation window; the fired reason is derived from `received_message`.
---
--- Suppression (pause) sources, each tracked in a reason set so overlapping
--- pauses compose:
---   * "tool"        — local ToolBatch executor running (spec: watchdog does NOT
---                     classify long local tool execution as provider stall);
---   * "soft_stop"   — soft-stop drain in progress (W6; never cancels work);
---   * "context_stop"— context-stop boundary reached (W6; one-shot);
---   * "stop"/"cancel" — hard stop / cancel in flight (defensive; the terminal
---                     stops the watchdog anyway).
--- pause() cancels the observation timer; resume() starts a FRESH window (the
--- downstream semantics: after a suppressed phase, the progress base resets).
---
--- Retry budget (spec: retry/watchdog budget share the terminal decision
--- boundary): `retry_count` counts watchdog retries for the current manual turn;
--- `remaining_budget()` feeds the decision-table `retry_budget` input slot
--- (nil when the watchdog is disabled = slot not wired). reserve_retry()
--- increments and emits the additive `watchdog.retry` event exactly once per
--- reservation; exhaustion is NOT an event here — the orchestrator's terminal
--- response.failed carries reason "watchdog_exhausted" + counters.
---
--- Reset semantics (downstream alignment): a MANUAL submit resets the budget
--- (reset()); watchdog auto-submits and retries do NOT reset.
---
--- This module depends only on the clock contract ({ now_ms, schedule,
--- cancel_timer } — lua/maxa/runtime/clock.lua) and the event bus. It never
--- loads codecompanion.* / mcphub.* / lua/util/hooks/*.

local M = {}

M.name = "orchestrator.watchdog"

--- Bounded exponential backoff for one retry (spec: "bounded exponential/backoff
--- policy"; every retry delay is cancellable — the orchestrator schedules it
--- through the same injected clock).
---@param retry_count integer 1-based retry ordinal
---@return integer ms
function M.backoff_ms_for(retry_count)
  local n = math.max(1, tonumber(retry_count) or 1)
  return math.min(1000 * (2 ^ (n - 1)), 30000)
end

--- Create a watchdog observation engine.
---@param opts? table {
---   clock?:     table { now_ms, schedule, cancel_timer } (required for enabled
---               watchdogs; defaults to a no-op clock when absent),
---   bus?:       table event bus (emits `watchdog.retry`),
---   session_id?: string session id (event payload),
---   config?:    table { enabled?, timeout_ms?, max_retries? } from the
---               orchestrator config section,
--- }
---@return table watchdog
function M.new(opts)
  opts = opts or {}
  local config = opts.config or {}
  local self = setmetatable({
    clock = opts.clock,
    bus = opts.bus,
    session_id = opts.session_id,
    enabled = config.enabled == true,
    timeout_ms = config.timeout_ms or 180000,
    max_retries = config.max_retries or 3,
    -- Observation state (per watched request).
    active = false,
    request_id = nil,
    generation = nil,
    received_message = false,
    started_at = nil,
    last_progress_at = nil,
    timer = nil, -- current observation timer handle (clock.schedule)
    pauses = {}, -- reason -> true (tool/soft_stop/context_stop/stop/cancel)
    retry_count = 0, -- watchdog retries reserved for the current manual turn
    on_fired = nil, -- fun(reason: "no_message"|"no_progress") set by the orchestrator
  }, { __index = M })
  return self
end

---@return integer virtual now (ms)
function M:now_ms()
  if self.clock and self.clock.now_ms then
    return self.clock.now_ms()
  end
  return os.time() * 1000
end

--- Resolve the event name for `watchdog.retry` (bus constant first, literal
--- fallback for custom buses without the constant table).
---@return string
function M:_event_name()
  if self.bus and self.bus.events and self.bus.events.watchdog_retry then
    return self.bus.events.watchdog_retry
  end
  return "watchdog.retry"
end

--- Cancel the current observation timer (idempotent).
function M:_clear_timer()
  if self.timer then
    if self.clock and self.clock.cancel_timer then
      self.clock.cancel_timer(self.timer)
    end
    self.timer = nil
  end
end

--- Arm the observation timer at delay_ms from now (single timer per watch).
---@param delay_ms integer
function M:_arm(delay_ms)
  self:_clear_timer()
  if not (self.clock and self.clock.schedule) then
    return -- no clock: observation cannot run (disabled watchdogs never arm)
  end
  local handle = self.clock.schedule(math.max(0, delay_ms or self.timeout_ms), function()
    self.timer = nil
    self:_fire()
  end)
  self.timer = handle
end

--- Timer fire: derive the detection reason and hand it to the orchestrator.
--- pause() cancels the timer handle, so a fired callback is never paused; the
--- guard is a defensive belt (idempotent cancel race).
function M:_fire()
  if not self.enabled or not self.active then
    return
  end
  if next(self.pauses) then
    return -- suppressed (belt; pause cancels the handle first)
  end
  local reason = self.received_message and "no_progress" or "no_message"
  if self.on_fired then
    self.on_fired(reason)
  end
end

--- Start observing a request (orchestrator: after request.submitted). A fresh
--- no_message window starts; `retry_count` is PRESERVED (a watchdog retry chain
--- keeps its budget across generations; only a manual submit resets it).
---@param request table request record (id/generation)
---@return self
function M:start(request)
  if not self.enabled then
    return self
  end
  self:_clear_timer()
  self.active = true
  self.request_id = request and request.id
  self.generation = request and request.generation
  self.received_message = false
  self.started_at = self:now_ms()
  self.last_progress_at = self.started_at
  self.pauses = {}
  self:_arm(self.timeout_ms)
  return self
end

--- Stop observing (orchestrator: request terminal). The observation timer is
--- removed; `retry_count` is preserved (reset only on manual submit).
---@return self
function M:stop()
  self.active = false
  self.request_id = nil
  self.generation = nil
  self.received_message = false
  self.pauses = {}
  self:_clear_timer()
  return self
end

--- Reset the whole watchdog budget (orchestrator: MANUAL submit only). Cancels
--- any pending observation and zeroes the retry count.
---@return self
function M:reset()
  self:stop()
  self.retry_count = 0
  return self
end

--- Mark progress for the watched request: any content-bearing provider event
--- resets the observation window (no_message -> no_progress transition). While
--- paused (tool execution / drain), the flag is updated but no timer is armed —
--- resume() re-arms a fresh window.
---@param _reason string progress label (diagnostic; not persisted)
---@return self
function M:mark_progress(_reason)
  if not self.enabled or not self.active then
    return self
  end
  self.received_message = true
  self.last_progress_at = self:now_ms()
  if not next(self.pauses) then
    self:_arm(self.timeout_ms)
  end
  return self
end

--- Suppress observation for a bounded phase (tool execution / drains / stop).
--- Composable: multiple pause sources are tracked; any active source keeps the
--- watchdog suppressed.
---@param reason string pause source ("tool"|"soft_stop"|"context_stop"|"stop"|"cancel")
---@return self
function M:pause(reason)
  if not self.enabled or not self.active then
    return self
  end
  self.pauses[reason] = true
  self:_clear_timer()
  return self
end

--- End a suppressed phase. When no pause source remains, a FRESH observation
--- window starts from now (downstream: after a suppressed phase the progress
--- base resets; `received_message` is preserved so the next fire is no_progress).
---@param reason string pause source to release
---@return self
function M:resume(reason)
  if not self.enabled or not self.active then
    return self
  end
  self.pauses[reason] = nil
  if not next(self.pauses) then
    self.last_progress_at = self:now_ms()
    self:_arm(self.timeout_ms)
  end
  return self
end

---@return boolean true when the watchdog still watches the given request.
function M:is_active(request)
  return self.active and request ~= nil and self.request_id == request.id and self.generation == request.generation
end

---@return boolean true when another retry may be reserved (budget remains).
function M:can_retry()
  return self.enabled and self.retry_count < self.max_retries
end

--- Remaining retry budget for the decision table (spec: retry/watchdog budget
--- share the terminal decision boundary). nil when the watchdog is disabled
--- (slot not wired); otherwise >= 0 (0 => exhaustion, decision fail).
---@return integer|nil
function M:remaining_budget()
  if not self.enabled then
    return nil
  end
  return math.max(0, self.max_retries - self.retry_count)
end

--- Reserve one watchdog retry: increments the counter and emits the additive
--- `watchdog.retry` event (retry_count / max_retries / reason) exactly once per
--- reservation. Exhaustion never emits this event (the terminal response.failed
--- carries reason "watchdog_exhausted").
---@param reason "no_message"|"no_progress"
---@return integer retry_count after reservation
function M:reserve_retry(reason)
  self.retry_count = self.retry_count + 1
  if self.bus and self.bus.emit then
    self.bus.emit(self:_event_name(), {
      session_id = self.session_id,
      request_id = self.request_id,
      generation = self.generation,
      retry_count = self.retry_count,
      max_retries = self.max_retries,
      reason = reason,
    })
  end
  return self.retry_count
end

--- Backoff delay for the NEXT scheduled retry (bounded exponential; cancellable
--- via the injected clock handle).
---@return integer ms
function M:backoff_ms()
  return M.backoff_ms_for(self.retry_count)
end

return M
