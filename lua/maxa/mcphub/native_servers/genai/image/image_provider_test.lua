-- filepath: lua/maxa/mcphub/native_servers/genai/image/image_provider_test.lua
-- 单元测试: 图片 provider 配置与 openai_compatible driver 抽象
-- 运行方式: nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_provider_test.lua

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

local function assert_true(value, msg)
  if not value then
    error(msg or "expected true, got false")
  end
end

local function assert_nil(value, msg)
  if value ~= nil then
    error(string.format("%s: expected nil, got %s", msg or "assertion failed", tostring(value)))
  end
end

local function assert_match(pattern, value, msg)
  if type(value) ~= "string" or not value:match(pattern) then
    error(string.format("%s: pattern %q not found in %q", msg or "assertion failed", pattern, tostring(value)))
  end
end

local function assert_false(value, msg)
  if value then
    error(msg or "expected false, got true")
  end
end

local lazy_root = vim.fn.stdpath("data") .. "/lazy"
local plenary_root = lazy_root .. "/plenary.nvim"
vim.opt.runtimepath:prepend(plenary_root)
package.path = table.concat({
  vim.fn.stdpath("config") .. "/lua/?.lua",
  vim.fn.stdpath("config") .. "/lua/?/init.lua",
  plenary_root .. "/lua/?.lua",
  plenary_root .. "/lua/?/init.lua",
  package.path,
}, ";")

print("\n=== Testing genai image adapter abstraction ===\n")

local declaration = {
  image = {
    mode = "compatible",
    defaults = { model = "adapter-image", output_format = "png" },
    endpoints = { generations = "/images/generations", edits = "/images/edits" },
    request = { max_n = 15, image_field = "image", mask_field = "mask" },
  },
}
require("maxa.provider_config").configure({
  xuanjing = {
    base_url = "https://api.example/v1", api_key = "test-api-key",
    genai = { image = vim.tbl_extend("force", { adapter = "xuanjing_openai" }, vim.deepcopy(declaration.image)) },
  },
})

vim.env.MAXA_GENAI_ENV_FILE = vim.fn.tempname()
require("maxa.config").configure_early({
  presets = { default = { adapter = "xuanjing_openai" } },
  genai = { default_adapters = { image = "xuanjing_openai", tts = "xuanjing_openai", video = "xuanjing_openai" } },
})
local config = require("maxa.mcphub.native_servers.genai.config")
local image = require("maxa.mcphub.native_servers.genai.image")
local driver = require("maxa.mcphub.native_servers.genai.image.providers.openai_compatible")
local output_metadata = require("maxa.mcphub.native_servers.genai.image.output_metadata")
local result_text = require("maxa.mcphub.native_servers.genai.image.result_text")

test("should resolve default image adapter", function()
  local adapter, err = image.get_adapter()
  assert_true(adapter, err)
  assert_equal("xuanjing_openai", adapter.name)
  assert_equal("openai_compatible", adapter.driver)
  assert_equal("adapter-image", adapter.defaults.model)
  assert_equal("auto", adapter.defaults.requested_size)
  assert_equal("png", adapter.defaults.output_format)
  assert_equal(true, adapter.force_stream)
  assert_match("genai%-media", adapter.output_dir)
end)

test("should reject adapter without declared capability", function()
  local adapter, err = image.get_adapter("missing_adapter")
  assert_nil(adapter)
  assert_match("does not provide image capability", err)
end)

test("should persist and apply independent default adapter", function()
  local state = require("maxa.mcphub.native_servers.genai.default_adapter")
  local ok, err = state.persist_and_apply("image", "xuanjing_openai", config)
  assert_true(ok, err)
  assert_equal("xuanjing_openai", config.default_adapters.image)
  local body = table.concat(vim.fn.readfile(vim.env.MAXA_GENAI_ENV_FILE), "\n")
  assert_match("GENAI_DEFAULT_IMAGE_ADAPTER=xuanjing_openai", body)
  assert_false(body:match("GENAI_DEFAULT_PROVIDER"))
end)

