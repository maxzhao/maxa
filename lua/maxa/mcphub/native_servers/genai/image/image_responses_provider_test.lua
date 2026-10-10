-- filepath: lua/maxa/mcphub/native_servers/genai/image/image_responses_provider_test.lua
-- 单元测试: Responses image_generation provider driver
-- 运行方式: nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_responses_provider_test.lua

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

local function arg_value(args, flag)
  for i, value in ipairs(args) do
    if value == flag then
      return args[i + 1]
    end
  end
  return nil
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

print("\n=== Testing genai Responses image provider ===\n")

local env = require("maxa.utils.env")
local TEST_KEY = env.get("GENAI_TEST_API_KEY") or "test-api-key"

local provider_config = require("maxa.provider_config")
local default_declaration = {
  image = {
    mode = "codex",
    defaults = { model = "gpt-image-2", text_model = "gpt-5.5", requested_size = "auto", output_format = "png" },
    endpoints = { responses = "/responses" },
    request = { stream = true, max_n = 15, image_field = "image", mask_field = "mask" },
  },
}
local definitions = {
  xuanjing = {
    base_url = "https://gateway.example.invalid/v1", api_key = TEST_KEY,
    genai = { image = vim.tbl_extend("force", { adapter = "xuanjing_openai" }, vim.deepcopy(default_declaration.image)) },
  },
}
provider_config.configure(definitions)

vim.env.MAXA_GENAI_ENV_FILE = vim.fn.tempname()
require("maxa.config").configure_early({
  presets = { default = { adapter = "xuanjing_openai" } },
  genai = { default_adapters = { image = "xuanjing_openai", tts = "xuanjing_openai", video = "xuanjing_openai" } },
})
local config = require("maxa.mcphub.native_servers.genai.config")
local image = require("maxa.mcphub.native_servers.genai.image")
local driver = require("maxa.mcphub.native_servers.genai.image.providers.openai_responses_image_generation")
local utils = require("maxa.mcphub.native_servers.genai.image.utils")

local temp_dir = vim.fn.tempname()
vim.fn.mkdir(temp_dir, "p")
local image_a = temp_dir .. "/input-a.png"
local image_b = temp_dir .. "/input-b.jpg"
local image_empty = temp_dir .. "/empty.webp"
vim.fn.writefile({ "fake-image-a" }, image_a, "b")
vim.fn.writefile({ "fake-image-b" }, image_b, "b")
vim.fn.writefile({}, image_empty, "b")

local function json_has_key(tbl, key)
  return type(tbl) == "table" and tbl[key] ~= nil
end

local function make_json_response(body)
  return {
    status = 200,
    body = body,
    response_mode = "json",
  }
end

local function make_sse_response(body)
  return {
    status = 200,
    body = body,
    response_mode = "sse_or_json",
  }
end

local function fake_provider()
  return assert(image.get_adapter())
end

local function expected_api_key_for_provider(provider)
  if provider.adapter == "simplaj_openai" then
    return env.get("GENAI_TEST_IMAGE_API_KEY") or "test-image-api-key"
  end
  return TEST_KEY
end

local function add_resolve_adapter_fixture(opts)
  local declaration = vim.deepcopy(default_declaration.image)
  declaration.api_key = opts.image_api_key
  definitions[opts.name] = {
    base_url = opts.base_url, api_key = opts.api_key,
    genai = { image = vim.tbl_extend("force", { adapter = opts.name }, declaration) },
  }
  provider_config.configure(definitions)
  return assert(image.get_adapter(opts.name))
end

test("should resolve default provider", function()
  local provider, err = image.get_adapter()
  assert_true(provider, err)
  assert_equal("openai_responses_image_generation", provider.driver)
  assert_equal(config.default_adapters.image, provider.name)
  assert_nil(provider.base_url)
  assert_equal(TEST_KEY, provider.api_key)
  assert_nil(provider.defaults.stream)
  assert_equal(true, provider.force_stream)
end)

test("should prefer image api key when available", function()
  local provider = add_resolve_adapter_fixture({
    name = "test_image_key_openai",
    base_url = "https://gateway.example.invalid/v1",
    api_key = "text-key",
    image_api_key = "image-key",
  })
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("image-key", request.api_key)
end)

test("should fall back to api key when image api key is missing", function()
  local provider = add_resolve_adapter_fixture({
    name = "test_text_only_openai",
    base_url = "https://gateway.example.invalid/v1",
    api_key = "text-key",
  })
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("text-key", request.api_key)
end)

