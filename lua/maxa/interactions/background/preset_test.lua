-- Run: nvim --headless -u NONE -l lua/maxa/interactions/background/preset_test.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

local config = require("maxa.config")
config.configure_early({ presets = {
  default = { adapter = "my_oai", model = "gpt-6-sol", temperature = 0.0 },
  title = { adapter = "gemini", model = "title-model", temperature = 0.3 },
  compact = {},
} })
local adapters = require("maxa.adapters")
local original_resolve = adapters.resolve
adapters.resolve = function(name, opts)
  return {
    name = name,
    type = "http",
    schema = {
      model = { default = opts.model },
      temperature = { default = 1 },
    },
    map_schema_to_params = function(self, settings) self.parameters = settings end,
  }
end

local Background = require("maxa.interactions.background")
local default = assert(Background.new())
assert(default.adapter.name == "my_oai")
assert(default.settings.model == "gpt-6-sol" and default.settings.temperature == 0.0)
local title = assert(Background.new({ preset = "title" }))
assert(title.adapter.name == "gemini" and title.settings.model == "title-model" and title.settings.temperature == 0.3)
local compact = assert(Background.new({ preset = "compact", chat = {
  adapter = { name = "openai", model = { name = "parent-model" } },
  settings = { model = "parent-model", temperature = 0.42 },
} }))
assert(compact.adapter.name == "openai" and compact.settings.model == "parent-model")
assert(compact.settings.temperature == 0.42)
local unknown, err = Background.new({ preset = "missing" })
assert(unknown == nil and err:find("Unknown preset", 1, true))
local raw, raw_err = Background.new({ adapter = "openai" })
assert(raw == nil and raw_err:find("preset name", 1, true))
adapters.resolve = original_resolve
print("BACKGROUND_PRESET_OK")
