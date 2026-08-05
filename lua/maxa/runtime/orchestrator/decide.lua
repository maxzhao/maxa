-- filepath: lua/maxa/runtime/orchestrator/decide.lua
--- W5 continuation decision table (request-orchestrator §Continuation decision
--- table): a PURE function over a committed request/tool-batch/session snapshot.
---
--- The orchestrator calls M.decide at the single continuation decision point
--- (after a tool-batch terminal / request terminal) with an immutable snapshot
--- and input slots; the returned decision is executed by the caller and
--- persisted under its durable continuation key. This module has no runtime
--- dependencies (no orchestrator/session/events) so the fixture suite can unit
--- test every decision-table row in isolation.
---
--- Condition precedence (spec order):
---   1. session closed or hard-cancelled            -> terminate
---   2. hard stop requested (orchestrator:stop)     -> wait (W6 input slot;
---      suppresses continuation even if the work completed)
---   3. terminal non-retryable provider/runtime failure -> fail
---   4. soft stop / context-stop boundary           -> wait (W6 input slots;
---      default not triggered)
---   5. incomplete/unpaired tool calls/results      -> repair (never submit a
---      malformed pairing)
---   6. completed tool batch and AgentLoop permits  -> continue exactly once
---   7. retryable failure and retry budget          -> retry (W7 input slot;
---      default no budget)
---   8. compaction required and permitted           -> compaction placeholder
---      (phase 4; not wired here)
---   9. otherwise                                   -> wait
---
--- Input snapshot shape:
---   {
---     session = { state = string, generation = int },
---     request = { id, generation,
---                 terminal = { state = "completed"|"failed"|"cancelled" }|nil,
---                 error_code = string|nil },   -- schema.ERROR.* code
---     batch = { id, terminal = { state } }|nil, -- terminal tool batch (if any)
---     loop = { enabled = boolean, state = "armed"|"waiting_for_user",
---              iteration = int },
---     unpaired_tool_calls = { { call_id, name } }|nil, -- orphan assistant
---                          -- tool_call parts without paired results
---     inputs = {             -- external input slots (wired in later waves)
---       stop = boolean,           -- W6 hard stop (default false)
---       soft_stop = boolean,      -- W6 (default false)
---       context_stop = boolean,   -- W6 (default false)
---       retry_budget = int|nil,   -- W7 (nil = no budget wired)
---       compaction = boolean,     -- phase 4 (default false)
---     },
---   }
---
--- Output shape:
---   { kind = "continue"|"wait"|"fail"|"repair"|"retry"|"terminate"|"compaction",
---     ... kind-specific fields }
---   continue:  { kind, batch_id, iteration }
---   wait:      { kind, reason = "stop"|"soft_stop"|"context_stop"|"default" }
---   fail:      { kind, error_code, reason = "non_retryable"|"retry_budget_exhausted" }
---   repair:    { kind, calls = { {call_id,name} }, reason = "unpaired_tool_calls" }
---   retry:     { kind, error_code, retry_budget }
---   terminate: { kind, reason = "session_closed"|"request_cancelled" }
---   compaction:{ kind, reason = "phase4" }

local M = {}

M.name = "orchestrator.decide"

--- Decision kinds (spec §Continuation decision table).
M.kinds = {
  continue = "continue",
  wait = "wait",
  fail = "fail",
  repair = "repair",
  retry = "retry",
  terminate = "terminate",
  compaction = "compaction", -- placeholder (phase 4)
}

--- Error codes eligible for automatic retry (spec §Error and retry policy:
--- rate/network/timeout/provider-unavailable may retry with bounded backoff).
--- Authentication, invalid configuration/request, unsupported protocol and
--- persistence corruption are NOT retried. W7 wires the budget/backoff; here
--- they only gate the `retry` decision row.
M.retryable_codes = {
  rate_limited = true,
  quota = true,
  provider_unavailable = true,
  network = true,
  timeout = true,
}

