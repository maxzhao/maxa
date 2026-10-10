-- Test AbilityHook inject_at parsing and pre-submit synchronous injection.
-- Run with: nvim --headless -u NONE -l lua/maxa/abilities/hooks/inject_at_test.lua

package.path = table.concat({
  vim.fn.getcwd() .. "/lua/?.lua",
  vim.fn.getcwd() .. "/lua/?/init.lua",
  package.path,
}, ";")

local tmp = vim.fn.getcwd() .. "/tmp/ability_hooks_inject_at_test"
vim.fn.delete(tmp, "rf")
vim.fn.mkdir(tmp, "p")

local function write(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected=%s\nactual=%s", message or "assert_eq failed", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local parser = require("maxa.abilities.hooks.parser")

local md_path = tmp .. "/ChatSubmitted.md"
write(md_path, [[---
load: startup
scope: global
inject_at: pre
---

## user

pre markdown hook
]])
local md_hook = assert(parser.parse_hook_file(md_path, tmp))
assert_eq(md_hook.inject_at, "pre", "markdown hook should parse inject_at=pre")

local md_default_path = tmp .. "/TaskStarted.md"
write(md_default_path, [[---
load: startup
scope: global
---

## user

post by default
]])
local md_default_hook = assert(parser.parse_hook_file(md_default_path, tmp))
assert_eq(md_default_hook.inject_at, "post", "markdown hook should default inject_at=post")

local md_disabled_path = tmp .. "/DisabledMarkdown.md"
write(md_disabled_path, [[---
enabled: false
load: startup
scope: global
---

## user

this markdown hook should not load
]])
assert_eq(parser.parse_hook_file(md_disabled_path, tmp), nil, "markdown hook should not load when enabled=false")

local lua_path = tmp .. "/ChatSubmitted.lua"
write(lua_path, [[return {
  load = "startup",
  scope = "global",
  inject_at = "pre",
  render = function(ctx)
    return {{ role = "user", content = "pre lua hook" }}
  end,
}
]])
local lua_hook = assert(parser.parse_lua_hook_file(lua_path, tmp))
assert_eq(lua_hook.inject_at, "pre", "lua hook should parse inject_at=pre")

local md_system_path = tmp .. "/InvalidSystem.md"
write(md_system_path, [[---
load: startup
---

## system

invalid
]])
assert_eq(parser.parse_hook_file(md_system_path, tmp), nil, "markdown system role must be rejected")

local md_missing_role_path = tmp .. "/MissingRole.md"
write(md_missing_role_path, [[---
load: startup
---

missing role
]])
assert_eq(parser.parse_hook_file(md_missing_role_path, tmp), nil, "markdown hook without role must be rejected")

local prompts = assert(parser.parse_prompts("##   user  \n\nuser body\n## llm\t\n\nllm body\n"))
assert_eq(#prompts, 2, "trimmed exact user/llm headings should parse")
assert_eq(prompts[1].role, "user", "first trimmed role")
assert_eq(prompts[1].content, "user body", "first prompt content")
assert_eq(prompts[2].role, "llm", "second trimmed role")
assert_eq(prompts[2].content, "llm body", "second prompt content")

local future_prompts, future_err = parser.parse_prompts([[## user

user body
## future-role

must not merge into user body
]])
assert_eq(future_prompts, nil, "unknown heading must be rejected")
assert(future_err:find("future-role", 1, true), "unknown heading error should identify its role")

for label, body in pairs({
  system = "## system\ninvalid",
  empty = "##\ninvalid",
  anomalous = "## user extra\ninvalid",
}) do
  local invalid_prompts = parser.parse_prompts(body)
  assert_eq(invalid_prompts, nil, label .. " heading must be rejected")
end

local lua_disabled_path = tmp .. "/DisabledLua.lua"
write(lua_disabled_path, [[return {
  enabled = false,
  load = "startup",
  scope = "global",
  render = function(ctx)
    return {{ role = "user", content = "this lua hook should not load" }}
  end,
}
]])
assert_eq(parser.parse_lua_hook_file(lua_disabled_path, tmp), nil, "lua hook should not load when enabled=false")

-- Mock maxa_ai chat lookup.
local chat = {
  id = 4242,
  bufnr = 999,
  messages = {},
  add_message = function(self, msg, opts)
    table.insert(self.messages, { role = msg.role, content = msg.content, opts = opts })
  end,
}

package.loaded["maxa"] = {
  buf_get_chat = function(bufnr)
    if bufnr == chat.bufnr then
      return chat
    end
    return nil
  end,
}

local registry = require("maxa.abilities.hooks.registry")
registry.reset()
assert(registry.register(lua_hook, nil))

local fire = require("maxa.abilities.hooks.fire")
fire.fire_sync("ChatSubmitted", { bufnr = chat.bufnr, chat_id = chat.id, user_message = "hello" })

assert_eq(#chat.messages, 1, "fire_sync should inject pre hook before returning")
assert_eq(chat.messages[1].content, "pre lua hook", "pre hook content should be injected")

-- Register a post hook for the same event; sync fire must not inject it.
local lua_post_path = tmp .. "/ChatSubmittedPost.lua"
write(lua_post_path, [[return {
  load = "startup",
  scope = "global",
  render = function(ctx)
    return {{ role = "user", content = "post lua hook" }}
  end,
}
]])
local post_hook = assert(parser.parse_lua_hook_file(lua_post_path, tmp))
post_hook.event_name = "ChatSubmitted"
assert_eq(post_hook.inject_at, "post", "lua hook should default inject_at=post")
assert(registry.register(post_hook, nil))

fire.fire_sync("ChatSubmitted", { bufnr = chat.bufnr, chat_id = chat.id, user_message = "hello" })
assert_eq(#chat.messages, 2, "fire_sync should not inject post hook")
assert_eq(chat.messages[2].content, "pre lua hook", "only pre hook should run on sync fire")

registry.reset()
local invalid_lua_path = tmp .. "/InvalidRole.lua"
write(invalid_lua_path, [[return {
  load = "startup",
  scope = "global",
  inject_at = "pre",
  render = function(ctx)
    return {{ role = "system", content = "invalid" }}
  end,
}
]])
local invalid_lua_hook = assert(parser.parse_lua_hook_file(invalid_lua_path, tmp))
invalid_lua_hook.event_name = "ChatSubmitted"
assert(registry.register(invalid_lua_hook, nil))
local count_before_invalid = #chat.messages
fire.fire_sync("ChatSubmitted", { bufnr = chat.bufnr, chat_id = chat.id, user_message = "hello" })
assert_eq(#chat.messages, count_before_invalid, "Lua system role must be rejected without injection")

registry.reset()
vim.fn.delete(tmp, "rf")
print("ability_hooks_inject_at_test: OK")
