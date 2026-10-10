-- Run: nvim --headless -u NONE -l lua/maxa/session/history/title_generator_test.lua
local root = vim.fn.stdpath("config")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local request_actions
local request_adapter
local mapped_adapter_name
local mapped_settings
local chat
local notifications = {}
local callback_count = 0

package.loaded["maxa.http"] = {
  new = function(opts)
    request_adapter = opts.adapter
    return {
      request = function(_, _, actions)
        request_actions = actions
        return {}
      end,
    }
  end,
}
package.loaded["maxa.config"] = {
  constants = { USER_ROLE = "user", LLM_ROLE = "assistant" },
}
package.loaded["maxa.session.history.log"] = {
  trace = function() end,
  error = function() end,
}
package.loaded["maxa.schema"] = {
  get_default = function(_, overrides)
    return overrides or {}
  end,
}
package.loaded["maxa.adapters"] = {
  resolve = function(adapter)
    if type(adapter) == "string" then
      local resolved = vim.deepcopy(chat.adapter)
      resolved.name = adapter
      return resolved
    end
    return adapter
  end,
  call_handler = function(adapter)
    return adapter.result
  end,
}

local original_notify = vim.notify
vim.notify = function(message)
  table.insert(notifications, message)
end

local TitleGenerator = require("maxa.session.history.title_generator")
local generator = TitleGenerator.new({ auto_generate_title = true })
chat = {
  adapter = {
    handlers = {},
    map_schema_to_params = function(self, settings)
      mapped_adapter_name = self.name
      mapped_settings = settings
      return { opts = {} }
    end,
    map_roles = function(_, messages)
      return messages
    end,
  },
  settings = {},
}

local passed = 0
local failed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end

local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", message or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_contains(haystack, needle, message)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(string.format("%s: expected %q to contain %q", message or "assertion failed", tostring(haystack), needle))
  end
end

local function start_request()
  request_actions = nil
  notifications = {}
  callback_count = 0
  generator:_make_adapter_request(chat, "title prompt", function()
    callback_count = callback_count + 1
  end)
  assert(request_actions and type(request_actions.callback) == "function", "request callback was not registered")
end

test("structured response errors expose the nested API message", function()
  start_request()
  request_actions.callback({
    stderr = {
      status = 429,
      body = '{"error":{"message":"quota exhausted"}}',
    },
  }, nil, chat.adapter)
  assert_equal(1, callback_count, "failure callback count")
  assert_equal(1, #notifications, "notification count")
  assert_contains(notifications[1], "quota exhausted", "structured API error")
end)

test("string errors are formatted without field access", function()
  start_request()
  request_actions.callback("network unavailable", nil, chat.adapter)
  assert_equal(1, callback_count, "failure callback count")
  assert_contains(notifications[1], "network unavailable", "string error")
end)

test("nil stderr falls back to the transport error message", function()
  start_request()
  request_actions.callback({ message = "request failed", stderr = nil }, nil, chat.adapter)
  assert_equal(1, callback_count, "failure callback count")
  assert_contains(notifications[1], "request failed", "nil stderr fallback")
end)

test("parser output tables are formatted and only fail once", function()
  start_request()
  local adapter = {
    handlers = {},
    result = {
      status = "error",
      output = { error = { message = "invalid model" } },
    },
  }
  request_actions.callback(nil, "response", adapter)
  request_actions.callback({ message = "late duplicate" }, nil, adapter)
  assert_equal(1, callback_count, "failure callback count")
  assert_equal(1, #notifications, "notification count")
  assert_contains(notifications[1], "invalid model", "parser error")
end)

test("nil parser errors use a safe fallback", function()
  start_request()
  local adapter = {
    handlers = {},
    result = { status = "error", output = nil },
  }
  request_actions.callback(nil, "response", adapter)
  assert_equal(1, callback_count, "failure callback count")
  assert_contains(notifications[1], "Unknown error", "nil parser error")
end)

package.loaded["maxa.mcphub.native_servers.config"] = {
  get_internal_adapter = function(name)
    assert_equal("title", name)
    return { adapter = "title-gateway", model = "title-model", thinking_mode = "none", temperature = 0.0 }
  end,
  get_reasoning_effort_settings = function(_, mode)
    return { ["reasoning.effort"] = mode }
  end,
}
test("named title preset is resolved at request time with explicit overrides", function()
  generator.opts.title_generation_opts = { preset = "title" }
  start_request()
  assert_equal("title-gateway", mapped_adapter_name)
  assert_equal("title-model", mapped_settings.model)
  assert_equal("none", mapped_settings["reasoning.effort"])
  assert_equal(0.0, mapped_settings.temperature)

  generator.opts.title_generation_opts = { preset = "title", adapter = "explicit-gateway", model = "explicit-model" }
  start_request()
  assert_equal("explicit-gateway", mapped_adapter_name)
  assert_equal("explicit-model", mapped_settings.model)
end)

vim.notify = original_notify
print(string.format("TITLE_GENERATOR_TEST_OK passed=%d failed=%d", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
