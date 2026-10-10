-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/call_tools_parallel_cancel_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
local prefix = "maxa.interactions.chat.tools.builtin."
local inventory = require("maxa.interactions.chat.tools.builtin")
local bridge = require(prefix .. "runtime.async_cancel_bridge")
local registry = require(prefix .. "runtime.async_registry")
local adapter = require(prefix .. "runtime.adapter")
local fixture = require(prefix .. "tests.native_batch_fixture")
local pending, started, cancelled = {}, {}, {}
inventory.definitions.read = { name = "read", inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } }, run = function(ctx, response)
  local name = ctx.params.path
  started[#started + 1] = name
  bridge.register_handle({ cancel = function() cancelled[name] = (cancelled[name] or 0) + 1 end })
  pending[name] = response
end }
local chat = { messages = {}, opts = { cwd = vim.fn.getcwd() } }
local function member(path, asynchronous)
  return { scope = "tool", command = "read", args = vim.json.encode({ path = path }),
    opts = asynchronous and '{"async":true}' or nil }
end
local batch = fixture.execute(chat, { title = "cancel scheduling", mode = "sequence", runs = {
  member("background", true), member("active"), member("queued"),
} })
assert(vim.deep_equal(started, { "background", "active" }) and not batch.closed, batch.error)
local submit = { async_id = batch.members[1].text:match("async_id: ([^\n]+)") }
assert(registry.get(submit.async_id).status == "running")
assert(chat.current_tool.cancel("stop scheduling"))
assert(batch.closed and batch.summary.status == "cancelled")
assert(cancelled.active == 1 and cancelled.background == nil and cancelled.queued == nil)
assert(batch.members[2].text:find("TOOL_CANCELLED", 1, true) and batch.members[3].text:find("TOOL_CANCELLED", 1, true))
assert(registry.get(submit.async_id).status == "running", "batch cancellation took ownership of submitted async work")
local count = #batch.outputs
pending.active:text("late result"):send()
assert(#batch.outputs == count and #started == 2, "late completion emitted output or started a queued member")
local killed
adapter.invoke(inventory.resolve("kill"), { chat = chat, cwd = chat.opts.cwd,
  params = { title = "cancel background member", async_id = submit.async_id } }, function(value) killed = value end)
assert(killed and killed.ok and adapter.content_to_result(killed.content):find("status: cancelled", 1, true))
assert(cancelled.background == 1 and registry.get(submit.async_id).status == "cancelled")
pending.background:text("late background result"):send()
assert(registry.get(submit.async_id).status == "cancelled")
print("call_tools_parallel_cancel_spec: scheduler cancellation and independent async ownership passed")
