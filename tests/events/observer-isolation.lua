-- filepath: tests/events/observer-isolation.lua
--- W1 observer isolation: a throwing observer never aborts sibling observers
--- nor the reducer phase; failures are recorded with the legacy shape.

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()
local bus = events.new()

local order = {}
bus.register_reducer(function()
  table.insert(order, "reducer")
end)
bus.on("response.completed", function()
  table.insert(order, "obs1")
  error("observer boom")
end)
bus.on("response.completed", function()
  table.insert(order, "obs2")
end)

local envelope = bus.emit("response.completed", { session_id = "sess-iso" })
ctx.assert_eq(envelope.event_id, "sess-iso:1", "envelope produced despite failing observer")

-- Reducer first, then observers in registration order; obs2 still ran.
ctx.assert_eq(table.concat(order, ","), "reducer,obs1,obs2", "dispatch order with failing observer")

-- Failure projection: one legacy-shaped entry for the observer error.
local fails = bus.failures["response.completed"]
ctx.check(type(fails) == "table" and #fails == 1, "one observer failure recorded")
if type(fails) == "table" and fails[1] then
  ctx.check(tostring(fails[1].err):find("observer boom", 1, true) ~= nil, "observer failure error text")
  ctx.check(fails[1].phase == nil, "observer failures keep the legacy shape (no phase)")
  ctx.assert_eq(fails[1].sequence, 1, "observer failure sequence")
end

if not ctx.ok then
  error("observer-isolation: " .. table.concat(ctx.failures, "; "), 0)
end
print("OBSERVER_ISOLATION_OK")
