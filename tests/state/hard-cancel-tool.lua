-- filepath: tests/state/hard-cancel-tool.lua
--- Phase-2 W8 fixture: hard cancel of an owned ToolBatch propagates to every
--- current/pending tool and no queued tool executes afterwards.
---
--- Assertions (runtime-fixture-contract async/hard-cancel-tool):
--- Scenario A (all calls started, external cancel):
---   * every started (running) owned tool receives handler.cancel;
---   * every non-terminal call is marked cancelled (CAS) with a persisted
---     cancelled/error result; the batch drains (tool_batch.draining once) and
---     reaches terminal cancelled (tool_batch.finished once);
---   * late task.complete() for ANY call is rejected (CAS) — results/terminal
---     policy explicit: cancellation wins, no overwrite;
---   * no queued execution afterwards (no new handler.run invocations) and no
---     continuation (one provider call, one request).
--- Scenario B (cancel inside the first handler, pending calls still queued):
---   * pending calls NEVER execute after the cancel (handler.run not invoked);
---   * batch terminal cancelled exactly once; no continuation.
---
--- Fixture convention: prints HARD_CANCEL_TOOL_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

local function tool_provider(call_ids, names)
  local provider = {
    name = "scripted-hard-cancel-tool",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  local calls = 0
  function provider.stream(_, params, callbacks)
    calls = calls + 1
    local chunks = {}
    for i, cid in ipairs(call_ids) do
      chunks[#chunks + 1] = normalize.tool_call_started(cid, names[i])
      chunks[#chunks + 1] = normalize.tool_call_completed(cid, "{}")
    end
    params = vim.tbl_deep_extend("force", params or {}, { chunks = chunks })
    return mock.stream(mock, params, callbacks)
  end
  return provider, function()
    return calls
  end
end

-- Scenario A: three async tools, all started; external hard cancel.
do
  local runs = { c1 = 0, c2 = 0, c3 = 0 }
  local cancels = { c1 = 0, c2 = 0, c3 = 0 }
  local tasks = {}
  local handlers = {}
  for _, cid in ipairs({ "c1", "c2", "c3" }) do
    handlers[cid] = {
      mode = "async",
      run = function(args, ctx, task)
        runs[cid] = runs[cid] + 1
        tasks[cid] = task
        return task
      end,
      cancel = function()
        cancels[cid] = cancels[cid] + 1
      end,
    }
  end

  local provider, calls = tool_provider({ "c1", "c2", "c3" }, { "c1", "c2", "c3" })
  local bus = events.new()
  local orch = orchestrator.new({ provider = provider, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("run three", { provider_params = {} })
  A.check(res.tool_pending == true, "hct-a: batch running")
  A.assert_eq(runs.c1, 1, "hct-a: c1 started")
  A.assert_eq(runs.c2, 1, "hct-a: c2 started")
  A.assert_eq(runs.c3, 1, "hct-a: c3 started")
  local batch = orch.session.tool_batches[#orch.session.tool_batches]
  A.assert_eq(batch.state, "running", "hct-a: batch running")

  -- External hard cancel.
  local cancelled = orch:cancel("hard tool cancel")
  A.check(cancelled == true, "hct-a: cancel performed")
  A.assert_eq(cancels.c1, 1, "hct-a: c1 handler.cancel called")
  A.assert_eq(cancels.c2, 1, "hct-a: c2 handler.cancel called")
  A.assert_eq(cancels.c3, 1, "hct-a: c3 handler.cancel called")
  A.assert_eq(rec.count("tool_batch.draining"), 1, "hct-a: draining once")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "hct-a: finished once")
  A.assert_eq(batch.terminal.state, "cancelled", "hct-a: batch terminal cancelled")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "hct-a: request terminal cancelled")
  for _, cid in ipairs({ "c1", "c2", "c3" }) do
    local call = batch.calls[({ c1 = 1, c2 = 2, c3 = 3 })[cid]]
    A.assert_eq(call.state, "cancelled", ("hct-a: %s call cancelled"):format(cid))
    A.check(call.result ~= nil and call.result.is_error == true, "hct-a: " .. cid .. " result error")
    A.check(call.result.content:find("cancelled", 1, true) ~= nil, "hct-a: " .. cid .. " result mentions cancelled")
  end
  -- Persisted results: one tool message per call, all error/cancelled.
  local stack = orch.messages
  local n_tool_msgs = 0
  for i = 1, stack:len() do
    if stack:get(i).role == "tool" then
      n_tool_msgs = n_tool_msgs + 1
    end
  end
  A.assert_eq(n_tool_msgs, 3, "hct-a: three persisted tool messages")
  A.check(stack:last().content[1].content:find("cancelled", 1, true) ~= nil, "hct-a: last result cancelled")

  -- Late completions rejected for every call.
  for _, cid in ipairs({ "c1", "c2", "c3" }) do
    A.check(tasks[cid].is_cancelled() == true, ("hct-a: %s task cancelled"):format(cid))
    A.check(tasks[cid].complete("late success") == false, ("hct-a: %s late complete rejected"):format(cid))
  end
  A.assert_eq(batch.terminal.state, "cancelled", "hct-a: batch stays cancelled")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "hct-a: barrier exactly once")
  A.assert_eq(rec.count("tool_call.finished"), 3, "hct-a: three tool_call.finished")
  A.assert_eq(calls(), 1, "hct-a: no continuation")
  A.assert_eq(#orch.session.requests, 1, "hct-a: one request total")
  A.assert_eq(runs.c1 + runs.c2 + runs.c3, 3, "hct-a: no later queued execution")
end

-- Scenario B: cancel inside the FIRST handler; pending calls never execute.
do
  local orch_ref
  local never_run = { c2 = 0, c3 = 0 }
  local handlers = {
    c1 = {
      mode = "async",
      run = function(args, ctx, task)
        orch_ref:cancel("cancel from inside handler")
        return task
      end,
      cancel = function() end,
    },
    c2 = {
      mode = "async",
      run = function()
        never_run.c2 = never_run.c2 + 1
      end,
    },
    c3 = {
      mode = "async",
      run = function()
        never_run.c3 = never_run.c3 + 1
      end,
    },
  }

  local provider, calls = tool_provider({ "c1", "c2", "c3" }, { "c1", "c2", "c3" })
  local bus = events.new()
  orch_ref = orchestrator.new({ provider = provider, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch_ref:submit("cancel mid-batch", { provider_params = {} })
  A.check(res.terminal_state == "cancelled", "hct-b: request terminal cancelled")
  A.assert_eq(never_run.c2, 0, "hct-b: queued c2 never executed")
  A.assert_eq(never_run.c3, 0, "hct-b: queued c3 never executed")
  local batch = orch_ref.session.tool_batches[#orch_ref.session.tool_batches]
  A.assert_eq(batch.terminal.state, "cancelled", "hct-b: batch terminal cancelled")
  A.assert_eq(batch.calls[1].state, "cancelled", "hct-b: c1 cancelled")
  A.assert_eq(batch.calls[2].state, "cancelled", "hct-b: c2 cancelled without run")
  A.assert_eq(batch.calls[3].state, "cancelled", "hct-b: c3 cancelled without run")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "hct-b: barrier once")
  A.assert_eq(rec.count("tool_call.finished"), 3, "hct-b: three calls terminal")
  A.assert_eq(calls(), 1, "hct-b: no continuation")
  A.assert_eq(#orch_ref.session.requests, 1, "hct-b: one request total")
end

if A.ok then
  print("HARD_CANCEL_TOOL_OK")
else
  error("HARD_CANCEL_TOOL_FAILED count=" .. #A.failures)
end
