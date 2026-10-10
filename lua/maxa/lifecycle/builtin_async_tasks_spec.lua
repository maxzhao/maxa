-- filepath: lua/maxa/lifecycle/builtin_async_tasks_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {}
vim.uv = vim.uv or vim.loop
vim.fn = vim.fn or {}
vim.fn.timer_start = vim.fn.timer_start or function(_, _) return 1 end
vim.fn.timer_stop = vim.fn.timer_stop or function(_) return 1 end
vim.api = vim.api or {}
vim.api.nvim_create_augroup = vim.api.nvim_create_augroup or function() return 1 end
vim.api.nvim_create_autocmd = vim.api.nvim_create_autocmd or function(_, _) return 1 end
vim.list_extend = vim.list_extend or function(dst, src)
  for _, item in ipairs(src or {}) do table.insert(dst, item) end
  return dst
end

local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")
local hook = require("maxa.lifecycle.builtin_async_tasks")

local function assert_eq(actual, expected, label)
  if actual ~= expected then error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual))) end
end
local function assert_true(value, label) if not value then error(label or "expected truthy value") end end

local chat_task = registry.create({ tool = "call", label = "chat", chat_id = "chat-1" })
local buf_task = registry.create({ tool = "call", label = "buf", bufnr = 123 })
local both_task = registry.create({ tool = "call", label = "both", chat_id = "chat-2", bufnr = 456 })
local other = registry.create({ tool = "call", label = "other", chat_id = "other", bufnr = 789 })

local cancelled = hook._cancel_for_event({ data = { id = "chat-1" } }, "chat closed")
assert_eq(#cancelled, 1, "chat event count")
assert_eq(chat_task.status, "cancelled", "chat task cancelled")

cancelled = hook._cancel_for_event({ buf = 123 }, "buf closed")
assert_eq(#cancelled, 1, "buf event count")
assert_eq(buf_task.status, "cancelled", "buf task cancelled")

cancelled = hook._cancel_for_event({ data = { id = "chat-2", bufnr = 456 } }, "both closed")
assert_true(#cancelled >= 1, "combined event count")
assert_eq(both_task.status, "cancelled", "both task cancelled")
assert_eq(other.status, "running", "other remains running")

registry.cancel(other.id, "cleanup")

print("builtin_async_tasks_spec: OK")
