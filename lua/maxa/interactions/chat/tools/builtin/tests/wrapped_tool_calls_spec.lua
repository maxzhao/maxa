-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/wrapped_tool_calls_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local wrapped = require("maxa.interactions.chat.tools.builtin.runtime.wrapped_tool_calls")
local function call(id, name, args)
  return { id = id, ["function"] = { name = name, arguments = vim.json.encode(args) } }
end
local direct = { role = "assistant", tools = { calls = { call("d", "load", { target = "task-admin" }) } } }
local expanded = wrapped.iter_message_calls(direct)
assert(#expanded == 1 and expanded[1].tool_name == "load" and expanded[1].args.target == "task-admin")

local nested = { role = "assistant", tools = { calls = {
  call("c", "call", { tool = "load", params = { target = "justfile.md" } }),
  call("m", "multicall", { calls = {
    { label = "ability", tool = "load", params = { target = "mcp-creator" } },
    { label = "server", tool = "load", params = { target = "time" } },
  } }),
} } }
local semantic = wrapped.iter_message_calls(nested)
assert(#semantic == 3)
assert(semantic[1].tool_name == "load" and semantic[1].args.target == "justfile.md")
assert(semantic[2].args.target == "mcp-creator" and semantic[3].args.target == "time")

local ids = wrapped.context_ids_for_loaded_call("load", { target = "example" })
assert(vim.tbl_contains(ids, "ability:revision:example"))
assert(vim.tbl_contains(ids, "ability:instructions:example"))
local reference_ids = wrapped.context_ids_for_loaded_call("load", { target = "#example[/references/guide.md]" })
assert(reference_ids[1] == "ability:reference:file:#example[/references/guide.md]")
assert(reference_ids[2] == "ability:reference:resource:#example[/references/guide.md]")
local current = wrapped.iter_message_calls({ role = "assistant", tools = { calls = {
  call("r", "run", { title = "load", scope = "tool", command = "load", args = '{"target":"neovim"}' }),
  call("b", "multicall", { title = "batch" }),
  call("b-1", "load", { target = "time" }),
  call("b-2", "run", { title = "shell", command = "echo safe" }),
} } })
assert(#current == 4 and current[1].args.target == "neovim" and current[1].call_id == "r")
assert(current[2].tool_name == "multicall" and current[2].call_id == "b")
assert(current[3].args.target == "time" and current[3].call_id == "b-1" and current[3].index == nil)
assert(current[4].tool_name == "run" and current[4].args.command == "echo safe" and current[4].call_id == "b-2")
print("WRAPPED_TOOL_CALLS_ABILITY_OK")
