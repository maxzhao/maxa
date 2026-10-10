-- Run: nvim --headless -u NONE -l abilities/neovim/builtin/run_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
package.loaded["maxa.config"] = { constants = { USER_ROLE = "user", LLM_ROLE = "assistant" } }
package.loaded["maxa.mcphub.utils.config_manager"] = {
  get_effective_catalog = function() return { servers = {} } end,
  is_server_disabled = function() return false end,
}
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local inventory = require("maxa.interactions.chat.tools.builtin")
local catalog = require("maxa.abilities.catalog")
local abilities = require("maxa.session.abilities")
local chat = { messages = {}, opts = { cwd = root } }
local function invoke(name, params, owner)
  local result
  owner = owner or chat
  adapter.invoke(inventory.resolve(name), {
    cwd = root, chat = owner, params = params, caller = { maxa_ai = { chat = owner } },
  }, function(value) result = value end)
  assert(result, "synchronous Lua execution did not complete")
  return result
end
local function text(result)
  assert(result.ok, result.error)
  return adapter.content_to_result(result.content)
end
local function lua(code, options, owner)
  return invoke("run", vim.tbl_extend("force", {
    title = "Execute current-Neovim Lua", scope = "@neovim:lua", command = code,
  }, options or {}), owner)
end

local refused = lua("_G.neovim_lua_test = true")
assert(not refused.ok and refused.error:find("Unsupported run scope: @neovim:lua", 1, true))
assert(_G.neovim_lua_test == nil, "unloaded extension executed code")
local ability = assert(catalog.resolve("neovim", root))
assert(catalog.resolve_builtin_extension(ability, "run"))
local revision = abilities.build_revision({ ability = ability })
local _, loaded = abilities.synthetic_catalog_pair(revision, "load-neovim")
chat.messages[1] = loaded
vim.list_extend(chat.messages, abilities.build_context_batch(revision, "Loaded test instructions.", nil, "load-neovim"))

assert(text(lua("local value = 1")) == "Code executed successfully. (No output)")
assert(text(lua("vim.print('lua-output')")) == "lua-output")
assert(text(lua("local value = 'line one\\nline two'\nprint(value)")):find("line one\nline two", 1, true))
local cwd_before = vim.fn.getcwd()
assert(text(lua("vim.print(vim.fn.getcwd())")) == cwd_before)
assert(not lua("_G.neovim_lua_test = true", { title = "   " }).ok)
assert(not lua("   ").ok, "blank command accepted")
for _, options in ipairs({
  { args = '{}' }, { timeout = 1 }, { cwd = root .. "/other" },
  { opts = '{"async":true}' }, { opts = '{"pty":false}' },
}) do
  local rejected = lua("_G.neovim_lua_test = true", options)
  assert(not rejected.ok, vim.inspect(options))
end
assert(_G.neovim_lua_test == nil, "invalid options executed code")
local failed = lua("error('lua-test-error')")
assert(not failed.ok and failed.error:find("Lua execution error:", 1, true)
  and failed.error:find("lua-test-error", 1, true))
assert(not lua("_G.neovim_lua_test = true", nil, { messages = {}, opts = { cwd = root } }).ok,
  "another Chat inherited extension authorization")

local limit = require("maxa.interactions.chat.tools.builtin.runtime.utils").MAX_OUTPUT_CHARS
local large = text(lua(string.format("print(string.rep('x', %d))", limit + 1)))
local log = assert(large:match("Full output: ([^\n]+)"), large)
assert(large:find("Preview:", 1, true) and large:find("Size:", 1, true))
assert(#table.concat(vim.fn.readfile(log), "\n") > limit)
vim.fn.delete(log)
local batch = require("maxa.interactions.chat.tools.builtin.tests.native_batch_fixture").execute(chat, {
  title = "Lua extension batch", mode = "sequence", runs = {
    { scope = "@neovim:lua", command = "vim.print('first')" },
    { scope = "@neovim:lua", command = "vim.print('second')" },
  },
})
assert(batch.summary.status == "completed" and batch.members[1].text == "first" and batch.members[2].text == "second")
assert(inventory.resolve("lua") == nil, "retired standalone Lua remains executable")
local retired = invoke("run", { title = "Retired Lua", scope = "tool", command = "lua", args = '{"code":"print(1)"}' })
assert(not retired.ok and retired.error:find("Unknown Chat builtin: lua", 1, true))
vim.fn.delete(root, "rf")
print("NEOVIM_RUN_TEST_OK")