test("should reject empty runtime default adapter", function()
  local state = require("maxa.mcphub.native_servers.genai.default_adapter")
  local ok, err = state.write_persisted("image", "")
  assert_false(ok)
  assert_match("adapter is required", err)
end)

test("should return adapter copy instead of mutable global table", function()
  local adapter = assert(image.get_adapter())
  adapter.defaults.model = "mutated-model"
  local fresh = assert(image.get_adapter())
  assert_equal("adapter-image", fresh.defaults.model)
end)

test("should merge call params over adapter and global defaults", function()
  local adapter = assert(image.get_adapter())
  local merged = image.build_request_params(adapter, {
    prompt = "a small cat", requested_size = "512x512", output_format = "webp",
  })
  assert_equal("a small cat", merged.prompt)
  assert_equal("512x512", merged.requested_size)
  assert_equal("webp", merged.output_format)
  assert_equal("adapter-image", merged.model)
end)

test("should ignore absent optional params", function()
  local adapter = assert(image.get_adapter())
  local merged = image.build_request_params(adapter, { prompt = "cat", model = vim.NIL, requested_size = "" })
  assert_equal("adapter-image", merged.model)
  assert_equal("auto", merged.requested_size)
end)

test("should use default adapter for vim.NIL or empty", function()
  assert_equal("xuanjing_openai", assert(image.get_adapter(vim.NIL)).name)
  assert_equal("xuanjing_openai", assert(image.get_adapter("")).name)
end)

test("should prepare generation request without network call", function()
  local adapter = assert(image.get_adapter())
  local request, err = driver.generate(adapter, { prompt = "a small cat" })
  assert_true(request, err)
  assert_equal("POST", request.method)
  assert_match("/images/generations$", request.endpoint)
  assert_equal("adapter-image", request.body.model)
  assert_equal("auto", request.body.size)
end)

test("should reject generation without prompt", function()
  local request, err = driver.generate(assert(image.get_adapter()), {})
  assert_nil(request); assert_match("prompt", err)
end)

test("should reject edit without image_paths", function()
  local request, err = driver.edit(assert(image.get_adapter()), { prompt = "edit this" })
  assert_nil(request); assert_match("image_paths", err)
end)

local function be16(value)
  return string.char(math.floor(value / 256) % 256, value % 256)
end

local function be32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function le24(value)
  return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256)
end

local function le32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function png_bytes(width, height)
  return "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(width) .. be32(height) .. "\8\6\0\0\0" .. "\0\0\0\0"
end

local function jpeg_bytes(width, height)
  return "\255\216\255\192" .. be16(17) .. "\8" .. be16(height) .. be16(width) .. string.rep("\0", 10) .. "\255\217"
end

