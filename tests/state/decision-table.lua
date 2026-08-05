-- filepath: tests/state/decision-table.lua
--- Phase-2 W5 fixture: the continuation decision table (pure function) —
--- one row per spec condition (request-orchestrator §Continuation decision
--- table, precedence order):
---   1. session closed / hard-cancelled        -> terminate
---   2. hard stop requested (W6 stop slot)     -> wait
---   3. terminal non-retryable failure         -> fail
---   4. soft stop / context-stop boundary      -> wait
---   5. incomplete/unpaired tool calls         -> repair
---   6. completed batch + loop armed           -> continue
---   7. retryable failure + budget             -> retry
---   8. compaction (phase 4 placeholder)       -> compaction
---   9. otherwise                              -> wait
---
--- Fixture convention: prints DECISION_TABLE_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local decide = require("maxa.runtime.orchestrator.decide")

local A = assert_mod.new()

-- Shared snapshot skeleton (per-row overrides).
local function base()
  return {
    session = { state = "waiting_for_user", generation = 1 },
    request = { id = "req1", generation = 1, terminal = nil, error_code = nil },
    batch = nil,
    loop = { enabled = true, state = "armed", iteration = 0 },
    unpaired_tool_calls = {},
    inputs = {},
  }
end

-- Row 1a: session closed -> terminate.
do
  local s = base()
  s.session.state = "closed"
  local d = decide.decide(s)
  A.assert_eq(d.kind, "terminate", "dt: closed session -> terminate")
  A.assert_eq(d.reason, "session_closed", "dt: closed reason")
end

-- Row 1b: hard-cancelled request -> terminate.
do
  local s = base()
  s.request.terminal = { state = "cancelled" }
  local d = decide.decide(s)
  A.assert_eq(d.kind, "terminate", "dt: cancelled request -> terminate")
  A.assert_eq(d.reason, "request_cancelled", "dt: cancelled reason")
end

-- Row 2 (W6): hard stop requested -> wait (stop wins over fail/soft boundaries;
-- even a completed request must not continue after an explicit stop).
do
  local s = base()
  s.inputs.stop = true
  s.request.terminal = { state = "completed" }
  local d = decide.decide(s)
  A.assert_eq(d.kind, "wait", "dt: stop -> wait")
  A.assert_eq(d.reason, "stop", "dt: stop reason")
end

-- Row 3: terminal non-retryable failure -> fail.
do
  local s = base()
  s.request.terminal = { state = "failed" }
  s.request.error_code = "invalid_request"
  local d = decide.decide(s)
  A.assert_eq(d.kind, "fail", "dt: non-retryable failure -> fail")
  A.assert_eq(d.error_code, "invalid_request", "dt: fail error_code")
  A.assert_eq(d.reason, "non_retryable", "dt: fail reason")
end

-- Row 3b: retryable failure WITHOUT budget -> fail (budget exhausted).
do
  local s = base()
  s.request.terminal = { state = "failed" }
  s.request.error_code = "network"
  -- inputs.retry_budget absent (nil) = not wired
  local d = decide.decide(s)
  A.assert_eq(d.kind, "fail", "dt: retryable failure without budget -> fail")
  A.assert_eq(d.reason, "retry_budget_exhausted", "dt: fail reason (no budget)")
end

-- Row 4a: soft stop slot -> wait.
do
  local s = base()
  s.inputs.soft_stop = true
  local d = decide.decide(s)
  A.assert_eq(d.kind, "wait", "dt: soft_stop -> wait")
  A.assert_eq(d.reason, "soft_stop", "dt: soft_stop reason")
end

-- Row 4b: context-stop slot -> wait.
do
  local s = base()
  s.inputs.context_stop = true
  local d = decide.decide(s)
  A.assert_eq(d.kind, "wait", "dt: context_stop -> wait")
  A.assert_eq(d.reason, "context_stop", "dt: context_stop reason")
end

-- Row 5: unpaired tool calls -> repair (never submit a malformed pairing).
do
  local s = base()
  s.unpaired_tool_calls = { { call_id = "c9", name = "echo" } }
  local d = decide.decide(s)
  A.assert_eq(d.kind, "repair", "dt: unpaired tool calls -> repair")
  A.assert_eq(d.calls[1].call_id, "c9", "dt: repair call_id")
  A.assert_eq(d.reason, "unpaired_tool_calls", "dt: repair reason")
end

-- Row 5a: completed batch + loop armed -> continue (exactly one).
do
  local s = base()
  s.batch = { id = "b1", terminal = { state = "completed" } }
  local d = decide.decide(s)
  A.assert_eq(d.kind, "continue", "dt: completed batch + armed -> continue")
  A.assert_eq(d.batch_id, "b1", "dt: continue batch_id")
  A.assert_eq(d.iteration, 1, "dt: continue iteration advances")
end

-- Row 5b: completed batch + loop parked (waiting_for_user) -> wait.
do
  local s = base()
  s.batch = { id = "b1", terminal = { state = "completed" } }
  s.loop.state = "waiting_for_user"
  local d = decide.decide(s)
  A.assert_eq(d.kind, "wait", "dt: completed batch + parked loop -> wait")
  A.assert_eq(d.reason, "default", "dt: parked-loop wait reason")
end

-- Row 5c: completed batch + loop disabled -> wait.
do
  local s = base()
  s.batch = { id = "b1", terminal = { state = "completed" } }
  s.loop.enabled = false
  local d = decide.decide(s)
  A.assert_eq(d.kind, "wait", "dt: completed batch + disabled loop -> wait")
end

-- Row 6: retryable failure + budget -> retry.
do
  local s = base()
  s.request.terminal = { state = "failed" }
  s.request.error_code = "network"
  s.inputs.retry_budget = 2
  local d = decide.decide(s)
  A.assert_eq(d.kind, "retry", "dt: retryable failure + budget -> retry")
  A.assert_eq(d.error_code, "network", "dt: retry error_code")
  A.assert_eq(d.retry_budget, 2, "dt: retry budget carried")
end

-- Row 7: compaction slot -> placeholder kind (phase 4).
do
  local s = base()
  s.inputs.compaction = true
  local d = decide.decide(s)
  A.assert_eq(d.kind, "compaction", "dt: compaction slot -> placeholder")
  A.assert_eq(d.reason, "phase4", "dt: compaction reason")
end

-- Row 8: otherwise -> wait (idle completed request, no batch).
do
  local s = base()
  s.request.terminal = { state = "completed" }
  local d = decide.decide(s)
  A.assert_eq(d.kind, "wait", "dt: default -> wait")
  A.assert_eq(d.reason, "default", "dt: default reason")
end

-- Precedence sanity: closed session wins over a completed batch.
do
  local s = base()
  s.session.state = "closed"
  s.batch = { id = "b1", terminal = { state = "completed" } }
  local d = decide.decide(s)
  A.assert_eq(d.kind, "terminate", "dt: closed wins over completed batch")
end

-- Precedence sanity: unpaired calls win over a completed batch (repair first).
do
  local s = base()
  s.batch = { id = "b1", terminal = { state = "completed" } }
  s.unpaired_tool_calls = { { call_id = "c9", name = "echo" } }
  local d = decide.decide(s)
  A.assert_eq(d.kind, "repair", "dt: unpaired wins over completed batch")
end

if A.ok then
  print("DECISION_TABLE_OK")
else
  error("DECISION_TABLE_FAILED count=" .. #A.failures)
end
