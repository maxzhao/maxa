-- filepath: tests/tools/lib/harness.lua
--- Phase-3 W1 tools-suite harness (test-only; never loaded by the runtime).
---
--- Builds an isolated executor environment for tool-registry fixtures:
--- fresh event bus, session with one active request, message stack, one
--- ToolBatch with the given calls, and a tools executor bound to an optional
--- registry / deterministic clock / on_terminal hook.

local events = require("maxa.runtime.events")
local session_mod = require("maxa.runtime.session")
local conversation = require("maxa.runtime.conversation")
local tools = require("maxa.runtime.tools")

local M = {}

---@param opts table {
---   calls:        table[] batch call records,
---   registry?:    table|nil tool registry (tools/registry.lua instance),
---   clock?:       table|nil deterministic clock (fake_clock instance),
---   on_terminal?: fun(executor, summary)|nil,
---   session_id?:  string,
---   request_id?:  string,
--- }
---@return table exec, table harness { bus, session, req, stack, batch }
function M.new(opts)
  opts = opts or {}
  local bus = events.new()
  local session = session_mod.new({ session_id = opts.session_id or "s-tools", events = bus, emit = false })
  local req, rerr = session:start_request({ request_id = opts.request_id or "r-tools", intent = "manual" })
  assert(req, "harness: start_request failed: " .. tostring(rerr and rerr.message))
  local stack = conversation.new_stack()
  local batch, berr = session:new_tool_batch({ calls = opts.calls or {} })
  assert(batch, "harness: new_tool_batch failed: " .. tostring(berr and berr.message))
  local exec = tools.new_executor({
    session = session,
    batch = batch,
    conversation = conversation,
    stack = stack,
    registry = opts.registry,
    events = bus,
    clock = opts.clock,
    request = req,
    on_terminal = opts.on_terminal,
  })
  return exec, { bus = bus, session = session, req = req, stack = stack, batch = batch }
end

return M
