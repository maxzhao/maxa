-- filepath: tests/tools/parallel-barrier.lua
--- Phase-3 W7 fixture T-005: batch concurrency policy + exactly-once barrier
--- (tool-runtime §Batch and concurrency policy).
---   * the registry exposes the `execution.concurrency` declaration (default 1,
---     validated as a positive integer; >1 is declared but NOT activated this
---     wave — the executor still runs sequentially),
---   * a multi-tool batch of independent calls executes strictly in ordinal
---     order (concurrency=1 default) and results preserve ordinals,
---   * tool_batch.finished fires EXACTLY ONCE (barrier),
---   * every provider-facing result is persisted into the role="tool" stack
---     message BEFORE the barrier event is observed (persistence precedes the
---     barrier; spec: "Required message/tool/usage persistence precedes the
---     corresponding durable terminal event").
---
--- Fixture convention: prints TOOLS_PARALLEL_BARRIER_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local registry_mod = require("maxa.runtime.tools.registry")
local harness = require("tests.tools.lib.harness")

local A = assert_mod.new()

do
  -- Registry concurrency declaration (declared + validated, not activated).
  local reg = registry_mod.new()
  local def, err = reg:register({
    id = "demo/alpha",
    name = "alpha",
    description = "sequential tool alpha",
    input_schema = { type = "object" },
    execution = { concurrency = 2 }, -- declaration exists; no parallel executor yet
    run = function(_, ctx)
      return ("alpha:%d"):format(ctx.ordinal)
    end,
  })
  A.check(def ~= nil and err == nil, "barrier: register with concurrency=2 accepted")
  A.assert_eq(def.execution.concurrency, 2, "barrier: declared concurrency kept")
  local def2, err2 = reg:register({
    id = "demo/beta",
    name = "beta",
    description = "sequential tool beta",
    input_schema = { type = "object" },
    run = function(_, ctx)
      return ("beta:%d"):format(ctx.ordinal)
    end,
  })
  A.check(def2 ~= nil and err2 == nil, "barrier: default-concurrency register accepted")
  A.assert_eq(def2.execution.concurrency, 1, "barrier: default concurrency is 1")

  -- Fail-closed concurrency validation: 0 / non-number / fractional rejected.
  local function bad_concurrency(value)
    local d, e = reg:register({
      id = "demo/bad-" .. tostring(value),
      name = "bad-" .. tostring(value),
      description = "bad concurrency",
      input_schema = { type = "object" },
      execution = { concurrency = value },
      run = function()
        return "x"
      end,
    })
    return d == nil and e ~= nil
  end
  A.check(bad_concurrency(0), "barrier: concurrency=0 rejected")
  A.check(bad_concurrency("2"), "barrier: non-number concurrency rejected")
  A.check(bad_concurrency(1.5), "barrier: fractional concurrency rejected")

  -- Multi-tool independent batch (3 calls, no dependency IDs).
  local exec_order = {}
  local reg2 = registry_mod.new()
  for _, id in ipairs({ "demo/t1", "demo/t2", "demo/t3" }) do
    local name = id:match("demo/(.*)")
    local okd, derr = reg2:register({
      id = id,
      name = name,
      description = "sequential tool " .. name,
      input_schema = { type = "object", properties = { v = { type = "number" } } },
      run = function(args, ctx)
        exec_order[#exec_order + 1] = { name = ctx.name, ordinal = ctx.ordinal, v = args.v }
        return ("%s=%s"):format(ctx.name, tostring(args.v))
      end,
    })
    A.check(okd ~= nil and derr == nil, "barrier: register " .. id)
  end

  local finished_count = 0
  local stack_at_barrier = nil
  local exec, h = harness.new({
    registry = reg2,
    calls = {
      { call_id = "c1", name = "t1", arguments = '{"v":1}' },
      { call_id = "c2", name = "t2", arguments = '{"v":2}' },
      { call_id = "c3", name = "t3", arguments = '{"v":3}' },
    },
  })
  h.bus.on(h.bus.events.tool_batch_finished or "tool_batch.finished", function()
    finished_count = finished_count + 1
    -- Barrier observer: at this exact moment every call result must already be
    -- persisted (persistence precedes the durable terminal event).
    stack_at_barrier = vim.json.encode(h.stack:to_table())
  end)
  exec:run_all()

  A.check(exec:is_terminal(), "barrier: batch terminal after run_all")
  A.assert_eq(finished_count, 1, "barrier: tool_batch.finished exactly once")
  A.check(stack_at_barrier ~= nil, "barrier: barrier observer ran")
  local decoded = vim.json.decode(stack_at_barrier)
  local tool_msgs = 0
  for _, msg in ipairs(decoded) do
    if msg.role == "tool" then
      tool_msgs = tool_msgs + 1
    end
  end
  A.assert_eq(tool_msgs, 3, "barrier: 3 tool results persisted before barrier (got " .. tool_msgs .. ")")

  -- Sequential execution (default concurrency=1): run order == ordinal order.
  A.assert_eq(#exec_order, 3, "barrier: all three calls ran")
  for i, rec in ipairs(exec_order) do
    A.assert_eq(rec.ordinal, i, ("barrier: run order ordinal %d"):format(i))
    A.assert_eq(rec.name, ("t%d"):format(i), ("barrier: run order name %d"):format(i))
  end
  -- Ordinal preserved in results.
  local summary = exec:summary()
  for i, s in ipairs(summary) do
    A.assert_eq(s.ordinal, i, ("barrier: result ordinal %d"):format(i))
    A.assert_eq(s.status, "success", ("barrier: result status %d"):format(i))
  end
end

if A.ok then
  print("TOOLS_PARALLEL_BARRIER_OK")
else
  error("TOOLS_PARALLEL_BARRIER_FAILED count=" .. #A.failures)
end
