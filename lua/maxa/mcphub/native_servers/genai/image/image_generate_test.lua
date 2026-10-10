-- filepath: lua/maxa/mcphub/native_servers/genai/image/image_generate_test.lua
-- 单元测试: image_generate 工具与 OpenAI-compatible 生图响应保存
-- 运行方式: nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_generate_test.lua

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

print("\n=== Testing genai image_generate tool ===\n")

local declaration = {
  image = {
    mode = "compatible",
    defaults = { model = "gpt-image-2" },
    endpoints = { generations = "/images/generations", edits = "/images/edits" },
    request = { max_n = 15, image_field = "image", mask_field = "mask" },
  },
}
require("maxa.provider_config").configure({
  xuanjing = {
    base_url = "https://gateway.example.invalid/v1", api_key = "test-api-key", proxy = true,
    genai = { image = vim.tbl_extend("force", { adapter = "xuanjing_openai" }, vim.deepcopy(declaration.image)) },
  },
  missing_key = {
    base_url = "https://gateway.example.invalid/v1",
    genai = { image = vim.tbl_extend("force", { adapter = "missing_key_openai" }, vim.deepcopy(declaration.image)) },
  },
})

vim.env.MAXA_GENAI_ENV_FILE = vim.fn.tempname()
require("maxa.adapters.proxy").configure("http://127.0.0.1:10808")
require("maxa.config").configure_early({
  presets = { default = { adapter = "xuanjing_openai" } },
  genai = { default_adapters = { image = "xuanjing_openai", tts = "xuanjing_openai", video = "xuanjing_openai" } },
})
local config = require("maxa.mcphub.native_servers.genai.config")
local image = require("maxa.mcphub.native_servers.genai.image")
local driver = require("maxa.mcphub.native_servers.genai.image.providers.openai_compatible")
local image_generate = require("maxa.mcphub.native_servers.genai.tools.image_generate")
local genai = require("maxa.mcphub.native_servers.genai")

local temp_dir = vim.fn.tempname()

local function make_res()
  return {
    text_value = nil,
    error_value = nil,
    sent = false,
    text = function(self, value)
      self.text_value = value
      return self
    end,
    send = function(self)
      self.sent = true
      return self.text_value
    end,
    error = function(self, value)
      self.error_value = value
      self.sent = true
      return value
    end,
  }
end

test("should expose image_generate schema with required prompt", function()
  assert_equal("image_generate", image_generate.name)
  assert_true(image_generate.inputSchema.properties.prompt ~= nil, "prompt schema should exist")
  assert_true(image_generate.inputSchema.properties.preset ~= nil, "preset schema should exist")
  assert_nil(image_generate.inputSchema.properties.adapter, "legacy adapter must not be advertised")
  assert_nil(image_generate.inputSchema.properties.provider, "provider schema should be absent")
  assert_true(image_generate.inputSchema.properties.background ~= nil, "background schema should exist")
  assert_true(image_generate.inputSchema.properties.text_model ~= nil, "text_model schema should exist")
  assert_true(image_generate.inputSchema.properties.requested_size ~= nil, "requested_size schema should exist")
  assert_nil(image_generate.inputSchema.properties.size, "legacy size schema should be absent")
  assert_nil(image_generate.inputSchema.properties.aspect, "legacy aspect schema should be absent")
  assert_nil(image_generate.inputSchema.properties.ratio, "legacy ratio schema should be absent")
  assert_equal("prompt", image_generate.inputSchema.required[1])
end)

test("should register image_generate in genai tools", function()
  local found = false
  for _, tool in ipairs(genai.capabilities.tools) do
    if tool.name == "image_generate" then
      found = true
      break
    end
  end
  assert_true(found, "image_generate should be registered")
end)

