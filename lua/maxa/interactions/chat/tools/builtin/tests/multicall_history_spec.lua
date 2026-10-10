-- Non-UI identity/history contract. No tool execution or display assertions.
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/multicall_history_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
local history = require("maxa.interactions.chat.tools.builtin.runtime.multicall_history")
local validator = require("maxa.interactions.chat.tools.validator")
local responses = require("maxa.adapters.http.openai_responses")
local inventory = require("maxa.interactions.chat.tools.builtin")
local run_args = {
  { scope = "tool", command = "read", args = '{"path":"README.md"}' },
  { command = "printf safe", opts = '{"async":true}', title = "async" },
  { scope = "tool", command = "read", args = '{"path":"README.md"}', opts = '{"async":true}' },
  { scope = "tool", command = "wait", args = '{"async_id":"history-probe"}' },
  { scope = "tool", command = "wait", args = '{"async_id":"history-probe","title":"explicit target"}' },
}
local call = { id = "fc_original", call_id = "call_original", type = "function", provider_meta = "preserved",
  ["function"] = { name = "multicall", arguments = vim.json.encode({ title = "batch", runs = run_args }) } }
local chat = { opts = { cwd = vim.fn.getcwd() }, messages = {
  { role = "llm", content = "", tools = { calls = { vim.deepcopy(call) } } },
}, tool_registry = { schemas = {} } }
for _, name in ipairs(inventory.names) do
  chat.tool_registry.schemas["<tool>" .. name .. "</tool>"] = { ["function"] = {
    name = name, parameters = inventory.resolve(name).inputSchema,
  } }
end
local before = vim.deepcopy(call)
local calls, raw, execution_params = history.expand(call, run_args, chat)
assert(calls, raw)
assert(#calls == #run_args + 1 and #raw == #run_args and vim.deep_equal(call, before))
assert(calls[2]["function"].name == "read" and calls[3]["function"].name == "run" and calls[4]["function"].name == "run")
assert(calls[2].id ~= calls[2].call_id and calls[2].call_id ~= calls[3].call_id)
assert(vim.json.decode(calls[4]["function"].arguments).opts == '{"async":true}')
assert(vim.json.decode(calls[3]["function"].arguments).title == "async")
for _, index in ipairs({ 4, 5 }) do
  assert(vim.json.decode(calls[index]["function"].arguments).title == nil, "inherited title leaked into history")
  assert(execution_params[index].title == "batch", "execution default missing")
end
assert(vim.json.decode(calls[6]["function"].arguments).title == "explicit target")
local plan = validator.classify_batch({ adapter = responses }, chat, calls,
  { expanded_runs = true, execution_params = execution_params })
assert(not plan.native_batch.error and #plan.corrections == 0)
for _, entry in ipairs(plan.entries) do assert(entry.kind == "valid", entry.reason) end
plan.native_batch.expansion = { raw_runs = raw, original_entries = { plan.entries[1] } }
assert(history.stage(chat, plan))
assert(#chat.messages[1].tools.calls == #calls and chat.messages[1]._meta.multicall_expansion.state == "executing")
-- Pair records reflect actual outputs supplied by the execution owner.
for _, item in ipairs(calls) do
  chat.messages[#chat.messages + 1] = { role = "tool", content = "actual result", tools = { call_id = item.call_id } }
end
history.commit(chat, plan)
local saved = chat.messages[1].tools.calls
assert(#saved == #calls and saved[1].id == call.id and saved[1].call_id == call.call_id)
assert(saved[1].provider_meta == "preserved" and vim.json.decode(saved[1]["function"].arguments).runs == nil)
assert(chat.messages[1]._meta.multicall_expansion.state == "closed")
local wire = responses.handlers.request.build_messages(responses, chat.messages)
assert(#wire.input == #calls * 2 and wire.input[1].type == "function_call"
  and wire.input[#calls + 1].type == "function_call_output")
for index = 1, #calls do assert(wire.input[index].call_id == wire.input[index + #calls].call_id) end
assert(wire.input[1].id == call.id, "provider-issued item identity must be preserved")
for index = 2, #calls do
  assert(wire.input[index].arguments == calls[index]["function"].arguments, "wire rewrote canonical arguments")
  assert(not wire.input[index].arguments:find('"batch"', 1, true), "inherited title leaked onto wire")
  assert(wire.input[index].id == nil, "runtime-authored item IDs must not be sent as provider item IDs")
  assert(saved[index].id == calls[index].id, "local history identity must be preserved")
end
-- Already-saved expanded histories must replay without migration or re-execution.
local restored = vim.json.decode(vim.json.encode(chat.messages))
assert(vim.deep_equal(wire, responses.handlers.request.build_messages(responses, restored)))
local signed = vim.deepcopy(call); signed.thought_signature = "signed"
assert(not history.expand(signed, run_args, chat))
local single = validator.classify_batch({ adapter = responses }, chat, { call })
assert(single.native_batch.runs and not single.native_batch.error)
assert(validator.classify_batch({ adapter = responses }, chat, calls).native_batch.error)
print("multicall_history_spec: schema-shaped runs, sync/async identity, staging/closure and Responses replay passed")
