-- Run: nvim --headless -l lua/maxa/session/status/quota_proxy_test.lua
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name .. ": " .. tostring(err))
  end
end

local root = vim.fn.stdpath("config")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local proxy = require("maxa.adapters.proxy")
local definitions = { enabled = { id = "enabled", proxy = true }, disabled = { id = "disabled", proxy = false } }
package.loaded["maxa.provider_config"] = { provider = function(id) return definitions[id] end }
proxy.configure("http://127.0.0.1:10808")
local enabled = { name = "proxied", backend = { id = "enabled" } }
local disabled = { name = "direct", backend = { id = "disabled" } }

local original_jobstart = vim.fn.jobstart
local commands = {}
vim.fn.jobstart = function(command)
  table.insert(commands, command)
  return #commands
end

local cases = {
  {
    name = "sub2api",
    module = "maxa.adapters.quota.sub2api",
    config = { api_base = "https://sub.example/v1", api_key = "key", initial_delay = 60000 },
  },
  {
    name = "newapi",
    module = "maxa.adapters.quota.newapi",
    config = { api_base = "https://new.example", access_token = "token", user_id = "1", initial_delay = 60000 },
  },
  {
    name = "deepseek",
    module = "maxa.adapters.quota.deepseek",
    config = { api_base = "https://deep.example", api_key = "key", initial_delay = 60000 },
  },
  {
    name = "local",
    module = "maxa.adapters.quota.local",
    config = { api_base = "https://local.example/v1", api_key = "key", initial_delay = 60000 },
  },
}

for _, case in ipairs(cases) do
  test(case.name .. " quota follows adapter proxy policy", function()
    commands = {}
    local provider = require(case.module).new(case.config, enabled)
    provider:refresh()
    provider:stop()
    assert(#commands >= 1, "quota request was not started")
    for _, command in ipairs(commands) do
      assert(type(command) == "string", "quota command must remain a shell command")
      assert(command:find("--proxy", 1, true), "proxy argument missing: " .. command)
      assert(command:find("http://127.0.0.1:10808", 1, true), "configured proxy missing: " .. command)
    end
  end)
end

test("quota stays direct when adapter disables proxy", function()
  commands = {}
  local provider = require("maxa.adapters.quota.sub2api").new(cases[1].config, disabled)
  provider:refresh()
  provider:stop()
  assert(#commands == 1, "expected one quota request")
  assert(commands[1]:find("--noproxy '*'", 1, true), "direct adapter unexpectedly used proxy")
end)

test("quota resolves a dynamic provider policy for each request", function()
  commands = {}
  local current = "http://127.0.0.1:10808"
  definitions.enabled.proxy = function(provider)
    assert(provider.id == "enabled")
    return current
  end
  local provider = require("maxa.adapters.quota.sub2api").new(cases[1].config, enabled)
  provider:refresh()
  provider:stop()
  current = nil
  provider = require("maxa.adapters.quota.sub2api").new(cases[1].config, enabled)
  provider:refresh()
  provider:stop()
  assert(#commands == 2, "expected two quota requests")
  assert(commands[1]:find("--proxy 'http://127.0.0.1:10808'", 1, true))
  assert(commands[2]:find("--noproxy '*'", 1, true))
end)

vim.fn.jobstart = original_jobstart
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
