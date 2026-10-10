-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/call_tools_parallel_async_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
local prefix = "maxa.interactions.chat.tools.builtin."
local inventory = require("maxa.interactions.chat.tools.builtin")
local adapter = require(prefix .. "runtime.adapter")
local registry = require(prefix .. "runtime.async_registry")
local fixture = require(prefix .. "tests.native_batch_fixture")
local pending, started = {}, {}
inventory.definitions.read = { name = "read", inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } }, run = function(ctx, response)
  started[#started + 1] = ctx.params.path
  pending[ctx.params.path] = response
end }
local chat = { messages = {}, opts = { cwd = vim.fn.getcwd() } }
local batch = fixture.execute(chat, { title = "individual async", mode = "sequence", runs = {
  { scope = "tool", command = "read", args = '{"path":"one"}', opts = '{"async":true}' },
  { scope = "tool", command = "read", args = '{"path":"two"}', opts = '{"async":true}' },
} })
assert(batch.closed and batch.summary.status == "completed", batch.error)
assert(vim.deep_equal(started, { "one", "two" }), "sequence waits for submission, not background completion")
assert(batch.summary.async_id == nil and batch.summary.results == nil and #batch.outputs == 3)
local function submission(text)
  return { async_id = text:match("async_id: ([^\n]+)") }
end
local first, second = submission(batch.members[1].text), submission(batch.members[2].text)
assert(first.async_id and second.async_id and first.async_id ~= second.async_id)
assert(registry.get(first.async_id).status == "running" and registry.get(second.async_id).status == "running")
local function wait(id, consume)
  local result
  adapter.invoke(inventory.resolve("wait"), { chat = chat, cwd = chat.opts.cwd,
    params = { title = "inspect member", async_id = id, mode = "try", consume = consume } }, function(value) result = value end)
  assert(result and result.ok, result and result.error)
  return adapter.content_to_result(result.content)
end
assert(wait(first.async_id):find("status: running", 1, true))
local complete = string.rep("full asynchronous output\n", 600)
pending.two:text("second done"):send()
pending.one:text(complete):send()
assert(wait(first.async_id, true) == complete, "wait must return the full original member result")
assert(wait(second.async_id, true) == "second done")
assert(wait(first.async_id):find("status: not_found", 1, true))
assert(batch.members[1].text:find("status: running", 1, true), "saved submission was rewritten by completion")
print("call_tools_parallel_async_spec: independent IDs, submission ordering and raw wait results passed")
