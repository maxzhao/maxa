-- filepath: tests/actions/dispatch.lua
--- Phase-5 W4 dispatch fixtures: started/completed event order + typed result,
--- not_found, handler-throw -> failed event + {ok=false} + no lock, busy
--- rejection for requires_idle_request, and input_schema validation.

local assert_mod = require("tests.actions.lib.assert")
local actions = require("maxa.runtime.actions")
local events_mod = require("maxa.runtime.events")

local a = assert_mod.new()

-- Fresh bus + registry for event isolation.
local bus = events_mod.new()
local reg = actions.new({ events = bus })

local events_log = {}
bus.on("action.started", function(payload)
  events_log[#events_log + 1] = { name = "started", payload = payload }
end)
bus.on("action.completed", function(payload)
  events_log[#events_log + 1] = { name = "completed", payload = payload }
end)
bus.on("action.failed", function(payload)
  events_log[#events_log + 1] = { name = "failed", payload = payload }
end)

-- 1. dispatch success: started then completed, typed result, handler input.
local received = nil
local def = {
  id = "dispatch.echo",
  kind = "action",
  title = "Echo",
  input_schema = {},
  contexts = { "session" },
  mutates = { "none" },
  requires_idle_request = false,
  persistence = "none",
  handler = function(input, ctx)
    received = input
    return { echo = input.msg }
  end,
}
reg:register(def)
local res = reg:dispatch("dispatch.echo", { msg = "hi" }, { request_busy = false })
a.check(res.ok == true, "dispatch: success returns ok=true")
a.check(res.result and res.result.echo == "hi", "dispatch: typed result carries handler result")
a.check(received and received.msg == "hi", "dispatch: handler receives input")
a.check(#events_log == 2, "dispatch: exactly started+completed events (" .. #events_log .. ")")
a.check(events_log[1].name == "started" and events_log[2].name == "completed", "dispatch: started before completed")
a.check(
  events_log[1].payload.action_id == "dispatch.echo" and events_log[1].payload.kind == "action",
  "dispatch: started payload action_id/kind"
)
a.check(events_log[2].payload.result.echo == "hi", "dispatch: completed payload result")

-- 2. unknown id -> not_found, no events.
events_log = {}
local nf = reg:dispatch("dispatch.missing", {}, {})
a.check(nf.ok == false and nf.code == "not_found", "dispatch: unknown id -> not_found")
a.check(#events_log == 0, "dispatch: not_found emits no events")

-- 3. handler throw -> failed event + {ok=false} + caller stays usable.
local boom = {
  id = "dispatch.boom",
  kind = "command",
  title = "Boom",
  input_schema = {},
  contexts = { "global" },
  mutates = { "none" },
  requires_idle_request = false,
  persistence = "none",
  handler = function()
    error("kaboom")
  end,
}
reg:register(boom)
events_log = {}
local fres = reg:dispatch("dispatch.boom", {}, {})
a.check(fres.ok == false and fres.code == "handler_failed", "dispatch: handler throw -> handler_failed")
a.check(fres.error and fres.error:find("kaboom", 1, true), "dispatch: failed result carries error")
a.check(#events_log == 2 and events_log[1].name == "started" and events_log[2].name == "failed", "dispatch: throw emits started then failed")
a.check(
  events_log[2].payload.error and events_log[2].payload.error:find("kaboom", 1, true),
  "dispatch: failed event carries error"
)

-- Not locked: subsequent dispatch works normally.
events_log = {}
local after = reg:dispatch("dispatch.echo", { msg = "again" }, {})
a.check(after.ok == true and after.result.echo == "again", "dispatch: not locked after handler failure")

-- 4. requires_idle_request + busy context -> busy rejection, no events.
local idle = {
  id = "dispatch.idle",
  kind = "action",
  title = "Idle only",
  input_schema = {},
  contexts = { "session" },
  mutates = { "session" },
  requires_idle_request = true,
  persistence = "none",
  handler = function()
    return "idle-ok"
  end,
}
reg:register(idle)
events_log = {}
local busy_res = reg:dispatch("dispatch.idle", {}, { request_busy = true })
a.check(busy_res.ok == false and busy_res.code == "busy", "dispatch: requires_idle_request + busy -> busy")
a.check(#events_log == 0, "dispatch: busy rejection emits no events")
local idle_ok = reg:dispatch("dispatch.idle", {}, { request_busy = false })
a.check(idle_ok.ok == true and idle_ok.result == "idle-ok", "dispatch: idle context allows requires_idle_request")

-- 5. input_schema validation (missing required / type mismatch / valid).
local schema_def = {
  id = "dispatch.schema",
  kind = "command",
  title = "Schema",
  input_schema = {
    type = "object",
    required = { "path" },
    properties = { path = { type = "string" }, count = { type = "number" } },
  },
  contexts = { "project" },
  mutates = { "filesystem" },
  requires_idle_request = false,
  persistence = "none",
  handler = function(input)
    return { path = input.path, count = input.count }
  end,
}
reg:register(schema_def)
local s1 = reg:dispatch("dispatch.schema", {}, {})
a.check(s1.ok == false and s1.code == "invalid_input", "dispatch: schema missing required -> invalid_input")
local s2 = reg:dispatch("dispatch.schema", { path = 42 }, {})
a.check(s2.ok == false and s2.code == "invalid_input", "dispatch: schema type mismatch -> invalid_input")
local s3 = reg:dispatch("dispatch.schema", { path = "a.lua", count = 3 }, {})
a.check(s3.ok == true and s3.result.path == "a.lua" and s3.result.count == 3, "dispatch: schema valid input passes")

if not a.ok then
  error("DISPATCH_FIXTURE_FAILED: " .. table.concat(a.failures, "; "))
end
print("DISPATCH_FIXTURE_OK")
