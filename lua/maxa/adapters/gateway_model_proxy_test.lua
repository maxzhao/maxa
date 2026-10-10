-- Run: nvim --headless -u NONE -l lua/maxa/adapters/gateway_model_proxy_test.lua
local root = vim.fn.stdpath("config")
local lazy = vim.fn.stdpath("data") .. "/lazy"
vim.opt.runtimepath:prepend(lazy .. "/plenary.nvim")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  lazy .. "/plenary.nvim/lua/?.lua",
  lazy .. "/plenary.nvim/lua/?/init.lua",
  package.path,
}, ";")

local observed = {}
local model_api_unavailable = false
package.loaded["plenary.curl"] = {
  get = function(url, opts)
    observed[url] = opts.proxy == nil and "<nil>" or opts.proxy
    if model_api_unavailable then
      return { status = 503, body = "{}" }
    end
    local model = url == "https://api.deepseek.com/models" and "deepseek-v4-flash"
      or url:find("fluxion.example.invalid", 1, true) and opts.headers["x-api-key"] and "claude-opus-5"
      or opts.headers["x-api-key"] and "claude-fable-5"
      or url:find("generativelanguage", 1, true) and "gemini-2.5-pro"
      or "gpt-6.1-sol"
    return { status = 200, body = vim.json.encode({ data = { { id = model } } }) }
  end,
}

local specs = dofile(root .. "/lua/plugins/ai.lua")
local runtime = specs[1]
assert(runtime and runtime.name == "maxa")
assert(runtime.opts and runtime.opts.maxa and runtime.opts.maxa.providers)
assert(runtime.opts.maxa.proxy == nil and require("maxa.config").runtime().proxy == "env")
assert(runtime.opts.maxa.protocol_defaults.openai_responses.default_model == "gpt-6.1-sol")
assert(runtime.opts.maxa.protocol_defaults.openai_responses.compact_model == "gpt-6.1-sol")
assert(vim.deep_equal(runtime.opts.maxa.protocol_defaults.openai_responses.models.fallback, { ["gpt-6.1-sol"] = {} }))
assert(runtime.opts.maxa.protocol_defaults.openai_responses.thinking_mode == "xhigh")
assert(runtime.opts.maxa.protocol_defaults.anthropic_messages.default_model == "claude-opus-5")
for _, id in ipairs({ "gemini", "xuanjing", "openrouter" }) do
  assert(runtime.opts.maxa.providers[id].proxy == true, id .. " must retain its proxy flag")
end
local expected_raw = {
  "--http1.1", "--retry", "5", "--retry-delay", "2", "--retry-max-time", "150",
  "--connect-timeout", "30", "--speed-limit", "1", "--speed-time", "60",
}
for provider_id, provider in pairs(runtime.opts.maxa.providers) do
  for _, llm in pairs(provider.llm or {}) do
    if llm.name ~= "kiro_anthropic" then
      assert(llm.raw == nil, provider_id .. " must inherit protocol curl options")
    end
    if provider.llm and llm == provider.llm.openai_responses then
      assert(llm.thinking_mode == nil, provider_id .. " must inherit protocol thinking mode")
    end
  end
  if provider_id ~= "xuanjing" and provider_id ~= "fluxion" and provider_id ~= "xsai" then
    assert(provider.models == nil, provider_id .. " must inherit protocol model fallback")
  end
