-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/async_cancel_bridge_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {}
vim.tbl_extend = vim.tbl_extend or function(_, ...)
  local out = {}
  for _, tbl in ipairs({ ... }) do
    for k, v in pairs(tbl or {}) do out[k] = v end
  end
  return out
end

local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
bridge._reset()

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_true(value, label)
  if not value then error(label or "expected truthy value") end
end

local called = 0
local reason_seen = nil
bridge.with_context({ async_id = "a1", outer_tool_name = "call", inner_tool_name = "subagent__run_agent" }, function()
  assert_true(bridge.register_handle({
    kind = "test",
    cancel = function(reason)
      called = called + 1
      reason_seen = reason
    end,
  }), "register handle")
end)

local result = bridge.cancel("a1", "stop now")
assert_eq(result.cancelled, 1, "cancelled count")
assert_eq(called, 1, "handle called once")
assert_eq(reason_seen, "stop now", "reason")
bridge.cancel("a1", "again")
assert_eq(called, 1, "idempotent handle cancel")

local pending_called = 0
bridge.cancel("a2", "pre-cancel")
bridge.with_context({ async_id = "a2" }, function()
  bridge.register_handle({
    cancel = function(reason)
      pending_called = pending_called + 1
      assert_eq(reason, "pre-cancel", "pending reason")
    end,
  })
end)
assert_eq(pending_called, 1, "pending cancel applies on register")

bridge.clear("a1")
assert_eq(bridge._states()["a1"], nil, "clear removes state")

print("async_cancel_bridge_spec: OK")
