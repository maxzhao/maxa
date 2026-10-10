-- filepath: lua/maxa/mcphub/native_servers/genai/image/image_edit_test.lua
-- 单元测试: image_edit 工具与 OpenAI-compatible multipart 编辑请求
-- 运行方式: nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_edit_test.lua

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

local lazy_root = vim.fn.stdpath("data") .. "/lazy"
local plenary_root = lazy_root .. "/plenary.nvim"
vim.opt.runtimepath:prepend(plenary_root)
package.path = table.concat({
  plenary_root .. "/lua/?.lua",
  plenary_root .. "/lua/?/init.lua",
  package.path,
}, ";")

print("\n=== Testing genai image_edit tool ===\n")

local declaration = {
  image = {
    mode = "compatible",
    endpoints = { generations = "/images/generations", edits = "/images/edits" },
    request = { max_n = 15, image_field = "image", mask_field = "mask" },
  },
}
require("maxa.provider_config").configure({
  xuanjing = {
    base_url = "https://gateway.example.invalid/v1", api_key = "test-api-key",
    genai = { image = vim.tbl_extend("force", { adapter = "xuanjing_openai" }, vim.deepcopy(declaration.image)) },
  },
  missing_key = {
    base_url = "https://gateway.example.invalid/v1",
    genai = { image = vim.tbl_extend("force", { adapter = "missing_key_openai" }, vim.deepcopy(declaration.image)) },
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
local image_edit = require("maxa.mcphub.native_servers.genai.tools.image_edit")
local genai = require("maxa.mcphub.native_servers.genai")

local temp_dir = vim.fn.tempname()
vim.fn.mkdir(temp_dir, "p")
local image_a = temp_dir .. "/input-a.png"
local image_b = temp_dir .. "/input-b.png"
local mask = temp_dir .. "/mask.png"
vim.fn.writefile({ "fake-image-a" }, image_a, "b")
vim.fn.writefile({ "fake-image-b" }, image_b, "b")
vim.fn.writefile({ "fake-mask" }, mask, "b")

local function make_res()
  return {
    text_value = nil,
    error_value = nil,
    text = function(self, value)
      self.text_value = value
      return {
        send = function()
          return value
        end,
      }
    end,
    error = function(self, value)
      self.error_value = value
      return value
    end,
  }
end

test("should expose image_edit schema with required prompt and image_paths", function()
  assert_equal("image_edit", image_edit.name)
  assert_true(image_edit.inputSchema.properties.prompt ~= nil, "prompt schema should exist")
  assert_true(image_edit.inputSchema.properties.preset ~= nil, "preset schema should exist")
  assert_nil(image_edit.inputSchema.properties.adapter, "legacy adapter must not be advertised")
  assert_nil(image_edit.inputSchema.properties.provider, "provider schema should be absent")
  assert_true(image_edit.inputSchema.properties.image_paths ~= nil, "image_paths schema should exist")
  assert_true(image_edit.inputSchema.properties.background ~= nil, "background schema should exist")
  assert_true(image_edit.inputSchema.properties.text_model ~= nil, "text_model schema should exist")
  assert_true(image_edit.inputSchema.properties.requested_size ~= nil, "requested_size schema should exist")
  assert_nil(image_edit.inputSchema.properties.size, "legacy size schema should be absent")
  assert_nil(image_edit.inputSchema.properties.aspect, "legacy aspect schema should be absent")
  assert_nil(image_edit.inputSchema.properties.ratio, "legacy ratio schema should be absent")
  assert_equal("prompt", image_edit.inputSchema.required[1])
  assert_equal("image_paths", image_edit.inputSchema.required[2])
  assert_equal(1, image_edit.inputSchema.properties.image_paths.minItems)
end)

test("should register image_edit in genai tools", function()
  local found = false
  for _, tool in ipairs(genai.capabilities.tools) do
    if tool.name == "image_edit" then
      found = true
      break
    end
  end
  assert_true(found, "image_edit should be registered")
end)

test("should build multipart edit request for multiple images and mask", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.edit(provider, {
    prompt = "restyle these images",
    image_paths = { image_a, image_b },
    mask_path = mask,
    output_dir = temp_dir,
    filename_prefix = "edit test",
    background = "transparent",
    extra = {
      reference_strength = 0.5,
    },
  })

  assert_true(request, err)
  assert_equal("POST", request.method)
  assert_equal("multipart/form-data", request.content_type)
  assert_match("/images/edits$", request.endpoint)
  assert_equal("image", request.multipart.image_field)
  assert_equal("mask", request.multipart.mask_field)
  assert_equal(2, #request.multipart.images)
  assert_match("input%-a%.png$", request.multipart.images[1])
  assert_match("input%-b%.png$", request.multipart.images[2])
  assert_match("mask%.png$", request.multipart.mask)
  assert_equal("restyle these images", request.multipart.fields.prompt)
  assert_equal("auto", request.multipart.fields.size)
  assert_equal("auto", request.params.requested_size)
  assert_equal(true, request.multipart.fields.stream)
  assert_equal(true, request.stream)
  assert_equal("transparent", request.multipart.fields.background)
  assert_equal(0.5, request.multipart.fields.reference_strength)
end)


test("should default compatible edit to streaming", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.edit(provider, {
    prompt = "restyle this image",
    image_paths = { image_a },
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal(true, request.multipart.fields.stream)
  assert_equal(true, request.stream)
end)

test("should forward openai_compatible edit requested_size unchanged", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.edit(provider, {
    prompt = "make it tall",
    image_paths = { image_a },
    output_dir = temp_dir,
    requested_size = "1024x1536",
  })

  assert_true(request, err)
  assert_equal("1024x1536", request.multipart.fields.size)
  assert_equal("1024x1536", request.params.requested_size)
end)

test("should reject openai_compatible edit legacy size controls and text_model", function()
  local provider = assert(image.get_adapter())
  for _, field in ipairs({ "size", "aspect", "ratio" }) do
    local request, err = driver.edit(provider, {
      prompt = "legacy field",
      image_paths = { image_a },
      output_dir = temp_dir,
      [field] = "1:1",
    })
    assert_nil(request)
    assert_match(field, err)
  end

  local request, err = driver.edit(provider, {
    prompt = "bad text model",
    image_paths = { image_a },
    output_dir = temp_dir,
    text_model = "gpt-5.6-sol",
  })

  assert_nil(request)
  assert_match("text_model", err)
end)

test("should dedupe repeated final edit image across SSE events", function()
  local encoded = vim.base64.encode("same-edited-image")
  local decoded, err = driver._decode_sse_response(table.concat({
    'data: {"data":[{"b64_json":"' .. encoded .. '"}]}',
    "",
    'data: {"response":{"body":{"data":[{"b64_json":"' .. encoded .. '"}]}}}',
    "",
    "data: [DONE]",
    "",
  }, "\n"))

  assert_true(decoded, err)
  assert_equal(1, #decoded.data)
  assert_equal(encoded, decoded.data[1].b64_json)
end)

test("should save b64_json edit response without returning base64", function()
  local provider = assert(image.get_adapter())
  local request = assert(driver.edit(provider, {
    prompt = "edit this",
    image_paths = { image_a },
    output_dir = temp_dir,
    output_format = "png",
    filename_prefix = "edit output",
  }))

  local result, err = driver.save_image_response(request, {
    body = {
      data = {
        { b64_json = vim.base64.encode("fake-edited-image") },
      },
    },
  })

  assert_true(result, err)
  assert_equal("xuanjing_openai", result.provider)
  assert_equal("json", result.response_mode)
  assert_equal(1, #result.files)
  assert_match("edit_output", result.files[1].path)
  assert_equal(#"fake-edited-image", result.files[1].bytes)
  assert_equal("unverified", result.size_check)
  assert_equal("unverified", result.files[1].size_check)
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "edited output file should exist")
end)

test("should asynchronously download url edit response without blocking save path", function()
  local provider = assert(image.get_adapter())
  local request = assert(driver.edit(provider, {
    prompt = "edit url",
    image_paths = { image_a },
    output_dir = temp_dir,
    output_format = "png",
  }))

  local original_jobstart = vim.fn.jobstart
  vim.fn.jobstart = function(cmd, opts)
    assert_equal("curl", cmd[1])
    local output_path
    for i, part in ipairs(cmd) do
      if part == "-o" then
        output_path = cmd[i + 1]
        break
      end
    end
    assert_true(output_path ~= nil, "curl output path should be provided")
    vim.schedule(function()
      vim.fn.writefile({ "async-downloaded-edit-url-image" }, output_path, "b")
      opts.on_exit(12, 0)
    end)
    return 12
  end

  local result, err
  driver.save_image_response_async(request, {
    response_mode = "json",
    body = {
      data = {
        { url = "https://example.test/edit.png" },
      },
    },
  }, function(callback_result, callback_err)
    result = callback_result
    err = callback_err
  end)

  vim.wait(1000, function()
    return result ~= nil or err ~= nil
  end)
  vim.fn.jobstart = original_jobstart

  assert_true(result, err)
  assert_equal(1, #result.files)
  assert_equal("json", result.response_mode)
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "downloaded edit output file should exist")
end)

test("should reject edit without prompt", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.edit(provider, { image_paths = { image_a } })

  assert_nil(request)
  assert_match("prompt", err)
end)

test("should reject edit without image_paths", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.edit(provider, { prompt = "edit" })

  assert_nil(request)
  assert_match("image_paths", err)
end)

test("should reject edit when input image is missing", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.edit(provider, {
    prompt = "edit",
    image_paths = { temp_dir .. "/missing.png" },
  })

  assert_nil(request)
  assert_match("not found", err)
end)

test("should reject edit when mask file is missing", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.edit(provider, {
    prompt = "edit",
    image_paths = { image_a },
    mask_path = temp_dir .. "/missing-mask.png",
  })

  assert_nil(request)
  assert_match("mask_path", err)
  assert_match("not found", err)
end)

test("should return clear error when api key is missing", function()
  local adapter, err = image.get_adapter("missing_key_openai")
  assert_nil(adapter)
  assert_match("API key is missing", err)
end)

test("handler should return clear error for missing prompt", function()
  local res = make_res()
  image_edit.handler({ params = { image_paths = { image_a } } }, res)
  assert_match("prompt", res.error_value)
end)

test("handler should return clear error for empty image_paths", function()
  local res = make_res()
  image_edit.handler({ params = { prompt = "edit", image_paths = {} } }, res)
  assert_match("image_paths", res.error_value)
end)

test("handler should reject legacy size controls before provider dispatch", function()
  for _, field in ipairs({ "size", "aspect", "ratio" }) do
    local res = make_res()
    image_edit.handler({ params = { prompt = "edit", image_paths = { image_a }, [field] = "1:1" } }, res)
    assert_match(field, res.error_value)
  end
end)

test("handler should return clear error for unknown adapter", function()
  local res = make_res()
  image_edit.handler({ params = { prompt = "edit", image_paths = { image_a }, adapter = "missing_provider" } }, res)
  assert_match("does not provide image capability", res.error_value)
end)


print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
