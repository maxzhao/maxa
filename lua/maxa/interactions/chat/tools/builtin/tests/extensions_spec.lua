-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/extensions_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary) == 1 then vim.opt.runtimepath:append(plenary) end
package.loaded["maxa.config"] = { constants = { USER_ROLE = "user", LLM_ROLE = "assistant" } }
package.loaded["maxa.mcphub.utils.config_manager"] = {
  get_effective_catalog = function() return { servers = {} } end,
  is_server_disabled = function() return false end,
}
local root = vim.fn.tempname()
local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
end
local function package(name, body)
  local dir = root .. "/.maxa/abilities/" .. name
  write(dir .. "/SKILL.md", "---\nname: " .. name .. "\ndescription: Extension fixture.\n---\nFixture instructions.")
  write(dir .. "/ABILITY.yaml", "builtin_extensions: [search]\n")
  write(dir .. "/builtin/search.lua", body)
  return dir
end
local function script(text)
  return string.format([[return {
    match = function(ctx) return ctx.params.scope == "symbols" end,
    run = function(ctx, response) return response:text(%q):send() end,
  }]], text)
end
local first = package("first", script("FIRST"))
package("second", script("SECOND"))
local state = require("maxa.session.abilities")
local catalog = require("maxa.abilities.catalog")
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local inventory = require("maxa.interactions.chat.tools.builtin")
local chat = { messages = {}, opts = { cwd = root } }
local function enable(name)
  local ability = assert(catalog.resolve(name, root))
  local revision = state.build_revision({ ability = ability })
  local call_id = "load-" .. name .. "-" .. #chat.messages
  local _, result = state.synthetic_catalog_pair(revision, call_id)
  chat.messages[#chat.messages + 1] = result
  vim.list_extend(chat.messages, state.build_context_batch(revision, "Fixture instructions.", nil, call_id))
end
local default_calls = 0
inventory.definitions.search = {
  name = "search",
  inputSchema = { type = "object", properties = { scope = { type = "string" } } },
  run = function(_, response)
    default_calls = default_calls + 1
    return response:text("DEFAULT"):send()
  end,
}
local function context(params, owner)
  return { chat = owner or chat, cwd = root, params = params or {}, caller = { maxa_ai = { chat = owner or chat } } }
end
local function invoke(tool, params, owner)
  local result
  adapter.invoke(tool, context(params, owner), function(value) result = value end)
  assert(result, "synchronous fixture did not complete")
  return result
end
local function text(result)
  assert(result.ok, result.error)
  return adapter.content_to_result(result.content)
end
assert(text(invoke(inventory.definitions.search, { scope = "symbols" })) == "DEFAULT")
enable("first")
enable("second")
assert(text(invoke(inventory.definitions.search, { scope = "symbols" })) == "FIRST")
assert(text(invoke(inventory.definitions.search, { scope = "files" })) == "DEFAULT")
assert(text(invoke(inventory.definitions.search, { scope = "symbols" }, { messages = {} })) == "DEFAULT")
enable("first") -- a refreshed revision must not move first behind second
assert(text(invoke(inventory.definitions.search, { scope = "symbols" })) == "FIRST")
local restored = { messages = vim.deepcopy(chat.messages), opts = { cwd = root } }
assert(text(invoke(inventory.definitions.search, { scope = "symbols" }, restored)) == "FIRST")

write(first .. "/builtin/search.lua", script("EDITED"))
assert(text(invoke(inventory.definitions.search, { scope = "symbols" })) == "EDITED", "code edits must apply without reload")
write(first .. "/ABILITY.yaml", "builtin_extensions: []\n")
assert(text(invoke(inventory.definitions.search, { scope = "symbols" })) == "SECOND", "permission edits must apply without reload")
write(first .. "/ABILITY.yaml", "builtin_extensions: [search]\n")
local call = require("maxa.interactions.chat.tools.builtin.tools.builtin_run")
assert(text(invoke(call, { title = "search", scope = "tool", command = "search", args = '{"scope":"symbols"}' })) == "EDITED")
-- multicall is an execution declaration, never an Ability interception point.
write(first .. "/ABILITY.yaml", "builtin_extensions: [search, multicall]\n")
write(first .. "/builtin/multicall.lua", "error('multicall extension must never be loaded')")
local forbidden, forbidden_err = catalog.resolve("first", root)
assert(not forbidden and forbidden_err:find("builtin_extensions cannot extend multicall", 1, true), forbidden_err)
local declaration = adapter.child_context(context(), "multicall", { title = "Reserved batch" })
declaration.native_batch_declaration = true
local declaration_result
adapter.invoke(inventory.resolve("multicall"), declaration, function(result) declaration_result = result end)
assert(declaration_result and not declaration_result.ok)
assert(declaration_result.error:find("multicall requires a complete native model tool batch", 1, true),
  "multicall must bypass extension selection even when a loaded package now has an invalid declaration")
write(first .. "/ABILITY.yaml", "builtin_extensions: [search]\n")
local multicall = require("maxa.interactions.chat.tools.builtin.tests.native_batch_fixture")
local batch = multicall.execute(chat, {
  title = "Extension paths", runs = {
    { scope = "tool", command = "search", args = '{"scope":"symbols"}' },
    { scope = "tool", command = "search", args = '{"scope":"files"}' },
  },
})
assert(batch.summary.status == "completed" and batch.members[1].text == "EDITED" and batch.members[2].text == "DEFAULT")
-- Schema upgrades/invalid metadata in unrelated loaded packages must not lock
-- ordinary recovery builtins. Known declarations for this builtin stay closed.
local extensions = require("maxa.interactions.chat.tools.builtin.runtime.extensions")
write(first .. "/ABILITY.yaml", "builtin_extensions: [search]\nfuture_suite_field: [game-development]\n")
local recovery, recovery_err = extensions.select("load", context())
assert(recovery == nil and recovery_err == nil, "unrelated schema error blocked load: " .. tostring(recovery_err))
local broken, broken_err = extensions.select("search", context({ scope = "symbols" }))
assert(not broken and broken_err:find("unknown field future_suite_field", 1, true), broken_err)
assert(not invoke(inventory.definitions.search, { scope = "symbols" }).ok, "declared broken extension must fail closed")
write(first .. "/ABILITY.yaml", "builtin_extensions: [search]\n")
local unrelated = package("unrelated", script("UNRELATED"))
write(unrelated .. "/ABILITY.yaml", "builtin_extensions: []\nsuite: [game-development]\n")
enable("unrelated")
write(unrelated .. "/ABILITY.yaml", "future_suite_field: [game-development]\n")
assert(text(invoke(inventory.definitions.search, { scope = "files" })) == "DEFAULT", "unrelated metadata blocked actual builtin dispatch")
vim.fn.delete(unrelated, "rf")
local before_errors = default_calls
for _, body in ipairs({
  "error('module exploded')",
  "return {}",
  "return {match=function() error('match exploded') end, run=function() end}",
  "return {match=function() return nil end, run=function() end}",
  "return {match=function() return true end, run=function() error('run exploded') end}",
  "return {match=function() return true end, run=function(_, response) return response:error('explicit failure') end}",
}) do
  write(first .. "/builtin/search.lua", body)
  local result = invoke(inventory.definitions.search, { scope = "symbols" })
  assert(not result.ok and result.error:find("Ability 'first' builtin 'search':", 1, true), result.error)
end
vim.fn.delete(first .. "/builtin/search.lua")
assert(not invoke(inventory.definitions.search, { scope = "symbols" }).ok)
assert(default_calls == before_errors, "extension errors must not execute the default")

write(first .. "/builtin/search.lua", [[return {
  match = function() return true end,
  run = function(ctx, response)
    require("maxa.interactions.chat.tools.builtin.runtime.tool_call_core").execute(ctx,
      {tool="search", params={scope="symbols"}}, function(result)
        if result.ok then response:text("BAD RECURSION"):send() else response:error(result.error) end
      end)
  end,
}]])
local recursive = invoke(inventory.definitions.search, { scope = "symbols" })
assert(not recursive.ok and recursive.error:find("recursive extension dispatch", 1, true))

write(first .. "/builtin/search.lua", [[return {
  match = function() return true end,
  run = function(_, response)
    vim.defer_fn(function() response:text("ASYNC"):send(); response:error("late error") end, 1)
  end,
}]])
local calls, async_result = 0
adapter.invoke(inventory.definitions.search, context({}), function(result)
  calls = calls + 1
  async_result = result
end)
assert(vim.wait(1000, function() return async_result ~= nil end))
assert(text(async_result) == "ASYNC" and calls == 1)
-- Semantic read owns its 20k protocol; generic preview truncation must not replace it.
write(first .. "/ABILITY.yaml", "builtin_extensions: [search, read]\n")
write(first .. "/builtin/read.lua", [[return {
  match=function() return true end,
  run=function(_, response) response:text("next_cursor: none\n---\n" .. string.rep("x", 19000)):send() end,
}]])
local read = inventory.resolve("read")
local large = text(invoke(read, { path = "semantic" }))
assert(#large > 10500 and large:match("^next_cursor: none\n%-%-%-\n"))
write(first .. "/builtin/read.lua", [[return {
  match=function() return true end,
  run=function(_, response) response:text(string.rep("x", 20001)):send() end,
}]])
assert(not invoke(read, { path = "semantic" }).ok, "read extension must retain a hard output bound")
-- run preparation is shared by direct and wrapped dispatch, before matching.
local run_definition = inventory.resolve("run")
local run_defaults = 0
inventory.definitions.run = {
  name = "run",
  inputSchema = run_definition.inputSchema,
  prepare = run_definition.prepare,
  run = function(ctx, response)
    assert(ctx.params.scope == "shell" and ctx.params.cwd == root)
    run_defaults = run_defaults + 1
    return response:text("SHELL_DEFAULT"):send()
  end,
}
write(first .. "/ABILITY.yaml", "builtin_extensions: [search, read, run]\n")
_G.run_prepare_matches = 0
write(first .. "/builtin/run.lua", [[return {
  match = function(ctx)
    _G.run_prepare_matches = _G.run_prepare_matches + 1
    if ctx.params.scope ~= "@fixture:ops" then return false end
    assert(type(ctx.params.args) == "table" and ctx.params.args.value == 7)
    assert(ctx.params.args.nested[1] == vim.NIL)
    assert(type(ctx.params.opts) == "table" and ctx.params.opts.custom == true)
    assert(ctx.caller.maxa_ai.chat == ctx.chat)
    return true
  end,
  run = function(ctx, response)
    assert(ctx.params.command == "inspect" and ctx.params.cwd == ctx.cwd)
    return response:text("PREPARED"):send()
  end,
}]])
local raw = { title = "prepared operation", scope = "@fixture:ops", command = "inspect", args = '{"value":7,"nested":[null]}', opts = '{"custom":true}' }
assert(text(invoke(inventory.definitions.run, raw)) == "PREPARED")
assert(type(raw.args) == "string" and type(raw.opts) == "string" and raw.cwd == nil)
local prepared_batch = multicall.execute(chat, {
  title = "Prepared run", runs = { vim.deepcopy(raw) },
})
assert(prepared_batch.members[1].text == "PREPARED")
assert(text(invoke(inventory.definitions.run, { title = "noop", command = "noop" })) == "SHELL_DEFAULT")
assert(run_defaults == 1)
local matches_before_error = _G.run_prepare_matches
for _, field in ipairs({ "args", "opts" }) do
  for _, value in ipairs({ "", "[]", "null", "true", "{" }) do
    local invalid = vim.tbl_extend("force", {}, raw, { [field] = value })
    assert(not invoke(inventory.definitions.run, invalid).ok)
  end
end
assert(_G.run_prepare_matches == matches_before_error, "invalid parsing reached match")
local good_prepare = inventory.definitions.run.prepare
for _, bad in ipairs({ false, function() error("prepare exploded") end, function() return nil, "invalid params" end, function() return "bad" end }) do
  inventory.definitions.run.prepare = bad
  assert(not invoke(inventory.definitions.run, raw).ok)
end
assert(_G.run_prepare_matches == matches_before_error and run_defaults == 1)
inventory.definitions.run.prepare = good_prepare
_G.run_prepare_matches = nil
vim.fn.delete(root, "rf")
print("BUILTIN_EXTENSIONS_SPEC_OK")
