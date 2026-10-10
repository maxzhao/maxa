-- Backend-only scheduler regression; no UI appearance assertions.
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/native_batch_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
local inventory = require("maxa.interactions.chat.tools.builtin")
local fixture = require("maxa.interactions.chat.tools.builtin.tests.native_batch_fixture")
local chat = { messages = {}, opts = { cwd = vim.fn.getcwd() } }
local pending, started = {}, {}
inventory.definitions.read = {
  name = "read", inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } },
  run = function(ctx, response)
    started[#started + 1] = ctx.params.path
    pending[ctx.params.path] = response
  end,
}
local function members(count)
  local list = {}
  for index = 1, count do list[index] = { name = "read", args = { path = tostring(index) } } end
  return list
end
local function launch(options, count)
  pending, started = {}, {}
  return fixture.execute(chat, vim.tbl_extend("force", { title = "scheduler" }, options or {}), members(count))
end
local function done(index, failure)
  local response = assert(pending[tostring(index)], "member did not start: " .. index)
  pending[tostring(index)] = nil
  if failure then response:error("failure " .. index) else response:text("member " .. index):send() end
end
-- Omitted and zero launch all 16, including before any response completes.
for _, options in ipairs({ {}, { max_concurrency = 0 }, { max_concurrency = 16 } }) do
  local batch = launch(options, 16)
  assert(#started == 16 and not batch.closed, batch.error)
  for index = 16, 1, -1 do done(index) end
  assert(batch.closed and batch.summary.succeeded == 16 and batch.summary.results == nil)
  assert(batch.outputs[#batch.outputs].text == "status: completed\nmode: parallel\nmembers: 16\nsucceeded: 16\nfailed: 0\nnot_executed: 0")
  assert(#batch.outputs == 17, "one full result per member plus declaration closure facts")
  for index = 1, 16 do assert(batch.members[index].text == "member " .. index) end
end
local capped = launch({ max_concurrency = 2 }, 4)
assert(vim.deep_equal(started, { "1", "2" }))
done(2); assert(vim.deep_equal(started, { "1", "2", "3" }) and not capped.closed)
done(1); assert(vim.deep_equal(started, { "1", "2", "3", "4" }))
done(4); done(3); assert(capped.closed and capped.summary.succeeded == 4)
local one = launch({ max_concurrency = 1 }, 2)
assert(#started == 1); done(1); assert(#started == 2); done(2); assert(one.closed)
for _, options in ipairs({ { max_concurrency = 17 }, { max_concurrency = -1 }, { on_error = "continue" }, { async = true } }) do
  local rejected = launch(options, 2)
  assert(rejected.closed and rejected.error and #started == 0, "invalid declaration partially executed")
end
local overflow = launch({}, 17)
assert(overflow.error and #started == 0, "17 members accepted")
for _, options in ipairs({ { mode = "sequence" }, { mode = "sequence", on_error = "stop" } }) do
  local stopped = launch(options, 3)
  assert(#started == 1); done(1, true)
  assert(stopped.closed and #started == 1 and stopped.summary.first_failed_index == 1)
  assert(stopped.summary.failed == 1 and stopped.summary.not_executed == 2)
  assert(stopped.outputs[#stopped.outputs].text == "status: failed\nmode: sequence\non_error: stop\nmembers: 3\nsucceeded: 0\nfailed: 1\nnot_executed: 2\nfirst_failed_index: 1")
  for index = 2, 3 do assert(stopped.members[index].text:find("NOT_EXECUTED_SEQUENCE_STOP", 1, true)) end
end
local continued = launch({ mode = "sequence", on_error = "continue", max_concurrency = 16 }, 3)
assert(#started == 1); done(1, true); assert(#started == 2); done(2); assert(#started == 3); done(3)
assert(continued.closed and continued.summary.failed == 1 and continued.summary.succeeded == 2)
-- Preflight is atomic even if an earlier native member is valid.
for _, bad in ipairs({
  { name = "read", args = {} }, { name = "ask", args = { mode = "input" } },
  { name = "multicall", args = { title = "nested" } },
  { name = "run", args = { title = "nested", scope = "tool", command = "multicall" } },
  { name = "run", args = { title = "extension", scope = "@unloaded:ops", command = "noop" } },
}) do
  started = {}
  local rejected = fixture.execute(chat, { title = "preflight" }, { members(1)[1], bad })
  assert(rejected.closed and rejected.error and #started == 0, rejected.error)
end
local not_model = fixture.execute(chat, { title = "not model" }, members(1), {})
assert(not_model.error and #started == 0)
-- Runs use the real expansion/staging/closure path and keep large member text whole.
local expanded = fixture.execute(chat, { title = "expanded", runs = {
  { scope = "tool", command = "read", args = '{"path":"large"}' },
} })
local large = string.rep("full member output\n", 900)
pending.large:text(large):send()
assert(expanded.closed and expanded.members[1].text == large)
assert(#expanded.message.tools.calls == 2 and expanded.message._meta.multicall_expansion.state == "closed")
assert(vim.json.decode(expanded.message.tools.calls[1]["function"].arguments).runs == nil)
assert(expanded.summary.results == nil and #expanded.outputs == 2)
-- Retain real shell execution as a native run member.
local shell = fixture.execute(chat, { title = "shell", runs = { { command = "printf native-shell" } } })
assert(vim.wait(5000, function() return shell.closed end), "shell member did not finish")
assert(shell.summary.status == "completed" and shell.members[1].text:find("native-shell", 1, true), shell.error)
print("NATIVE_BATCH_SPEC_OK")
