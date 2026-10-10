-- filepath: lua/maxa/mcphub/native_servers/subagent/utils_test.lua
-- 单元测试: utils.lua 中的 get_chat_save_id 函数
-- Run: nvim --headless -l lua/maxa/mcphub/native_servers/subagent/utils_test.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- 简单测试框架
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

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_nil(value, msg)
  if value ~= nil then
    error(string.format("%s: expected nil, got %s", msg or "assertion failed", tostring(value)))
  end
end

-- 加载被测模块
local utils = require("maxa.mcphub.native_servers.subagent.utils")

print("\n=== Testing utils.get_chat_save_id ===\n")

test("should return save_id when chat.opts.save_id exists", function()
  local chat = {
    opts = {
      save_id = "20260129_143052",
    },
  }
  local result = utils.get_chat_save_id(chat)
  assert_equal("20260129_143052", result)
end)

test("should return nil when chat is nil", function()
  local result = utils.get_chat_save_id(nil)
  assert_nil(result)
end)

test("should return nil when chat.opts is nil", function()
  local chat = {}
  local result = utils.get_chat_save_id(chat)
  assert_nil(result)
end)

test("should return nil when chat.opts.save_id is nil", function()
  local chat = {
    opts = {},
  }
  local result = utils.get_chat_save_id(chat)
  assert_nil(result)
end)

test("should return nil when chat.opts.save_id is empty string", function()
  local chat = {
    opts = {
      save_id = "",
    },
  }
  local result = utils.get_chat_save_id(chat)
  assert_nil(result)
end)

