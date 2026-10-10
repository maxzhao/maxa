-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/get_async_result_spec.lua
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
vim.deepcopy = vim.deepcopy or function(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for k, v in pairs(value) do copy[k] = vim.deepcopy(v) end
  return copy
end

local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")
local tool = require("maxa.interactions.chat.tools.builtin.tools.builtin_wait")

local function response()
  local texts = {}
  return {
    texts = texts,
    error_text = nil,
    text = function(self, text)
      table.insert(texts, text)
      return self
    end,
    send = function(self) self.sent = true; return self end,
    error = function(self, text)
      self.error_text = text
      return self
    end,
  }
end

local function payload(res)
  local text = res.texts[1]
  return { async_id = text:match("async_id: ([^\n]+)"), status = text:match("status: ([^\n]+)"),
    wait_timed_out = text:find("wait_timed_out: true", 1, true) ~= nil,
    error = text:match("\n%-%-%-\n(.*)") }
end

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

local title_required = false
for _, name in ipairs(tool.inputSchema.required or {}) do
  title_required = title_required or name == "title"
end
assert_true(title_required, "schema requires title")
assert_eq(tool.inputSchema.properties.title.type, "string", "title schema type")

local res = response()
tool.run({ params = { async_id = "missing", mode = "try" } }, res)
assert_true(res.error_text and res.error_text:find("title parameter is required", 1, true), "missing title rejected")

res = response()
tool.run({ params = { title = "   ", async_id = "missing", mode = "try" } }, res)
assert_true(res.error_text and res.error_text:find("title parameter cannot be empty", 1, true), "blank title rejected")

res = response()
tool.run({ params = { title = "Check missing task", async_id = "missing", mode = "try" } }, res)
local p = payload(res)
assert_eq(p.status, "not_found", "missing status")

local task = registry.create({ tool = "run", label = "sleep" })
res = response()
tool.run({ params = { title = "Poll sleep task", async_id = task.id, mode = "try" } }, res)
p = payload(res)
assert_eq(p.status, "running", "running status")
assert_eq(p.async_id, task.id, "running async id")

res = response()
tool.run({ params = { title = "Wait for sleep task", async_id = task.id, mode = "wait", timeout = 1 } }, res)
assert_true(not res.sent, "wait should be pending")
registry.succeed(task.id, "final result")
assert_true(res.sent, "wait sends on completion")
assert_eq(res.texts[1], "final result", "success result is verbatim")

local indefinite = registry.create({ tool = "call", label = "indefinite" })
local timer_count = #timers
res = response()
tool.run({ params = { title = "Wait indefinitely", async_id = indefinite.id, mode = "wait", timeout = 0 } }, res)
assert_true(not res.sent, "indefinite wait should be pending")
assert_eq(#timers, timer_count, "indefinite wait should not start a timeout timer")
registry.succeed(indefinite.id, "indefinite result")
assert_true(res.sent, "indefinite wait sends on completion")
assert_eq(res.texts[1], "indefinite result", "indefinite wait result")

res = response()
tool.run({ params = { title = "Consume sleep result", async_id = task.id, mode = "try", consume = true } }, res)
assert_eq(res.texts[1], "final result", "consume returns raw result first")
assert_eq(registry.get(task.id), nil, "consume removes task")

local fail_task = registry.create({ tool = "call", label = "bad" })
registry.fail(fail_task.id, "boom")
res = response()
tool.run({ params = { title = "Check failed task", async_id = fail_task.id, mode = "try" } }, res)
p = payload(res)
assert_eq(p.status, "failed", "failed status")
assert_eq(p.error, "boom", "failed error")

local slow = registry.create({ tool = "call", label = "slow" })
res = response()
tool.run({ params = { title = "Wait for slow task", async_id = slow.id, mode = "wait", timeout = 1 } }, res)
timers[#timers]()
assert_true(res.sent, "wait timeout sends")
p = payload(res)
assert_eq(p.status, "running", "timeout still running")
assert_eq(p.wait_timed_out, true, "timeout flag")

print("get_async_result_spec: OK")
