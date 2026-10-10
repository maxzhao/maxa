-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/async_registry_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {}
vim.uv = vim.uv or vim.loop
vim.fn = vim.fn or {}
local timers = {}
vim.fn.timer_start = function(_, cb)
  table.insert(timers, cb)
  return #timers
end
vim.fn.timer_stop = function(_) return 1 end
vim.json = vim.json or require("vim.json")

local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
  end
end

local function assert_true(value, label)
  if not value then
    error(label or "expected truthy value")
  end
end

local task = registry.create({ tool = "run", label = "sleep" })
assert_true(task.id:match("^async_") ~= nil, "async id prefix")
assert_eq(task.status, "running", "initial status")
assert_eq(registry.get(task.id), task, "get returns task")

local waited_task = nil
local wait_timed_out = nil
registry.wait(task.id, 1000, function(done_task, timed_out)
  waited_task = done_task
  wait_timed_out = timed_out
end)
assert_eq(waited_task, nil, "wait should not complete before terminal state")

assert_true(registry.succeed(task.id, "done"), "succeed returns true")
assert_eq(task.status, "succeeded", "succeeded status")
assert_eq(task.result, "done", "stored result")
assert_eq(waited_task, task, "waiter receives task")
assert_eq(wait_timed_out, false, "waiter not timed out")
assert_true(registry.is_terminal(task.status), "succeeded terminal")

local public = registry.public(task)
assert_eq(public.async_id, task.id, "public async id")
assert_eq(public.status, "succeeded", "public status")
assert_true(type(public.duration_ms) == "number", "public duration")

assert_true(registry.consume(task.id), "consume terminal task")
assert_eq(registry.get(task.id), nil, "consumed task removed")

local timeout_task = registry.create({ tool = "call", label = "slow" })
local timeout_seen = false
registry.wait(timeout_task.id, 1, function(done_task, timed_out)
  assert_eq(done_task, timeout_task, "timeout callback task")
  assert_eq(timed_out, true, "timeout flag")
  timeout_seen = true
end)
timers[#timers]()
assert_true(timeout_seen, "wait timeout callback called")
assert_eq(timeout_task.status, "running", "task still running after wait timeout")

assert_true(registry.fail(timeout_task.id, "boom", "failed"), "fail returns true")
assert_eq(timeout_task.status, "failed", "failed status")
assert_eq(timeout_task.error, "boom", "stored error")

local cancel_called = false
local cancel_task = registry.create({ tool = "run", label = "sleep", chat_id = "chat-a", bufnr = 42 })
registry.set_canceller(cancel_task.id, function(reason)
  cancel_called = reason:match("manual") ~= nil
end)
local ok_cancel, cancelled = registry.cancel(cancel_task.id, "manual cancel")
assert_true(ok_cancel, "cancel returns ok")
assert_eq(cancelled.status, "cancelled", "cancel status")
assert_true(cancel_called, "canceller called")
assert_eq(cancel_task.error, "manual cancel", "cancel reason stored")

local chat_task = registry.create({ tool = "call", label = "chat", chat_id = "chat-b" })
local bufnr_task = registry.create({ tool = "call", label = "buf", bufnr = 77 })
local other_task = registry.create({ tool = "call", label = "other", chat_id = "other", bufnr = 88 })
local by_chat = registry.cancel_by_chat("chat-b", "chat closed")
assert_eq(#by_chat, 1, "cancel_by_chat count")
assert_eq(chat_task.status, "cancelled", "chat task cancelled")
local by_bufnr = registry.cancel_by_bufnr(77, "buf closed")
assert_eq(#by_bufnr, 1, "cancel_by_bufnr count")
assert_eq(bufnr_task.status, "cancelled", "buf task cancelled")
assert_eq(other_task.status, "running", "other task still running")
local all = registry.cancel_all("exit")
assert_true(#all >= 1, "cancel_all count")
assert_eq(other_task.status, "cancelled", "other task cancelled by all")

print("async_registry_spec: OK")
