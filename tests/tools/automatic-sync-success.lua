-- filepath: tests/tools/automatic-sync-success.lua
--- Phase-3 W1 fixture: a successful synchronous tool call executed through the
--- registry resolves automatically with NO approval event/UI, emits the
--- running/succeeded lifecycle, and persists its result BEFORE the batch
--- barrier opens (which owns the continuation decision) (fixture contract
--- tool/automatic-sync-success; T-002).
---   * the handler is resolved from the registry (not injected),
---   * tool_call.finished carries status "success",
---   * inside on_terminal the persisted tool message is already on the stack,
---   * no event name contains "approval".
---
--- Fixture convention: prints TOOLS_AUTOMATIC_SYNC_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local registry_mod = require("maxa.runtime.tools.registry")
local harness = require("tests.tools.lib.harness")

local A = assert_mod.new()

local seen_args = nil
local reg = registry_mod.new()
local def, derr = reg:register({
  id = "demo/echo",
  name = "echo",
  description = "echo a path",
  input_schema = {
    type = "object",
    properties = { path = { type = "string" } },
    required = { "path" },
  },
  execution = { mode = "sync" },
  run = function(args)
    seen_args = args
    return "echo:" .. args.path
  end,
})
A.check(def ~= nil, "as: registration succeeded (" .. tostring(derr and derr.message) .. ")")

local terminal_seen = 0
local persisted_before_continuation = false
local exec, h -- declared first so on_terminal can capture h as an upvalue
exec, h = harness.new({
  registry = reg,
  calls = {
    { call_id = "c1", name = "echo", arguments = '{"path":"/tmp/x"}' },
  },
  on_terminal = function()
    terminal_seen = terminal_seen + 1
    -- The barrier opened => the result must already be persisted on the stack
    -- (persistence precedes the batch terminal / continuation hook).
    persisted_before_continuation = h.stack:last() ~= nil and h.stack:last().role == "tool"
  end,
})
local rec = recorder.new()
rec.attach(h.bus)
local res = exec:run_all()

A.check(res.complete == true, "as: batch reached terminal")
A.assert_eq(h.batch.terminal.state, "completed", "as: batch completed")
A.assert_eq(terminal_seen, 1, "as: on_terminal (continuation hook) called exactly once")

-- Registry resolution: handler ran with the decoded arguments.
A.check(seen_args ~= nil and seen_args.path == "/tmp/x", "as: registry handler ran with decoded args")
A.assert_eq(h.stack:len(), 1, "as: one persisted tool message")
local part = h.stack:get(1).content[1]
A.assert_eq(part.call_id, "c1", "as: result paired to call id")
A.assert_eq(part.status, "success", "as: success status")
A.assert_eq(part.content, "echo:/tmp/x", "as: result content persisted")
A.assert_eq(h.batch.calls[1].state, "succeeded", "as: call state succeeded")

-- Result persisted BEFORE the continuation hook (barrier) ran.
A.check(persisted_before_continuation == true, "as: persisted result precedes continuation")

-- Events: running/succeeded lifecycle, barrier exactly once, no approval.
A.assert_eq(rec.count("tool_call.finished"), 1, "as: one tool_call.finished")
local fin = rec.items[1]
for _, item in ipairs(rec.items) do
  if item.event == "tool_call.finished" then
    A.assert_eq(item.payload.status, "success", "as: finished payload status success")
    A.assert_eq(item.payload.call_id, "c1", "as: finished payload call_id")
  end
end
A.assert_eq(rec.count("tool_batch.finished"), 1, "as: tool_batch.finished exactly once")
local saw_approval = false
for _, item in ipairs(rec.items) do
  if item.event:lower():find("approval", 1, true) then
    saw_approval = true
  end
end
A.check(saw_approval == false, "as: no approval events emitted")

if A.ok then
  print("TOOLS_AUTOMATIC_SYNC_OK")
else
  error("TOOLS_AUTOMATIC_SYNC_FAILED count=" .. #A.failures)
end
