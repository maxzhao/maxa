-- filepath: lua/maxa/runtime/tools/init.lua
--- maxa runtime minimal ToolBatch executor (phase-2 W4, phase-3 W1 bridge).
---
--- Scope: executes one ToolBatch entity (session.new_tool_batch output) with
--- injected handler tables AND/OR the phase-3 tool registry. Phase-3 W1 wires
--- the registry: when no injected handler exists for a call name, the executor
--- resolves the definition through `opts.registry` (make_handler), validates
--- the decoded arguments against the registry schema (exact field-path errors,
--- standard invalid-call result), and enforces the definition's timeout_ms for
--- async completions via a deadline (sync handlers cannot be interrupted in
--- the single-threaded runtime; documented limitation).
---
--- Handler contract (injected, test/consumer-owned):
---   handlers[name] = {
---     run    = fn(args, ctx, task) -> result | task | nil,
---     cancel = fn() | nil,          -- best-effort task cancellation
---     mode   = "sync" | "async"     -- default "sync"
---     schema = table|nil,           -- optional: when present, arguments are
---                                   -- validated before execution (W1)
---     timeout_ms = integer|nil,     -- optional: async deadline enforcement (W1)
---     cancellable = boolean|nil,    -- default true: false disables cancel
---   }
---   * sync  mode: run returns the result content (string) directly; the call
---     completes immediately after run returns (pcall-guarded).
---   * async mode: run receives an executor-owned task identity (phase-3 W2:
---     tools/task.lua layer)
---       { id, owner={session_id,request_id,batch_id}, generation,
---         complete(result[, caller]), cancel(reason[, caller]),
---         is_cancelled([caller]), poll([caller]),
---         retain(action, opts), expire(opts) }
---     and either returns it (identity) or completes it later through
---     task.complete. Completion is compare-and-set: once a call is terminal
---     (succeeded/failed/cancelled), a late complete() is ignored with a
---     recorded diagnostic and no mutation. `caller` (optional identity)
---     enables the session/request/generation owner double check on every
---     operation. run may also return a plain string for immediate completion.
---   ctx = { call_id, name, arguments (decoded), raw_arguments, ordinal,
---          session_id, request_id, batch_id, clock }
---
--- Result normalization (provider-facing content):
---   * string                    -> success
---   * { status="error", ... }   -> error   (is_error=true)
---   * { error=true, ... }       -> error
---   * handler throw             -> standard error result (handler_error)
---   * unknown tool / bad JSON   -> standard error result (still participates
---                                 in batch completion, tool-runtime §Call
---                                 lifecycle)
---   * cancellation              -> standard error result (cancelled)
---
--- Persistence (result and UI separation): every terminal call persists its
--- tool_result part into a role="tool" message on the shared message stack
--- BEFORE tool_call.finished and BEFORE the batch barrier. Results for the
--- same call_id merge by appending into the same tool message (aligned to
--- upstream Chat:add_tool_output merge semantics).
---
--- Barrier (exactly once): when every call is terminal, the batch transitions
--- to terminal (completed|cancelled; failed reserved for executor-level
--- failure), tool_batch.finished fires once, then on_terminal(executor,
--- summary) runs. The orchestrator owns continuation from that hook; tool
--- handlers never submit the Chat directly (tool-runtime §Batch policy).
---
--- Cancellation propagation: executor:cancel(reason) marks every non-terminal
--- call cancelled (CAS), invokes each running handler's cancel() best-effort,
--- drains the batch (running -> draining -> cancelled) and runs the barrier.
--- Late async completions after cancellation are ignored.
---
--- Events (additive, constants on the events module):
---   tool_batch.started / tool_batch.draining / tool_batch.finished /
---   tool_call.finished
---
--- Phase-3 W2 additions:
---   * Task identity carries `generation` (owning request generation) and the
---     TTL(result) lifecycle (discard/defer/keep/persist + expire) governs the
---     auxiliary result payload only: provider-facing result content and the
---     persisted tool message are untouched (tool-runtime §Result and UI
---     separation).
---   * Every completed call result receives a default retention record
---     (aux-payload policy, keep-for-session) attached AFTER persistence, so
---     the TTL layer never changes the barrier / persistence order.
---   * Task state is CAS-synced from every terminal path (task.complete, task
---     cancel, timeout boundary, batch cancel) through tools.task.
---
--- It never loads codecompanion.* / mcphub.* / lua/util/hooks/*.

local session_mod = require("maxa.runtime.session")
local jschema = require("maxa.runtime.tools.schema")
local task_mod = require("maxa.runtime.tools.task")

local M = {}

M.name = "tools"

--- Call lifecycle states (tool-runtime §Call lifecycle terminal set).
M.CALL_STATES = {
  pending = "pending",
  running = "running",
  succeeded = "succeeded",
  failed = "failed",
  cancelled = "cancelled",
}

local TERMINAL_CALL_STATES = {
  [M.CALL_STATES.succeeded] = true,
  [M.CALL_STATES.failed] = true,
  [M.CALL_STATES.cancelled] = true,
}

--- Standard error-result content (failure contract: exact identifiers, bounded
--- size, no secret exposure; caller-provided messages are trusted runtime text).
---@param code string stable error code (unknown_tool/invalid_args/...)
---@param message string diagnostic
---@return string content
local function standard_error(code, message)
  return ("tool error [%s]: %s"):format(code, message)
end

--- Normalize a handler/task result value into a result record.
---@param value any
---@return table { status="success"|"error", content=string }
local function normalize_result(value)
  if type(value) == "string" then
    return { status = "success", content = value }
  end
  if type(value) == "table" then
    local is_err = value.error == true or value.status == "error"
    return {
      status = is_err and "error" or "success",
      content = tostring(value.content or ""),
    }
  end
  return { status = "success", content = tostring(value or "") }
end

--- Decode tool-call arguments (JSON text). Schema validation is a phase-3
--- registry concern; this wave validates the encoded arguments only.
---@param arguments any encoded arguments from the provider
---@return boolean ok
---@return table|nil decoded
---@return string|nil err exact JSON diagnostic
local function decode_arguments(arguments)
  if type(arguments) ~= "string" then
    return false, nil, "arguments must be a JSON string"
  end
  local ok, decoded = pcall(vim.json.decode, arguments)
  if not ok or type(decoded) ~= "table" then
    return false, nil, ("invalid JSON arguments: %s"):format(tostring(decoded or "decode failed"))
  end
  return true, decoded, nil
end

-------------------------------------------------------------------------------
-- Executor
-------------------------------------------------------------------------------

local Executor = {}
Executor.__index = Executor

--- Create a ToolBatch executor bound to a session + batch + message stack.
---@param opts table {
---   session:      table, session instance (owner scope for transitions),
---   batch:        table, ToolBatch entity (Session:new_tool_batch output),
---   conversation: table, conversation module (tool_result_part),
---   stack:        table, the orchestrator's message stack (results persisted
---                 into role="tool" messages here),
---   handlers?:    table, name -> handler record (see module header),
---   registry?:    table|nil, phase-3 W1 tool registry (make_handler bridge;
---                 nil keeps the legacy injected-handler-only behavior),
---   provider_tool_ids?: table|nil, W1 wire-name -> registry-id map (built by
---                 the orchestrator when the request tools were filled);
---                 provider calls by the encoded wire name resolve back to the
---                 registry id before registry resolution,
---   events?:      table|nil, event bus (default: no batch events emitted),
---   clock?:       table|nil, { now_ms } deterministic clock (diagnostic),
---   request?:     table|nil, owning request record (identity payloads),
---   on_terminal?: fun(executor, summary), called exactly once at the barrier,
--- }
---@return table executor
function M.new_executor(opts)
  opts = opts or {}
  local session = opts.session
  local batch = opts.batch
  assert(session and batch, "tools.new_executor: session and batch are required")
  local self = setmetatable({
    session = session,
    batch = batch,
    conversation = opts.conversation,
    stack = opts.stack,
    handlers = opts.handlers or {},
    registry = opts.registry, -- phase-3 W1: registry bridge (nil = injected-only)
    provider_tool_ids = opts.provider_tool_ids, -- W1: wire name -> registry id map
    events = opts.events,
    clock = opts.clock,
    request = opts.request, -- identity payload source (session_id/request_id/generation)
    on_terminal = opts.on_terminal,
    session_id = session.id,
    request_id = batch.request_id,
    generation = (opts.request and opts.request.generation) or nil,
    calls = {}, -- ordered call records (batch.calls order == ordinal)
    _started = false,
    _cancelled = false,
    _barrier_done = false,
    _tool_msg_by_call = {}, -- call_id -> stack tool message (merge target)
  }, Executor)

  -- Normalize the batch's call records IN PLACE so the ToolBatch entity is the
  -- single source of truth: execution state/result are visible on batch.calls
  -- for audit, while the executor keeps ordered references in self.calls.
  for i, call in ipairs(batch.calls or {}) do
    if type(call.call_id) ~= "string" or call.call_id == "" then
      -- Spec: missing IDs receive runtime-generated IDs with provenance.
      call.call_id = ("gen:%s:%d"):format(batch.id, i)
      call.provenance = { generated = true, source = "missing_call_id" }
    end
    call.ordinal = call.ordinal or i
    call.state = call.state or M.CALL_STATES.pending
    call.result = call.result or nil
    call.task = nil
    self.calls[#self.calls + 1] = call
  end
  return self
end

---@return boolean true when the batch reached a terminal state (barrier done).
function Executor:is_terminal()
  return self.batch.terminal ~= nil
end

---@return boolean true when every call is terminal (succeeded/failed/cancelled).
function Executor:all_calls_terminal()
  for _, call in ipairs(self.calls) do
    if not TERMINAL_CALL_STATES[call.state] then
      return false
    end
  end
  return true
end

---@return table[] ordered per-call summary
---  { call_id, name, ordinal, status="success"|"error", state, is_error }
function Executor:summary()
  local out = {}
  for _, call in ipairs(self.calls) do
    out[#out + 1] = {
      call_id = call.call_id,
      name = call.name,
      ordinal = call.ordinal,
      status = call.result and call.result.status or "pending",
      state = call.state,
      is_error = call.result and call.result.is_error or false,
    }
  end
  return out
end

--- Transition the owned batch entity through the session reducer.
---@param action string transition action ("run"|"drain"|"terminal")
---@param ctx table transition context
---@return boolean ok
function Executor:transition(action, ctx)
  ctx = ctx or {}
  ctx.session = ctx.session or self.session
  local ok, _, err = session_mod.transition(self.batch, action, ctx)
  if not ok then
    -- The reducer already emitted session.transition_rejected; do not throw.
    return false
  end
  return true
end

--- Emit a batch-scoped bus event (constants on bus.events, literal fallback).
---@param key string events constant key
---@param payload table
function Executor:_emit(key, payload)
  if not self.events then
    return
  end
  local name
  if self.events.events and self.events.events[key] then
    name = self.events.events[key]
  else
    name = ({
      tool_batch_started = "tool_batch.started",
      tool_batch_draining = "tool_batch.draining",
      tool_batch_finished = "tool_batch.finished",
      tool_call_finished = "tool_call.finished",
    })[key]
  end
  self.events.emit(name, payload)
end

--- Shared identity payload prefix for batch events.
---@return table
function Executor:_identity()
  return {
    session_id = self.session_id,
    request_id = self.request_id,
    generation = self.generation,
    batch_id = self.batch.id,
  }
end

--- Run the whole batch sequentially in ordinal order (concurrency=1, W4).
--- Sync handlers complete inline; async handlers leave their calls running and
--- the batch stays running until every task completes (task.complete CAS) or
--- the batch is cancelled.
---@return table { complete=boolean } true when the batch reached terminal
function Executor:run_all()
  if self._started then
    return { complete = self:is_terminal() }
  end
  self._started = true

  local ok = self:transition("run", { reason = "tool batch execution starts" })
  if not ok then
    -- Defensive: the batch transition was rejected; surface a terminal failed
    -- batch so the barrier still opens exactly once (nothing hangs).
    return self:_fail_batch("batch run transition rejected")
  end
  self:_emit(
    "tool_batch_started",
    vim.tbl_extend("force", self:_identity(), {
      calls = #self.calls,
    })
  )

  self:_check_timeouts()
  for _, call in ipairs(self.calls) do
    if self:is_terminal() then
      break -- cancelled between calls (defensive; sync execution cannot interleave)
    end
    self:_execute_call(call)
  end
  self:_check_barrier()
  return { complete = self:is_terminal() }
end

--- Current wall clock (ms). Prefers the deterministic clock seam when present.
---@return integer
function Executor:_now_ms()
  if self.clock and type(self.clock.now_ms) == "function" then
    return self.clock.now_ms()
  end
  if vim.uv and vim.uv.hrtime then
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  return os.time() * 1000
end

--- Resolve the handler for a tool call: injected handlers win (test/consumer
--- injection contract), then a W1 wire-name map entry (provider calls arrive
--- by the encoded name, e.g. `fixture-echo-echo`; the map restores the
--- registry id, so same-named tools stay unambiguous), otherwise the registry
--- generates a handler from the registered definition (phase-3 W1 bridge).
--- Returns nil for unknown tools.
---@param name string tool name
---@return table|nil handler
function Executor:_resolve_handler(name)
  local h = self.handlers and self.handlers[name]
  if h and type(h.run) == "function" then
    return h
  end
  local lookup = name
  if self.provider_tool_ids and self.provider_tool_ids[name] then
    lookup = self.provider_tool_ids[name]
  end
  if self.registry and type(self.registry.make_handler) == "function" then
    return self.registry:make_handler(lookup)
  end
  return nil
end

--- Phase-3 W1: deadline enforcement for tool calls with a declared
--- timeout_ms. A call whose deadline passed while still running is completed
--- as a typed timeout result (cancel propagation best-effort) so a stalled
--- async tool cannot hold the batch barrier forever. Runs on every completion
--- and barrier boundary; a deadline can also be observed by a late
--- task.complete, which produces the same typed timeout result.
function Executor:_check_timeouts()
  if self:is_terminal() then
    return
  end
  for _, call in ipairs(self.calls) do
    if call.state == M.CALL_STATES.running and call.deadline then
      if self:_now_ms() >= call.deadline then
        local h = self:_resolve_handler(call.name)
        if h and h.cancel and h.cancellable ~= false then
          pcall(h.cancel)
        end
        self:_complete_call(call, {
          status = "error",
          content = standard_error("timeout", ("%s timed out after %dms"):format(call.name, call.timeout_ms or 0)),
        })
      end
    end
  end
end

--- Execute one call: validate -> resolve handler -> run (sync/async).
---@param call table call record
function Executor:_execute_call(call)
  if TERMINAL_CALL_STATES[call.state] then
    return -- W8 belt: a cancelled/terminal call is never executed again
  end
  call.state = M.CALL_STATES.running
  call.started_at = self:_now_ms()

  -- JSON argument validation (tool-runtime §Call lifecycle: validate before
  -- execution). Invalid calls produce a standard error result that still
  -- participates in batch completion.
  local okv, decoded, verr = decode_arguments(call.arguments)
  if not okv then
    return self:_complete_call(call, {
      status = "error",
      content = standard_error("invalid_args", ("%s: %s"):format(call.name, verr)),
    })
  end
  local handler = self:_resolve_handler(call.name)
  if not handler then
    return self:_complete_call(call, {
      status = "error",
      content = standard_error("unknown_tool", ("unknown tool %q"):format(tostring(call.name))),
    })
  end
  -- Phase-3 W1: registry-supplied schemas validate arguments before execution.
  -- A schema mismatch is a standard invalid-call result (still participates in
  -- batch completion) with an exact field path (e.g. args.path.required).
  if handler.schema ~= nil then
    local okv2, verr2 = jschema.validate(handler.schema, decoded)
    if not okv2 then
      return self:_complete_call(call, {
        status = "error",
        content = standard_error("invalid_args", ("%s: schema mismatch at args.%s"):format(call.name, verr2)),
      })
    end
  end
  -- Phase-3 W1: timeout_ms from the definition (registry-generated handlers)
  -- is enforced for async completions via a deadline; sync handlers cannot be
  -- interrupted in the single-threaded runtime (documented limitation).
  local timeout_ms = handler.timeout_ms
  if type(timeout_ms) == "number" and timeout_ms > 0 then
    call.timeout_ms = timeout_ms
    call.deadline = self:_now_ms() + timeout_ms
  end

  local ctx = {
    call_id = call.call_id,
    name = call.name,
    arguments = decoded,
    raw_arguments = call.arguments,
    ordinal = call.ordinal,
    session_id = self.session_id,
    request_id = self.request_id,
    batch_id = self.batch.id,
    clock = self.clock,
  }
  local task = self:_make_task(call)
  local mode = handler.mode or "sync"

  if mode == "async" then
    local okr, ret = pcall(handler.run, decoded, ctx, task)
    if not okr then
      return self:_complete_call(call, {
        status = "error",
        content = standard_error("handler_error", ("%s failed: %s"):format(call.name, tostring(ret))),
      })
    end
    if type(ret) == "string" then
      -- Convenience: async handler completed synchronously with a plain result.
      return self:_complete_call(call, { status = "success", content = ret })
    end
    -- Task identity: completion arrives later through task.complete (CAS).
    call.task = (type(ret) == "table" and type(ret.complete) == "function") and ret or task
    return
  end

  local okr, ret = pcall(handler.run, decoded, ctx, task)
  if not okr then
    return self:_complete_call(call, {
      status = "error",
      content = standard_error("handler_error", ("%s failed: %s"):format(call.name, tostring(ret))),
    })
  end
  self:_complete_call(call, { status = "success", content = tostring(ret or "") })
end

--- Create the executor-owned async task identity for a call (owner-scoped;
--- phase-3 W2: tools/task.lua layer — identity/owner/generation, CAS with
--- diagnostics, owner validation). Completion is compare-and-set: a terminal
--- call (incl. cancellation) ignores late complete()/cancel() and records a
--- diagnostic on the task.
---@param call table call record
---@return table task
function Executor:_make_task(call)
  local task = task_mod.create({
    id = ("task:%s:%d"):format(self.batch.id, call.ordinal),
    owner = {
      session_id = self.session_id,
      request_id = self.request_id,
      batch_id = self.batch.id,
    },
    generation = self.generation,
    clock = self.clock,
    resolve = function(value)
      -- Phase-3 W1: a completion arriving after the declared deadline is a
      -- typed timeout result (the deadline is enforced on every boundary too).
      if call.deadline and self:_now_ms() >= call.deadline then
        return {
          status = "error",
          content = standard_error("timeout", ("%s timed out after %dms"):format(call.name, call.timeout_ms or 0)),
        }
      end
      local okn, norm = pcall(normalize_result, value)
      if not okn then
        return {
          status = "error",
          content = standard_error("handler_error", ("%s returned an invalid result"):format(call.name)),
        }
      end
      return norm
    end,
  })
  -- Executor-side completion: the task CAS already decided; the call record is
  -- mutated exactly once (result + persist + emit + barrier). A false CAS
  -- result is a late/owner-rejected completion: ignored, diagnostic recorded.
  local function complete_task(value, caller)
    local ok, res = task_mod.complete(task, value, caller)
    if not ok then
      return false
    end
    self:_complete_call(call, { status = res.status, content = res.content })
    return true
  end
  -- Keep the identity contract: handlers call task.complete(value[, caller]);
  -- `caller` enables the owner double check for stale callbacks.
  task.complete = complete_task
  task.cancel = function(reason, caller)
    local ok = task_mod.cancel(task, reason, caller)
    if not ok then
      return false
    end
    local h = self:_resolve_handler(call.name)
    if h and h.cancel and h.cancellable ~= false then
      pcall(h.cancel)
    end
    return self:_cancel_call(call, reason or "task cancelled")
  end
  task.is_cancelled = function(caller)
    return task_mod.is_cancelled(task, caller)
  end
  task.poll = function(caller)
    return task_mod.poll(task, caller)
  end
  return task
end

--- Terminal completion of a call (CAS): record result, persist the
--- provider-facing tool_result part, attach the default TTL retention
--- metadata, emit tool_call.finished, then check the batch barrier. Late
--- completions for a terminal call are ignored. When the completion did NOT
--- originate from the task path (sync handlers, timeout boundary), the
--- executor-owned task is CAS-synced so poll/is_cancelled stay coherent.
---@param call table call record
---@param result table { status="success"|"error", content=string }
---@return boolean changed true when this call performed the completion
function Executor:_complete_call(call, result)
  if TERMINAL_CALL_STATES[call.state] then
    return false
  end
  local status = result.status == "error" and "error" or "success"
  if call.task and not task_mod.is_terminal(call.task) then
    task_mod._set_terminal(call.task, status, {
      status = status,
      content = tostring(result.content or ""),
      is_error = status == "error",
    }, "complete")
  end
  call.state = status == "success" and M.CALL_STATES.succeeded or M.CALL_STATES.failed
  call.result = {
    call_id = call.call_id,
    name = call.name,
    ordinal = call.ordinal,
    status = status,
    content = tostring(result.content or ""),
    is_error = status == "error",
    state = call.state,
  }
  self:_persist_result(call)
  self:_attach_retention(call)
  self:_emit(
    "tool_call_finished",
    vim.tbl_extend("force", self:_identity(), {
      call_id = call.call_id,
      name = call.name,
      ordinal = call.ordinal,
      status = status,
      state = call.state,
      is_error = call.result.is_error,
    })
  )
  self:_check_barrier()
  return true
end

--- Mark a call cancelled (CAS) + persist + emit (single-call cancellation
--- path). The executor-owned task is CAS-synced so late success can never
--- overwrite the cancellation (async-cancel-late-result).
---@param call table call record
---@param reason string
---@return boolean changed
function Executor:_cancel_call(call, reason)
  if TERMINAL_CALL_STATES[call.state] then
    return false
  end
  if call.task and not task_mod.is_terminal(call.task) then
    task_mod._set_terminal(call.task, "cancelled", {
      status = "error",
      content = standard_error("cancelled", reason or "tool call cancelled"),
      is_error = true,
    }, "cancel")
  end
  call.state = M.CALL_STATES.cancelled
  call.result = {
    call_id = call.call_id,
    name = call.name,
    ordinal = call.ordinal,
    status = "error",
    content = standard_error("cancelled", reason or "tool call cancelled"),
    is_error = true,
    state = M.CALL_STATES.cancelled,
  }
  self:_persist_result(call)
  self:_attach_retention(call)
  self:_emit(
    "tool_call_finished",
    vim.tbl_extend("force", self:_identity(), {
      call_id = call.call_id,
      name = call.name,
      ordinal = call.ordinal,
      status = "error",
      state = M.CALL_STATES.cancelled,
      is_error = true,
    })
  )
  -- Barrier: a single-call cancellation can leave every call terminal, so the
  -- batch must transition exactly like _complete_call does (barrier opens once
  -- when the last call becomes terminal).
  self:_check_barrier()
  return true
end

--- Attach the default TTL retention metadata to a completed call result
--- (phase-3 W2). Auxiliary-payload policy only: the provider-facing `content`
--- and the persisted tool message are untouched (tool-runtime §Result and UI
--- separation). Runs AFTER persistence, so the TTL layer never changes the
--- barrier / persistence order. Default = keep-for-session; the explicit
--- retain/expire APIs on tools.task can change it later without touching
--- pairing/history data.
---@param call table call record (call.result must be set)
function Executor:_attach_retention(call)
  local result = call.result
  if not result or result.retention then
    return
  end
  result.retention = task_mod.retention_meta(task_mod.TTL_ACTIONS.keep, {
    owner = {
      session_id = self.session_id,
      request_id = self.request_id,
      batch_id = self.batch.id,
    },
    set_at_ms = self:_now_ms(),
    source = "default",
  })
end

--- Persist one call result as a role="tool" message on the shared stack.
--- Same call_id results merge by appending into the same tool message (aligned
--- to upstream Chat:add_tool_output merge semantics).
---@param call table call record (call.result must be set)
function Executor:_persist_result(call)
  if not self.stack or not self.conversation then
    return
  end
  local part = self.conversation.tool_result_part(call.call_id, call.result.status, call.result.content, {
    is_error = call.result.is_error,
  })
  local msg = self._tool_msg_by_call[call.call_id]
  if msg then
    msg.content[#msg.content + 1] = part
    return
  end
  self.stack:add_message({ role = "tool", content = { part } }, { turn_id = self.request_id })
  self._tool_msg_by_call[call.call_id] = self.stack:last()
end

--- Barrier check: every call terminal + every result persisted -> finish once.
---@return boolean done true when this call performed the barrier
function Executor:_check_barrier()
  if self._barrier_done then
    return false
  end
  self:_check_timeouts()
  if not self:all_calls_terminal() then
    return false
  end
  return self:_finish_barrier()
end

--- Finish the batch barrier exactly once: batch terminal transition ->
--- tool_batch.finished -> on_terminal(executor, summary). Cancelled batches end
--- in "cancelled"; normal completions in "completed" (per-call error results
--- still complete the batch — invalid/failed calls participate, tool-runtime
--- §Call lifecycle).
---@return boolean done true when this call performed the barrier
function Executor:_finish_barrier()
  if self._barrier_done then
    return false
  end
  self._barrier_done = true
  local state = self._cancelled and session_mod.tool_batch_states.cancelled or session_mod.tool_batch_states.completed
  self:transition("terminal", {
    to = state,
    reason = "tool batch barrier",
  })
  local summary = self:summary()
  self:_emit(
    "tool_batch_finished",
    vim.tbl_extend("force", self:_identity(), {
      state = state,
      calls = summary,
    })
  )
  if self.on_terminal then
    self.on_terminal(self, summary)
  end
  return true
end

--- Executor-level failure (defensive): batch -> terminal failed, barrier once.
---@param reason string
---@return table { complete=true }
function Executor:_fail_batch(reason)
  if self._barrier_done then
    return { complete = true }
  end
  self._barrier_done = true
  self._cancelled = false
  self:transition("terminal", {
    to = session_mod.tool_batch_states.failed,
    reason = reason,
  })
  local summary = self:summary()
  self:_emit(
    "tool_batch_finished",
    vim.tbl_extend("force", self:_identity(), {
      state = session_mod.tool_batch_states.failed,
      calls = summary,
    })
  )
  if self.on_terminal then
    self.on_terminal(self, summary)
  end
  return { complete = true }
end

--- Cancel the whole batch: propagate to running handlers, mark every
--- non-terminal call cancelled (CAS), drain (running -> draining -> cancelled),
--- then run the barrier exactly once. Idempotent; returns true only for the
--- call that performed the cancellation.
---@param reason? string diagnostic reason
---@return boolean cancelled
function Executor:cancel(reason)
  if self:is_terminal() then
    return false
  end
  if self._cancelled then
    return false
  end
  self._cancelled = true

  -- Propagate cancellation to running handlers (best-effort; injected and
  -- registry-resolved handlers both, unless the tool declares cancellable=false).
  for _, call in ipairs(self.calls) do
    if call.state == M.CALL_STATES.running then
      local h = self:_resolve_handler(call.name)
      if h and h.cancel and h.cancellable ~= false then
        pcall(h.cancel)
      end
    end
  end

  -- Drain the batch (stop accepting new work) before marking calls terminal.
  if self.batch.state == session_mod.tool_batch_states.running then
    if self:transition("drain", { reason = reason or "batch cancelled" }) then
      self:_emit(
        "tool_batch_draining",
        vim.tbl_extend("force", self:_identity(), {
          reason = reason or "batch cancelled",
        })
      )
    end
  end

  -- Mark every non-terminal call cancelled (CAS) + persist + emit per call.
  for _, call in ipairs(self.calls) do
    self:_cancel_call(call, reason or "batch cancelled")
  end

  self:_finish_barrier()
  return true
end

M.Executor = Executor

return M
