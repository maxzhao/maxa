-- Run: nvim --headless -u NONE -l lua/maxa/mcphub/native_servers/genai/default_adapter_ui_test.lua

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then print("PASS " .. name) else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

local selections = {}
local listed_medium
package.loaded["maxa.mcphub.native_servers.genai.config"] = {}
package.loaded["maxa.mcphub.native_servers.genai.default_adapter"] = {
  current = function()
    return { image = "openai", tts = "elevenlabs", video = "replicate" }
  end,
}
local declarations = {
  openai = { name = "openai", formatted_name = "OpenAI", capabilities = { image = {} } },
  elevenlabs = { name = "elevenlabs", formatted_name = "ElevenLabs", capabilities = { tts = {} } },
  replicate = { name = "replicate", formatted_name = "Replicate", capabilities = { video = {} } },
}
package.loaded["maxa.mcphub.native_servers.genai.capability_registry"] = {
  get = function(name) return declarations[name] end,
  list = function(medium)
    listed_medium = medium
    return { declarations.openai }
  end,
}
package.loaded["maxa.mcphub.native_servers.genai.default_adapter_ui"] = nil

local old_select = vim.ui.select
vim.ui.select = function(items, opts, cb)
  table.insert(selections, { items = items, opts = opts, cb = cb })
end
local ui = require("maxa.mcphub.native_servers.genai.default_adapter_ui")

test("medium picker displays each current provider", function()
  ui.select_adapter()
  local pick = selections[#selections]
  assert(pick.opts.format_item("image") == "image - OpenAI")
  assert(pick.opts.format_item("tts") == "tts - ElevenLabs")
  assert(pick.opts.format_item("video") == "video - Replicate")
end)

test("medium picker keeps raw medium selection behavior", function()
  local pick = selections[#selections]
  pick.cb("image")
  assert(listed_medium == "image")
  assert(selections[#selections].opts.prompt == "Set genai image default adapter")
end)

vim.ui.select = old_select
print(string.format("RESULT %d passed, %d failed", total - failed, failed))
if failed > 0 then vim.cmd("cquit 1") end
