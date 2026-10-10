-- Run: nvim --headless -l lua/maxa/mcphub/native_servers/genai/media/media_contract_test.lua
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("✓ " .. name) else failed = failed + 1; print("✗ " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b) assert(a == b, string.format("expected %s, got %s", tostring(a), tostring(b))) end
local function contains(list, value) for _, item in ipairs(list) do if item == value then return true end end return false end

local root = vim.fn.stdpath("config")
local lazy_root = vim.fn.stdpath("data") .. "/lazy"
local plenary_root = lazy_root .. "/plenary.nvim"
vim.opt.runtimepath:prepend(plenary_root)
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", plenary_root .. "/lua/?.lua", plenary_root .. "/lua/?/init.lua", package.path }, ";")
local provider = require("maxa.mcphub.native_servers.genai.adapter")
local speech = require("maxa.mcphub.native_servers.genai.audio.openai_speech")
local video = require("maxa.mcphub.native_servers.genai.video.infinite_canvas")
local audio_tool = require("maxa.mcphub.native_servers.genai.tools.audio_speech")
local video_tool = require("maxa.mcphub.native_servers.genai.tools.video_generate")
local http = require("maxa.mcphub.native_servers.genai.media.http")

test("tool schemas expose exact required contracts", function()
  eq("audio_speech", audio_tool.name); eq("input", audio_tool.inputSchema.required[1])
  eq("video_generate", video_tool.name); eq("prompt", video_tool.inputSchema.required[1])
  eq(7, video_tool.inputSchema.properties.reference_image_paths.maxItems)
  assert(audio_tool.inputSchema.properties.preset and not audio_tool.inputSchema.properties.adapter)
  assert(video_tool.inputSchema.properties.preset and video_tool.inputSchema.properties.generation_preset)
  assert(not video_tool.inputSchema.properties.provider and not video_tool.inputSchema.properties.adapter)
end)

test("speech request merges defaults and validates speed", function()
  local body = assert(speech.build_request({ defaults = { model = "tts", voice = "alloy", response_format = "mp3", speed = 1 } }, { input = "hello", speed = 1.5 }))
  eq("hello", body.input); eq(1.5, body.speed); eq("tts", body.model)
  local invalid, err = speech.build_request({ defaults = { model = "tts", voice = "alloy", response_format = "mp3" } }, { input = "hello", speed = 5 })
  eq(nil, invalid); assert(err:match("0%.25%.%.4"))
end)

test("video multipart uses Infinite Canvas fields", function()
  local form, merged = video.build_create({ defaults = { model = "sora", seconds = 6, size = "1280x720", resolution_name = "720p", preset = "normal" }, request = { reference_field = "input_reference[]", max_reference_images = 7 } }, { prompt = "orbit" })
  assert(contains(form.strings, "prompt=orbit")); assert(contains(form.strings, "seconds=6")); assert(contains(form.strings, "resolution_name=720p")); eq("sora", merged.model)
  local explicit = assert(video.build_create({ defaults = { seconds = 6, preset = "normal" }, request = {} }, { prompt = "orbit", generation_preset = "cinematic" }))
  assert(contains(explicit.strings, "preset=cinematic"))
end)

test("video parser accepts envelopes and failures", function()
  local task = assert(video.parse_task('{"code":0,"data":{"id":"v1","status":"completed","url":"https://x/v.mp4"}}'))
  eq("v1", task.id); eq("completed", task.status)
  local failed = assert(video.parse_task('{"id":"v2","status":"failed","error":{"message":"moderated"}}'))
  eq("moderated", failed.error)
  local missing, err = video.parse_task('{"code":500,"msg":"quota"}')
  eq(nil, missing); eq("quota", err)
end)

test("capability endpoints honor overrides", function()
  local p = { api_root = "https://x/v1", endpoints = {} }
  eq("https://x/v1/custom/speech", provider.endpoint(p, "speech", nil, { endpoint = "/custom/speech" }))
  eq("https://x/v1/jobs/abc", provider.endpoint(p, "video_retrieve", "abc", { endpoints = { retrieve = "/jobs/{id}" } }))
end)

test("capability presence alone defines support", function()
  local missing, missing_err = provider.capability({ name = "p" }, "tts")
  eq(nil, missing); assert(missing_err:match("does not provide tts"))
  local enabled = assert(provider.capability({ name = "p", image = { mode = "codex" } }, "image"))
  eq("codex", enabled.mode); eq(nil, enabled.enabled)
end)

test("video parser accepts Infinite Canvas result url aliases", function()
  local direct = assert(video.parse_task('{"id":"v2","status":"completed","result_url":"https://x/result.mp4"}'))
  eq("https://x/result.mp4", direct.url)
  local nested = assert(video.parse_task('{"id":"v3","status":"completed","content":{"video_url":"https://x/content.mp4"}}'))
  eq("https://x/content.mp4", nested.url)
end)

