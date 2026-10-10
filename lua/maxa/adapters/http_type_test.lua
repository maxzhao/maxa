-- Run: nvim --headless -u NONE -l lua/maxa/adapters/http_type_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
for _, name in ipairs({ "plenary.nvim" }) do
  local path = vim.fn.stdpath("data") .. "/lazy/" .. name
  if vim.fn.isdirectory(path) == 1 then vim.opt.runtimepath:append(path) end
end

local config = require("maxa.config")
local adapters = require("maxa.adapters")
local http = require("maxa.adapters.http")
package.loaded["maxa.provider_config"] = {
  owner = function(name) return (name == "openai" or name == "custom_gateway") and "test-provider" or nil end,
}
local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  assert(ok, name .. ": " .. tostring(err))
  passed = passed + 1
end
local function minimal(name, adapter_type)
  return {
    name = name,
    type = adapter_type,
    schema = { model = { default = "test" } },
    handlers = {},
  }
end

config.adapters.http.bad_config = function() return minimal("bad_config", "acp") end

test("extend rejects explicit non-http direct and configured adapters", function()
  assert(http.extend(minimal("direct", "acp")) == nil)
  assert(http.extend("bad_config") == nil)
end)

test("resolve rejects direct, resolved, and function-returned non-http adapters", function()
  assert(http.resolve(minimal("direct", "acp")) == nil)
  local resolved = setmetatable(minimal("resolved", "acp"), { __index = http })
  assert(http.resolve(resolved) == nil)
  assert(http.resolve(function() return minimal("function", "acp") end) == nil)
end)

test("omitted type defaults to http for provider-declared services", function()
  assert(http.extend(minimal("extended")).type == "http")
  local from_provider = http.extend(minimal("openai"), { backend = { id = "test-provider" } })
  assert(http.resolve(from_provider).type == "http")
  assert(http.resolve(minimal("direct")) == nil)
  assert(http.resolve(function() return minimal("function") end) == nil)
end)

test("resolved predicate and interaction constructors reject mutated non-http instances", function()
  config.adapters.http.openai = function()
    return adapters.extend("openai_responses", { name = "openai", backend = { id = "test-provider" } })
  end
  local resolved = http.resolve("openai")
  assert(http.resolved(resolved) == true)
  resolved.type = "acp"
  assert(http.resolved(resolved) == false)
  assert(adapters.resolved(resolved) == false)

  local original_chat_resolve = adapters.resolve
  local resolve_calls = 0
  adapters.resolve = function(adapter)
    resolve_calls = resolve_calls + 1
    assert(adapter == resolved or adapter == "openai")
    return nil
  end
  local Chat = require("maxa.interactions.chat")
  local context = require("maxa.utils.context").get(vim.api.nvim_get_current_buf(), {})
  assert(Chat.new({ adapter = resolved, buffer_context = context, auto_submit = false }) == nil)
  config.configure_early({ presets = { default = { adapter = "openai", model = "test" } } })
  local Background = require("maxa.interactions.background")
  assert(Background.new() == nil)
  adapters.resolve = original_chat_resolve
  assert(resolve_calls == 2)
end)

test("protocol bases remain extendable but only provider services resolve", function()
  config.adapters.http.custom_gateway = function()
    return adapters.extend("openai_responses", { name = "custom_gateway", backend = { id = "test-provider" } })
  end
  for _, name in ipairs({ "anthropic", "gemini", "openai_compatible", "openai_responses" }) do
    assert(adapters.extend(name), name .. " must remain an implementation base")
    assert(adapters.resolve(name) == nil, name .. " has no provider declaration")
  end
  for _, name in ipairs({ "openai", "custom_gateway" }) do
    local adapter = adapters.resolve(name)
    assert(adapter and adapter.name == name and adapter.type == "http", name)
  end
end)

print(string.format("HTTP_TYPE_TEST_OK passed=%d", passed))
