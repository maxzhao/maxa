-- Run: nvim --headless -l lua/maxa/mcphub/native_servers/genai/default_adapter_test.lua
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("✓ " .. name) else failed = failed + 1; print("✗ " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b) assert(a == b, string.format("expected %s, got %s", tostring(a), tostring(b))) end

local root = vim.fn.stdpath("config")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local registry = require("maxa.mcphub.native_servers.genai.capability_registry")
test("shared media defaults do not select a deployment adapter", function()
  eq(nil, require("maxa.presets").get_default("image").adapter)
end)
local state = require("maxa.mcphub.native_servers.genai.default_adapter")

registry.clear_for_test()
test("registry lists only explicit capabilities and deep copies", function()
  local source = { image = { mode = "codex" }, tts = {} }
  assert(registry.register("a", "Adapter A", source))
  assert(registry.register("b", "Adapter B", { video = {} }))
  source.image.mode = "compatible"
  eq(1, #registry.list("image")); eq("a", registry.list("image")[1].name)
  eq(1, #registry.list("video")); eq("b", registry.list("video")[1].name)
  eq("codex", registry.get("a").capabilities.image.mode)
  local copy = registry.get("a"); copy.capabilities.image.mode = "changed"
  eq("codex", registry.get("a").capabilities.image.mode)
end)

test("registry rejects unknown capabilities", function()
  local ok, err = registry.register("bad", "Bad", { audio = {} })
  eq(false, ok); assert(err:match("unsupported genai capability"))
end)

test("state persists independent medium keys", function()
  local path = vim.fn.tempname(); vim.env.MAXA_GENAI_ENV_FILE = path
  vim.fn.writefile({ "OTHER=value", "GENAI_DEFAULT_TTS_ADAPTER=old_tts" }, path)
  local config = { default_adapters = { image = "old_image", tts = "old_tts", video = "old_video" } }
  assert(state.persist_and_apply("image", "new_image", config))
  eq("new_image", config.default_adapters.image); eq("old_tts", config.default_adapters.tts)
  local body = table.concat(vim.fn.readfile(path), "\n")
  assert(body:match("OTHER=value")); assert(body:match("GENAI_DEFAULT_TTS_ADAPTER=old_tts")); assert(body:match("GENAI_DEFAULT_IMAGE_ADAPTER=new_image"))
  local loaded = state.get_initial_config({ default_adapters = { image = "fallback", tts = "fallback", video = "fallback" } })
  eq("new_image", loaded.default_adapters.image); eq("old_tts", loaded.default_adapters.tts); eq("fallback", loaded.default_adapters.video)
  vim.fn.delete(path)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
