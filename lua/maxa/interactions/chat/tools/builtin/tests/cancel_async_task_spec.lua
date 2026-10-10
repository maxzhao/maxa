-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/cancel_async_task_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {}
vim.uv = vim.uv or vim.loop
vim.fn = vim.fn or {}
vim.fn.timer_start = vim.fn.timer_start or function(_, _) return 1 end
vim.fn.timer_stop = vim.fn.timer_stop or function(_) return 1 end
vim.json = vim.json or require("vim.json")
vim.deepcopy = vim.deepcopy or function(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for k, v in pairs(value) do copy[k] = vim.deepcopy(v) end
  return copy
end

local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")
local tool = require("maxa.interactions.chat.tools.builtin.tools.builtin_kill")

local function response()
  local texts = {}
  return {
    texts = texts,
    text = function(self, text) table.insert(texts, text); return self end,
    send = function(self) self.sent = true; return self end,
    error = function(self, text) self.error_text = text; return self end,
  }
end

local function payload(res)
  local text = res.texts[1]
  return { status = text:match("status: ([^\n]+)"), cancellation = text:match("cancellation: ([^\n]+)") }
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual))) end
end
local function assert_true(value, label) if not value then error(label or "expected truthy value") end end

local res = response()
  tool.run({ params = { title = "Check missing task", async_id = "missing" } }, res)
local p = payload(res)
assert_eq(p.cancellation, "not_performed", "missing cancellation")
assert_eq(p.status, "not_found", "missing status")

local cancelled_reason = nil
local task = registry.create({ tool = "run", label = "sleep" })
registry.set_canceller(task.id, function(reason) cancelled_reason = reason end)
res = response()
  tool.run({ params = { title = "Cancel running task", async_id = task.id } }, res)
p = payload(res)
assert_eq(p.status, "cancelled", "cancel status")
assert_eq(p.cancellation, "requested", "cooperative cancellation requested")
assert_true(cancelled_reason and cancelled_reason:match("cancel") ~= nil, "canceller reason")
assert_eq(task.status, "cancelled", "registry status")

local done = registry.create({ tool = "call", label = "done" })
registry.succeed(done.id, "ok")
res = response()
  tool.run({ params = { title = "Check completed task", async_id = done.id } }, res)
p = payload(res)
assert_eq(p.status, "succeeded", "terminal status")
assert_eq(p.cancellation, "not_performed_already_terminal", "terminal not cancelled")

print("cancel_async_task_spec: OK")
