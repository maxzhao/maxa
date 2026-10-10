-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/call_tools_parallel_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
local prefix = "maxa.interactions.chat.tools.builtin."
local adapter = require(prefix .. "runtime.adapter")
local registry = require(prefix .. "runtime.async_registry")
local bridge = require(prefix .. "runtime.async_cancel_bridge")
local chat = { messages = {}, opts = { cwd = vim.fn.getcwd() } }
local order, pending, cancelled = {}, {}, 0
local connected, authorized, server_disabled, tool_disabled, native = true, true, false, false, false
local ensures, connection_done = 0, nil
package.loaded["maxa.session.abilities"] = {
  catalog = function() return { order = {}, abilities = {} } end,
  resolve_tool = function(owner, cwd, ability, tool)
    assert(owner == chat and cwd == chat.opts.cwd)
    if ability == "unloaded" or not authorized then return nil, "Ability not loaded" end
    local properties = {
      defer = { type = "boolean" }, fail = { type = "boolean" }, count = { type = "integer", minimum = 1 },
    }
    if tool == "needs_title" or tool == "optional_title" then properties.title = { type = "string" } end
    return { server_name = ability, tool_name = tool,
      tool = { inputSchema = { type = "object", properties = properties,
        required = tool == "needs_title" and { "title" } or nil, additionalProperties = false } } }
  end,
}
package.loaded["maxa.mcphub.utils.config_manager"] = {
  is_server_disabled = function() return server_disabled end,
  is_effective_tool_disabled = function() return tool_disabled end,
}
package.loaded["maxa.mcphub"] = { get_project_transport = function() return {
  inspect_server = function(_, _, done)
    done({ connected = connected, server = { capabilities = { tools = {
      { name = "first" }, { name = "interactive", interactive = true },
    } } } })
  end,
  resolve = function() return { catalog = { servers = { demo = { is_native = native } } } } end,
  ensure_server = function(cwd, name, done)
    assert(cwd == chat.opts.cwd and name == "demo")
    ensures, connection_done = ensures + 1, done
  end,
  call_tool = function(_, _, tool, args, opts)
    order[#order + 1] = tool
    assert(args.async == nil, "wrapper async leaked")
    if tool == "optional_title" then assert(args.title == nil, "optional MCP title inherited") end
    if tool == "needs_title" then assert(args.title == "business title", "MCP title changed") end
    if args.defer then
      pending[tool] = opts.callback
      bridge.register_handle({ cancel = function() cancelled = cancelled + 1 end })
    elseif args.fail then opts.callback({ isError = true, content = { { type = "text", text = "failure" } } })
    else opts.callback({ content = { { type = "text", text = tool } } }) end
  end,
} end }
local run = require(prefix .. "tools.builtin_run")
local batch = require(prefix .. "tests.native_batch_fixture")
local function invoke(definition, args)
  if definition == batch then return batch.execute(chat, args) end
  local holder = {}
  adapter.invoke(definition, { chat = chat, cwd = chat.opts.cwd, params = args,
    caller = { maxa_ai = { chat = chat } } }, function(value) holder.result = value end)
  return holder
end
local function payload(holder)
  assert(holder.result and holder.result.ok, holder.result and holder.result.error)
  local text = adapter.content_to_result(holder.result.content)
  return { async_id = text:match("async_id: ([^\n]+)") }
end
local function member(label, args, asynchronous)
  local opts = asynchronous ~= nil and vim.json.encode({ async = asynchronous }) or nil
  return { scope = "tool", command = "@demo:" .. label,
    args = next(args or {}) and vim.json.encode(args) or "{}", opts = opts }
end
local function reject(definition, args, reason)
  local before = #order
  local h = invoke(definition, args)
  local err = definition == batch and h.error or (h.result and not h.result.ok and h.result.error)
  assert(err and err:find(reason, 1, true), err)
  assert(#order == before, "invalid request partially executed")
end
reject(run, { command = "echo safe" }, "title")
for _, target in ipairs({ "run", "multicall" }) do
  reject(run, { title = "guard", scope = "tool", command = target }, "cannot call")
  reject(batch, { title = "guard", runs = { member("first"), { scope = "tool", command = target } } }, "cannot call")
end
reject(run, { title = "no injection", command = "echo safe", json_patches = vim.NIL }, "not supported")
reject(batch, { title = "no injection", runs = { member("first") }, json_patches = {} }, "unknown property")
reject(batch, { title = "no batch async", async = true, runs = { member("first") } }, "unknown property")
reject(run, { title = "bad object", scope = "tool", command = "@demo:first", args = "[]" }, "decode")
reject(run, { title = "bad argv", scope = "tool", command = "@demo:first", args = {} }, "JSON object")
reject(run, { title = "outer timeout", scope = "tool", command = "@demo:first", timeout = 1 }, "outer timeout")
local single = invoke(run, { title = "single", scope = "tool", command = "@demo:single", args = "{}" })
assert(single.result.ok and adapter.content_to_result(single.result.content) == "single")
order = {}
local seq = invoke(batch, { title = "sequence", mode = "sequence", on_error = "continue", max_concurrency = 8,
  runs = { member("one", { defer = true }), member("bad", { fail = true }), member("three") } })
assert(vim.deep_equal(order, { "one" }) and not seq.closed, seq.error or vim.inspect(seq))
pending.one({ content = { { type = "text", text = "done one" } } })
assert(seq.closed and seq.summary.status == "failed")
assert(vim.deep_equal(order, { "one", "bad", "three" }))
assert(seq.members[1].text == "done one" and not seq.members[2].ok and seq.members[3].ok)
order = {}
local par = invoke(batch, { title = "parallel", max_concurrency = 2,
  runs = { member("p1", { defer = true }), member("p2", { defer = true }), member("p3") } })
assert(vim.deep_equal(order, { "p1", "p2" }))
pending.p2({ content = { { type = "text", text = "done two" } } })
assert(vim.deep_equal(order, { "p1", "p2", "p3" }) and not par.closed)
pending.p1({ content = { { type = "text", text = "done one" } } })
assert(par.closed and par.summary.status == "completed")
assert(par.members[1].text == "done one" and par.members[2].text == "done two")
chat._maxa_hidden_image_analysis = true
reject(run, { title = "hidden", scope = "tool", command = "read", args = "{}" }, "Hidden")
reject(batch, { title = "hidden", runs = { member("first") } }, "Hidden")
chat._maxa_hidden_image_analysis = nil
reject(run, { title = "typed MCP", scope = "tool", command = "@demo:first", args = '{"count":"1"}' }, "$.count")
reject(batch, { title = "no labels", runs = { { label = "old", command = "echo safe" } } }, "unknown property")

-- Inner target prepare belongs to that target, not the already-prepared member run.
local inventory = require("maxa.interactions.chat.tools.builtin")
local old = inventory.definitions.read
local prepared_count, execution_count = 0, 0
inventory.definitions.read = {
  name = "read", inputSchema = { type = "object", properties = { value = { type = "string" } }, required = { "value" } },
  prepare = function(ctx) prepared_count = prepared_count + 1; return { value = tonumber(ctx.params.value) } end,
  run = function(ctx, res) execution_count = execution_count + 1; assert(ctx.params.value == 3); return res:text("target prepared"):send() end,
}
local wrapped = invoke(run, { title = "prepare target", scope = "tool", command = "read", args = '{"value":"3"}' })
assert(wrapped.result.ok and prepared_count == 1 and execution_count == 1)
local member_result = invoke(batch, { title = "prepare target batch", runs = {
  { scope = "tool", command = "read", args = '{"value":"3"}' },
} })
assert(member_result.summary.status == "completed" and prepared_count == 2 and execution_count == 2)
assert(member_result.members[1].text == "target prepared")
local invalid = invoke(run, { title = "bad target", scope = "tool", command = "read", args = '{"value":3}' })
assert(not invalid.result.ok and prepared_count == 2 and execution_count == 2)
inventory.definitions.read = old

-- Required first-party titles inherit before validation without rewriting raw args.
local wait = inventory.resolve("wait")
local wait_run, titles = wait.run, {}
wait.run = function(ctx, response)
  titles[#titles + 1] = ctx.params.title
  return wait_run(ctx, response)
end
local missing_title = { async_id = "title-inheritance-probe", mode = "try" }
local single_args = { title = "outer title", scope = "tool", command = "wait", args = vim.json.encode(missing_title) }
local original = vim.deepcopy(single_args)
assert(invoke(run, single_args).result.ok)
assert(titles[1] == "outer title" and vim.deep_equal(single_args, original))
assert(invoke(run, { title = "outer title", scope = "tool", command = "wait",
  args = vim.json.encode(vim.tbl_extend("force", missing_title, { title = vim.NIL })) }).result.ok)
assert(titles[2] == "outer title")
local batch_args = { title = "batch title", runs = {
  { scope = "tool", command = "wait", args = vim.json.encode(missing_title), title = vim.NIL },
  { scope = "tool", command = "wait", args = vim.json.encode(missing_title), title = "member title" },
  { scope = "tool", command = "wait", args = vim.json.encode(vim.tbl_extend("force", missing_title, { title = "target title" })) },
} }
local raw_batch = vim.deepcopy(batch_args)
assert(invoke(batch, batch_args).summary.status == "completed")
assert(vim.deep_equal(titles, { "outer title", "outer title", "batch title", "member title", "target title" }))
assert(vim.deep_equal(batch_args, raw_batch), "title inheritance mutated raw batch args")
reject(wait, missing_title, "title")
for _, invalid_title in ipairs({ "", "   ", 42 }) do
  reject(run, { title = "outer title", scope = "tool", command = "wait",
    args = vim.json.encode(vim.tbl_extend("force", missing_title, { title = invalid_title })) }, "title")
end
wait.run = wait_run

-- MCP declarations retain their own required/optional business-title contract.
reject(run, { title = "wrapper title", scope = "tool", command = "@demo:needs_title", args = "{}" }, "title")
assert(invoke(run, { title = "wrapper title", scope = "tool", command = "@demo:needs_title",
  args = '{"title":"business title"}' }).result.ok)
assert(invoke(run, { title = "wrapper title", scope = "tool", command = "@demo:optional_title", args = "{}" }).result.ok)
-- Disconnected sources resolve for preflight but connect only after validation.
local core = require(prefix .. "runtime.tool_call_core")
connected, native, order = false, true, {}
local before_ensure = ensures
local preflight
core.resolve_target({ chat = chat, cwd = chat.opts.cwd }, "@demo:first", function(target, err)
  assert(not err)
  preflight = target
end)
assert(preflight and not preflight.connected and ensures == before_ensure)
reject(batch, { title = "offline interaction", runs = { member("first"), member("interactive") } }, "interactive")
assert(ensures == before_ensure, "preflight connected a source before rejecting the batch")
reject(run, { title = "invalid offline params", scope = "tool", command = "@demo:first", args = '{"count":"1"}' }, "$.count")
server_disabled = true
reject(run, { title = "disabled server", scope = "tool", command = "@demo:first", args = "{}" }, "disabled")
server_disabled, tool_disabled = false, true
reject(run, { title = "disabled tool", scope = "tool", command = "@demo:first", args = "{}" }, "disabled")
tool_disabled, authorized = false, false
reject(run, { title = "unready", scope = "tool", command = "@demo:first", args = "{}" }, "not loaded")
authorized = true
assert(ensures == before_ensure, "denied/invalid requests connected a source")

local offline = invoke(run, { title = "offline", scope = "tool", command = "@demo:first", args = "{}" })
assert(not offline.result and #order == 0 and ensures == before_ensure + 1)
connected = true
connection_done({})
assert(offline.result.ok and vim.deep_equal(order, { "first" }))

connected = false
local failed = invoke(run, { title = "startup error", scope = "tool", command = "@demo:first", args = "{}" })
local calls_before = #order
connection_done(nil, "startup failed")
assert(not failed.result.ok and failed.result.error:find("startup failed", 1, true) and #order == calls_before)

local revoked = invoke(run, { title = "revoked while waiting", scope = "tool", command = "@demo:first", args = "{}" })
connected, authorized = true, false
connection_done({})
assert(not revoked.result.ok and #order == calls_before)
authorized, connected = true, false
local policy_changed = invoke(run, { title = "disabled while waiting", scope = "tool", command = "@demo:first", args = "{}" })
connected, tool_disabled = true, true
connection_done({})
assert(not policy_changed.result.ok and #order == calls_before)
tool_disabled, connected = false, false

local waiting = payload(invoke(run, { title = "cancel connection wait", scope = "tool", command = "@demo:first",
  args = "{}", opts = '{"async":true}' }))
assert(registry.cancel(waiting.async_id, "stop connecting"))
connected = true
connection_done({})
assert(registry.get(waiting.async_id).status == "cancelled" and #order == calls_before)
connected = false
local closed = invoke(run, { title = "close during connection", scope = "tool", command = "@demo:first", args = "{}" })
chat._closed, connected = true, true
connection_done({})
assert(not closed.result and #order == calls_before)
chat._closed = nil

-- Actual batch members connect after the whole side-effect-free preflight.
connected, order = false, {}
local reconnect_batch = invoke(batch, { title = "offline sequence", mode = "sequence", runs = { member("first"), member("first") } })
assert(not reconnect_batch.closed and #order == 0)
connected = true
connection_done({})
assert(reconnect_batch.summary.status == "completed" and vim.deep_equal(order, { "first", "first" }))

-- An External source uses the same reconnect path without a local definition.
connected, native, order = false, false, {}
local external = invoke(run, { title = "external reconnect", scope = "tool", command = "@demo:external", args = "{}" })
assert(not external.result and #order == 0)
connected = true
connection_done({})
assert(external.result.ok and vim.deep_equal(order, { "external" }))
print("MULTICALL_TOOL_DISPATCH_SPEC_OK")
