-- filepath: lua/maxa/mcphub/native_servers/config_test.lua
-- 运行方式: nvim --headless -l lua/maxa/mcphub/native_servers/config_test.lua

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

local runtime = require("maxa.config")
runtime.configure_early({ presets = {
  default = { adapter = "my_oai", model = "gpt-6-sol", temperature = 0.0 },
  compact = { adapter = "my_oai", model = "gpt-6-sol", thinking_mode = "xhigh" },
  summary = { adapter = "deepseek", model = "deepseek-v4-flash", temperature = 0.0, thinking_mode = "none" },
  translate = { adapter = "deepseek", model = "deepseek-v4-flash", temperature = 0.0, thinking_mode = "none" },
  title = { adapter = "deepseek", model = "deepseek-v4-flash", temperature = 0.0, thinking_mode = "none" },
} })
local config = require("maxa.mcphub.native_servers.config")

print("\n=== Testing compaction reasoning configuration ===\n")

test("compact runtime config should use its own thinking mode", function()
  local runtime, err = config.get_runtime_adapter("compact")
  assert_equal(nil, err)
  assert_equal("xhigh", runtime.reasoning_effort, "planning reasoning effort")
end)

test("summary runtime config should use its own thinking mode", function()
  local runtime, err = config.get_runtime_adapter("summary")
  assert_equal(nil, err)
  assert_equal("none", runtime.reasoning_effort, "summary reasoning effort")
end)

test("summary translate and title route through the configured DeepSeek gateway", function()
  for _, name in ipairs({ "summary", "translate", "title" }) do
    local preset, err = config.get_adapter(name)
    assert_equal(nil, err)
    assert_equal("deepseek", preset.adapter, name .. " adapter")
    assert_equal("deepseek-v4-flash", preset.model, name .. " model")
    assert_equal("none", preset.thinking_mode, name .. " thinking mode")
  end
end)

test("runtime maxa block should not inherit missing fields from global preset", function()
  local chat = {
    adapter = {
      name = "test",
      maxa = {
        compact = {
          adapter = "inherit",
          model = "runtime-model",
        },
      },
    },
  }
  local runtime, err = config.get_runtime_adapter("compact", { chat = chat })
  assert_equal(nil, err)
  assert_equal("runtime-model", runtime.model, "runtime model")
  assert_equal(nil, runtime.thinking_mode, "runtime thinking mode")
  assert_equal(nil, runtime.reasoning_effort, "runtime reasoning effort")
end)

test("reasoning settings should select the target adapter schema key", function()
  local responses = config.get_reasoning_effort_settings({ schema = { ["reasoning.effort"] = {} } }, "none")
  assert_equal("none", responses["reasoning.effort"], "OpenAI Responses key")
  assert_equal(nil, responses.reasoning_effort, "should not include unrelated OpenAI key")

  local openai = config.get_reasoning_effort_settings({ schema = { reasoning_effort = {} } }, "none")
  assert_equal("none", openai.reasoning_effort, "OpenAI/Gemini key")

  local anthropic = config.get_reasoning_effort_settings({ schema = { extended_thinking = {} } }, "none")
  assert_equal(false, anthropic.extended_thinking, "Anthropic key")
end)

test("shared defaults require deployment adapter before composition", function()
  local config_root = require("maxa.config")
  local original = vim.deepcopy(config_root.runtime().presets)
  local ok, err = pcall(config_root.configure_early, { presets = { default = {} } })
  assert_equal(false, ok)
  assert(tostring(err):find("default:chat is missing adapter", 1, true))
  config_root.configure_early({ presets = original })
  config.configure(config_root.runtime().presets)
end)
test("nil optional preset uses default internally; empty preset inherits; arbitrary names work", function()
  runtime.configure_early({ presets = {
    default = { adapter = "my_oai", model = "gpt-6-sol", temperature = 0.0, thinking_mode = "high" },
    compact = {}, default_agent = {},
    custom = { model = "custom-model", thinking_mode = "low" },
  } })
  local summary = assert(config.get_runtime_adapter("summary"))
  assert_equal("my_oai", summary.adapter)
  assert_equal(0.0, summary.temperature)
  local compact = assert(config.get_runtime_adapter("compact"))
  assert_equal("inherit", compact.adapter)
  assert_equal(nil, compact.model)
  local agent = assert(config.get_adapter("default_agent"))
  assert_equal("inherit", agent.adapter)
  local custom = assert(config.get_adapter("custom"))
  assert_equal("custom-model", custom.model)
  assert_equal("my_oai", custom.adapter)
  assert_equal("low", custom.thinking_mode)
  local missing, err = config.get_adapter("typo")
  assert_equal(nil, missing)
  assert(err:find("Unknown preset", 1, true))
  config.configure(runtime.runtime().presets)
end)
test("named presets and all default roles are independent and typed", function()
  runtime.configure_early({
    defaults = {
      chat = "primary", compact = { adapter = "inherit" }, summary = "small", translate = "small", title = "small",
      image = "picture", tts = { adapter = "voice", voice = "echo" }, video = { adapter = "movie", generation_preset = "normal" },
    },
    presets = {
      primary = { type = "chat", adapter = "my_oai", model = "main", visible = true, description = "Reasoning" },
      small = { type = "chat", adapter = "small", model = "small-model" },
      picture = { type = "image", adapter = "images", model = "image-model", visible = true, description = "Pictures" },
      compact = { type = "chat", adapter = "not-the-default" },
    },
  })
  local presets = require("maxa.presets")
  assert_equal("my_oai", assert(presets.get_default("chat")).adapter)
  assert_equal("inherit", assert(presets.get_default("compact")).adapter)
  for _, role in ipairs({ "summary", "translate", "title" }) do assert_equal("small", assert(presets.get_default(role)).adapter) end
  assert_equal("images", assert(presets.get_default("image")).adapter)
  assert_equal("voice", assert(presets.get_default("tts")).adapter)
  assert_equal("movie", assert(presets.get_default("video")).adapter)
  local selected = assert(presets.get_preset("primary", "chat"))
  assert_equal(nil, selected.description); assert_equal(nil, selected.visible); assert_equal(nil, selected.type)
  selected.model = "changed"
  assert_equal("main", assert(presets.get_preset("primary", "chat")).model)
  local bad, err = presets.get_preset("picture", "chat")
  assert_equal(nil, bad); assert(err:find("type chat", 1, true))
  assert_equal("picture", presets.visible()[1].name)
  local override = assert(config.get_runtime_adapter("compact", { chat = { adapter = { name = "provider", maxa = { compact = { adapter = "inherit", model = "provider-model" } } } } }))
  assert_equal("provider-model", override.model)
  assert_equal(nil, override.thinking_mode)
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