test("should build generation request for Responses image_generation", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("POST", request.method)
  assert_equal("application/json", request.content_type)
  assert_equal("https://gateway.example.invalid/v1/responses", request.endpoint)
  assert_equal(expected_api_key_for_provider(provider), request.api_key)
  assert_equal("gpt-5.5", request.body.model)
  assert_equal(true, request.body.stream)
  assert_equal(false, request.body.store)
  assert_equal("none", request.body.reasoning.effort)
  assert_equal("a small robot", request.body.input[1].content[1].text)
  assert_match("image_generation VERBATIM", request.body.instructions)
  assert_equal("input_text", request.body.input[1].content[1].type)
  assert_equal("image_generation", request.body.tools[1].type)
  assert_equal("gpt-image-2", request.body.tools[1].model)
  assert_equal("generate", request.body.tools[1].action)
  assert_equal("auto", request.body.tools[1].size)
  assert_equal("auto", request.body.tools[1].quality)
  assert_equal(1, request.body.tools[1].partial_images)
  assert_equal("png", request.body.tools[1].output_format)
  assert_equal("low", request.body.tools[1].moderation)
  assert_nil(request.body.tools[1].output_compression)
  assert_equal("image_generation", request.body.tool_choice.type)
end)

test("should separate text model, tool model, and requested size", function()
  local provider = fake_provider()
  local prompt = "16:9 wide robot"
  local request, err = driver.generate(provider, {
    prompt = prompt,
    text_model = "gpt-5.6-sol",
    model = "gpt-image-2",
    requested_size = "3840x2160",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("gpt-5.6-sol", request.body.model)
  assert_equal("gpt-image-2", request.body.tools[1].model)
  assert_equal("3840x2160", request.body.tools[1].size)
  assert_equal(0, request.body.tools[1].partial_images)
  assert_equal(prompt, request.body.input[1].content[1].text)
  assert_true(not request.body.instructions:match("16:9"), "instructions must not contain an aspect requirement")
  assert_match("Use 3840x2160 as the requested image size", request.body.instructions)
  assert_match("Pass this value to the tool unchanged", request.body.instructions)
  assert_true(not request.body.instructions:match("requested_size"), "instructions must not expose the MCP parameter name")
end)

test("should reject invalid requested size and legacy size controls", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "invalid-size robot",
    requested_size = "wide",
    output_dir = temp_dir,
  })
  assert_nil(request)
  assert_match("requested_size", err)

  for _, field in ipairs({ "size", "aspect", "ratio" }) do
    request, err = driver.generate(provider, {
      prompt = "legacy control",
      output_dir = temp_dir,
      [field] = "1:1",
    })
    assert_nil(request)
    assert_match(field, err)
  end
end)

test("should reject legacy and duplicate size controls under extra", function()
  local provider = fake_provider()
  for _, field in ipairs({ "size", "aspect", "ratio", "requested_size" }) do
    local request, err = driver.generate(provider, {
      prompt = "legacy extra control",
      output_dir = temp_dir,
      extra = { [field] = "1:1" },
    })
    assert_nil(request)
    assert_match("extra%." .. field, err)
  end
end)

test("should classify retryable and fatal Responses errors", function()
  assert_true(driver._is_retryable_error("HTTP request failed with status 502: Bad Gateway"))
  assert_true(driver._is_retryable_error("curl exit 56: Recv failure: Connection reset by peer"))
  assert_true(driver._is_fatal_error("HTTP request failed with status 401: invalid api key"))
  assert_true(not driver._is_fatal_error("HTTP request failed with status 502: Bad Gateway"))
end)

test("should reject transparent background for default Responses provider", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a small robot logo",
    output_dir = temp_dir,
    background = "transparent",
  })

  assert_nil(request)
  assert_match("background=transparent", err)
end)

test("should keep Responses stream connection alive every 30 seconds", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a long running image",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  local args = driver._build_json_curl_args("/tmp/request-body.json", request)
  assert_equal("30", arg_value(args, "--keepalive-time"))
  assert_equal("900", arg_value(args, "--max-time"))
end)

test("should allow overriding Responses keepalive and timeout", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a long running image",
    output_dir = temp_dir,
    keepalive_interval = 45,
    timeout = 1200,
  })

  assert_true(request, err)
  local args = driver._build_json_curl_args("/tmp/request-body.json", request)
  assert_equal("45", arg_value(args, "--keepalive-time"))
  assert_equal("1200", arg_value(args, "--max-time"))