end
assert(vim.deep_equal(runtime.opts.maxa.protocol_defaults.openai_responses.raw, expected_raw))
assert(vim.deep_equal(runtime.opts.maxa.protocol_defaults.anthropic_messages.raw, expected_raw))
assert(runtime.opts.adapters and runtime.opts.adapters.http and runtime.opts.adapters.http.xuanjing_openai == nil)
assert(#require("maxa.mcphub.native_servers.genai.capability_registry").list("image") == 0)
-- Override test-only endpoints without changing production provider configuration.
for _, id in ipairs({ "xuanjing", "fhl", "fluxion" }) do
  runtime.opts.maxa.providers[id].base_url = "https://" .. id .. ".example.invalid/v1"
end
require("maxa.config").setup(runtime.opts)
local adapters = require("maxa.config").adapters.http
assert(type(adapters.xuanjing_openai) == "function")
assert(type(adapters.fhl_openai) == "function")
assert(type(adapters.deepseek) == "function")
local xuanjing = adapters.xuanjing_openai()
local fhl = adapters.fhl_openai()
local deepseek = adapters.deepseek()
local anthropic = adapters.xuanjing_anthropic()
local gemini = adapters.gemini()
local my_oai = adapters.my_oai()
assert(vim.deep_equal(my_oai.raw, expected_raw))
assert(my_oai.model.name == "gpt-6.1-sol", "protocol default applies to OpenAI providers")
local settings = my_oai:make_from_schema()
assert(settings["reasoning.effort"] == "xhigh", "protocol thinking mode must be enabled for the default model")
my_oai:map_schema_to_params(settings)
local params = my_oai.handlers.request.build_parameters(my_oai, vim.deepcopy(my_oai.parameters), {})
assert(params.reasoning and params.reasoning.effort == "xhigh", "protocol thinking mode must reach the request")
assert(params.service_tier == "priority", "Fast mode must reach the request body as priority, matching Pi")
assert(my_oai.headers["x-codex-routing-hint"] == nil, "Fast mode must not require an extra routing header")
assert(require("maxa.model_catalog").choices("openai_responses")["gpt-6-sol"].opts.can_reason,
  "previous model capabilities must remain available")
assert(vim.deep_equal(anthropic.raw, expected_raw) and vim.deep_equal(gemini.raw, expected_raw))
assert(deepseek.schema.model.choices["gpt-6.1-sol"] == nil, "DeepSeek must not inherit protocol model fallback")
assert(anthropic.model.name == "claude-fable-5" and gemini.model.name == "gemini-2.5-pro")
assert(adapters.fluxion_anthropic().model.name == "claude-opus-5", "protocol default applies to Anthropic providers")
assert(my_oai.maxa.compact.model == "gpt-6.1-sol", "protocol compact default applies to OpenAI providers")
assert(vim.deep_equal(adapters.kiro_anthropic().raw, runtime.opts.maxa.providers.kiro.llm.anthropic_messages.raw))
assert(deepseek.type == "http")
assert(deepseek.name == "deepseek")
assert(deepseek.backend and deepseek.backend.protocol == "openai_responses")
assert(deepseek.backend.provider == "deepseek")
assert(deepseek.schema["reasoning.effort"].default == "xhigh"
  and xuanjing.schema["reasoning.effort"].default == "xhigh")
assert(deepseek.url == "https://api.deepseek.com/responses")
assert(deepseek.schema["reasoning.summary"] == nil and deepseek.schema.verbosity == nil)
assert(deepseek.maxa.compact.adapter == "inherit")
assert(deepseek.maxa.compact.model == "deepseek-v4-flash")
local deepseek_default = deepseek.schema.model.default
if type(deepseek_default) == "function" then deepseek_default = deepseek_default(deepseek) end
assert(deepseek_default == "deepseek-v4-flash")
local xuanjing_default = xuanjing.schema.model.default
local fhl_default = fhl.schema.model.default
if type(xuanjing_default) == "function" then xuanjing_default(xuanjing) end
if type(fhl_default) == "function" then fhl_default(fhl) end
assert(observed["https://xuanjing.example.invalid/v1/models"] == "http://127.0.0.1:10808", vim.inspect(observed))
assert(observed["https://fhl.example.invalid/v1/models"] == "<nil>", vim.inspect(observed))
local config = require("maxa.config")
model_api_unavailable = true
config.setup(runtime.opts)
for _, name in ipairs({ "my_oai", "xuanjing_openai", "fluxion_openai" }) do
  local fallback = config.adapters.http[name]()
  assert(fallback.model.name == "gpt-6.1-sol", name .. " must retain the default model when discovery fails")
  assert(fallback.maxa.compact.model == "gpt-6.1-sol", name .. " must retain the compact default on fallback")
  assert(fallback:make_from_schema()["reasoning.effort"] == "xhigh", name .. " must retain reasoning on fallback")
end
assert(not pcall(config.setup, { adapters = { http = { shadow = {} } } }))
assert(not pcall(config.setup, { adapters = { http = { opts = { proxy = "http://old.example" } } } }))
print("GATEWAY_MODEL_PROXY_TEST_OK")
vim.cmd("qa!")
