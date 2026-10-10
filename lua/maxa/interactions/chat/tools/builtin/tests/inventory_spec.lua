-- Focused inventory and native Chat callback contract regression.
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/inventory_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
for _, dependency in ipairs({ "plenary.nvim", "nui.nvim" }) do
  local path = vim.fn.stdpath("data") .. "/lazy/" .. dependency
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
  end
end
local expected = {
  "analyze",
  "ask",
  "multicall",
  "kill",
  "delete",
  "edit",
  "run",
  "fire",
  "wait",
  "keep",
  "load",
  "move",
  "read",
  "write",
  "search",
  "glob",
}

local inventory = require("maxa.interactions.chat.tools.builtin")
assert(vim.deep_equal(expected, inventory.names), "builtin order or exact inventory changed")
assert(vim.tbl_count(inventory.configs) == 16, "expected exactly 16 builtin configs")
assert(inventory.configs.winrun == nil, "retired winrun callback remains")

local schemas = {}
for _, name in ipairs(expected) do
  local definition = inventory.resolve(name)
  local config = inventory.configs[name]
  local callback = config.callback()
  assert(definition and definition.name == name, "definition missing: " .. name)
  assert(type(definition.run) == "function", "Chat-owned callback missing: " .. name)
  assert(definition.handler == nil, "Native MCP handler retained: " .. name)
  assert(config.id == "maxa_builtin:" .. name, "wrong config id: " .. name)
  assert(callback.schema["function"].name == name, "wrong schema name: " .. name)
  assert(type(callback.cmds[1]) == "function", "Chat callback missing: " .. name)
  schemas[name] = vim.deepcopy(definition.inputSchema)
end

local schema_pairs = {
  analyze = "builtin_analyze",
  multicall = "builtin_multicall",
  kill = "builtin_kill",
  delete = "builtin_delete",
  edit = "builtin_edit",
  run = "builtin_run",
  fire = "builtin_fire",
  wait = "builtin_wait",
  keep = "builtin_keep",
  load = "builtin_load",
  move = "builtin_move",
  read = "builtin_read",
  write = "builtin_write",
  search = "builtin_search",
  glob = "builtin_glob",
}
for public_name, module_name in pairs(schema_pairs) do
  local private_definition = require("maxa.interactions.chat.tools.builtin.tools." .. module_name)
  assert(vim.deep_equal(schemas[public_name], private_definition.inputSchema), "schema changed for " .. public_name)
end

for _, name in ipairs({
  "call",
  "execute",
  "load_context",
  "load_server",
  "load_skill",
  "execute_windows_command",
  "winrun",
  "report",
  "search_skill",
  "analyze_image",
  "call_tool",
  "call_tools_parallel",
  "cancel_async_task",
  "cancel",
  "delete_items",
  "edit_file",
  "execute_command",
  "execute_lua",
  "lua",
  "fire_event",
  "get_async_result",
  "invalid_call",
  "keep_tool_result",
  "move_item",
  "read_file",
  "write_file",
  "cmd_runner",
  "create_file",
  "delete_file",
  "file_search",
  "get_changed_files",
  "grep_search",
  "insert_edit_into_file",
  "list_code_usages",
  "memory",
  "next_edit_suggestion",
}) do
  assert(inventory.resolve(name) == nil, "legacy definition remains: " .. name)
end

local declaration = inventory.resolve("multicall")
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local function prepare_declaration(args, enabled)
  return adapter.prepare(declaration, { params = args, native_batch_declaration = enabled, chat = {} })
end
assert(not prepare_declaration({ title = "standalone" }))
for _, args in ipairs({
  { title = "parallel", on_error = "stop" },
  { title = "empty", runs = {} },
  { title = "legacy", calls = {} },
  { title = "async", async = true },
  { title = "limit", max_concurrency = 17 },
}) do assert(not prepare_declaration(args, true)) end
local runs_schema = declaration.inputSchema.properties.runs
assert(runs_schema.minItems == 1 and runs_schema.maxItems == 16)
assert(vim.deep_equal(runs_schema.items.required, { "command" }))
assert(runs_schema.items.properties.label == nil)
assert(vim.deep_equal(runs_schema.items.properties.title.type, { "string", "null" }))
assert(prepare_declaration({ title = "all", max_concurrency = 0 }, true))
assert(prepare_declaration({ title = "cap", max_concurrency = 16 }, true))
local with_runs = assert(prepare_declaration({ title = "member defaults", runs = {
  { scope = "tool", command = "read", args = '{"path":"README.md"}', title = vim.NIL },
} }, true))
assert(with_runs.params.runs[1].title == vim.NIL)
local ready = assert(prepare_declaration({ title = "defaults" }, true))
assert(ready.params.mode == "parallel" and ready.params.max_concurrency == 0 and ready.params.on_error == nil)
ready = assert(prepare_declaration({ title = "sequence", mode = "sequence" }, true))
assert(ready.params.on_error == "stop")
ready = assert(prepare_declaration({ title = "continue", mode = "sequence", on_error = "continue" }, true))
assert(ready.params.on_error == "continue")
local core = require("maxa.interactions.chat.tools.builtin.runtime.tool_call_core")
local retired_result
core.execute({}, { tool = "winrun", params = {} }, function(result)
  retired_result = result
end)
assert(retired_result and retired_result.ok == false, "nested winrun remains executable")
assert(retired_result.error == "Unknown Chat builtin: winrun", "retired winrun must use normal unavailable-tool path")

local config = require("maxa.config")
assert(vim.deep_equal(expected, config.interactions.chat.tools.opts.default_tools), "all builtins must be defaults")
assert(config.interactions.chat.tools.groups == nil, "tool groups must be absent")
assert(config.interactions.chat.tools.opts.system_prompt == nil, "tool system prompt must be absent")

local native = require("maxa.mcphub.native_servers")
assert(native.mcpx == nil, "mcpx Native server must be absent")
assert(native.misc == nil and native["json-artifact"] == nil, "retired Native servers must be absent")
for _, name in ipairs({ "subagent", "session", "genai" }) do
  assert(native[name] ~= nil, "remaining Native server missing: " .. name)
end

print("builtin_inventory_spec: OK")