end)

test("should reject generation when n is passed", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    n = 2,
    output_dir = temp_dir,
  })

  assert_nil(request)
  assert_match("omit n", err)
end)

test("should reject misleading Responses image parameters", function()
  local provider = fake_provider()

  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    text_model = "gpt-image-2",
    output_dir = temp_dir,
  })
  assert_nil(request)
  assert_match("text_model", err)

  request, err = driver.generate(provider, {
    prompt = "a small robot",
    quality = "high",
    output_dir = temp_dir,
  })
  assert_nil(request)
  assert_match("quality to auto", err)

  request, err = driver.generate(provider, {
    prompt = "a small robot",
    response_format = "b64_json",
    output_dir = temp_dir,
  })
  assert_nil(request)
  assert_match("do not pass response_format", err)
end)

test("should build edit request with input_image data URL", function()
  local provider = fake_provider()
  local request, err = driver.edit(provider, {
    prompt = "make this sky a sunset",
    image_paths = { image_a, image_b },
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("POST", request.method)
  assert_equal("application/json", request.content_type)
  assert_equal("https://gateway.example.invalid/v1/responses", request.endpoint)
  assert_equal(expected_api_key_for_provider(provider), request.api_key)
  assert_equal("gpt-5.5", request.body.model)
  assert_equal("gpt-image-2", request.body.tools[1].model)
  assert_equal("auto", request.body.tools[1].quality)
  assert_equal(3, #request.body.input[1].content)
  assert_equal("input_text", request.body.input[1].content[1].type)
  assert_equal("input_image", request.body.input[1].content[2].type)
  assert_equal("input_image", request.body.input[1].content[3].type)
  assert_match("^data:image/png;base64,", request.body.input[1].content[2].image_url)
  assert_equal("original", request.body.input[1].content[2].detail)
  assert_equal("image_generation", request.body.tools[1].type)
  assert_equal("low", request.body.tools[1].moderation)
  assert_equal("image_generation", request.body.tool_choice.type)
end)

test("should allow explicit edit input_image detail override", function()
  local provider = fake_provider()
  local request, err = driver.edit(provider, {
    prompt = "inspect the screenshot",
    image_paths = { image_a },
    detail = "high",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("high", request.body.input[1].content[2].detail)

  request, err = driver.edit(provider, {
    prompt = "rough reference only",
    image_paths = { image_a },
    extra = { detail = "low" },
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("low", request.body.input[1].content[2].detail)
end)

test("should reject moderation overrides for Responses provider", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
    moderation = "auto",
  })

  assert_nil(request)
  assert_match("fixes image_generation moderation", err)

  request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
    extra = {
      moderation = "auto",
    },
  })

  assert_nil(request)
  assert_match("fixes image_generation moderation", err)
end)

test("should allow disabling prompt rewrite guard without changing the prompt", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
    prompt_rewrite_guard = false,
  })

  assert_true(request, err)
  assert_equal("a small robot", request.body.input[1].content[1].text)
  assert_true(request.body.instructions ~= nil)
  assert_true(not request.body.instructions:match("DO NOT rewrite"))
  assert_match("Use auto as the requested image size", request.body.instructions)
  assert_true(not request.body.instructions:match("requested_size"), "instructions must not expose the MCP parameter name")
end)

test("should reject overriding fixed tool_choice through extra", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
    extra = {
      tool_choice = "auto",
    },
  })

  assert_nil(request)
  assert_match("tool_choice", err)
end)