test("should merge extra fields into generation JSON body", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.generate(provider, {
    prompt = "a tiny robot",
    output_dir = temp_dir,
    background = "transparent",
    extra = {
      moderation = "low",
    },
  })

  assert_true(request, err)
  assert_equal("a tiny robot", request.body.prompt)
  assert_equal("transparent", request.body.background)
  assert_equal("low", request.body.moderation)
  assert_equal(true, request.body.stream)
  assert_nil(request.body.response_format)
  assert_equal(true, request.stream)
  assert_match("/images/generations$", request.endpoint)
  assert_equal("function", type(request.proxy))
  assert_equal("http://127.0.0.1:10808", request.proxy())
end)


test("should not override explicit response_format for generation", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.generate(provider, {
    prompt = "a tiny robot",
    output_dir = temp_dir,
    response_format = "url",
  })

  assert_true(request, err)
  assert_equal("url", request.body.response_format)
end)

test("should not override extra response_format for generation", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.generate(provider, {
    prompt = "a tiny robot",
    output_dir = temp_dir,
    extra = {
      response_format = "url",
    },
  })

  assert_true(request, err)
  assert_equal("url", request.body.response_format)
end)

test("should default compatible generation to streaming", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.generate(provider, {
    prompt = "a tiny robot",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal(true, request.body.stream)
  assert_nil(request.body.response_format)
  assert_equal(true, request.stream)
end)

test("should allow a compatible adapter to opt out of streaming", function()
  local provider = assert(image.get_adapter())
  provider.force_stream = false
  local request, err = driver.generate(provider, {
    prompt = "a tiny robot",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_nil(request.body.stream)
  assert_nil(request.stream)
end)

test("should use compatible max_n=15 and reject larger counts", function()
  local provider = assert(image.get_adapter())
  assert_equal(15, provider.max_n)
  local request, err = driver.generate(provider, { prompt = "many", n = 15, output_dir = temp_dir })
  assert_true(request, err)
  assert_equal(15, request.body.n)
  request, err = driver.generate(provider, { prompt = "too many", n = 16, output_dir = temp_dir })
  assert_nil(request)
  assert_match("1%.%.15", err)
end)

test("should accept data images results direct and compatible envelopes", function()
  local b64 = { b64_json = "abc" }
  assert_equal(b64, driver._extract_response_items({ data = { b64 } })[1])
  assert_equal(b64, driver._extract_response_items({ images = { b64 } })[1])
  assert_equal(b64, driver._extract_response_items({ results = { b64 } })[1])
  assert_equal(b64, driver._extract_response_items(b64)[1])
  assert_equal(b64, driver._extract_response_items({ code = 0, data = { images = { b64 } } })[1])
  assert_equal(b64, driver._extract_response_items({ code = 0, data = b64 })[1])
  local items, err = driver._extract_response_items({ code = 503, msg = "busy" })
  assert_nil(items)
  assert_equal("busy", err)
end)

test("should extract JSON body from LF separated curl headers", function()
  local status, body = driver._extract_http_response(table.concat({
    "HTTP/2 200",
    "server: ESA",
    "content-type: application/json",
    "",
    '{"created":1,"data":[]}',
    "__HTTP_STATUS__200",
  }, "\n"))

  assert_equal(200, status)
  assert_equal('{"created":1,"data":[]}', body)
end)

test("should parse JSON body even when proxy headers are not separated by blank line", function()
  local decoded, err = driver._parse_response_body(table.concat({
    "HTTP/2 200",
    "server: ESA",
    "content-type: application/json",
    "via: ens-cache24.cn6020[24357,0]",
    "x-proxied-path: /v1/images/generations",
    '{"created":1,"data":[{"b64_json":"ZmFrZQ=="}]}',
  }, "\n"), false)

  assert_true(decoded, err)
  assert_equal("ZmFrZQ==", decoded.data[1].b64_json)
end)

test("should decode SSE image response", function()
  local decoded, err = driver._decode_sse_response(table.concat({
    'data: {"type":"progress","message":"starting"}',
    "",
    'data: {"data":[{"b64_json":"ZmFrZQ=="}]}',
    "",
    'data: {"response":{"body":{"data":[{"url":"https://example.test/image.png"}]}}}',
    "",
    "data: [DONE]",
    "",
  }, "\n"))

  assert_true(decoded, err)
  assert_equal("ZmFrZQ==", decoded.data[1].b64_json)
  assert_equal("https://example.test/image.png", decoded.data[2].url)
end)

test("should dedupe repeated final generation image across SSE events", function()
  local encoded = vim.base64.encode("same-generated-image")
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

test("should asynchronously finish streamed generation on image SSE data", function()
  local provider = assert(image.get_adapter())
  local original_jobstart = vim.fn.jobstart
  local original_jobstop = vim.fn.jobstop
  local stopped_job

  vim.fn.jobstop = function(job_id)
    stopped_job = job_id
    return 1
  end
  vim.fn.jobstart = function(cmd, opts)
    assert_equal("curl", cmd[1])
    local observed_proxy
    for i, part in ipairs(cmd) do
      if part == "--data-binary" then
        assert_match("^@", cmd[i + 1])
      elseif part == "--proxy" then
        observed_proxy = cmd[i + 1]
      end
    end
    assert_equal("http://127.0.0.1:10808", observed_proxy)

    vim.schedule(function()
      opts.on_stdout(9, {
        'data: {"data":[{"b64_json":"' .. vim.base64.encode("async-png-bytes") .. '"}]}',
        "",
        "",
      })
    end)
    return 9
  end

  local result, err
  driver.generate_image_async(provider, {
    prompt = "async stream",
    output_dir = temp_dir,
    output_format = "png",
    stream = true,
    response_format = "b64_json",
  }, function(callback_result, callback_err)
    result = callback_result
    err = callback_err
  end)

  vim.wait(1000, function()
    return result ~= nil or err ~= nil
  end)

  vim.fn.jobstart = original_jobstart
  vim.fn.jobstop = original_jobstop

  assert_true(result, err)
  assert_equal(1, #result.files)
  assert_equal(#"async-png-bytes", result.files[1].bytes)
  assert_equal(9, stopped_job)
end)

test("should keep provider defaults when optional generation params are absent", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.generate(provider, {
    prompt = "a tiny robot",
    model = vim.NIL,
    requested_size = "",
    quality = vim.NIL,
    output_format = "   ",
    n = vim.NIL,
    output_dir = vim.NIL,
    extra = vim.NIL,
  })

  assert_true(request, err)
  assert_equal("gpt-image-2", request.body.model)
  assert_equal("auto", request.body.size)
  assert_equal("auto", request.params.requested_size)
  assert_nil(request.body.quality)
  assert_equal("png", request.body.output_format)
  assert_nil(request.body.n)
  assert_equal(true, request.body.stream)
  assert_equal(true, request.stream)
  assert_match("genai%-media$", request.params.output_dir)
end)

test("should forward openai_compatible requested_size unchanged", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.generate(provider, {
    prompt = "wide scene",
    output_dir = temp_dir,
    requested_size = "3840x2160",
  })

  assert_true(request, err)
  assert_equal("3840x2160", request.body.size)
  assert_equal("3840x2160", request.params.requested_size)
end)

test("should reject openai_compatible legacy size controls and extra requested_size", function()
  local provider = assert(image.get_adapter())
  for _, field in ipairs({ "size", "aspect", "ratio" }) do
    local request, err = driver.generate(provider, {
      prompt = "legacy field",
      output_dir = temp_dir,
      [field] = "1:1",
    })
    assert_nil(request)
    assert_match(field, err)
  end

  for _, field in ipairs({ "size", "aspect", "ratio", "requested_size" }) do
    local request, err = driver.generate(provider, {
      prompt = "legacy extra field",
      output_dir = temp_dir,
      extra = { [field] = "1:1" },
    })
    assert_nil(request)
    assert_match("extra%." .. field, err)
  end
end)

test("should reject openai_compatible unsupported shared params", function()
  local provider = assert(image.get_adapter())
  local request, err = driver.generate(provider, {
    prompt = "bad text model",
    output_dir = temp_dir,
    text_model = "gpt-5.6-sol",
  })

  assert_nil(request)
  assert_match("text_model", err)

  request, err = driver.generate(provider, {
    prompt = "bad requested size",
    output_dir = temp_dir,
    requested_size = "wide",
  })

  assert_nil(request)
  assert_match("requested_size", err)
end)

test("should save b64_json response without returning base64", function()
  local provider = assert(image.get_adapter())
  local request = assert(driver.generate(provider, {
    prompt = "a tiny pixel",
    output_dir = temp_dir,
    output_format = "png",
    filename_prefix = "unit test image",
  }))

  local result, err = driver.save_image_response(request, {
    body = {
      data = {
        { b64_json = vim.base64.encode("fake-png-bytes") },
      },
    },
  })

  assert_true(result, err)
  assert_equal("xuanjing_openai", result.provider)
  assert_equal(1, #result.files)
  assert_match("unit_test_image", result.files[1].path)
  assert_equal(#"fake-png-bytes", result.files[1].bytes)
  assert_equal("auto", result.requested_size)
  assert_equal("unverified", result.size_check)
  assert_equal("unverified", result.files[1].size_check)
  assert_true(#result.warnings > 0, "metadata warning should be present")
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "output file should exist")
  local content = table.concat(vim.fn.readfile(result.files[1].path, "b"), "\n")
  assert_equal("fake-png-bytes", content)
end)

test("should download and return url entries when response has url", function()
  local provider = assert(image.get_adapter())
  local request = assert(driver.generate(provider, {
    prompt = "url only",
    output_dir = temp_dir,
    output_format = "png",
  }))

  local original_system = vim.system
  vim.system = function(cmd)
    local output_path
    for i, part in ipairs(cmd) do
      if part == "-o" then
        output_path = cmd[i + 1]
        break
      end
    end
    assert_true(output_path ~= nil, "curl output path should be provided")
    vim.fn.writefile({ "downloaded-url-image" }, output_path, "b")
    return {
      wait = function()
        return { code = 0, stdout = "", stderr = "" }
      end,
    }
  end

  local result, err = driver.save_image_response(request, {
    body = {
      data = {
        { url = "https://example.test/image.png" },
      },
    },
  })
  vim.system = original_system

  assert_true(result, err)
  assert_equal("json", result.response_mode)
  assert_equal(1, #result.files)
  assert_equal("https://example.test/image.png", result.urls[1])
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "downloaded output file should exist")
end)

test("should asynchronously download url response without blocking save path", function()
  local provider = assert(image.get_adapter())
  local request = assert(driver.generate(provider, {
    prompt = "async url",
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
      vim.fn.writefile({ "async-downloaded-url-image" }, output_path, "b")
      opts.on_exit(11, 0)
    end)
    return 11
  end

  local result, err
  driver.save_image_response_async(request, {
    response_mode = "json",
    body = {
      data = {
        { url = "https://example.test/image.png" },
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
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "downloaded output file should exist")
end)

test("should reject response without image data", function()
  local provider = assert(image.get_adapter())
  local request = assert(driver.generate(provider, {
    prompt = "empty",
    output_dir = temp_dir,
  }))

  local result, err = driver.save_image_response(request, { body = { data = {} } })
  assert_nil(result)
  assert_match("no image data", err)
end)

test("should return clear error when api key is missing", function()
  local adapter, err = image.get_adapter("missing_key_openai")
  assert_nil(adapter)
  assert_match("API key is missing", err)
end)

test("handler should return clear error for missing prompt", function()
  local res = make_res()
  image_generate.handler({ params = {} }, res)
  assert_match("prompt", res.error_value)
end)

test("handler should reject legacy size controls before provider dispatch", function()
  for _, field in ipairs({ "size", "aspect", "ratio" }) do
    local res = make_res()
    image_generate.handler({ params = { prompt = "cat", [field] = "1:1" } }, res)
    assert_match(field, res.error_value)
  end
end)

test("handler should return clear error for unknown adapter", function()
  local res = make_res()
  image_generate.handler({ params = { prompt = "cat", adapter = "missing_provider" } }, res)
  assert_match("does not provide image capability", res.error_value)
end)


print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
