-- filepath: tests/events/new-events-constants.lua
--- W1 additive event-name constants: the six new names exist with the exact
--- strings and are distinct from each other and from pre-existing names.

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()
local ev = events.events

local expected = {
  chat_hidden = "chat.hidden",
  chat_reattached = "chat.reattached",
  view_closed = "view.closed",
  action_started = "action.started",
  action_completed = "action.completed",
  action_failed = "action.failed",
}

local seen_values = {}
for key, value in pairs(expected) do
  ctx.assert_eq(ev[key], value, "constant " .. key)
  ctx.check(seen_values[value] == nil, "constant value " .. value .. " is unique")
  seen_values[value] = true
end

-- Pre-existing names untouched (spot check).
ctx.assert_eq(ev.session_created, "session.created", "pre-existing constant session_created")
ctx.assert_eq(ev.history_saved, "history.saved", "pre-existing constant history_saved")
ctx.assert_eq(ev.request_submitted, "request.submitted", "pre-existing constant request_submitted")

if not ctx.ok then
  error("new-events-constants: " .. table.concat(ctx.failures, "; "), 0)
end
print("NEW_EVENTS_CONSTANTS_OK")
