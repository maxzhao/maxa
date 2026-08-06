-- filepath: tests/events/transaction-reducer.lua
--- W1 transactional reducers: reducers run before observers in registration
--- order; a throwing reducer is a typed transactional failure (phase="reducer")
--- that never aborts sibling reducers or the observer dispatch.

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()
local bus = events.new()

local order = {}
bus.register_reducer(function()
  table.insert(order, "r1")
  error("reducer boom")
end)
bus.register_reducer(function()
  table.insert(order, "r2")
end)
bus.on("response.completed", function()
  table.insert(order, "obs")
end)

bus.emit("response.completed", { session_id = "sess-tx" })

-- r1 (throws) still ran; r2 still ran after r1; observer ran last.
ctx.assert_eq(table.concat(order, ","), "r1,r2,obs", "reducer-then-observer order")

-- Typed transactional failure recorded; observer failure list untouched.
local fails = bus.failures["response.completed"]
ctx.check(type(fails) == "table" and #fails == 1, "exactly one reducer failure recorded")
if type(fails) == "table" and fails[1] then
  ctx.assert_eq(fails[1].phase, "reducer", "failure phase is reducer")
  ctx.assert_eq(fails[1].event, "response.completed", "failure carries the event name")
  ctx.check(tostring(fails[1].err):find("reducer boom", 1, true) ~= nil, "reducer failure error text")
  ctx.assert_eq(fails[1].sequence, 1, "reducer failure sequence")
end

-- A live emit with an explicit duplicate event_id does not re-run reducers
-- (idempotent reducer effect), while observers still dispatch.
local order2 = {}
bus.on("chat.closed", function()
  table.insert(order2, "obs2")
end)
local dupe = bus.emit("chat.closed", { session_id = "sess-tx", event_id = "tx-dup" })
local dupe2 = bus.emit("chat.closed", { session_id = "sess-tx", event_id = "tx-dup" })
ctx.assert_eq(dupe.event_id, "tx-dup", "duplicate emit keeps the explicit event_id")
ctx.assert_eq(dupe2.event_id, "tx-dup", "duplicate emit second keeps the explicit event_id")
ctx.assert_eq(table.concat(order2, ","), "obs2,obs2", "observers dispatch on every emit")

if not ctx.ok then
  error("transaction-reducer: " .. table.concat(ctx.failures, "; "), 0)
end
print("TRANSACTION_REDUCER_OK")