local function webp_chunk(chunk_type, payload)
  local padding = #payload % 2 == 1 and "\0" or ""
  return "RIFF" .. le32(4 + 8 + #payload + #padding) .. "WEBP" .. chunk_type .. le32(#payload) .. payload .. padding
end

local function webp_vp8x_bytes(width, height)
  return webp_chunk("VP8X", "\0\0\0\0" .. le24(width - 1) .. le24(height - 1))
end

local function webp_vp8l_bytes(width, height)
  local width_minus_one = width - 1
  local height_minus_one = height - 1
  local b1 = width_minus_one % 256
  local b2 = math.floor(width_minus_one / 256) + (height_minus_one % 4) * 64
  local b3 = math.floor(height_minus_one / 4) % 256
  local b4 = math.floor(height_minus_one / 1024) % 16
  return webp_chunk("VP8L", string.char(0x2F, b1, b2, b3, b4))
end

local function webp_vp8_bytes(width, height)
  local payload = "\0\0\0" .. "\157\1\42" .. string.char(width % 256, math.floor(width / 256), height % 256, math.floor(height / 256))
  return webp_chunk("VP8 ", payload)
end

test("should inspect PNG JPEG and WebP dimensions from file bytes", function()
  local png = assert(output_metadata.inspect_bytes(png_bytes(1536, 1024)))
  assert_equal("png", png.actual_format)
  assert_equal(1536, png.actual_width)
  assert_equal(1024, png.actual_height)

  local jpeg = assert(output_metadata.inspect_bytes(jpeg_bytes(941, 1672)))
  assert_equal("jpeg", jpeg.actual_format)
  assert_equal(941, jpeg.actual_width)
  assert_equal(1672, jpeg.actual_height)

  local webp = assert(output_metadata.inspect_bytes(webp_vp8x_bytes(1672, 941)))
  assert_equal("webp", webp.actual_format)
  assert_equal(1672, webp.actual_width)
  assert_equal(941, webp.actual_height)

  local webp_lossless = assert(output_metadata.inspect_bytes(webp_vp8l_bytes(1254, 1254)))
  assert_equal("webp", webp_lossless.actual_format)
  assert_equal(1254, webp_lossless.actual_width)
  assert_equal(1254, webp_lossless.actual_height)

  local webp_lossy = assert(output_metadata.inspect_bytes(webp_vp8_bytes(2048, 1152)))
  assert_equal("webp", webp_lossy.actual_format)
  assert_equal(2048, webp_lossy.actual_width)
  assert_equal(1152, webp_lossy.actual_height)
end)

test("should report exact, mismatched, auto, unverified, and format mismatch metadata", function()
  local exact_path = vim.fn.tempname() .. ".png"
  local mismatch_path = vim.fn.tempname() .. ".jpeg"
  local malformed_path = vim.fn.tempname() .. ".png"
  local function write_binary(path, data)
    local file = assert(io.open(path, "wb"))
    assert(file:write(data))
    file:close()
  end
  write_binary(exact_path, png_bytes(1536, 1024))
  write_binary(mismatch_path, png_bytes(1672, 941))
  write_binary(malformed_path, "not-an-image")

  local exact = output_metadata.finalize_result({
    requested_size = "1536x1024",
    output_format = "png",
    files = { { path = exact_path, bytes = vim.uv.fs_stat(exact_path).size } },
  })
  assert_equal("matched", exact.size_check)
  assert_equal("1536x1024", exact.files[1].actual_size)

  local aggregate = output_metadata.finalize_result({
    requested_size = "3840x2160",
    output_format = "jpeg",
    files = {
      { path = mismatch_path, bytes = vim.uv.fs_stat(mismatch_path).size },
      { path = malformed_path, bytes = vim.uv.fs_stat(malformed_path).size },
    },
  })
  assert_equal("mismatched", aggregate.size_check)
  assert_equal("1672x941", aggregate.files[1].actual_size)
  assert_equal("png", aggregate.files[1].actual_format)
  assert_equal("unverified", aggregate.files[2].size_check)
  assert_true(#aggregate.warnings >= 3, "mismatch, format, and unverified warnings should be present")

  local automatic = output_metadata.finalize_result({
    requested_size = "auto",
    output_format = "png",
    files = { { path = exact_path, bytes = vim.uv.fs_stat(exact_path).size } },
  })
  assert_equal("not_applicable", automatic.size_check)
  assert_equal("not_applicable", automatic.files[1].size_check)

  local summary = result_text.build("done", aggregate)
  assert_match("Requested size: 3840x2160", summary)
  assert_match("1672x941 actual", summary)
  assert_match("Size check: mismatched", summary)
  assert_true(not summary:match("%- Size:"), "summary must not use ambiguous Size label")
end)

test("should reject edit when image file does not exist", function()
  local adapter = assert(image.get_adapter())
  local request, err = driver.edit(adapter, {
    prompt = "edit this",
    image_paths = { "/tmp/genai-image-provider-test-missing.png" },
  })

  assert_nil(request)
  assert_match("not found", err)
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
