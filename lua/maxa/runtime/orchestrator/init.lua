-- filepath: lua/maxa/runtime/orchestrator/init.lua
--- maxa runtime orchestrator: minimal message loop driving a provider stream
--- through a session (phase-1 W2 parts switch).
---
--- Scope (see .supermax/drafts/phase1-implementation-plan.md §4.8): this module
--- ships the `submit -> stream -> complete` loop only. It drives the provider
--- adapter through the unified stream surface (§4.1), consumes normalized events
--- (protocol.normalize), persists messages as content parts, normalizes usage
--- (provider fields authoritative, local_estimate fallback), and guarantees that
--- each request reaches exactly one terminal state / terminal event. It never
--- loads codecompanion.* / mcphub.* / lua/util/hooks/*.
---
--- Alignment (read-only): upstream `Chat:submit` current_request guard +
--- `_submit_http` three-callback handling + `Chat:done` (interactions/chat/init.lua),
--- and `.supermax/specs/chat-runtime-state` control ops (submit/intent, cancel).
---
--- Events emitted here (W8 full set; phase-0 names kept verbatim):
---   "request.submitted"   carrier begins; carries session/request identity
---   "request.started"     once, when the provider stream produces its first
---                         content-bearing event (W8; new name, additive)
---   "response.started"    once, together with request.started
---   "message.delta"       every incremental text chunk (delta + full text)
---   "reasoning.delta"     every incremental reasoning chunk (W8)
---   "tool_call.started"   per tool call, on the first tool_call_started event (W8)
---   "tool_call.delta"     per tool-argument fragment (W8)
---   "tool_call.completed" per tool call, with the fully accumulated args (W8)
---   "usage.updated"       every normalized usage snapshot (W8)
---   "response.completed"  terminal success (exactly once), carries normalized
---                         usage + finish_reason + tool_calls summary
---   "response.failed"     terminal provider/protocol failure (exactly once)
---   "response.cancelled"  terminal cancel via orchestrator:stop() (exactly once)
---
--- W3 (phase-2): submit-intent model — every submit carries an immutable
--- intent_id + kind (manual/automatic/regenerate/restore/retry) + expected
--- session generation + input/context revision; replaying the same intent_id
--- returns the recorded decision/request and never sends a duplicate provider
--- request. retry chains a new request generation to the failed request
--- (request.retry_of); regenerate truncates the stack after the last user
--- message (archived on the result); restore rebuilds session/loop/message-stack
--- state from a snapshot; callbacks guard on request id AND generation
--- (stale-callback safety).
---
--- W4 (phase-2): ToolBatch execution — on_done with tool calls moves the
--- request to tool_pending, creates the ToolBatch entity and runs the minimal
--- executor (tools/init.lua) with the injected tool_handlers table. Results are
--- persisted as role="tool" messages BEFORE the batch barrier; tool_batch.finished
--- fires exactly once. Batch-scoped bus events (additive): tool_batch.started /
--- tool_batch.draining / tool_batch.finished / tool_call.finished. A sync submit
--- whose batch is still running (async handlers) returns tool_pending=true.
---
--- W5 (phase-2): the W4 direct pass-through continuation is replaced by the
--- continuation decision table (orchestrator/decide.lua — pure function over a
--- committed request/tool-batch/session snapshot; request-orchestrator
--- §Continuation decision table). `_on_batch_terminal` is the single
--- continuation decision point: it finishes the owning request, decides,
--- persists the decision under its durable continuation key
--- `(session_generation, source_request_id, tool_batch_id|none, decision_kind)`
--- into session.loop.decisions (same-key second decisions are rejected with a
--- reference to the existing record — terminal-race / restore dedup), emits the
--- additive `continuation.decided` event exactly once per key, then executes:
--- continue submits exactly ONE automatic request; wait/fail/terminate park the
--- AgentLoop (session.loop.state -> waiting_for_user). AgentLoop minimal state:
--- session.loop = { enabled, state = armed|waiting_for_user, iteration,
--- decision_key, decisions }. restore-agent-loop: restore submits rebuild the
--- message stack + loop, and orphan assistant tool_call parts (no paired tool
--- result) are repaired with a synthetic cancelled result carrying provenance
--- "restore_repair"; restored loop decisions keep the no-duplicate-continuation
--- guarantee.
---
--- W6 (phase-2): control operations are separated at the orchestrator level:
---   * cancel()  — hard cancel of the provider stream + child tasks (the W4
---                 stop body); terminal cancelled, no suppression marker.
---   * stop()    — cancel + a hard stop marker (`_stop_requested` feeds the
---                 decision-table `stop` input slot -> wait, so continuation is
---                 suppressed even if the work completed), then the session
---                 moves to `stopped` (chat-runtime-state: non-closed ->
---                 stopped; recoverable, not closed). `:MaxaStop` keeps its
---                 terminal-cancelled behavior via the host View:stop path.
---   * soft_stop() — busy-only, toggle-off on repeat, never cancels the
---                 provider/tools; sets `_soft_stop_requested` (decision-table
---                 `soft_stop` input slot -> wait + loop parked) so the current
---                 response/tool batch drains and the next automatic
---                 continuation is suppressed. Additive events:
---                 chat.soft_stop_requested ({ requested, source =
---                 "manual"|"context_stop" }) and, at the drain boundary,
---                 chat.soft_stop_completed ({ reason = "soft_stop"|
---                 "context_stop" }, exactly once when a pending soft stop was
---                 consumed). The drained session lands at waiting_for_user.
---   Context-stop (W6): config-driven one-shot usage limit. `_context_stop` =
---   { enabled, target_ratio, triggered }; usage comes from an injectable
---   usage_provider (real token stats land in phase 4/5). Checkpoints: at the
---   text-only drain boundary and before the continuation decision (busy path
---   -> context_stop input -> wait) and at the automatic-submit entry (idle
---   path -> typed rejection). Armed -> consumed exactly once (triggered).
---   Usage unavailable -> fail-closed (arm fails; checks never trigger).
---   Orchestrator config (W6): orchestrator.new reads the `orchestrator`
---   section of `.maxa/runtime.yaml` (opts.config snapshot or opts.
---   orchestrator_config raw table) with defaults { tool_concurrency = 1,
---   watchdog = { enabled=false, timeout_ms=180000, max_retries=3 },
---   context_stop = { enabled=false} }. tool_concurrency is parsed but the
---   executor still runs sequentially this wave (>1 does not activate
---   parallelism).
---
--- W7 (phase-2): watchdog + retry budget. The observation state machine lives
--- in orchestrator/watchdog.lua (clock-driven; fake clock deterministic) and is
--- started at request.submitted / stopped at every response terminal. It
--- detects no_message / no_progress after `watchdog.timeout_ms` (default
--- 180000), excludes the local ToolBatch execution phase (pause "tool") and
--- soft/context-stop drains (pause "soft_stop"/"context_stop"; W6 semantics),
--- and is reset by MANUAL submits (watchdog auto-submits never reset the
--- budget). On a fire the orchestrator reserves one retry (additive
--- `watchdog.retry` event with retry_count/max_retries/reason), terminates the
--- stuck request as a terminal `timeout` failure (response.failed exactly once,
--- carrying watchdog counters; exhaustion adds reason "watchdog_exhausted"),
--- and routes through the continuation decision table with
--- `retry_budget = remaining watchdog budget` (max_retries default 3). The
--- retry decision schedules a cancellable clock-driven backoff
--- (watchdog.backoff_ms, bounded exponential) then submits kind="retry" with
--- retry_of = the failed request (new request generation, W3 chain); budget
--- exhaustion yields decision fail(retry_budget_exhausted) and parks the loop
--- (Chat unlocked at waiting_for_user). Long tool execution is never classified
--- as provider stall (spec §Progress and recovery).
---
--- Terminal guarantees:
---   - provider drive_stream fires exactly one of on_done / on_error; orchestrator
---     additionally guards its own callback so a terminal response event and the
---     session:finish_request transition happen exactly once per request.
---   - A late/duplicate terminal callback for an already-terminal or superseded
---     request is ignored without mutation (terminal-race safety).
---   - A second decision for the same durable continuation key is rejected with
---     a reference to the existing decision record (no repeated submit/events).
---   - The normalized `error` / `completed` adapter events are acknowledged but are
---     NOT terminal here: the adapter's terminal callback owns the transition.
---
local schema = require("maxa.runtime.schema")
local events = require("maxa.runtime.events")
local conversation = require("maxa.runtime.conversation")
local session_mod = require("maxa.runtime.session")
local tools = require("maxa.runtime.tools")
local decide = require("maxa.runtime.orchestrator.decide")
local clock_mod = require("maxa.runtime.clock")
local watchdog_mod = require("maxa.runtime.orchestrator.watchdog")
local normalize = require("maxa.runtime.protocol.normalize")
-- Protocol registry: needed by :use_provider_record for the offline mock fallback
-- and to bind real adapters (no cycle: protocol never requires orchestrator).
local protocol = require("maxa.runtime.protocol")

local M = {}

--- Durable continuation key (request-orchestrator §Continuation decision
--- table): (session_generation, source_request_id, tool_batch_id|none,
--- decision_kind). Same-key second decisions are rejected with a reference to
--- the existing decision record.
---@param generation integer session generation of the source request
---@param request_id string source request id
---@param batch_id string|nil terminal tool batch id (nil when none)
---@param kind string decision kind (decide.kinds.*)
---@return string key
local function continuation_key(generation, request_id, batch_id, kind)
  return table.concat({
    tostring(generation),
    tostring(request_id),
    batch_id and tostring(batch_id) or "none",
    kind,
  }, ":")
end

--- Park the AgentLoop (no continuation): state -> waiting_for_user.
---@param self table orchestrator
local function park_loop(self)
  self.session.loop.state = session_mod.loop_states.waiting_for_user
end

--- Re-arm the AgentLoop on a fresh manual submit (new user turn): state ->
--- armed. Automatic continuations never re-arm (they keep the armed state set
--- by the continue decision).
---@param self table orchestrator
local function rearm_loop(self)
  self.session.loop.state = session_mod.loop_states.armed
end

M.name = "orchestrator"

--- Resolve an event bus (defaults to the global events module).
---@param bus? table
---@return table
local function resolve_bus(bus)
  return bus or events
end

--- Ordinal key for an event name (used to detect the first chunk reliably).
--- The phase-0 event-set constants live on the bus (`events`), falling back to the
--- literal names when a custom bus does not expose them.
---@param bus table
---@param key string constant key
---@return string
local function event_name(bus, key)
  if bus and bus.events and bus.events[key] then
    return bus.events[key]
  end
  return ({
    request_submitted = "request.submitted",
    request_started = "request.started",
    response_started = "response.started",
    message_delta = "message.delta",
    reasoning_delta = "reasoning.delta",
    tool_call_started = "tool_call.started",
    tool_call_delta = "tool_call.delta",
    tool_call_completed = "tool_call.completed",
    usage_updated = "usage.updated",
    response_completed = "response.completed",
    response_failed = "response.failed",
    response_cancelled = "response.cancelled",
    tool_batch_started = "tool_batch.started",
    tool_batch_draining = "tool_batch.draining",
    tool_batch_finished = "tool_batch.finished",
    tool_call_finished = "tool_call.finished",
    continuation_decided = "continuation.decided",
    soft_stop_requested = "chat.soft_stop_requested",
    soft_stop_completed = "chat.soft_stop_completed",
    watchdog_retry = "watchdog.retry",
  })[key]
end

--- Resolve the final normalized usage for a completed request: a provider-final
--- snapshot wins; otherwise a local estimate fills the unknown fields
--- (streaming-usage §Usage: local estimates mark source: local_estimate).
---@param cur table _current record (usage/buff/input_chars)
---@return table usage normalized usage snapshot
local function final_usage(cur)
  local usage = cur.usage
  if usage and (usage.final == true or usage.source == "provider_final") then
    return usage
  end
  return normalize.local_estimate({
    input_chars = cur.input_chars,
    output_chars = cur.buff and #cur.buff or 0,
  })
end

--- Classify a provider error into a runtime error code: the granular transport
--- class (cause.class) maps to the W2 error families; otherwise the adapter's
--- own code is kept verbatim.
---@param err table|nil typed error from the provider stream
---@return string code schema.ERROR.*
local function classify_error_code(err)
  if err and err.cause and type(err.cause.class) == "string" then
    return normalize.class_to_code(err.cause.class)
  end
  return (err and err.code) or schema.ERROR.INTERNAL
end

--- W6 orchestrator config defaults (supermax-configuration `orchestrator`
--- section). tool_concurrency is parsed but the executor still runs
--- sequentially this wave (>1 does not activate parallelism).
local ORCHESTRATOR_DEFAULTS = {
  tool_concurrency = 1,
  watchdog = {
    enabled = false,
    timeout_ms = 180000,
    max_retries = 3,
  },
  context_stop = {
    enabled = false,
  },
}

--- Default context window (tokens) used by the default usage provider when the
--- provider record does not declare `context_window`. 128K is a common mid-range
--- assumption; declare `provider.definitions.*.context_window` for accuracy.
local DEFAULT_CONTEXT_WINDOW = 128000

--- Build the default usage provider for context-stop (W6): prefers the latest
--- normalized provider usage snapshot (`_current.usage` from usage_updated
--- events); falls back to a deterministic local estimate over the message stack
--- (~4 chars/token). The context window comes from the provider record's
--- `context_window` (config) or the default.
---@param orch table orchestrator (self)
---@return fun(): table usage snapshot { tokens, context_window, ratio, source }
local function default_usage_provider(orch)
  return function()
    local window = (orch.provider_record and orch.provider_record.context_window) or DEFAULT_CONTEXT_WINDOW
    local usage = orch._current and orch._current.usage
    local total = usage
      and (
        usage.total_tokens
        or (usage.input_tokens ~= nil and usage.output_tokens ~= nil and usage.input_tokens + usage.output_tokens)
      )
    if total then
      return { tokens = total, context_window = window, ratio = total / window, source = "provider" }
    end
    -- Local deterministic estimate: serialize each message and count chars.
    local chars = 0
    local stack = orch:_stack()
    for msg in stack:iter() do
      chars = chars + #vim.json.encode(msg)
    end
    local tokens = math.max(1, math.floor(chars / 4))
    return { tokens = tokens, context_window = window, ratio = tokens / window, source = "local_estimate" }
  end
end

--- Recursively copy a plain table (drops metatables/frozen proxies) so a config
--- Snapshot sub-view can be merged into the defaults safely.
---@param v any
---@return any
local function plain_copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, val in pairs(v) do
    out[k] = plain_copy(val)
  end
  return out
end

--- Resolve the orchestrator configuration from the caller options: a raw
--- `orchestrator_config` table wins; otherwise a config Snapshot's
--- `orchestrator` section (frozen proxy is unfrozen before merging). Merged
--- over ORCHESTRATOR_DEFAULTS.
---@param opts table orchestrator.new options
---@return table merged orchestrator config
local function resolve_orchestrator_config(opts)
  local src
  if type(opts.orchestrator_config) == "table" then
    src = opts.orchestrator_config
  elseif type(opts.config) == "table" and type(opts.config.get) == "function" then
    local section = opts.config:get("orchestrator")
    if type(section) == "table" then
      src = plain_copy(section)
    end
  end
  if type(src) ~= "table" then
    return vim.tbl_deep_extend("force", {}, ORCHESTRATOR_DEFAULTS)
  end
  return vim.tbl_deep_extend("force", {}, ORCHESTRATOR_DEFAULTS, plain_copy(src))
end

--- Create an orchestrator.
---@param opts? table {
---   session?:    table, a session instance (default: a fresh session via session_mod),
---   provider?:   table, a provider adapter implementing the unified stream surface,
---   events?:     table, event bus (default: global events),
---   conversation?: table, the conversation module (default: required),
---   model?:      string, display/schema model label (default "mock-model", passthrough),
---   project_id?: string, session project id (forwarded to session creation),
---   clock?:      table|nil deterministic clock (W2): { now_ms, schedule,
---                cancel_timer } forwarded to the fresh session (transition
---                stamps) and stored as `self.clock` for timer-driven work
---                (watchdog W7). When a session is supplied, `self.clock`
---                defaults to the session's own clock; nil otherwise (consumers
---                fall back to clock.default()).
---   tool_handlers?: table, injected ToolBatch handler table (W4; phase-3
---                replaces this with the real registry): name -> { run, cancel,
---                mode = "sync"|"async" } (see lua/maxa/runtime/tools/init.lua),
---   config?:      table|nil config Snapshot (.maxa/runtime.yaml) whose
---                `orchestrator` section seeds the orchestrator config (W6),
---   orchestrator_config?: table|nil raw orchestrator config table (wins over
---                opts.config; merged over ORCHESTRATOR_DEFAULTS) (W6),
---   usage_provider?: fun(): table|nil|undefined injectable usage snapshot
---                ({ ratio = number }) for context-stop (W6; real token stats
---                land in phase 4/5),
--- }
---@return table orchestrator
function M.new(opts)
  opts = opts or {}
  local bus = resolve_bus(opts.events)
  local conv = opts.conversation or conversation
  local session = opts.session
    or session_mod.new({
      project_id = opts.project_id,
      events = bus,
      clock = opts.clock,
    })
  -- W6 config resolution is hoisted so the watchdog (W7) can be constructed
  -- with the same resolved `orchestrator` section in the same table literal.
  local orch_config = resolve_orchestrator_config(opts)
  local self = setmetatable({
    session = session,
    clock = opts.clock or session._clock, -- effective clock for watchdog/timers (W2)
    provider = opts.provider, -- set via :use_provider
    provider_record = nil, -- resolved config record (set via :use_provider_record)
    _real_adapter = false, -- true when the bound provider is a real protocol adapter
    events = bus,
    conversation = conv,
    model = opts.model or "mock-model",
    tool_handlers = opts.tool_handlers or {}, -- injected handler table (W4)
    _active_executor = nil, -- running ToolBatch executor (W4; cancelled by :stop())
    _stop_requested = false, -- W4/W6 hard-stop marker: stop() sets it; feeds the
    -- decision-table `stop` input slot (suppresses continuation even if the
    -- current work completed normally). Reset on every accepted submit.
    _soft_stop_requested = false, -- W6 soft-stop marker: soft_stop() sets it;
    -- feeds the decision-table `soft_stop` input slot (drain -> wait). Reset on
    -- every accepted submit.
    orchestrator_config = orch_config, -- W6 config section
    -- W7 watchdog observation engine (orchestrator/watchdog.lua): clock-driven
    -- no_message/no_progress detection with a bounded retry budget. Disabled by
    -- default (no timers; retry_budget slot stays nil/not wired).
    _watchdog = watchdog_mod.new({
      clock = opts.clock or session._clock or clock_mod.default(),
      bus = bus,
      session_id = session.id,
      config = orch_config.watchdog or {},
    }),
    _retry_backoff = nil, -- W7 pending retry backoff timer handle (cancellable)
    _shutting_down = false, -- W8: best-effort teardown (shutdown) in progress;
    -- rejects ALL late provider/tool callbacks (quiet exit; no new work).
    _context_stop = { -- W6 context-stop state (one-shot armed -> consumed)
      enabled = false,
      target_ratio = nil, -- 0..1 usage ratio that triggers the stop
      triggered = false, -- armed -> consumed exactly once
      arm_error = nil, -- typed error when config-driven arming failed (fail-closed)
    },
    usage_provider = nil, -- W6 usage snapshot source; set right after construction
    -- (default local estimator unless the caller injected one)
    messages = nil, -- message stack created lazily on first submit
    _current = nil, -- { request=..., handle=..., started=bool, buff=string,
    --                reasoning=string, tool_calls=table[], finish_reason=string|nil,
    --                usage=table|nil, input_chars=int, terminal=bool }
  }, { __index = M })
  -- W6 default usage provider: makes context-stop usable out of the box (real
  -- token stats land in phase 4/5; the default prefers the latest normalized
  -- provider usage snapshot and falls back to a deterministic local estimate).
  self.usage_provider = opts.usage_provider or default_usage_provider(self)
  -- W7: watchdog fire -> orchestrator termination + continuation decision point
  -- (the module owns only the observation state machine and budget counters).
  self._watchdog.on_fired = function(reason)
    self:_watchdog_fired(reason)
  end
  -- W6 config-driven context-stop arming: `context_stop: { enabled, target }`
  -- from `.maxa/runtime.yaml` (or raw orchestrator_config). Arming is
  -- fail-closed: an invalid target or unavailable usage keeps the limit
  -- disabled and records the typed error.
  local cs_cfg = self.orchestrator_config.context_stop
  if cs_cfg and cs_cfg.enabled and cs_cfg.target ~= nil then
    local ok, err = self:context_stop_arm(cs_cfg.target)
    if not ok then
      self._context_stop.arm_error = err
    end
  end
  if opts.provider_record then
    self:use_provider_record(opts.provider_record)
  end
  return self
end

--- Attach/replace the provider adapter (unified stream surface).
---@param provider table provider implementing stream/parse_stream/normalize_usage
function M:use_provider(provider)
  self.provider = provider
  self.provider_record = nil
  self._provider_params = nil
  self._real_adapter = false
  return self
end

--- Attach a resolved config provider record (config.resolve_provider output).
--- Real provider path (plan §4.8): when the protocol adapter is registered AND an
--- api key is available, the adapter is bound and streamed through the transport
--- (the adapter owns transport/sse). Without a key or adapter (offline dev/UI)
--- the local mock provider is bound so the Chat view keeps working; the record's
--- model label is still applied for display.
---@param record table normalized provider record from config.resolve_provider
---@param opts? table {
---   params?: table pre-built adapter setup params (W10 host wiring: flattened
---     model/base_url/api_key_env/connect_timeout_ms/timeout_ms/proxy_env, plus
---     anthropic url/headers). When absent the raw record is passed to
---     adapter:setup as before (the record carries timeouts nested under
---     `request`, so pre-built params are required for full request options).
--- }
---@return self
function M:use_provider_record(record, opts)
  opts = opts or {}
  self.provider_record = record
  self._provider_params = opts.params or nil
  self._real_adapter = false
  if record and record.adapter and type(record.api_key) == "string" and record.api_key ~= "" then
    self.provider = record.adapter
    self.model = record.model or self.model
    self._real_adapter = true
  else
    self.provider = protocol.get(protocol.providers.mock)
    if record then
      self.model = record.model or self.model
    end
  end
  return self
end

--- Attach/replace the injected ToolBatch handler table (W4; phase-3 replaces
--- this with the real registry). Handlers are captured by the executor at
--- batch creation time.
---@param handlers table name -> { run=fn(args, ctx, task), cancel=fn()|nil, mode="sync"|"async" }
---@return self
function M:use_tool_handlers(handlers)
  self.tool_handlers = handlers or {}
  return self
end

---@return boolean true when a request is currently in flight.
function M:is_busy()
  return self.session:is_busy()
end

--- Ensure a message stack exists and return it.
---@return table stack
function M:_stack()
  if not self.messages then
    self.messages = self.conversation.new_stack()
  end
  return self.messages
end

--- Hard-cancel the current work (W6 control op `cancel`; the W4 M:stop body).
--- Idempotent: safe to call repeatedly; only the first cancel reaches a
--- terminal state. Returns true when this call performed the cancel.
--- Phase-0/W8 path: cancel the in-flight provider stream (terminal CANCELLED).
--- W4 path: when the provider stream already completed and a ToolBatch is
--- running (request tool_pending), cancel the batch executor — running handler
--- tasks get handler.cancel(), every non-terminal call is marked cancelled
--- (CAS), the batch drains to terminal cancelled, and results are persisted.
--- Unlike stop(), cancel() sets NO suppression marker: the terminal-cancelled
--- request already yields terminate in the decision table, and the session
--- returns to waiting_for_user (recoverable by a new manual submit).
---@param reason? string diagnostic reason (default "explicit cancel")
---@return boolean cancelled
function M:cancel(reason)
  -- W7: a cancel in flight suppresses watchdog observation (defensive; the
  -- terminal-cancelled response stops the watchdog anyway).
  self._watchdog:pause("cancel")
  local cur = self._current
  -- 1) Provider stream in flight.
  if cur and cur.handle and not cur.terminal then
    -- provider handle.cancel is a closure; it deliberately takes no `self` and at
    -- most an optional on-cancelled callback. Calling it with `cur.handle` (a
    -- table) as that callback would crash ("attempt to call a table value") once
    -- the cancel wins the terminal transition. Call zero-arg and read the return.
    local ok, res = pcall(cur.handle.cancel)
    if ok and res then
      return res
    end
    return false
  end
  -- 2) Tool-batch phase (W4): cancel the running executor (propagates to tasks).
  local exec = self._active_executor
  if exec and not exec:is_terminal() then
    return exec:cancel(reason or "explicit cancel")
  end
  return false
end

--- Terminate the current work AND suppress any continuation (W6 control op
--- `stop`; chat-runtime-state: "stop: terminates current work and prevents
--- continuation"). Implementation = cancel() + hard stop marker + session ->
--- stopped:
---   1. `_stop_requested = true` BEFORE the cancel so the batch drain's
---      synchronous decision point sees the `stop` input slot (even if the
---      provider ignored the cancel and the work completed, the decision table
---      returns wait — no automatic continuation);
---   2. cancel() (provider stream or executor drain, exactly the W4 path);
---   3. after the drain/terminal the session moves to `stopped` (the explicit
---      stop transition; recoverable — not closed, close is still possible).
--- :MaxaStop keeps its terminal-cancelled host behavior: the host View:stop()
--- path cancels the provider handle directly and the session returns to
--- waiting_for_user (this stronger orchestrator stop is the programmatic/UI
--- control op for "stop + no continuation").
--- Idempotent: returns false when there is nothing to cancel (no marker, no
--- session transition).
---@param reason? string diagnostic reason (default "explicit stop")
---@return boolean cancelled
function M:stop(reason)
  reason = reason or "explicit stop"
  local cur = self._current
  local exec = self._active_executor
  local has_work = (cur and cur.handle and not cur.terminal) or (exec and not exec:is_terminal())
  if not has_work then
    return false
  end
  -- 1) Suppress continuation BEFORE the cancel: the drain decision point must
  -- see the marker (W6 decision-table `stop` slot -> wait). The watchdog is
  -- paused for the same window and any pending retry backoff is cancelled (the
  -- user's stop wins over queued automatic retries).
  self._stop_requested = true
  self._watchdog:pause("stop")
  self:_cancel_retry_backoff()
  -- 2) Hard cancel (provider stream or executor drain).
  local cancelled = self:cancel(reason)
  -- 3) Explicit stop moves the session to `stopped` (chat-runtime-state legal
  -- transition; after the synchronous drain/terminal the session is back at
  -- waiting_for_user, and the stop transition is legal from there).
  self.session:stop(reason)
  return cancelled
end

--- Soft stop (W6 control op `soft_stop`; chat-runtime-state: "drains current
--- response/tool batch, then prevents continuation"). Never cancels the
--- provider or the tool executor: the current response/tool batch drains to
--- its natural terminal state, results are persisted, and the continuation
--- decision table sees the `soft_stop` input slot -> wait (AgentLoop parks at
--- waiting_for_user; the next manual submit re-arms).
--- Acceptance rules (downstream chat_soft_stop alignment):
---   * busy-only: an idle or closed session is rejected with a typed error;
---   * a repeat request while already armed TOGGLES the request off (the drain
---     may then continue normally).
---@return table { accepted = boolean, toggled_off = boolean|nil, error = table|nil }
function M:soft_stop()
  if self.session:is_closed() then
    return {
      accepted = false,
      error = schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s is closed; cannot soft stop"):format(self.session.id),
        nil,
        true
      ),
    }
  end
  if not self.session:is_busy() then
    return {
      accepted = false,
      error = schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("soft stop rejected: session %s is not busy (state %s); soft stop only drains active work"):format(
          self.session.id,
          self.session.state
        ),
        { session_id = self.session.id, state = self.session.state },
        false
      ),
    }
  end
  if self._soft_stop_requested then
    -- Repeat request while armed: toggle off (downstream toggle semantics).
    self._soft_stop_requested = false
    -- W7: the drain window is over; the watchdog resumes a fresh observation
    -- window (the stuck request may still be in flight).
    self._watchdog:resume("soft_stop")
    self.events.emit(event_name(self.events, "soft_stop_requested"), {
      session_id = self.session.id,
      requested = false,
      source = "manual",
    })
    return { accepted = false, toggled_off = true }
  end
  self._soft_stop_requested = true
  -- W7: soft-stop drain suppresses watchdog observation (W6 semantics: the
  -- drain is bounded by the natural request terminal, which stops the watchdog).
  self._watchdog:pause("soft_stop")
  self.events.emit(event_name(self.events, "soft_stop_requested"), {
    session_id = self.session.id,
    requested = true,
    source = "manual",
  })
  return { accepted = true }
end

--- Inject the context-stop usage provider (W6 test seam; real token statistics
--- land in phase 4/5). The provider returns a usage snapshot ({ ratio = number,
--- 0..1 }) or nil (unavailable -> fail-closed: checks never trigger).
---@param fn? fun(): table|nil
---@return self
function M:set_usage_provider(fn)
  self.usage_provider = fn or nil
  return self
end

--- Parse a context-stop target into a 0..1 usage ratio.
---   number 0-100        -> absolute percent (n/100)
---   string "85" / "85%" -> absolute percent
---   string "+10"        -> relative: current_ratio + 10/100 (requires usage)
---@param target number|string
---@param current_ratio? number current usage ratio (needed for relative targets)
---@return number|nil ratio
---@return string|nil err message
local function parse_context_target(target, current_ratio)
  if type(target) == "number" then
    if target < 0 or target > 100 then
      return nil, ("context-stop target must be 0-100 (got %s)"):format(tostring(target))
    end
    return target / 100, nil
  end
  if type(target) ~= "string" then
    return nil, "context-stop target must be a number (percent) or string"
  end
  local s = vim.trim(target)
  local relative = false
  if s:sub(1, 1) == "+" then
    relative = true
    s = vim.trim(s:sub(2))
  end
  local num = s:match("^(%d+%.?%d*)%%?$")
  local value = num and tonumber(num)
  if not value or value < 0 then
    return nil, ("invalid context-stop target %q"):format(tostring(target))
  end
  local ratio = value / 100
  if relative then
    if type(current_ratio) ~= "number" then
      return nil, "relative context-stop target requires current usage (usage unavailable)"
    end
    ratio = current_ratio + ratio
    if ratio > 1 + 1e-9 then
      return nil,
        ("context-stop target %q would exceed 100%% (current %s%%)"):format(
          tostring(target),
          string.format("%.2f", current_ratio * 100)
        )
    end
  elseif ratio > 1 + 1e-9 then
    return nil, ("context-stop target must be 0-100 (got %q)"):format(tostring(target))
  end
  return ratio, nil
end

--- Arm the context-stop limit (W6). One-shot: after the target is reached the
--- limit is consumed (triggered) and never fires again until re-armed.
--- Fail-closed: usage unavailable at arm time -> NOT armed (typed error; the
--- previous armed state, if any, is cleared).
---@param target number|string absolute percent (number, "85", "85%") or relative ("+10")
---@return boolean ok
---@return table|nil err typed error when arming failed
function M:context_stop_arm(target)
  local usage = self.usage_provider and self.usage_provider()
  if not usage or type(usage.ratio) ~= "number" then
    self._context_stop = { enabled = false, target_ratio = nil, triggered = false }
    return false,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        "context-stop arm failed: usage unavailable (fail-closed; inject usage_provider)",
        nil,
        false
      )
  end
  local ratio, perr = parse_context_target(target, usage.ratio)
  if not ratio then
    self._context_stop = { enabled = false, target_ratio = nil, triggered = false }
    return false, schema.new_error(schema.ERROR.INVALID_ARGUMENT, perr, nil, false)
  end
  self._context_stop = { enabled = true, target_ratio = ratio, triggered = false }
  return true
end

--- Disarm the context-stop limit (W6). Any armed state and trigger are cleared.
---@return self
function M:context_stop_disarm()
  self._context_stop = { enabled = false, target_ratio = nil, triggered = false }
  return self
end

--- W6 context-stop checkpoint: check the armed usage limit exactly once. When
--- the current usage ratio reaches the target, the limit is consumed
--- (triggered = one-shot) and the caller applies the boundary:
---   * busy drain boundary (_decide_continuation): the context_stop input slot
---     makes the decision table return wait — the drained work is persisted and
---     the next automatic continuation is suppressed (the runtime equivalent of
---     "busy -> one-shot soft stop");
---   * automatic-submit entry (idle): the continuation submit is rejected.
--- The observable `chat.soft_stop_requested` event (source = "context_stop")
--- fires exactly once at the trigger. Fail-closed: usage unavailable -> never
--- triggers.
---@return boolean reached true when this call consumed the limit (one-shot)
function M:_context_stop_check()
  local cs = self._context_stop
  if not cs or not cs.enabled or cs.triggered then
    return false
  end
  local usage = self.usage_provider and self.usage_provider()
  if not usage or type(usage.ratio) ~= "number" then
    return false -- fail-closed: no trigger without usage
  end
  if usage.ratio + 1e-9 < cs.target_ratio then
    return false
  end
  cs.triggered = true -- armed -> consumed (one-shot)
  -- W7: the context-stop boundary suppresses watchdog observation (the drain
  -- ends at a request terminal, which stops the watchdog).
  self._watchdog:pause("context_stop")
  self.events.emit(event_name(self.events, "soft_stop_requested"), {
    session_id = self.session.id,
    requested = true,
    source = "context_stop",
  })
  return true
end

--- Request ownership check (W3 upgrade): a terminal callback must act only on the
--- request that created it. Ownership requires BOTH the request id AND its
--- session generation to match the current active request — a stale callback for
--- a superseded request (different id OR different generation) is ignored
--- without mutation.
---@param cur table current _current record
---@param request table the request that owns this callback
---@return boolean
local function is_owned(cur, request)
  return cur and cur.request and cur.request.id == request.id and cur.request.generation == request.generation
end

--- Emit `request.started` + `response.started` exactly once per request. The
--- first content-bearing normalized event (response_started / message_delta /
--- reasoning_delta / tool_call_started) triggers it; mock/echo emit no
--- response_started, so the first-delta path covers them too.
---@param self table orchestrator
---@param cur table _current record
local function mark_started(self, cur)
  if cur.started then
    return
  end
  cur.started = true
  self._current.started = true
  -- W7: the first content-bearing event is progress: the watchdog switches from
  -- no_message to no_progress timing (fresh observation window).
  self._watchdog:mark_progress("response.started")
  -- W4: drive the request entity through its canonical lifecycle (submitted ->
  -- starting -> streaming) so the tool_pending transition (from streaming) is
  -- legal when the completed response carries tool calls. Record-only: valid
  -- transitions never emit bus events (W8 bus contract stays additive).
  session_mod.transition(cur.request, "start", {
    session = self.session,
    reason = "provider response started",
  })
  session_mod.transition(cur.request, "stream", {
    session = self.session,
    reason = "provider stream content",
  })
  self.events.emit(event_name(self.events, "request_started"), {
    session_id = self.session.id,
    request_id = cur.request.id,
    generation = cur.request.generation,
    turn_id = cur.request.id,
  })
  self.events.emit(event_name(self.events, "response_started"), {
    session_id = self.session.id,
    request_id = cur.request.id,
    generation = cur.request.generation,
    turn_id = cur.request.id,
  })
end

--- Tool-call summary for the terminal response.completed payload.
---@param cur table _current record (tool_calls)
---@return table[] list of { call_id, name }
local function tool_calls_summary(cur)
  local out = {}
  for _, tc in ipairs(cur.tool_calls or {}) do
    out[#out + 1] = { call_id = tc.call_id, name = tc.name }
  end
  return out
end

--- Build the ToolBatch call records from the accumulated provider tool calls,
--- preserving provider order as `ordinal` (tool-runtime §Batch and concurrency
--- policy: sequential default, ordinal-ordered persistence).
---@param cur table _current record (tool_calls)
---@return table[] list of { call_id, name, arguments, ordinal, provider_id }
local function batch_calls(cur)
  local out = {}
  for i, tc in ipairs(cur.tool_calls or {}) do
    out[i] = {
      call_id = tc.call_id,
      name = tc.name,
      arguments = tc.arguments,
      ordinal = i,
      provider_id = tc.provider_id,
    }
  end
  return out
end

--- Persist the assistant turn into the message stack as content parts.
--- The committed assistant message stores normalized parts only (reasoning,
--- text, tool_call parts — W8), never raw provider envelopes.
---@param cur table _current record (request/buff/reasoning/tool_calls)
local function persist_assistant(self, cur)
  local parts = {}
  local reasoning = cur.reasoning or ""
  if reasoning ~= "" then
    parts[#parts + 1] = self.conversation.reasoning_part(reasoning, {
      provider = (self.provider and self.provider.name) or nil,
      retained = true,
    })
  end
  local text = cur.buff or ""
  if text ~= "" then
    parts[#parts + 1] = self.conversation.text_part(text)
  end
  for _, tc in ipairs(cur.tool_calls or {}) do
    -- Empty JSON object stays an object (fixture contract: empty JSON objects
    -- remain objects); the schema rejects empty-string arguments.
    local args = tc.arguments
    if type(args) ~= "string" or args == "" then
      args = "{}"
    end
    local opts = {}
    if type(tc.provider_id) == "string" then
      opts.provider_id = tc.provider_id
    end
    parts[#parts + 1] = self.conversation.tool_call_part(tc.call_id, tc.name, args, opts)
  end
  self
    :_stack()
    :add_message({ role = "assistant", content = parts }, { idctx = self:_stack().idctx, turn_id = cur.request.id })
end

--- Actually run the provider stream and wire the unified callbacks. This is
--- delegated from :submit so a single submit can be made deterministic in tests.
---@param cur table _current record (request, buff, started, terminal)
---@param async boolean|nil drive provider asynchronously (UI) or synchronously (tests)
---@return table provider handle (active/cancel)
local function run_stream(self, cur, async)
  local provider = self.provider
  assert(provider, "orchestrator:submit: no provider attached; call :use_provider()")

  local buff = {}
  local function append(text)
    buff[#buff + 1] = text
    return table.concat(buff)
  end

  local callback = {
    -- Normalized event consumer (protocol.normalize shapes; W8 full set).
    -- Every content-bearing event is accumulated into `cur` and forwarded to the
    -- bus; tool calls are RECORDED as tool_call parts (never executed — tool
    -- batching/continuation is a phase-2 concern).
    on_event = function(event)
      if self._shutting_down then
        return -- W8 exit teardown: reject all late provider events (quiet)
      end
      if not is_owned(self._current, cur.request) then
        return -- late event for a superseded request: rejected
      end
      if self._current.terminal then
        return
      end
      local etype = event and event.type
      if etype == normalize.events.response_started then
        mark_started(self, cur)
      elseif etype == normalize.events.message_delta then
        mark_started(self, cur)
        -- W7: provider activity resets the watchdog observation window.
        self._watchdog:mark_progress("message.delta")
        local text = (event and event.delta) or ""
        local full = append(text)
        self._current.buff = full
        cur.buff = full
        self.events.emit(event_name(self.events, "message_delta"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          delta = text,
          text = full,
        })
      elseif etype == normalize.events.reasoning_delta then
        mark_started(self, cur)
        -- W7: provider activity resets the watchdog observation window.
        self._watchdog:mark_progress("reasoning.delta")
        local delta = (event and event.delta) or ""
        local full = (cur.reasoning or "") .. delta
        if event and type(event.text) == "string" then
          full = event.text -- full accumulated text wins when provided
        end
        self._current.reasoning = full
        cur.reasoning = full
        self.events.emit(event_name(self.events, "reasoning_delta"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          delta = delta,
          text = full,
        })
      elseif etype == normalize.events.tool_call_started then
        mark_started(self, cur)
        local call_id = event and event.call_id
        local name = (event and event.name) or "?"
        if type(call_id) == "string" and call_id ~= "" then
          -- Track for persistence; dedupe by stable call id.
          local exists = false
          for _, c in ipairs(cur.tool_calls) do
            if c.call_id == call_id then
              exists = true
              break
            end
          end
          if not exists then
            cur.tool_calls[#cur.tool_calls + 1] = {
              call_id = call_id,
              name = name,
              arguments = "",
              provider_id = event.provider_id,
            }
          end
        end
        self.events.emit(event_name(self.events, "tool_call_started"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          call_id = call_id,
          name = name,
        })
      elseif etype == normalize.events.tool_args_delta then
        -- W7: provider activity resets the watchdog observation window.
        self._watchdog:mark_progress("tool_args.delta")
        local call_id = event and event.call_id
        local fragment = (event and event.fragment) or ""
        for _, c in ipairs(cur.tool_calls) do
          if c.call_id == call_id then
            c.arguments = c.arguments .. fragment -- UTF-8 byte-wise accumulation
            break
          end
        end
        self.events.emit(event_name(self.events, "tool_call_delta"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          call_id = call_id,
          fragment = fragment,
        })
      elseif etype == normalize.events.tool_call_completed then
        -- W7: provider activity resets the watchdog observation window.
        self._watchdog:mark_progress("tool_call.completed")
        local call_id = event and event.call_id
        local name
        for _, c in ipairs(cur.tool_calls) do
          if c.call_id == call_id then
            name = c.name
            -- The completed event carries the fully accumulated encoded args
            -- (authoritative over delta fragments).
            if type(event.encoded_args) == "string" and event.encoded_args ~= "" then
              c.arguments = event.encoded_args
            end
            break
          end
        end
        self.events.emit(event_name(self.events, "tool_call_completed"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          call_id = call_id,
          name = name,
          arguments = event and event.encoded_args,
        })
      elseif etype == normalize.events.usage_updated then
        -- W7: usage snapshots count as provider progress (reset the watchdog).
        self._watchdog:mark_progress("usage.updated")
        -- Latest normalized snapshot wins; a provider-final snapshot is kept as-is
        -- by final_usage (streaming-usage: final correction is traceable).
        if event and event.usage then
          self._current.usage = event.usage
          cur.usage = event.usage
          self.events.emit(event_name(self.events, "usage_updated"), {
            session_id = self.session.id,
            request_id = cur.request.id,
            generation = cur.request.generation,
            turn_id = cur.request.id,
            usage = event.usage,
          })
        end
      elseif etype == normalize.events.finish_reason then
        if type(event.reason) == "string" then
          self._current.finish_reason = event.reason
          cur.finish_reason = event.reason
        end
      end
      -- error / completed normalized events are acknowledged but are NOT terminal
      -- here: the adapter's terminal callback (on_done/on_error) owns the
      -- exactly-once terminal transition (adapter contract).
    end,
    on_done = function()
      if self._shutting_down then
        return -- W8 exit teardown: late terminal callbacks cannot revive work
      end
      if not is_owned(self._current, cur.request) or self._current.terminal then
        return
      end
      self._current.terminal = true
      cur.terminal = true
      persist_assistant(self, cur)
      local usage = final_usage(cur)
      local calls = cur.tool_calls or {}
      if #calls == 0 then
        -- Text-only path (W8 verbatim): terminal decision + finish + event.
        if cur.intent then
          -- Record the terminal decision on the submit intent (idempotent replay
          -- source; overwrites the in_flight decision set at async submit time).
          self.session:set_intent_decision(cur.intent, {
            state = "completed",
            request = cur.request,
            terminal_state = "completed",
            ok = true,
            usage = usage,
            finish_reason = cur.finish_reason,
            tool_calls = tool_calls_summary(cur),
          })
        end
        self.session:finish_request(cur.request, "completed")
        -- W5 AgentLoop: a text-only completion is a turn boundary with no
        -- continuation decision point; park the loop (waiting_for_user).
        park_loop(self)
        -- W6: the drain completed — a soft-stop request is consumed here (the
        -- text-only path has no continuation decision point to consume it).
        -- The context-stop checkpoint also runs at this busy drain boundary so
        -- an armed usage limit is consumed (one-shot) even without a tool
        -- batch (spec: "reaching a context target while busy requests one-shot
        -- soft stop"; the text-only turn has no continuation to suppress, but
        -- the limit must not stay armed past its boundary).
        local ss_draining = self._soft_stop_requested
        local ctx_reached = self:_context_stop_check()
        self._soft_stop_requested = false
        if ss_draining or ctx_reached then
          self.events.emit(event_name(self.events, "soft_stop_completed"), {
            session_id = self.session.id,
            request_id = cur.request.id,
            generation = cur.request.generation,
            turn_id = cur.request.id,
            reason = ctx_reached and "context_stop" or "soft_stop",
          })
        end
        self.events.emit(event_name(self.events, "response_completed"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          usage = usage,
          finish_reason = cur.finish_reason,
          tool_calls = tool_calls_summary(cur),
        })
        -- W7: response terminal stops the watchdog observation (timer removed).
        self._watchdog:stop()
        return
      end

      -- W4 tool-call path: request -> tool_pending, then execute the ToolBatch.
      -- The provider response IS complete (response.completed fires here with
      -- the tool_calls summary); the request's terminal transition and the
      -- intent decision are deferred to the batch barrier
      -- (_on_batch_terminal), which also owns the continuation decision.
      session_mod.transition(cur.request, "tool_pending", {
        session = self.session,
        reason = "response carries tool calls; ToolBatch executes",
      })
      self.events.emit(event_name(self.events, "response_completed"), {
        session_id = self.session.id,
        request_id = cur.request.id,
        generation = cur.request.generation,
        turn_id = cur.request.id,
        usage = usage,
        finish_reason = cur.finish_reason,
        tool_calls = tool_calls_summary(cur),
      })
      local batch, berr = self.session:new_tool_batch({ calls = batch_calls(cur) })
      if not batch then
        -- Defensive: the batch could not be created (no active request); the
        -- request cannot proceed and must not hang.
        self.session:finish_request(cur.request, "failed")
        self.events.emit(event_name(self.events, "response_failed"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          error = {
            code = schema.ERROR.INTERNAL,
            message = "tool batch creation failed: " .. tostring(berr and berr.message or "?"),
            terminal = true,
          },
        })
        return
      end
      local exec = tools.new_executor({
        session = self.session,
        batch = batch,
        conversation = self.conversation,
        stack = self:_stack(),
        handlers = self.tool_handlers or {},
        events = self.events,
        clock = self.clock,
        request = cur.request,
        on_terminal = function(_, summary)
          self:_on_batch_terminal(cur, batch, summary)
        end,
      })
      self._active_executor = exec
      -- W7: local tool execution is excluded from stall detection (spec: the
      -- watchdog does not classify long local tool execution as provider stall).
      -- The batch barrier (_on_batch_terminal) stops the watchdog; a later
      -- automatic continuation starts a fresh observation window.
      self._watchdog:pause("tool")
      exec:run_all()
    end,
    on_error = function(err)
      if self._shutting_down then
        return -- W8 exit teardown: late terminal callbacks cannot revive work
      end
      if not is_owned(self._current, cur.request) or self._current.terminal then
        return
      end
      self._current.terminal = true
      cur.terminal = true
      cur.last_error = err -- retained for the sync submit result path
      local code = classify_error_code(err)
      local terminal_state = "failed"
      local ev = "response_failed"
      if code == schema.ERROR.CANCELLED then
        terminal_state = "cancelled"
        ev = "response_cancelled"
      end
      if cur.intent then
        -- Terminal failure decision for the submit intent (replayable; the
        -- retry submit links its new request generation to this failed request).
        self.session:set_intent_decision(cur.intent, {
          state = terminal_state, -- "failed" | "cancelled"
          request = cur.request,
          terminal_state = terminal_state,
          ok = false,
          error = err,
        })
      end
      self.session:finish_request(cur.request, terminal_state)
      self.events.emit(event_name(self.events, ev), {
        session_id = self.session.id,
        request_id = cur.request.id,
        generation = cur.request.generation,
        turn_id = cur.request.id,
        error = {
          code = code,
          message = (err and err.message) or tostring(err),
          cause = (err and err.cause) or nil,
          terminal = true,
        },
      })
      -- W7: response terminal stops the watchdog observation (timer removed).
      self._watchdog:stop()
    end,
  }

  local params = {
    model = self.model,
    async = async,
  }
  -- Forward extra stream params (chunks / recording / delay / error / cancel) so the
  -- host / tests can drive the mock/echo provider deterministically.
  if self._last_params then
    for k, v in pairs(self._last_params) do
      if k ~= "model" and k ~= "async" then
        params[k] = v
      end
    end
  end

  if self._real_adapter and self.provider_record then
    -- Real provider path (plan §4.8): adapter:setup(record) then adapter:stream.
    -- The transport lives inside the adapter; params.normalized carries the
    -- normalized conversation snapshot (message-context-target §Normalized records).
    -- W10: the host may pre-build the setup params (flattened timeouts/proxy_env,
    -- anthropic url/headers) via use_provider_record(record, { params = ... });
    -- without them the raw record is passed to setup as before.
    -- A start failure is surfaced as a terminal error through the same callback
    -- (exactly-once), with a no-op handle so :stop() stays safe.
    local record = self.provider_record
    local sp, serr = provider.setup(provider, self._provider_params or record)
    if not sp then
      callback.on_error(schema.new_error(schema.ERROR.CONFIGURATION, tostring(serr), nil, true))
      return {
        active = false,
        cancel = function()
          return false
        end,
      }
    end
    params = sp
    params.model = self.model or sp.model
    params.normalized = { messages = self:_stack():to_table(), tools = {} }
    -- Preserve host-provided setup extras that adapter:setup normalized away
    -- (e.g. anthropic_messages url/headers: setup() does not carry them, but
    -- stream() requires them — live.lua merges them into st_params the same way).
    if self._provider_params then
      for k, v in pairs(self._provider_params) do
        if params[k] == nil then
          params[k] = v
        end
      end
    end
    local handle, herr = provider.stream(provider, params, callback)
    if not handle then
      callback.on_error(schema.new_error(schema.ERROR.PROVIDER, tostring(herr), nil, true))
      return {
        active = false,
        cancel = function()
          return false
        end,
      }
    end
    return handle
  end

  return provider.stream(provider, params, callback)
end
---@return table[] list of { call_id, name }
function M:_unpaired_tool_calls()
  local stack = self:_stack()
  local calls = {}
  local n = stack:len()
  for i = 1, n do
    local msg = stack:get(i)
    if msg and msg.role == "assistant" then
      for _, part in ipairs(msg.content or {}) do
        if part.type == "tool_call" and type(part.call_id) == "string" then
          local paired = false
          -- Only messages AFTER the owning assistant message can pair.
          for j = i + 1, n do
            local later = stack:get(j)
            if later and later.role == "tool" then
              for _, rpart in ipairs(later.content or {}) do
                if rpart.type == "tool_result" and rpart.call_id == part.call_id then
                  paired = true
                  break
                end
              end
            end
            if paired then
              break
            end
          end
          if not paired then
            calls[#calls + 1] = { call_id = part.call_id, name = part.name }
          end
        end
      end
    end
  end
  return calls
end

--- Restore-agent-loop repair (W5): every orphan assistant tool_call part (no
--- paired tool result anywhere after it) gets a synthetic cancelled tool result
--- injected IMMEDIATELY after the owning assistant message, mirroring the
--- downstream orphan-pairing safety (chat_agent_loop_auto_restore). The part
--- carries provenance "restore_repair"; the tool message carries the same
--- provenance record. Idempotent: a repaired call is paired, so a second pass
--- injects nothing new.
---@param self table orchestrator
---@return integer injected number of synthetic results injected
function M:_repair_orphan_tool_calls()
  local stack = self:_stack()
  local injected = 0
  -- Collect orphan calls per owning assistant message index FIRST (scanning
  -- must not be confused by messages inserted during the pass).
  local orphans = {} -- idx -> { call_id, name }
  local i = 0
  for msg in stack:iter() do
    i = i + 1
    if msg.role == "assistant" then
      for _, part in ipairs(msg.content or {}) do
        if part.type == "tool_call" and type(part.call_id) == "string" then
          local paired = false
          local j = 0
          for later in stack:iter() do
            j = j + 1
            if j > i and later.role == "tool" then
              for _, rpart in ipairs(later.content or {}) do
                if rpart.type == "tool_result" and rpart.call_id == part.call_id then
                  paired = true
                  break
                end
              end
            end
            if paired then
              break
            end
          end
          if not paired then
            orphans[i] = orphans[i] or {}
            orphans[i][#orphans[i] + 1] = { call_id = part.call_id, name = part.name }
          end
        end
      end
    end
  end
  -- Inject in DESCENDING message order so earlier insert positions stay valid.
  for idx = #stack.messages, 1, -1 do
    local list = orphans[idx]
    if list then
      -- Inject AFTER the owning assistant message: for a stable order within
      -- one assistant message, insert at idx+1 in ascending call order.
      for c = #list, 1, -1 do
        local call = list[c]
        local part = self.conversation.tool_result_part(
          call.call_id,
          "cancelled",
          "[synthetic] tool call interrupted before execution (restore-agent-loop)",
          { is_error = true, provenance = "restore_repair" }
        )
        stack:insert_message(idx + 1, { role = "tool", content = { part } }, {
          turn_id = (self.messages and self.messages:get(idx) and self.messages:get(idx).turn_id) or nil,
          provenance = { source = "restore_repair" },
        })
        injected = injected + 1
      end
    end
  end
  return injected
end

--- batch's terminal state, records the submit-intent decision, then runs the
--- W5 continuation decision point: pure decision table -> durable-key dedup ->
--- continuation.decided (once per key) -> execute (continue submits exactly
--- one automatic request; wait/fail/terminate park the AgentLoop).
---@param cur table _current record of the owning request
---@param batch table ToolBatch entity (terminal)
---@param summary table[] per-call summary (executor output)
---@return table|nil result _decide_continuation result (replayed decisions
---   still return the existing record reference)
function M:_on_batch_terminal(cur, batch, summary)
  -- W8 ownership closure: only the CURRENT request's executor may run the
  -- barrier consequences. A stale executor callback (superseded request,
  -- cleared _current after close/shutdown) is rejected without mutation; the
  -- exit teardown path is quiet (session close records the cancellation).
  if not cur or self._shutting_down or self._current ~= cur then
    self._active_executor = nil
    return
  end
  self._active_executor = nil
  -- W7: the request reaches its terminal at the batch barrier; the watchdog
  -- observation ends here (a continue decision restarts it on the next
  -- request.submitted with a fresh window).
  self._watchdog:stop()
  local terminal_state = (batch.terminal and batch.terminal.state) or "failed"
  if cur and cur.intent then
    self.session:set_intent_decision(cur.intent, {
      state = terminal_state,
      request = cur.request,
      terminal_state = terminal_state,
      ok = terminal_state == "completed",
      usage = final_usage(cur),
      finish_reason = cur.finish_reason,
      tool_calls = tool_calls_summary(cur),
      tool_batch_id = batch.id,
    })
  end
  self.session:finish_request(cur.request, terminal_state)
  return self:_decide_continuation(cur, batch)
end

--- W5 continuation decision point: decision table (pure) over the committed
--- request/batch/session snapshot + durable-key dedup + exactly-once execution.
--- A second decision for the same durable key is REJECTED: the existing
--- decision record is returned (`result.replayed = true`) and nothing is
--- submitted/emitted/mutated — the terminal-race and restore dedup core.
---@param cur table _current record of the finished request
---@param batch table|nil terminal ToolBatch entity (nil for text-only requests)
---@param known_ctx_reached? boolean|nil W7 watchdog path: the context-stop
---   checkpoint was already consumed by the watchdog fire (one-shot); passing it
---   avoids re-running the check (which would return false after consumption and
---   let the retry/fail decision bypass the context boundary).
---@param retry_budget_override? integer|nil W7 watchdog path: the remaining
---   retry budget captured BEFORE the retry reservation. The decision table
---   must see the budget that INCLUDES the retry being scheduled (fire #n
---   reserves retry n and the decision still sees max_retries - (n-1) > 0, so
---   the LAST allowed retry executes; only the fire AFTER the last retry sees
---   0 -> fail). nil = compute from the watchdog as usual.
---@return table result {
---   decision?=table,   decision-table output,
---   key?=string,       durable continuation key,
---   record?=table,     decision record (new or existing),
---   replayed?=boolean, true when the key was already decided (no execution),
---   submit?=table,     automatic submit result (kind == "continue"),
--- }
function M:_decide_continuation(cur, batch, known_ctx_reached, retry_budget_override)
  local loop = self.session.loop
  -- W6 context-stop checkpoint (busy path): the armed usage limit is checked
  -- BEFORE the continuation decision. Reaching the target consumes the limit
  -- (one-shot) and feeds the context_stop input slot -> decision wait, so the
  -- current drain suppresses the next automatic continuation. On the W7
  -- watchdog path the checkpoint may already be consumed by the fire handler
  -- (known_ctx_reached=true) — it must still feed the decision slot.
  local ctx_reached = known_ctx_reached or self:_context_stop_check()
  -- W6: capture the pending manual soft-stop request BEFORE the drain consumes
  -- it, so the completion boundary event can fire exactly once below.
  local ss_pending = self._soft_stop_requested == true
  -- W7: retry budget = remaining watchdog budget (nil when the watchdog is
  -- disabled = slot not wired; the decision table only retries retryable codes
  -- WITH budget > 0). Watchdog stalls terminate the stuck request as `timeout`
  -- (retryable), so the retry row is reached exactly once per reserved retry;
  -- exhaustion (remaining 0) yields fail(retry_budget_exhausted). The watchdog
  -- fire path overrides this with the PRE-reservation remaining (so the retry
  -- being scheduled still sees budget > 0).
  local retry_budget
  if retry_budget_override ~= nil then
    retry_budget = retry_budget_override
  else
    retry_budget = (self._watchdog and self._watchdog:remaining_budget()) or nil
  end
  -- Decision-table input: committed snapshot + external input slots. W6 wires
  -- the three control slots: stop (hard stop marker), soft_stop (soft_stop()
  -- request), context_stop (armed usage limit reached); retry budget is the W7
  -- slot, compaction phase 4.
  local decision = decide.decide({
    session = { state = self.session.state, generation = self.session.generation },
    request = {
      id = cur.request.id,
      generation = cur.request.generation,
      terminal = cur.request.terminal,
      error_code = cur.last_error and classify_error_code(cur.last_error) or nil,
    },
    batch = batch and {
      id = batch.id,
      terminal = batch.terminal,
    } or nil,
    loop = loop,
    unpaired_tool_calls = self:_unpaired_tool_calls(),
    inputs = {
      stop = self._stop_requested == true,
      soft_stop = self._soft_stop_requested == true,
      context_stop = ctx_reached,
      retry_budget = retry_budget,
      compaction = false,
    },
  })
  local key = continuation_key(cur.request.generation, cur.request.id, batch and batch.id or nil, decision.kind)
  local record = {
    key = key,
    kind = decision.kind,
    session_generation = cur.request.generation,
    source_request_id = cur.request.id,
    tool_batch_id = batch and batch.id or nil,
    at = (self.clock and self.clock.now_ms and self.clock.now_ms()) or os.time() * 1000,
    request_id = nil, -- filled after a continue submit
    intent_id = nil, -- filled after a continue submit
  }
  local ok, rres = self.session:record_loop_decision(key, record)
  if not ok then
    -- Persistence boundary failure (spec §Persistence/event order: failure to
    -- persist a required boundary stops continuation and yields failure).
    return { rejected = true, error = rres, decision = decision, key = key }
  end
  if not rres.changed then
    -- Same key decided twice: reject; return the existing record reference.
    -- No submit, no event, no loop mutation (terminal-race / restore dedup).
    return { replayed = true, decision = decision, key = key, record = rres.record }
  end
  record = rres.record
  -- Loop minimal-state update: continue keeps the loop armed and advances the
  -- iteration counter; every other kind parks the loop.
  loop.decision_key = key
  if decision.kind == decide.kinds.continue then
    loop.iteration = decision.iteration
    loop.state = session_mod.loop_states.armed
  elseif decision.kind == decide.kinds.retry then
    -- W7: a retry preserves the original turn (no user boundary), so the loop
    -- stays armed: a completed retry tool batch may still continue the AgentLoop.
    loop.state = session_mod.loop_states.armed
  else
    park_loop(self)
  end
  -- Additive event: exactly once per durable key (after the batch terminal
  -- event, before the scheduled next intent — spec §Persistence/event order).
  -- W6: carries the decision reason too (stop/soft_stop/context_stop wait
  -- boundaries are distinguishable by consumers).
  self.events.emit(event_name(self.events, "continuation_decided"), {
    session_id = self.session.id,
    request_id = cur.request.id,
    generation = cur.request.generation,
    turn_id = cur.request.id,
    tool_batch_id = batch and batch.id or nil,
    decision_kind = decision.kind,
    decision_reason = decision.reason,
    decision_key = key,
  })
  -- W6: the drain boundary consumed the soft-stop request (whether the
  -- decision waited on it or a hard stop/context stop won). A fresh manual
  -- submit re-arms; an automatic continuation never happens while the flag was
  -- set (the decision table returns wait). The completion boundary event fires
  -- exactly once here when a pending soft-stop request or a context-stop
  -- trigger was consumed by this drain (never on the continue path: a pending
  -- soft stop / reached context target always yields wait).
  self._soft_stop_requested = false
  if ss_pending or ctx_reached then
    self.events.emit(event_name(self.events, "soft_stop_completed"), {
      session_id = self.session.id,
      request_id = cur.request.id,
      generation = cur.request.generation,
      turn_id = cur.request.id,
      tool_batch_id = batch and batch.id or nil,
      -- The consumed soft-stop source: a manual request ("soft_stop") or a
      -- context-stop trigger ("context_stop"). When a hard stop raced the
      -- drain, the boundary reason is observable via continuation.decided
      -- (decision_reason=stop); this event still reports the soft-stop source.
      reason = ctx_reached and "context_stop" or "soft_stop",
    })
  end
  if decision.kind == decide.kinds.continue then
    local res = self:submit("", {
      kind = "automatic",
      intent_id = ("auto:%s"):format(batch.id),
      provider_params = {},
    })
    if res and res.request then
      record.request_id = res.request.id
      record.intent_id = res.intent and res.intent.id
    end
    return { decision = decision, key = key, record = record, submit = res }
  end
  if decision.kind == decide.kinds.retry then
    -- W7: schedule ONE retry after a cancellable clock-driven backoff; the
    -- retry submit creates a new request generation linked to the failed
    -- request (kind="retry" + retry_of, W3 chain). The timer is cancelled by a
    -- manual submit / stop / close (manual submit has precedence over queued
    -- automatic retries at the ready boundary). The submit itself re-validates
    -- the boundary (idle session + retry_of terminal-failed), so a raced
    -- manual submit / close is safely rejected.
    self:_cancel_retry_backoff()
    local clock = self.clock or clock_mod.default()
    local backoff_ms = (self._watchdog and self._watchdog:backoff_ms()) or 1000
    local timer = clock.schedule(backoff_ms, function()
      self._retry_backoff = nil
      local res = self:submit("", {
        kind = "retry",
        retry_of = cur.request.id,
        provider_params = {},
      })
      if res and res.request then
        record.request_id = res.request.id
        record.intent_id = res.intent and res.intent.id
      end
    end)
    self._retry_backoff = timer
    record.backoff_ms = backoff_ms
    return { decision = decision, key = key, record = record }
  end
  -- wait / fail / terminate / repair / compaction: recorded + loop parked;
  -- execution is wired in later waves (repair already happened during restore;
  -- compaction is a phase-4 transaction).
  return { decision = decision, key = key, record = record }
end

--- Cancel a pending retry backoff timer (W7). Idempotent; safe when idle.
function M:_cancel_retry_backoff()
  if self._retry_backoff then
    local clock = self.clock or clock_mod.default()
    clock.cancel_timer(self._retry_backoff)
    self._retry_backoff = nil
  end
end

--- W7 watchdog fire: the watched request produced no expected progress within
--- the observation window. The orchestrator:
---   1. lets the context-stop boundary win when it was reached (one-shot);
---   2. reserves one retry (watchdog.retry event) while the budget remains;
---   3. terminates the stuck request as a terminal `timeout` failure (exactly
---      one response.failed; exhaustion carries reason "watchdog_exhausted");
---   4. routes through the continuation decision point with the remaining
---      retry budget — retry schedules a cancellable backoff + retry submit,
---      fail(retry_budget_exhausted) parks the loop (Chat unlocked).
--- Local tool execution can never reach here (paused) — belt-checked anyway.
---@param reason "no_message"|"no_progress"
function M:_watchdog_fired(reason)
  if self._shutting_down then
    return -- W8 exit teardown: no new work while shutting down
  end
  local cur = self._current
  local wd = self._watchdog
  if not wd or not wd.enabled or not cur or cur.terminal then
    return -- no watch / already terminal: nothing to repair
  end
  if not wd:is_active(cur.request) then
    return -- stale watch (request superseded): ignore
  end
  -- Belt: never repair while a local tool executor is running (the pause path
  -- already cancels the timer) or a stop/soft-stop/context-stop boundary is
  -- pending (W6 semantics: the drain is the user's boundary, not a stall).
  local exec = self._active_executor
  if (exec and not exec:is_terminal()) or self._stop_requested or self._soft_stop_requested then
    return
  end
  -- Context-stop boundary wins over retry: consume the one-shot limit and let
  -- the decision table wait(context_stop) — no retry reservation.
  local ctx_reached = self:_context_stop_check()
  local exhausted = false
  -- Capture the remaining budget BEFORE the reservation: the decision table
  -- must see the budget that INCLUDES the retry being scheduled (fire #n
  -- reserves retry n and the decision still sees max_retries - (n-1) > 0, so
  -- the LAST allowed retry executes; only the fire AFTER the last retry sees
  -- 0 -> fail(retry_budget_exhausted)).
  local retry_budget = (not ctx_reached) and wd:remaining_budget() or nil
  if not ctx_reached and wd:can_retry() then
    wd:reserve_retry(reason)
  elseif not ctx_reached then
    exhausted = true
  end
  self:_terminate_stuck_request(cur, schema.ERROR.TIMEOUT, reason, exhausted)
  -- The known context state and the pre-reservation budget are passed through
  -- so the decision point neither re-runs the (already consumed) one-shot
  -- checkpoint nor sees the post-reservation (decremented) budget.
  self:_decide_continuation(cur, nil, ctx_reached, retry_budget)
end

--- Force the terminal-failed transition of a stuck request (W7): the provider
--- stream never delivered a terminal callback, so the orchestrator owns the
--- exactly-once terminal here. The provider handle is cancelled best-effort;
--- any late callback is rejected by the terminal/ownership guards. Emits
--- response.failed exactly once with the watchdog error (+ counters; the
--- exhausted variant adds top-level reason "watchdog_exhausted").
---@param cur table _current record of the stuck request
---@param code string schema.ERROR.* code (timeout)
---@param reason "no_message"|"no_progress"
---@param exhausted boolean true when the retry budget is exhausted
function M:_terminate_stuck_request(cur, code, reason, exhausted)
  local wd = self._watchdog
  local timeout_ms = (wd and wd.timeout_ms) or 180000
  local msg = ("watchdog: %s within %dms (request %s)"):format(
    reason == "no_message" and "no message received" or "no progress",
    timeout_ms,
    cur.request.id
  )
  local err = schema.new_error(code, msg, { watchdog = reason, watchdog_timeout_ms = timeout_ms }, true)
  -- Best-effort: stop the hung provider handle (the terminal is forced here;
  -- a late provider terminal callback is rejected by the terminal guard).
  if cur.handle and type(cur.handle.cancel) == "function" then
    pcall(cur.handle.cancel)
  end
  cur.terminal = true
  cur.last_error = err
  if cur.intent then
    self.session:set_intent_decision(cur.intent, {
      state = "failed",
      request = cur.request,
      terminal_state = "failed",
      ok = false,
      error = err,
    })
  end
  self.session:finish_request(cur.request, "failed")
  self.events.emit(event_name(self.events, "response_failed"), {
    session_id = self.session.id,
    request_id = cur.request.id,
    generation = cur.request.generation,
    turn_id = cur.request.id,
    error = {
      code = code,
      message = msg,
      cause = { watchdog = reason, watchdog_timeout_ms = timeout_ms },
      terminal = true,
    },
    -- Additive W7 fields: the watchdog counters and, on exhaustion, the
    -- terminal reason "watchdog_exhausted" (single terminal failure event).
    watchdog = {
      retry_count = (wd and wd.retry_count) or 0,
      max_retries = (wd and wd.max_retries) or 0,
      reason = reason,
      exhausted = exhausted,
    },
    reason = exhausted and "watchdog_exhausted" or nil,
  })
  -- W7: the request is terminal — observation ends (timer removed).
  self._watchdog:stop()
end

--- Rebuild a submit result from a recorded intent decision (idempotent replay).
--- The same intent_id never starts a second provider request; the caller
--- receives the same request object reference (or an equivalent terminal
--- snapshot) recorded by the first submit.
---@param self table orchestrator
---@param intent table intent record (kind/decision)
---@return table result
local function replay_result(self, intent)
  local d = intent.decision
  local out = { replayed = true, intent = intent }
  if not d then
    out.pending = true
    return out
  end
  if d.rejected then
    out.rejected = true
    out.error = d.error
    return out
  end
  if d.request then
    out.request = d.request
  end
  out.terminal_state = d.terminal_state
  out.ok = d.terminal_state == "completed"
  out.usage = d.usage
  if d.async then
    out.async = true
    out.in_flight = d.state == "in_flight"
    -- A replay of an in-flight async intent hands back the live handle when the
    -- current _current record still belongs to the same request.
    if self._current and self._current.request == d.request then
      out.handle = self._current.handle
    end
  end
  return out
end

--- Submit through the loop: submit -> stream -> complete.
--- W3 intent model: every submit records an immutable submit intent (kind,
--- expected session generation, input/context revision); replaying the same
--- intent_id returns the recorded decision/request and never sends a duplicate
--- provider request. manual keeps the phase-0 guards (duplicate while busy,
--- closed, empty submission); automatic/retry/regenerate/restore apply their
--- W3 policies (no manual user turn; retry links to the failed request;
--- regenerate preserves the user boundary; restore rebuilds from a snapshot).
---@param text string user input (manual kind only; ignored otherwise)
---@param opts? table {
---   intent_id?:           string, immutable intent id (default: generated),
---   kind?:                "manual"|"automatic"|"regenerate"|"restore"|"retry"
---                         (default "manual"),
---   expected_generation?: integer, expected session generation (stale intents
---                         are rejected),
---   turn_id?:             string, provider-neutral turn identity,
---   input_revision?:      string|integer, captured input revision,
---   context_revision?:    string|integer, captured context revision,
---   config_snapshot_id?:  string|nil, configuration snapshot id,
---   retry_of?:            string, failed request id (kind="retry"),
---   snapshot?:            table, { session = Session:snapshot(), messages = stack:to_table() }
---                         (kind="restore"),
---   provider_params?:     table, forwarded to provider.stream (chunks/recording/delay/...),
---   async?:               boolean, drive provider asynchronously (UI); default false (sync,
---                         deterministic, good for headless tests),
--- }
---@return table result {
---   replayed?=boolean,             true when the submit replayed a recorded intent,
---   rejected?=boolean,             true when the submit was refused,
---   error?=table,                  typed error when rejected,
---   diagnostic?=string,            exact composition diagnostic when rejected,
---   intent?=table,                 the submit intent record,
---   archived?=table[]|nil,         regenerate: removed assistant segment,
---   async?=boolean,                true when driven asynchronously (result is the handle),
---   handle?=table,                 provider handle (active/cancel) when async,
---   ok?=boolean,                   true when a sync submit completed successfully,
---   request?=table,                the request record,
---   terminal_state?=string,        completed|failed|cancelled (sync),
---   usage?=table|nil,              normalized usage on sync success,
---   error_record?=table|nil,       typed error on sync failure/cancel,
--- }
function M:submit(text, opts)
  opts = opts or {}
  local kind = opts.kind or "manual"
  if not session_mod.intent_kinds[kind] then
    return {
      rejected = true,
      error = schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("illegal submit intent kind %q (must be one of %s)"):format(
          tostring(kind),
          table.concat(vim.tbl_keys(session_mod.intent_kinds), "|")
        ),
        nil,
        false
      ),
    }
  end

  -- Idempotent replay: the same intent_id returns the recorded decision/request
  -- and never sends a duplicate provider request (submit-intent §Idempotency).
  if type(opts.intent_id) == "string" then
    local existing = self.session:find_intent(opts.intent_id)
    if existing then
      return replay_result(self, existing)
    end
  end

  -- Record the submit attempt (immutable identity + captured expectations).
  local intent, ierr = self.session:new_intent({
    intent_id = opts.intent_id,
    kind = kind,
    turn_id = opts.turn_id,
    expected_generation = opts.expected_generation,
    input_revision = opts.input_revision,
    context_revision = opts.context_revision,
    config_snapshot_id = opts.config_snapshot_id,
  })
  if not intent then
    return { rejected = true, error = ierr }
  end

  --- Record a rejection decision on the intent and build the rejected result.
  ---@param err table typed error
  ---@param extra? table additional result fields (diagnostic/...)
  ---@return table result
  local function rejected(err, extra)
    self.session:set_intent_decision(intent, {
      state = "rejected",
      rejected = true,
      error = err,
    })
    local out = { rejected = true, error = err, intent = intent }
    if extra then
      for k, v in pairs(extra) do
        out[k] = v
      end
    end
    return out
  end

  -- Stale-intent guard: an explicit expected_generation must match the current
  -- session generation (the legal boundary recorded at intent creation).
  if opts.expected_generation ~= nil and opts.expected_generation ~= self.session.generation then
    return rejected(
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("stale submit intent: expected session generation %d but current is %d"):format(
          opts.expected_generation,
          self.session.generation
        ),
        {
          expected_generation = opts.expected_generation,
          current_generation = self.session.generation,
        },
        false
      )
    )
  end

  -- Kind-specific legality checks + input/turn side effects.
  local archived = nil -- regenerate: removed assistant segment (result-carried)
  local input_chars = 0
  if kind == "manual" then
    -- Duplicate-submit guard (plan §4.10): a busy session rejects a second
    -- manual submit WITHOUT creating a second request identity or user turn.
    if self.session:is_busy() then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          "a request is already in progress; duplicate manual submit rejected (phase 0 policy)",
          { session_id = self.session.id },
          false
        )
      )
    end
    if self.session:is_closed() then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("session %s is closed; cannot submit"):format(self.session.id),
          nil,
          true
        )
      )
    end
    -- Submission validation (message-context-target §Submission validation):
    -- empty-submit is refused before any request identity is created.
    local vres = self.conversation.validate_submission({ text = text }, {
      project_id = self.session.project_id,
    })
    if not vres.ok then
      return rejected(vres.error, { diagnostic = vres.diagnostic })
    end
    input_chars = #vres.instruction
    -- Persist the visible user input as a manual turn (content parts).
    self:_stack():add_message(
      { role = "user", content = { self.conversation.text_part(vres.instruction) } },
      { idctx = self:_stack().idctx }
    )
  elseif kind == "automatic" then
    -- W6 context-stop checkpoint (idle path): when the armed usage limit is
    -- reached, the automatic continuation submit is blocked (typed rejection,
    -- no request, no user turn) — the user takes over at the boundary. The
    -- limit is consumed exactly once; manual submits are unaffected.
    if self:_context_stop_check() then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("automatic continuation submit rejected: context-stop target reached (session %s)"):format(self.session.id),
          { session_id = self.session.id, context_stop = true },
          false
        )
      )
    end
    -- W3 policy: automatic continuation submits are legal only at an idle
    -- boundary; while the session is not idle (busy/stopped/closed/...) the
    -- submit is rejected WITHOUT a request and WITHOUT a user turn (the legal
    -- automatic timing is wired by the W5 continuation decision).
    if not self.session:is_idle() then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("automatic continuation submit rejected: session %s is not idle (state %s)"):format(
            self.session.id,
            self.session.state
          ),
          { session_id = self.session.id, state = self.session.state },
          false
        )
      )
    end
    -- No manual user turn is created for automatic continuation.
  elseif kind == "retry" then
    local retry_of = opts.retry_of
    local failed = retry_of and self.session:find_request(retry_of) or nil
    if not failed then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("retry submit requires opts.retry_of to reference an existing request (got %q)"):format(tostring(retry_of)),
          nil,
          false
        )
      )
    end
    if not (failed.terminal and failed.terminal.state == "failed") then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("retry submit requires the referenced request %s to be terminal-failed (state %s)"):format(
            retry_of,
            tostring(failed.terminal and failed.terminal.state or failed.state)
          ),
          { request_id = retry_of },
          false
        )
      )
    end
    -- No new user turn: the retry reuses the original turn's messages.
  elseif kind == "regenerate" then
    if not self.session:is_idle() then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("regenerate submit rejected: session %s is not idle (state %s)"):format(self.session.id, self.session.state),
          { session_id = self.session.id, state = self.session.state },
          false
        )
      )
    end
    -- Preserve the user boundary: truncate everything after the last user
    -- message (the prior assistant attempt incl. tool calls/results is
    -- archived on the result). No new user message is added.
    archived = self:_stack():truncate_after_last_user()
    if not archived then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          "regenerate submit requires a user message boundary in the message stack",
          nil,
          false
        )
      )
    end
  elseif kind == "restore" then
    local snap = opts.snapshot
    if type(snap) ~= "table" then
      return rejected(
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          "restore submit requires opts.snapshot (Session:snapshot + messages to_table)",
          nil,
          false
        )
      )
    end
    -- Rebuild the message stack BEFORE mutating the session so a malformed
    -- snapshot cannot partially restore state.
    local restored_stack
    if type(snap.messages) == "table" then
      local ok, st = pcall(self.conversation.stack_from_table, snap.messages)
      if not ok then
        return rejected(
          schema.new_error(
            schema.ERROR.INVALID_ARGUMENT,
            "restore submit: invalid snapshot messages: " .. tostring(st),
            nil,
            false
          )
        )
      end
      restored_stack = st
    end
    local rok, rerr = self.session:restore(type(snap.session) == "table" and snap.session or snap)
    if not rok then
      return rejected(rerr)
    end
    if restored_stack then
      self.messages = restored_stack
    end
    -- W5 restore-agent-loop: repair orphan assistant tool_call parts (no
    -- paired tool result) with synthetic cancelled results (provenance
    -- "restore_repair") so the restored stack never carries a malformed
    -- tool_call/tool_result pairing into the next submit.
    self:_repair_orphan_tool_calls()
  end

  -- Store forwarding params for provider.stream.
  self._last_params = opts.provider_params or {}

  -- Start a new request through the session (advances generation, session -> busy).
  local request, start_err = self.session:start_request({
    intent = kind,
    retry_of = kind == "retry" and opts.retry_of or nil,
  })
  if not request then
    return rejected(start_err)
  end

  -- A new accepted submit starts a fresh chain: any earlier stop marker (W4)
  -- and soft-stop request (W6) apply only to the chain they interrupted, not
  -- to later manual work.
  self._stop_requested = false
  self._soft_stop_requested = false
  -- W5 AgentLoop: a fresh MANUAL submit re-arms the loop (new user turn);
  -- automatic continuations never re-arm (the continue decision keeps armed).
  if kind == "manual" then
    -- W7: a manual submit resets the watchdog retry budget (downstream
    -- semantics: manual submit resets the count; watchdog auto-submits do NOT)
    -- and cancels any pending retry backoff (manual submit has precedence over
    -- queued automatic retries at the ready boundary).
    self._watchdog:reset()
    self:_cancel_retry_backoff()
    rearm_loop(self)
  end

  -- Carry the request (request identity for stale-callback checks) + the intent
  -- (terminal decision recording for idempotent replay).
  local cur = {
    request = request,
    intent = intent,
    buff = "",
    reasoning = "", -- accumulated reasoning text (reasoning_delta)
    tool_calls = {}, -- ordered { call_id, name, arguments, provider_id } records
    finish_reason = nil, -- latest finish_reason label
    started = false,
    terminal = false,
    handle = nil,
    usage = nil, -- latest normalized usage from usage_updated events
    input_chars = input_chars,
  }
  self._current = cur

  self.events.emit(event_name(self.events, "request_submitted"), {
    session_id = self.session.id,
    request_id = request.id,
    generation = request.generation,
    turn_id = request.id,
    intent = kind,
    intent_id = intent.id,
  })

  -- W7: watchdog observation starts at request.submitted (fresh no_message
  -- window per request generation; the retry budget is preserved across a
  -- watchdog retry chain and reset only by a manual submit).
  self._watchdog:start(request)

  local async = not not opts.async
  local handle = run_stream(self, cur, async)
  cur.handle = handle

  if async then
    self.session:set_intent_decision(intent, {
      state = "in_flight",
      request = request,
      async = true,
    })
    return { ok = true, async = true, handle = handle, request = request, intent = intent, archived = archived }
  end

  -- Synchronous completion: headless/tests observe the final state here.
  -- The provider stream has already run to terminal (drive_sync). Return the result.
  local result = {
    ok = request.terminal and request.terminal.state == "completed",
    request = request,
    terminal_state = request.terminal and request.terminal.state or nil,
    intent = intent,
    archived = archived,
  }
  if result.terminal_state == "completed" then
    result.usage = final_usage(cur)
  elseif request.state == session_mod.request_states.tool_pending then
    -- W4: sync submit whose ToolBatch is still running (async handlers). The
    -- batch completes asynchronously through task.complete; the barrier and the
    -- continuation run then. Not a failure: no error_record is set.
    result.tool_pending = true
  else
    result.error_record = schema.new_error(
      classify_error_code(cur.last_error or nil),
      "request did not complete (see terminal_state); phase-1 sync submit",
      { terminal_state = result.terminal_state },
      result.terminal_state == "cancelled"
    )
  end
  return result
end

--- @return table snapshot { session = table, busy = boolean, model = string }
function M:snapshot()
  return {
    session = self.session:snapshot(),
    busy = self.session:is_busy(),
    model = self.model,
  }
end

--- Restore-agent-loop entry (W5): rebuild session/loop/message-stack state from
--- an in-memory snapshot ({ session = Session:snapshot(), messages =
--- stack:to_table() }), repair orphan assistant tool_call pairings (synthetic
--- cancelled results with provenance "restore_repair"), and keep the
--- durable-loop-decision dedup guarantee (restored loop.decisions are
--- authoritative: the same continuation key is never decided twice).
--- Thin semantic wrapper over submit kind="restore" (which owns the repair).
---@param snapshot table { session = table, messages = table[]|nil }
---@return table result submit result (rejected on invalid/non-idle snapshot)
function M:restore_agent_loop(snapshot)
  return self:submit("", { kind = "restore", snapshot = snapshot })
end

--- Best-effort cancellation of every owned async handle (W8): the in-flight
--- provider stream handle (if any) and the running ToolBatch executor. Each
--- cancel is pcall-guarded. The provider handle's own cancel may synchronously
--- fire the terminal callback (on_error CANCELLED) — that is the deterministic
--- cancel -> terminal -> cleanup order: `self._current` is still valid while
--- the cancel runs, so the terminal transition/event is processed normally.
---@param reason string diagnostic reason
---@return table { cancelled=boolean, provider=boolean, executor=boolean }
function M:_cancel_owned(reason)
  local out = { cancelled = false, provider = false, executor = false }
  local cur = self._current
  if cur and cur.handle and type(cur.handle.cancel) == "function" and not cur.terminal then
    local ok = pcall(cur.handle.cancel)
    out.provider = true
    out.cancelled = true
    if not ok then
      -- The handle cancel threw; the terminal is still forced by close/shutdown
      -- (session control marks the request cancelled) — never propagate.
      out.cancelled = false
    end
  end
  local exec = self._active_executor
  if exec and not exec:is_terminal() then
    out.executor = true
    out.cancelled = true
    pcall(function()
      exec:cancel(reason)
    end)
  end
  return out
end

--- Close the orchestrator + underlying session. Idempotent. W8 close order is
--- deterministic: CANCEL (provider handle + ToolBatch executor, task
--- propagation + barrier, so owned async work reaches its terminal first) ->
--- TERMINAL (the cancel-driven response.cancelled / batch terminal /
--- continuation decision run while `self._current` is still valid) -> CLEANUP
--- (watchdog stop, retry backoff cancel, reference clear, session:close).
--- A late provider/tool callback after close is rejected by the cleared
--- `_current` ownership guard (no mutation, no revival).
---@return boolean changed
function M:close()
  self:_cancel_owned("orchestrator close")
  -- W7: stop watchdog observation and cancel any pending retry backoff so no
  -- queued automatic retry can fire into a closed session.
  self._watchdog:stop()
  self:_cancel_retry_backoff()
  self._current = nil
  self._last_params = nil
  self._active_executor = nil
  return self.session:close()
end

--- Best-effort runtime teardown (W8 nvim-exit): cancel every closeable owned
--- handle (provider stream, tool executor), stop the watchdog observation and
--- retry backoff timers, then close the session. QUIET by contract: while
--- shutting down, late provider/tool callbacks are rejected (the
--- `_shutting_down` guard in run_stream/_on_batch_terminal) so exit teardown
--- never emits terminal events, never schedules retries and never creates new
--- work; the session close still records the cancelled terminals. Failures are
--- collected into the returned report (never thrown, never re-scheduled).
--- Idempotent: a second shutdown is a no-op returning the same shape.
---@return table report {
---   closed=boolean,   session reached closed,
---   cancelled=table,  labels of handles this call cancelled,
---   failures=table[]  { what=string, error=string } best-effort failures,
--- }
function M:shutdown()
  local report = { closed = self.session:is_closed(), cancelled = {}, failures = {} }
  if self._shutting_down then
    return report -- already tearing down (idempotent)
  end
  if self.session:is_closed() then
    return report -- closed earlier: nothing owned remains
  end
  self._shutting_down = true
  local function attempt(label, fn)
    local ok, err = pcall(fn)
    if not ok then
      report.failures[#report.failures + 1] = { what = label, error = tostring(err) }
    end
    return ok
  end
  local cur = self._current
  if cur and cur.handle and type(cur.handle.cancel) == "function" and not cur.terminal then
    attempt("provider handle", function()
      cur.handle.cancel()
    end)
    report.cancelled[#report.cancelled + 1] = "provider"
  end
  local exec = self._active_executor
  if exec and not exec:is_terminal() then
    attempt("executor", function()
      exec:cancel("runtime shutdown")
    end)
    report.cancelled[#report.cancelled + 1] = "executor"
  end
  attempt("watchdog", function()
    self._watchdog:stop()
  end)
  attempt("retry backoff", function()
    self:_cancel_retry_backoff()
  end)
  -- Cleanup after the cancels: any callback arriving now is rejected by the
  -- `_shutting_down` guard (and the cleared reference below).
  self._current = nil
  self._active_executor = nil
  self._last_params = nil
  attempt("session close", function()
    self.session:close()
  end)
  report.closed = self.session:is_closed()
  return report
end

return M
