-- Run: nvim --headless -u NONE -l lua/maxa/session/builtin_registry_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary) == 1 then
  vim.opt.runtimepath:append(plenary)
end

local registry = require("maxa.session.builtin_registry")
local retired = {
  "call",
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
  "load_context",
  "load_server",
  "load_skill",
  "move_item",
  "read_file",
  "write_file",
  "winrun",
  "report",
  "search_skill",
}
local stored_schemas = {
  ["<tool>read</tool>"] = { type = "function", ["function"] = { name = "stale-read" } },
  ["<tool>session__read_file</tool>"] = { type = "function", ["function"] = { name = "session__read_file" } },
  ["<tool>pause_loop</tool>"] = { type = "function", ["function"] = { name = "pause_loop" } },
}
local stored_in_use = { read = true, session__read_file = true, pause_loop = true }
for _, name in ipairs(retired) do
  stored_schemas["<tool>" .. name .. "</tool>"] = { type = "function", ["function"] = { name = name } }
  stored_in_use[name] = true
  assert(registry.is_retired_schema("<tool>" .. name .. "</tool>", stored_schemas["<tool>" .. name .. "</tool>"]))
end
assert(registry.is_retired_schema(nil, { type = "function", ["function"] = { name = "winrun" } }))
assert(not registry.is_retired_schema("<tool>run</tool>", { name = "run" }))
local original_schemas, original_in_use = vim.deepcopy(stored_schemas), vim.deepcopy(stored_in_use)

local schemas, in_use = registry.reconcile(stored_schemas, stored_in_use)
assert(vim.deep_equal(stored_schemas, original_schemas), "restore must not rewrite stored schemas")
assert(vim.deep_equal(stored_in_use, original_in_use), "restore must not rewrite stored tool identities")
for _, name in ipairs(retired) do
  assert(schemas["<tool>" .. name .. "</tool>"] == nil, "retired schema remains: " .. name)
  assert(in_use[name] == nil, "retired in_use remains: " .. name)
end
assert(schemas["<tool>session__read_file</tool>"] == nil and in_use.session__read_file == nil)
assert(schemas["<tool>pause_loop</tool>"] == nil and in_use.pause_loop == nil)
assert(vim.tbl_count(schemas) == 17 and vim.tbl_count(in_use) == 17)
local current_multicall = schemas["<tool>multicall</tool>"]
assert(not registry.is_retired_schema("<tool>multicall</tool>", current_multicall))
assert(registry.is_retired_schema("<tool>multicall</tool>", { ["function"] = { name = "multicall", parameters = {
  properties = { calls = { type = "array" } },
} } }))
assert(registry.is_retired_schema("<tool>multicall</tool>", { ["function"] = { name = "multicall" } }))
for _, name in ipairs(require("maxa.interactions.chat.tools.builtin").names) do
  local schema = schemas["<tool>" .. name .. "</tool>"]
  assert(schema, "missing builtin schema: " .. name)
  local fn = schema["function"] or schema
  assert(fn.name == name, "current schema did not replace stored schema: " .. name)
  assert(in_use[name], "missing current in_use: " .. name)
end
print("builtin_registry_test: OK")