test("deterministic speech binary save", function()
  local original, result = http.request_async, nil
  local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
  http.request_async = function(_, cb) cb({ body = "ID3audio", headers = "Content-Type: audio/mpeg\r\n", status = 200 }) end
  speech.speech_async({ name = "p", api_key = "k", api_root = "https://x/v1", output_dir = dir }, { defaults = { model = "tts", voice = "v", response_format = "mp3", speed = 1 } }, { input = "hello" }, function(value) result = value end)
  http.request_async = original
  assert(result and result.adapter == "p" and result.bytes == 8 and vim.fn.filereadable(result.path) == 1)
  vim.fn.delete(dir, "rf")
end)

test("video cancellation stops pending polls and completes once", function()
  local original, callbacks, callback_count, final_err = http.request_async, 0, 0, nil
  http.request_async = function(_, cb)
    callbacks = callbacks + 1
    cb({ body = '{"id":"cancel-me","status":"queued"}', headers = "Content-Type: application/json\r\n", status = 200 })
  end
  local handle = video.generate_async(
    { name = "p", api_key = "k", api_root = "https://x/v1" },
    { defaults = { model = "sora", seconds = 6 }, request = { poll_interval_ms = 100, max_poll_attempts = 3 } },
    { prompt = "orbit" },
    function(_, err) callback_count = callback_count + 1; final_err = err end
  )
  assert(handle.cancel())
  vim.wait(180)
  http.request_async = original
  eq(1, callbacks); eq(1, callback_count); eq("Video generation cancelled", final_err)
end)

test("deterministic video create poll content flow", function()
  local original, calls, result = http.request_async, 0, nil
  local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
  http.request_async = function(opts, cb)
    calls = calls + 1
    if calls == 1 then cb({ body = '{"id":"v1","status":"queued"}', headers = "Content-Type: application/json\r\n", status = 200 })
    elseif calls == 2 then cb({ body = '{"id":"v1","status":"completed"}', headers = "Content-Type: application/json\r\n", status = 200 })
    else cb({ body = "video-bytes", headers = "Content-Type: video/mp4\r\n", status = 200 }) end
  end
  video.generate_async({ name = "p", api_key = "k", api_root = "https://x/v1", output_dir = dir }, { defaults = { model = "sora", seconds = 6 }, request = { poll_interval_ms = 1, max_poll_attempts = 3 } }, { prompt = "orbit" }, function(value) result = value end)
  vim.wait(1000, function() return result ~= nil end, 5)
  http.request_async = original
  assert(result and result.task_id == "v1" and result.bytes == 11 and calls == 3)
  vim.fn.delete(dir, "rf")
end)

test("media-only provider resolves proxy again for each curl invocation", function()
  local route = "http://127.0.0.1:10808"
  require("maxa.provider_config").configure({
    media = { base_url = "https://media.example/v1", api_key = "test-key",
      proxy = function(current) eq("media", current.id); return route end,
      genai = { tts = { adapter = "media-tts" } } },
  })
  local service = assert(provider.get_adapter("media-tts", "tts"))
  local commands = {}
  local original_system = vim.system
  vim.system = function(args, _, finish)
    commands[#commands + 1] = args
    finish({ stdout = "200", code = 0 })
    return { kill = function() end }
  end
  local completed = 0
  http.request_async({ url = "https://media.example/v1/speech", proxy = service.proxy }, function() completed = completed + 1 end)
  route = nil
  http.request_async({ url = "https://media.example/v1/speech", proxy = service.proxy }, function() completed = completed + 1 end)
  vim.wait(100, function() return completed == 2 end, 5)
  vim.system = original_system
  assert(contains(commands[1], "--proxy") and contains(commands[1], "http://127.0.0.1:10808"))
  assert(contains(commands[2], "--noproxy") and contains(commands[2], "*"))
  local missing = provider.get_adapter("unregistered", "tts")
  eq(nil, missing)
end)

test("explicit named media preset resolves type and parameter precedence", function()
  local runtime = require("maxa.config").runtime()
  local previous = runtime.presets
  runtime.presets = {
    voice = { type = "tts", adapter = "media-tts", model = "named", voice = "echo", visible = true, description = "Speech" },
    image = { type = "image", adapter = "images", model = "picture" },
  }
  local resolver = require("maxa.mcphub.native_servers.genai.preset")
  local name, params, err = resolver.resolve(nil, "tts", { preset = "voice", input = "hello", voice = "alloy" })
  eq(nil, err); eq("media-tts", name); eq("named", params.model); eq("alloy", params.voice)
  eq(nil, params.preset); eq(nil, params.type); eq(nil, params.description); eq(nil, params.source)
  local bad, _, wrong = resolver.resolve(nil, "tts", { preset = "image", input = "hello" })
  eq(nil, bad); assert(wrong:find("type tts", 1, true))
  local missing, _, unknown = resolver.resolve(nil, "tts", { preset = "missing", input = "hello" })
  eq(nil, missing); assert(unknown:find("Unknown preset", 1, true))
  local original, dispatched = speech.speech_async, false
  speech.speech_async = function(service, capability, request)
    dispatched = true
    eq("media-tts", service.name); eq("named", request.model); eq("echo", request.voice)
    eq(nil, request.preset)
  end
  audio_tool.handler({ params = { input = "hello", preset = "voice" } }, { error = function(_, message) error(message) end })
  speech.speech_async = original
  assert(dispatched)
  runtime.presets = previous
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then vim.cmd("cquit 1") end
vim.cmd("qa!")
