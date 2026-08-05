-- filepath: tests/tools/timeout-ms.lua
--- Phase-3 W1 fixture: registry timeout_ms enforcement (executor bridge).
---   * a late async completion after the declared deadline is a typed timeout
---     error result (task.complete deadline check),
---   * an expired deadline is observed on the next completion/barrier boundary
---     (_check_timeouts) with best-effort cancel propagation,
---   * sync tools without timeout_ms are unaffected.
---
--- Fixture convention: prints TOOLS_TIMEOUT_MS_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local fake_clock = require("tests.state.lib.fake_clock")
local registry_mod = require("maxa.runtime.tools.registry")
local harness = require("tests.tools.lib.harness")

local A = assert_mod.new()

-------------------------------------------------------------------------------
-- A. Late completion after the deadline -> typed timeout result
-------------------------------------------------------------------------------
do
  local cancelled = false
  local reg = registry_mod.new()
  local def = reg:register({
    id = "demo/slow",
    name = "slow",
    description = "async tool with a timeout",
    input_schema = { type = "object" },
    execution = { mode = "async", timeout_ms = 100, cancellable = true },
    run = function()
      return nil -- keeps the executor-owned task; completes later
    end,
    cancel = function()
      cancelled = true
    end,
  })
  local clock = fake_clock.new({ now = 1000 })
  local exec, h = harness.new({
    registry = reg,
    clock = clock,
    calls = {
      { call_id = "c1", name = "slow", arguments = "{}" },
    },
  })
  local res = exec:run_all()
  A.check(res.complete == false, "tm: async call still running after run_all")
  local call = h.batch.calls[1]
  A.assert_eq(call.state, "running", "tm: call running with deadline")
  A.check(call.deadline == 1100, "tm: deadline = start + timeout_ms")

  clock.advance(150) -- now = 1150 > deadline
  local task = call.task
  A.check(task ~= nil, "tm: executor task identity exposed")
  local done = task.complete("late success")
  A.check(done == true, "tm: late completion performed (as timeout)")
  A.assert_eq(call.state, "failed", "tm: late success did not succeed the call")
  local part = h.stack:get(1).content[1]
  A.assert_eq(part.status, "error", "tm: timeout result is an error")
  A.check(part.content:find("timeout", 1, true) ~= nil, "tm: timeout code in result: " .. part.content)
  A.check(part.content:find("late success", 1, true) == nil, "tm: late content never persisted")
  A.assert_eq(h.batch.terminal.state, "completed", "tm: batch completed via timeout result")
end

-------------------------------------------------------------------------------
-- B. Deadline observed at the barrier boundary with cancel propagation
-------------------------------------------------------------------------------
do
  local slow_cancelled = false
  local reg = registry_mod.new()
  reg:register({
    id = "demo/slow",
    name = "slow",
    description = "async tool with a timeout",
    input_schema = { type = "object" },
    execution = { mode = "async", timeout_ms = 100 },
    run = function()
      return nil
    end,
    cancel = function()
      slow_cancelled = true
    end,
  })
  reg:register({
    id = "demo/fast",
    name = "fast",
    description = "sync tool that advances the clock",
    input_schema = { type = "object" },
    execution = { mode = "sync" },
    run = function(_, ctx)
      ctx.clock.advance(150) -- expiry of the slow call happens mid-batch
      return "fast done"
    end,
  })
  local clock = fake_clock.new({ now = 2000 })
  local exec, h = harness.new({
    registry = reg,
    clock = clock,
    calls = {
      { call_id = "c1", name = "slow", arguments = "{}" },
      { call_id = "c2", name = "fast", arguments = "{}" },
    },
  })
  local res = exec:run_all()
  A.check(res.complete == true, "tm: batch reached terminal")
  A.assert_eq(h.batch.terminal.state, "completed", "tm: batch completed")
  local c1 = h.batch.calls[1]
  A.assert_eq(c1.state, "failed", "tm: slow call timed out at the boundary")
  A.check(c1.result.content:find("timeout", 1, true) ~= nil, "tm: timeout result persisted")
  A.check(slow_cancelled == true, "tm: timeout propagated cancel() to the async handler")
  local c2 = h.batch.calls[2]
  A.assert_eq(c2.state, "succeeded", "tm: independent sync call unaffected")
  A.assert_eq(h.stack:len(), 2, "tm: both results persisted")
end

if A.ok then
  print("TOOLS_TIMEOUT_MS_OK")
else
  error("TOOLS_TIMEOUT_MS_FAILED count=" .. #A.failures)
end
