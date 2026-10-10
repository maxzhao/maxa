-- Run: nvim --headless -u NONE -l lua/maxa/provider_config_test.lua
local root = vim.fn.stdpath("config")
local lazy = vim.fn.stdpath("data") .. "/lazy"
vim.opt.runtimepath:prepend(lazy .. "/plenary.nvim")
package.path = table.concat({
  root .. "/lua/?.lua", root .. "/lua/?/init.lua",
  lazy .. "/plenary.nvim/lua/?.lua", lazy .. "/plenary.nvim/lua/?/init.lua", package.path,
}, ";")

local observed = {}
package.loaded["plenary.curl"] = {
  get = function(url, opts)
    observed[#observed + 1] = { url = url, key = opts.headers.Authorization or opts.headers["x-api-key"], headers = opts.headers }
    local id = opts.headers["x-api-key"] == "key-b" and "claude-opus-5" or "gpt-6-sol"
    return { status = 200, body = vim.json.encode({ data = { { id = id } } }) }
  end,
}

local config = require("maxa.config")
assert(config.runtime().proxy == "env", "shared proxy address source defaults to env")
config.configure_early({ presets = { default = { adapter = "one", model = "gpt-6-sol" } } })
local providers = require("maxa.provider_config")
local defs = {
  relay = {
    type = "sub2api", base_url = "https://example.invalid/v1", api_key = "key-a", quota = true,
    llm = {
      openai_responses = { name = "one", schema = { model = { default = "gpt-6-sol" } } },
      anthropic_messages = { name = "two", api_key = "key-b", schema = { model = {
        default = "claude-opus-5", choices = { ["claude-opus-5"] = { opts = { can_reason = true } } },
      } }, model_choices = "replace" },
    },
    genai = {
      image = { adapter = "one", mode = "compatible", api_key = "image-key" },
      tts = { adapter = "media-only" },
    },
  },
}
providers.configure(defs)
local one = providers.adapters().one()
assert(one.name == "one" and one.backend.id == "relay")
assert(one.schema.model.default == "gpt-6-sol")
assert(observed[1] and observed[1].key == "Bearer key-a")
local two_from_api = providers.adapters().two()
assert(two_from_api.schema.model.choices["claude-opus-5"])
assert(observed[2] and observed[2].key == "key-b" and observed[2].headers["anthropic-version"] == "2023-06-01",
  "Anthropic discovery must use its effective key and protocol headers")
assert(providers.media("one", "image").api_key == "image-key")
assert(providers.media("media-only", "tts").api_root == "https://example.invalid/v1")
local media_service, tts = require("maxa.mcphub.native_servers.genai.adapter").get_adapter("media-only", "tts")
assert(media_service and tts and media_service.api_root == "https://example.invalid/v1")
assert(media_service.api_key == "key-a", "media-only adapter inherits provider key")
local registry = require("maxa.mcphub.native_servers.genai.capability_registry")
assert(#registry.list("image") == 1 and #registry.list("tts") == 1)

-- Media connections belong to their capability/provider, never a same-name LLM.
local independent = vim.deepcopy(defs)
independent.relay.models = { source = "static", choices = { ["gpt-6-sol"] = {} } }
independent.relay.llm.openai_responses.base_url = "https://chat-only.invalid/v1"
independent.relay.llm.openai_responses.api_key = "chat-only-key"
independent.relay.genai.image.api_key = nil
providers.configure(independent)
local independent_media = providers.media("one", "image")
assert(independent_media.api_root == "https://example.invalid/v1")
assert(independent_media.api_key == "key-a", "same-name LLM key must not affect media")
assert(providers.adapters().one().maxa.genai == nil, "LLM adapters must not carry derived media capabilities")
independent.relay.genai.image.base_url = "https://image-only.invalid/v1/"
independent.relay.genai.image.api_key = "image-only-key"
providers.configure(independent)
independent_media = providers.media("one", "image")
assert(independent_media.api_root == "https://image-only.invalid/v1")
assert(independent_media.api_key == "image-only-key", "capability connection overrides provider defaults")

-- An omitted media name uses the provider ID with zero, one or multiple LLMs.
for _, llm in ipairs({ {}, { openai_responses = defs.relay.llm.openai_responses }, defs.relay.llm }) do
  providers.configure({
    relay = {
      base_url = "https://example.invalid/v1", api_key = "key-a", llm = vim.deepcopy(llm),
      genai = { image = { mode = "codex" }, tts = {}, video = {} },
    },
  })
  local service, capability = require("maxa.mcphub.native_servers.genai.adapter").get_adapter("relay", "image")
  assert(service and service.name == "relay" and service.api_key == "key-a")
  assert(capability.mode == "codex" and registry.get("relay").capabilities.tts)
  assert(providers.media("relay", "video"))
end
for _, name in ipairs({ "", "   ", false }) do
  local invalid = vim.deepcopy(defs)
  invalid.relay.genai.image.adapter = name
  assert(not pcall(providers.configure, invalid), "explicit invalid media name must not use provider ID")
end
local implicit_collision = vim.deepcopy(defs)
implicit_collision.one = { base_url = "https://other.invalid/v1", genai = { image = { mode = "codex" } } }
assert(not pcall(providers.configure, implicit_collision), "implicit media names must honor cross-provider collisions")

local named = vim.deepcopy(defs)
named.relay.models = { source = "static", choices = { ["gpt-6-sol"] = {} } }
named.relay.llm.anthropic_messages.schema.model = { preset = "default" }
named.relay.llm.anthropic_messages.model_choices = nil
providers.configure(named, { default = { model = "gpt-6-sol" } })
local from_preset = providers.adapters().two()
assert(from_preset.schema.model.default == "gpt-6-sol" and from_preset.schema.model.choices["gpt-6-sol"],
  "provider model preset must resolve against final deployment choices")
assert(not pcall(providers.configure, named, { default = {} }), "model preset without a model must fail")

local explicit = vim.deepcopy(defs)
explicit.relay.llm.openai_responses.schema.model.choices = { ["gpt-6-sol"] = {} }
explicit.relay.api_key = nil
providers.configure(explicit)
assert(providers.adapters().one().schema.model.choices["gpt-6-sol"], "explicit model works without discovery credentials")
explicit.relay.api_key = "key-a"
package.loaded["plenary.curl"].get = function()
  return { status = 200, body = vim.json.encode({ data = { { id = "gpt-6-luna" } } }) }
end
providers.configure(explicit)
local listed = providers.adapters().one()
assert(listed.schema.model.default == "gpt-6-sol" and listed.schema.model.choices["gpt-6-luna"],
  "explicit model remains available when a provider listing omits it")

local discovered = vim.deepcopy(defs)
package.loaded["plenary.curl"].get = function(_, opts)
  local ids = opts.headers["x-api-key"] and { { id = "claude-sonnet-4-6" }, { id = "gpt-6-sol" } }
    or { { id = "relay-future" } }
  return { status = 200, body = vim.json.encode({ data = ids }) }
end
discovered.relay.llm.anthropic_messages.model_choices = nil
discovered.relay.llm.anthropic_messages.schema.model.choices = nil
providers.configure(discovered)
local future = providers.adapters().one()
assert(future.model.name == "relay-future" and future.schema.model.choices["relay-future"],
  "discovered but uncataloged models remain selectable")
local anth = providers.adapters().two()
assert(anth.model.name == "claude-sonnet-4-6" and not anth.schema.model.choices["gpt-6-sol"],
  "a missing preferred model must select a compatible advertised model")
assert(anth.maxa.compact.model == anth.model.name, "Anthropic compact must follow the selected model")

local valid = vim.deepcopy(defs)
valid.relay.models = { source = "static", choices = { ["claude-opus-5"] = {}, ["gpt-6-sol"] = {} } }
valid.relay.llm.openai_compatible = { name = "three", schema = { model = {
  default = "gpt-6-sol", choices = { ["gpt-6-sol"] = {} },
} } }
valid.relay.llm.gemini = { name = "four", schema = { model = {
  default = "gpt-6-sol", choices = { ["gpt-6-sol"] = {} },
} } }
providers.configure(valid)
local two = providers.adapters().two()
assert(two.schema.model.choices["claude-opus-5"] and not two.schema.model.choices["claude-sonnet-4-6"])
local three, four = providers.adapters().three(), providers.adapters().four()
local billing = require("maxa.session.status.billing")
local shared = { snapshot = function() return { remaining = 17 } end }
assert(billing.register("provider:relay", shared))
assert(billing.snapshot({ adapter = providers.adapters().one() }).remaining == 17)
assert(billing.snapshot({ adapter = two }).remaining == 17)
local stopped = 0
billing.register("provider:relay", { stop = function() stopped = stopped + 1 end })
billing.unregister("one")
assert(stopped == 1 and billing._providers()["provider:relay"] == nil,
  "unregister must clear the provider-group cache")
assert(three.env.url == "https://example.invalid/v1" and three.env.chat_url == "/chat/completions")
assert(four.url == "https://example.invalid/v1/chat/completions")
assert(observed[1] and #observed == 2, "static model choices must not make HTTP requests")

local protocol_defaults = {
  openai_responses = {
    default_model = "gpt-6-sol", compact_model = "gpt-6-sol",
    models = { fallback = { ["gpt-6-sol"] = {} } },
    raw = { "--retry", "5" }, thinking_mode = "xhigh",
  },
  anthropic_messages = { default_model = "claude-opus-5" },
}
local protocol_named = vim.deepcopy(valid)
protocol_named.relay.llm.openai_responses.schema = nil
protocol_named.relay.llm.anthropic_messages.schema = nil
protocol_named.relay.llm.anthropic_messages.model_choices = nil
providers.configure(protocol_named, nil, protocol_defaults)
assert(providers.adapters().one().model.name == "gpt-6-sol")
assert(providers.adapters().one().maxa.compact.model == "gpt-6-sol")
assert(vim.deep_equal(providers.adapters().one().raw, { "--retry", "5" }))
assert(providers.adapters().one().schema["reasoning.effort"].default == "xhigh")
assert(providers.adapters().two().model.name == "claude-opus-5")

local inherited = vim.deepcopy(protocol_named)
inherited.relay.models = nil
inherited.relay.api_key = nil
providers.configure(inherited, nil, protocol_defaults)
assert(providers.adapters().one().model.name == "gpt-6-sol", "protocol fallback works without provider models")
inherited.relay.llm.openai_responses.schema = {
  model = { default = "gpt-6-luna", choices = { ["gpt-6-luna"] = {} } },
}
providers.configure(inherited, nil, protocol_defaults)
local explicit_choice = providers.adapters().one()
assert(explicit_choice.model.name == "gpt-6-luna" and not explicit_choice.schema.model.choices["gpt-6-sol"],
  "explicit adapter choices must not inherit protocol fallback models")
inherited.relay.models = { fallback = { ["gpt-6-luna"] = {} } }
inherited.relay.llm.openai_responses.schema = nil
providers.configure(inherited, nil, protocol_defaults)
assert(providers.adapters().one().model.name == "gpt-6-luna", "provider fallback overrides protocol fallback")

protocol_named.relay.llm.openai_responses.schema = {
  model = { default = "gpt-6-luna", choices = { ["gpt-6-luna"] = {} } },
}
providers.configure(protocol_named, nil, protocol_defaults)
assert(providers.adapters().one().model.name == "gpt-6-luna", "provider model overrides the protocol default")
assert(providers.adapters().one().maxa.compact.model == "gpt-6-sol", "protocol compact default remains independent")
protocol_named.relay.llm.openai_responses.maxa = { compact = { adapter = "inherit", model = "gpt-6-luna" } }
providers.configure(protocol_named, nil, protocol_defaults)
assert(providers.adapters().one().maxa.compact.model == "gpt-6-luna", "provider compact overrides the protocol")
protocol_named.relay.llm.openai_responses.raw = { "--retry", "1" }
protocol_named.relay.llm.openai_responses.thinking_mode = "low"
providers.configure(protocol_named, nil, protocol_defaults)
assert(vim.deep_equal(providers.adapters().one().raw, { "--retry", "1" }))
assert(providers.adapters().one().schema["reasoning.effort"].default == "low")

protocol_named.relay.llm.openai_responses.raw = nil
protocol_named.relay.llm.openai_responses.thinking_mode = nil
protocol_named.relay.llm.openai_responses.schema = nil
protocol_named.relay.llm.openai_responses.maxa = nil
protocol_named.relay.models.choices = { ["gpt-6-luna"] = {} }
providers.configure(protocol_named, nil, protocol_defaults)
local fallback = providers.adapters().one()
assert(fallback.model.name == "gpt-6-luna" and fallback.maxa.compact.model == "gpt-6-luna",
  "unavailable protocol defaults must fall back to the selected model")
assert(not pcall(providers.configure, valid, nil, { openai_responses = { default_model = "" } }),
  "protocol defaults must reject empty model IDs")
assert(not pcall(providers.configure, valid, nil, { openai_responses = { model = "gpt-6-sol" } }),
  "the obsolete protocol model key must not be silently ignored")

local duplicate = vim.deepcopy(valid)
duplicate.other = { base_url = "https://other.invalid/v1", genai = { image = { adapter = "one", mode = "compatible" } } }
local ok = pcall(providers.configure, duplicate)
assert(not ok, "another provider must not claim an existing adapter")

local unavailable = vim.deepcopy(valid)
unavailable.relay.models = { source = "api", url = "https://example.invalid/unavailable" }
package.loaded["plenary.curl"].get = function() return { status = 503, body = "unavailable" } end
providers.configure(unavailable)
assert(not pcall(providers.adapters().one), "API failure without a fallback must not invent models")
unavailable.relay.models.fallback = { ["gpt-6-sol"] = {}, ["claude-opus-5"] = {} }
providers.configure(unavailable)
assert(providers.adapters().one().model.name == "gpt-6-sol", "configured fallback retains the default")
assert(providers.adapters().two().model.name == "claude-opus-5", "Anthropic uses its configured fallback")

assert(require("maxa.adapters.http.openai_responses").schema["reasoning.effort"].default == nil,
  "the protocol must not impose a reasoning effort")
local without_thinking = providers.adapters().one()
assert(without_thinking.raw == nil, "providers without raw must not inherit local curl options")
assert(without_thinking.schema["reasoning.effort"].default == nil
  and without_thinking:make_from_schema()["reasoning.effort"] == nil,
  "providers without thinking_mode must omit reasoning effort")
local with_thinking = vim.deepcopy(valid)
with_thinking.relay.llm.openai_responses.thinking_mode = "xhigh"
with_thinking.relay.llm.openai_responses.raw = { "--connect-timeout", "30" }
providers.configure(with_thinking)
assert(vim.deep_equal(providers.adapters().one().raw, { "--connect-timeout", "30" }),
  "provider raw options must be opt-in")
assert(providers.adapters().one().schema["reasoning.effort"].default == "xhigh"
  and providers.adapters().one():make_from_schema()["reasoning.effort"] == "xhigh",
  "an explicit provider thinking_mode must become the reasoning effort")

for _, field in ipairs({ "proxy", "maxa" }) do
  local invalid = vim.deepcopy(valid)
  invalid.relay.llm.openai_responses[field] = field == "proxy" and true or { proxy = false }
  assert(not pcall(providers.configure, invalid), "LLM proxy override must be rejected: " .. field)
end
local invalid = vim.deepcopy(valid)
invalid.relay.proxy = " "
assert(not pcall(providers.configure, invalid), "blank provider proxy must be rejected")

-- Both discovery owners must never send --noproxy alongside an enabled proxy.
local proxy = require("maxa.adapters.proxy")
for _, enabled in ipairs({ true, false }) do
  local expected = enabled and "http://proxy.example:8080" or nil
  proxy.configure(expected or false)
  local calls = {}
  package.loaded["plenary.curl"].get = function(_, opts)
    calls[#calls + 1] = opts
    return { status = 200, body = vim.json.encode({ data = { { id = "gpt-6-sol" } } }) }
  end
  local function check(opts)
    assert(opts.proxy == expected, "discovery proxy changed")
    if enabled then
      assert(opts.raw == nil, "enabled proxy must not be bypassed")
    else
      assert(vim.deep_equal(opts.raw, { "--noproxy", "*" }), "direct discovery must bypass inherited proxy")
    end
  end
  providers.configure({ fixture = {
    base_url = "https://discovery.invalid/v1", api_key = "fixture-key", proxy = true,
    llm = { openai_responses = { name = "discovery-fixture", schema = { model = { default = "gpt-6-sol" } } } },
  } })
  assert(providers.adapters()["discovery-fixture"]())
  assert(#calls == 1, "provider discovery did not execute")
  check(calls[1])

  package.loaded["maxa.adapters.http.openai_compatible"] = nil
  local compatible = require("maxa.adapters.http.openai_compatible")
  providers.configure({ fixture = {
    base_url = "https://compatible.invalid", api_key = "fixture-key", proxy = true,
    models = { source = "static", choices = { ["gpt-6-sol"] = {} } },
    llm = { openai_compatible = { name = "compatible-fixture", schema = { model = {
      default = "gpt-6-sol", choices = { ["gpt-6-sol"] = {} },
    } } } },
  } })
  local adapter = providers.adapters()["compatible-fixture"]()
  local models = compatible.schema.model.choices(adapter)
  assert(models[1] == "gpt-6-sol" and #calls == 2, "compatible discovery did not execute")
  check(calls[2])
end

print("PROVIDER_CONFIG_TEST_OK")
vim.cmd("qa!")