--- Normalize the external input slots with their W5 defaults.
---@param inputs? table
---@return table
local function default_inputs(inputs)
  inputs = inputs or {}
  return {
    stop = inputs.stop == true,
    soft_stop = inputs.soft_stop == true,
    context_stop = inputs.context_stop == true,
    retry_budget = inputs.retry_budget, -- nil = not wired (no budget)
    compaction = inputs.compaction == true,
  }
end

--- Decide the continuation kind for a committed snapshot. Pure: no side effects.
---@param snapshot table committed request/tool-batch/session snapshot (above)
---@return table decision
function M.decide(snapshot)
  snapshot = snapshot or {}
  local inputs = default_inputs(snapshot.inputs)
  local session = snapshot.session or {}
  local request = snapshot.request or {}
  local batch = snapshot.batch
  local loop = snapshot.loop or {}
  local unpaired = snapshot.unpaired_tool_calls or {}

  -- 1) session closed / hard-cancelled -> terminate; no continuation.
  if session.state == "closed" then
    return { kind = M.kinds.terminate, reason = "session_closed" }
  end
  if request.terminal and request.terminal.state == "cancelled" then
    return { kind = M.kinds.terminate, reason = "request_cancelled" }
  end

  -- 2) hard stop requested (orchestrator:stop, W6) -> wait for user: the stop
  -- suppresses continuation even when the current work completed normally (e.g.
  -- the provider ignored the cancel). Higher precedence than fail/soft-stop:
  -- the user's explicit stop wins over error classification and soft boundaries.
  if inputs.stop then
    return { kind = M.kinds.wait, reason = "stop" }
  end

  -- Retry eligibility for a terminal-failed request (row 7); a retryable code
  -- WITH budget is deferred to its own row AFTER continue (spec precedence).
  local retryable = request.terminal
    and request.terminal.state == "failed"
    and type(request.error_code) == "string"
    and M.retryable_codes[request.error_code] == true
  local budget_ok = type(inputs.retry_budget) == "number" and inputs.retry_budget > 0

  -- 3) terminal failure without retry path -> fail (session returns to the
  -- declared failed/waiting boundary).
  if request.terminal and request.terminal.state == "failed" and not (retryable and budget_ok) then
    return {
      kind = M.kinds.fail,
      error_code = request.error_code,
      reason = retryable and "retry_budget_exhausted" or "non_retryable",
    }
  end

  -- 4) soft stop / context-stop -> wait for user after current durable work
  -- (W6 input slots; default not triggered).
  if inputs.soft_stop or inputs.context_stop then
    return {
      kind = M.kinds.wait,
      reason = inputs.soft_stop and "soft_stop" or "context_stop",
    }
  end

  -- 5) incomplete/unpaired tool calls -> repair; never submit malformed pairing.
  if #unpaired > 0 then
    return {
      kind = M.kinds.repair,
      calls = unpaired,
      reason = "unpaired_tool_calls",
    }
  end

  -- 6) completed tool batch + AgentLoop permits next iteration -> exactly one
  -- automatic continuation.
  if
    batch
    and batch.terminal
    and batch.terminal.state == "completed"
    and loop.enabled ~= false
    and loop.state == "armed"
  then
    return {
      kind = M.kinds.continue,
      batch_id = batch.id,
      iteration = (type(loop.iteration) == "number" and loop.iteration or 0) + 1,
    }
  end

  -- 7) retryable failure + budget available -> schedule one retry (W7 wires
  -- backoff/request generation; the budget slot already gates the decision).
  if retryable and budget_ok then
    return {
      kind = M.kinds.retry,
      error_code = request.error_code,
      retry_budget = inputs.retry_budget,
    }
  end

  -- 8) compaction required and permitted -> placeholder (phase 4 transaction;
  -- then reconsider from the new session generation).
  if inputs.compaction then
    return { kind = M.kinds.compaction, reason = "phase4" }
  end

  -- 9) otherwise -> wait for user / complete turn.
  return { kind = M.kinds.wait, reason = "default" }
end

return M