test("should build default edit requests like codex-proxy edit mode example", function()
  local provider = fake_provider()
  local request, err = driver.edit(provider, {
    prompt = "repair this image",
    image_paths = { image_a },
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("edit", request.body.tools[1].action)
  assert_equal("image_generation", request.body.tool_choice.type)
  assert_equal("image_generation", request.body.tools[1].type)
end)

test("should include the requested image size in edit instructions without exposing MCP fields", function()
  local provider = fake_provider()
  local request, err = driver.edit(provider, {
    prompt = "make this image taller",
    image_paths = { image_a },
    requested_size = "1024x1536",
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_match("Use 1024x1536 as the requested image size", request.body.instructions)
  assert_match("Pass this value to the tool unchanged", request.body.instructions)
  assert_true(not request.body.instructions:match("requested_size"), "instructions must not expose the MCP parameter name")
end)

test("should build edit request with input_image_mask data URL", function()
  local mask_path = temp_dir .. "/mask.png"
  vim.fn.writefile({ "fake-mask" }, mask_path, "b")
  local provider = fake_provider()
  local request, err = driver.edit(provider, {
    prompt = "edit this",
    image_paths = { image_a },
    mask_path = mask_path,
    output_dir = temp_dir,
  })

  assert_true(request, err)
  assert_equal("edit", request.body.tools[1].action)
  assert_true(type(request.body.tools[1].input_image_mask) == "table", "input_image_mask should be present")
  assert_match("^data:image/png;base64,", request.body.tools[1].input_image_mask.image_url)
  assert_equal(mask_path, request.params.mask_path)
end)

test("should reject png with non-100 output_compression", function()
  local provider = fake_provider()
  local request, err = driver.generate(provider, {
    prompt = "a small robot",
    output_dir = temp_dir,
    output_format = "png",
    output_compression = 80,
  })

  assert_nil(request)
  assert_match("PNG output", err)
end)

test("should parse image_generation_call result from SSE and save file", function()
  local provider = fake_provider()
  local request = assert(driver.generate(provider, {
    prompt = "async image",
    output_dir = temp_dir,
    output_format = "png",
    filename_prefix = "responses test",
    stream = true,
  }))

  local response = make_sse_response(table.concat({
    'data: {"type":"response.output_item.added","item":{"type":"image_generation_call"}}',
    "",
    'data: {"type":"response.output_item.done","item":{"type":"image_generation_call","result":"' .. vim.base64.encode(
      "fake-response-image"
    ) .. '","revised_prompt":"revised prompt"}}',
    "",
    "data: [DONE]",
    "",
  }, "\n"))

  local result, err = driver.save_image_response(request, response)
  assert_true(result, err)
  assert_equal("revised prompt", result.revised_prompt)
  assert_equal(1, #result.files)
  assert_equal("auto", result.requested_size)
  assert_equal("unverified", result.size_check)
  assert_equal("unverified", result.files[1].size_check)
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "output file should exist")
end)

test("should ignore streaming partial image payloads and save only final result", function()
  local provider = fake_provider()
  local partial = vim.base64.encode("partial-preview-image")
  local final = vim.base64.encode("final-response-image")
  local request = assert(driver.generate(provider, {
    prompt = "async image with partial preview",
    output_dir = temp_dir,
    output_format = "png",
    filename_prefix = "responses partial test",
    stream = true,
  }))

  local response = make_sse_response(table.concat({
    'data: {"type":"response.image_generation_call.partial_image","partial_image_index":0,"b64_json":"'
      .. partial
      .. '"}',
    "",
    'data: {"type":"response.output_item.done","item":{"type":"image_generation_call","result":"'
      .. final
      .. '","revised_prompt":"final prompt"}}',
    "",
    "data: [DONE]",
    "",
  }, "\n"))

  local result, err = driver.save_image_response(request, response)
  assert_true(result, err)
  assert_equal(1, result.count)
  assert_equal(1, #result.files)
  assert_equal("final-response-image", table.concat(vim.fn.readfile(result.files[1].path, "b"), "\n"))
end)

test("should dedupe duplicate image_generation_call results from SSE", function()
  local provider = fake_provider()
  local encoded = vim.base64.encode("same-response-image")
  local request = assert(driver.generate(provider, {
    prompt = "async image duplicate",
    output_dir = temp_dir,
    output_format = "png",
    filename_prefix = "responses duplicate test",
    stream = true,
  }))

  local response = make_sse_response(table.concat({
    'data: {"type":"response.output_item.done","item":{"type":"image_generation_call","result":"'
      .. encoded
      .. '","revised_prompt":"revised prompt"}}',
    "",
    'data: {"type":"response.completed","response":{"output":[{"type":"image_generation_call","result":"'
      .. encoded
      .. '","revised_prompt":"revised prompt"}]}}',
    "",
    "data: [DONE]",
    "",
  }, "\n"))

  local result, err = driver.save_image_response(request, response)
  assert_true(result, err)
  assert_equal(1, result.count)
  assert_equal(1, #result.files)
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "output file should exist")
end)

test("should dedupe duplicate image_generation_call results from SSE for edit", function()
  local provider = fake_provider()
  local encoded = vim.base64.encode("same-edit-response-image")
  local request = assert(driver.edit(provider, {
    prompt = "async edit duplicate",
    image_paths = { image_a },
    output_dir = temp_dir,
    output_format = "png",
    filename_prefix = "responses edit duplicate test",
    stream = true,
  }))

  local response = make_sse_response(table.concat({
    'data: {"type":"response.output_item.done","item":{"type":"image_generation_call","result":"'
      .. encoded
      .. '","revised_prompt":"revised prompt"}}',
    "",
    'data: {"type":"response.completed","response":{"output":[{"type":"image_generation_call","result":"'
      .. encoded
      .. '","revised_prompt":"revised prompt"}]}}',
    "",
    "data: [DONE]",
    "",
  }, "\n"))

  local result, err = driver.save_image_response(request, response)
  assert_true(result, err)
  assert_equal(1, result.count)
  assert_equal(1, #result.files)
  assert_true(vim.fn.filereadable(result.files[1].path) == 1, "output file should exist")
end)

test("should parse image_generation_call result from JSON and keep tool usage", function()
  local provider = fake_provider()
  local request = assert(driver.generate(provider, {
    prompt = "sync image",
    output_dir = temp_dir,
    output_format = "jpeg",
  }))

  local result, err = driver.save_image_response(
    request,
    make_json_response({
      output = {
        {
          type = "image_generation_call",
          result = vim.base64.encode("fake-response-image-json"),
          revised_prompt = "json revised",
        },
      },
      tool_usage = {
        image_gen = {
          input_tokens = 12,
          output_tokens = 34,
          total_tokens = 46,
        },
      },
    })
  )

  assert_true(result, err)
  assert_equal("json revised", result.revised_prompt)
  assert_true(json_has_key(result, "tool_usage"), "tool_usage should be preserved")
  assert_equal(1, #result.files)
end)

test("should parse object-shaped image_generation_call result aliases", function()
  local provider = fake_provider()
  local aliases = {
    { key = "b64_json", bytes = "object-b64-json-image" },
    { key = "base64", bytes = "object-base64-image" },
    { key = "image", bytes = "object-image-field" },
    { key = "data", bytes = "object-data-field" },
  }

  for _, alias in ipairs(aliases) do
    local request = assert(driver.generate(provider, {
      prompt = "sync object image " .. alias.key,
      output_dir = temp_dir,
      output_format = "png",
      filename_prefix = "responses object " .. alias.key,
    }))
    local result_object = {}
    result_object[alias.key] = vim.base64.encode(alias.bytes)

    local result, err = driver.save_image_response(
      request,
      make_json_response({
        output = {
          {
            type = "image_generation_call",
            result = result_object,
            revised_prompt = "object revised " .. alias.key,
          },
        },
      })
    )

    assert_true(result, err)
    assert_equal("object revised " .. alias.key, result.revised_prompt)
    assert_equal(1, #result.files)
    assert_equal(alias.bytes, table.concat(vim.fn.readfile(result.files[1].path, "b"), "\n"))
  end
end)

test("should surface SSE image_generation error before JSON fallback", function()
  local decoded, err = driver._parse_response_body(
    table.concat({
      "event: response.output_item.added",
      'data: {"type":"response.output_item.added","item":{"type":"image_generation_call","status":"in_progress"}}',
      "",
      "event: error",
      'data: {"type":"error","error":{"type":"image_generation_user_error","code":"moderation_blocked","message":"blocked by safety","param":null}}',
      "",
    }, "\n"),
    true
  )

  assert_nil(decoded)
  assert_match("blocked by safety", err)
end)

test("should reject empty image_generation response", function()
  local provider = fake_provider()
  local request = assert(driver.generate(provider, {
    prompt = "empty",
    output_dir = temp_dir,
  }))

  local result, err = driver.save_image_response(request, make_json_response({ output = {} }))
  assert_nil(result)
  assert_match("no image result", err)
end)

test("should encode local file to data url", function()
  local data_url, err = utils.file_to_data_url(image_a)
  assert_true(data_url, err)
  assert_match("^data:image/png;base64,", data_url)
  local encoded = data_url:match("^data:image/png;base64,(.+)$")
  assert_equal("fake-image-a", vim.base64.decode(encoded))
end)

test("should preserve binary bytes when encoding data url", function()
  local binary_path = temp_dir .. "/binary.png"
  local original = "\137PNG\r\n\26\n\0\1\2\255"
  local file = assert(io.open(binary_path, "wb"))
  file:write(original)
  file:close()

  local data_url, err = utils.file_to_data_url(binary_path)
  assert_true(data_url, err)
  local encoded = data_url:match("^data:image/png;base64,(.+)$")
  assert_equal(original, vim.base64.decode(encoded))
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