test("append_sub_agent_tail ends API messages with real user task", function()
  local original_config = package.loaded["maxa.config"]
  package.loaded["maxa.config"] = {
    constants = { USER_ROLE = "user", LLM_ROLE = "assistant" },
  }
  local messages = { { role = "user", content = "prefix" } }
  utils.append_sub_agent_tail(messages, "real task")
  assert_equal(2, #messages)
  assert_equal("user", messages[#messages].role)
  assert_equal("real task", messages[#messages].content)
  package.loaded["maxa.config"] = original_config
end)

test("render-only tail does not mutate API messages", function()
  local original_config = package.loaded["maxa.config"]
  local original_display = package.loaded["maxa.interactions.chat.tools.display"]
  package.loaded["maxa.config"] = {
    constants = { USER_ROLE = "user", LLM_ROLE = "assistant" },
  }
  package.loaded["maxa.interactions.chat.tools.display"] = {
    build_render_messages = function(messages)
      return vim.deepcopy(messages)
    end,
  }
  local messages = { { role = "user", content = "real task" } }
  local render = utils.build_sub_agent_render_messages(messages)
  assert_equal(1, #messages)
  assert_equal("real task", messages[#messages].content)
  assert_equal(2, #render)
  assert_equal("assistant", render[#render].role)
  assert_equal("", render[#render].content)
  package.loaded["maxa.config"] = original_config
  package.loaded["maxa.interactions.chat.tools.display"] = original_display
end)

test("default_agent without parent uses default preset fields", function()
  local runtime = require("maxa.config")
  runtime.configure_early({ presets = { default = {
    adapter = "stub", model = "model-from-default", temperature = 0.0, thinking_mode = "low",
  } } })
  local presets = require("maxa.mcphub.native_servers.config")
  presets.configure(runtime.runtime().presets)
  local original = package.loaded["maxa.adapters"]
  package.loaded["maxa.adapters"] = { resolve = function(value)
    if type(value) == "table" then return value end
    return { name = value, schema = {
      model = { default = "old" }, temperature = { default = 1 }, ["reasoning.effort"] = { default = "none" },
    } }
  end }
  local resolved = utils.resolve_adapter_by_key(nil, nil)
  package.loaded["maxa.adapters"] = original
  assert_equal("stub", resolved.name)
  assert_equal("model-from-default", resolved.schema.model.default)
  assert_equal(0.0, resolved.schema.temperature.default)
  assert_equal("low", resolved.schema["reasoning.effort"].default)
end)
test("inherit-style preset applies parent settings and explicit overrides", function()
  local presets = require("maxa.mcphub.native_servers.config")
  presets.configure({ default = { adapter = "fallback" }, default_agent = {}, chosen = { adapter = "inherit", temperature = 0.2 } })
  local original = package.loaded["maxa.adapters"]
  package.loaded["maxa.adapters"] = { resolve = function(value) return value end }
  local parent = { adapter = { name = "parent-provider", schema = {
    model = { default = "base" }, temperature = { default = 1 },
  } }, settings = { model = "parent-model", temperature = 0.7 } }
  local resolved = utils.resolve_adapter_by_key("chosen", parent)
  package.loaded["maxa.adapters"] = original
  assert_equal("parent-provider", resolved.name)
  assert_equal("parent-model", resolved.schema.model.default)
  assert_equal(0.2, resolved.schema.temperature.default)
  assert_equal("base", parent.adapter.schema.model.default)
  assert_equal(true, utils.infer_inherit_mode({ goal_prompt = "task", messages = {} }, true))
end)

test("hidden image child rejects delegation before recursion rules", function()
  local allowed, err = utils.check_execution_allowed("run_agent", { _maxa_hidden_image_analysis = true })
  assert_equal(false, allowed)
  assert(tostring(err):find("Hidden image-analysis child", 1, true))
end)

test("new messages reject rules context and retain other context types", function()
  local allowed, err = utils.validate_messages({
    { role = "context", type = "rules", path = "AGENTS.md" },
    { role = "user", content = "task" },
  })
  assert_equal(false, allowed)
  assert(tostring(err):find("invalid context type 'rules'", 1, true))
  assert(tostring(err):find("file, symbols, url, image", 1, true))

  for _, item in ipairs({
    { type = "file", path = "file.txt" },
    { type = "symbols", path = { "file.lua" } },
    { type = "url", url = "https://example.com" },
    { type = "image", path = "image.png" },
  }) do
    allowed, err = utils.validate_messages({
      vim.tbl_extend("force", { role = "context" }, item),
      { role = "user", content = "task" },
    })
    assert_equal(true, allowed, tostring(err))
  end
end)

test("run and resume schemas and preflight exclude rules context", function()
  for _, tool in ipairs({
    require("maxa.mcphub.native_servers.subagent.tools.run_agent"),
    require("maxa.mcphub.native_servers.subagent.tools.resume_agent"),
  }) do
    local types = tool.inputSchema.properties.messages.items.properties.type.enum
    assert_equal("file,symbols,url,image", table.concat(types, ","))
    local error_message
    tool.handler({ params = {
      save_id = "20260129_143052",
      title = "test",
      goal_prompt = "task",
      messages = { { role = "context", type = "rules", path = "AGENTS.md" }, { role = "user", content = "task" } },
    } }, { error = function(_, message) error_message = message end })
    assert(tostring(error_message):find("invalid context type 'rules'", 1, true), tool.name)
  end
end)

test("public selectors use preset and reject wrong types or conflicting legacy selectors", function()
  local runtime = require("maxa.config")
  runtime.configure_early({ defaults = { chat = "custom" }, presets = {
    custom = { type = "chat", adapter = "stub", model = "main" },
    image = { type = "image", adapter = "images", model = "picture" },
  } })
  for _, tool in ipairs({
    require("maxa.mcphub.native_servers.subagent.tools.run_agent"),
    require("maxa.mcphub.native_servers.subagent.tools.resume_agent"),
  }) do
    assert(tool.inputSchema.properties.preset and not tool.inputSchema.properties.adapter)
    local message
    tool.handler({ params = { title = "test", goal_prompt = "task", save_id = "20260129_143052", preset = "image" } },
      { error = function(_, value) message = value end })
    assert(tostring(message):find("type chat", 1, true), tostring(message))
  end
  local key, err = utils.preset_key({ preset = "custom", adapter = "different" })
  assert_equal(nil, key); assert(err:find("conflict", 1, true))
  assert_equal("custom", utils.preset_key({ preset = "custom" }))
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))

-- 退出码
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
