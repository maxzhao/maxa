-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/analyze_image_spec.lua
-- Focused ordered multi-image schema, preparation, child-message, and result tests.
-- Run: nvim --headless -l lua/maxa/interactions/chat/tools/builtin/tests/analyze_image_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name .. ": " .. tostring(err))
  end
end
local function eq(expected, actual, message)
  assert(expected == actual, message or string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end
local function contains(value, needle)
  assert(type(value) == "string" and value:find(needle, 1, true), tostring(value) .. " lacks " .. needle)
end

local created_opts, installed_opts, submit_count, prepared_calls
local child
local function reset()
  created_opts, installed_opts, submit_count, prepared_calls = nil, nil, 0, {}
  child = {
    id = 222,
    messages = {},
    tools = { messages = {} },
    context_items = {},
    tool_registry = { schemas = {}, in_use = {}, flags = {} },
    submit = function()
      submit_count = submit_count + 1
    end,
  }
end
local function prepared(params, index)
  return {
    payload = { base64 = "BASE64-" .. index, mimetype = "image/png" },
    metadata = {
      path = params.path,
      source_format = "PNG",
      final_format = "PNG",
      mimetype = "image/png",
      original_width = index * 10,
      original_height = index * 5,
      width = params.target_long_edge or index * 10,
      height = index * 5,
      detail = params.detail or "original",
      normalized = false,
      cropped = params.region ~= nil,
      resized = params.target_long_edge ~= nil,
      region = params.region,
      source_mimetype = "internal/hidden",
    },
  }
end
package.loaded["maxa.interactions.chat.tools.builtin.runtime.image_preparation"] = {
  API_MAX_SIZE = 8000,
  validate = function(params)
    if type(params) ~= "table" then
      return nil, "image params must be an object"
    end
    if not params.path or vim.trim(params.path) == "" then
      return nil, "path is required"
    end
    if params.extra then
      return nil, "unknown image parameter: extra"
    end
    return params
  end,
  prepare = function(params)
    prepared_calls[#prepared_calls + 1] = params
    if params.path == "/bad" then
      return nil, "bad image"
    end
    return prepared(params, #prepared_calls)
  end,
}
package.loaded["maxa.interactions.chat.tools.builtin.runtime.image_analysis_controller"] = {
  DEFAULT_TIMEOUT_SECONDS = 300,
  install = function(opts)
    installed_opts = opts
    return { cancel = function() end }
  end,
}
package.loaded["maxa.session.history_core"] = {
  make_unsavable_save_id = function(kind)
    return "unsavable/" .. kind
  end,
}
package.loaded["maxa.mcphub.native_servers.subagent.utils"] = {
  build_non_interactive_defaults = function(opts)
    return opts
  end,
  with_subagent_chat_creation = function(_, fn, opts)
    eq(true, opts.hidden)
    eq(true, opts.restore_last_chat)
    return true, fn()
  end,
  inherit_tool_registry = function(parent, target)
    target.tool_registry = vim.deepcopy(parent.tool_registry)
    return true
  end,
  inherit_context_items = function(parent, target)
    target.context_items = vim.deepcopy(parent.context_items or {})
  end,
  build_sub_agent_render_messages = function(messages)
    local render = vim.deepcopy(messages)
    render[#render + 1] = { role = "assistant", content = "", opts = { visible = false } }
    return render
  end,
  restrict_hidden_image_analysis_tools = function(target)
    for key, schema in pairs(target.tool_registry.schemas or {}) do
      local name = tostring(key):match("<tool>(.-)</tool>") or schema.name
      if name == "analyze"
        or name == "call"
        or name == "multicall"
        or name:match("^subagent__")
      then
        target.tool_registry.schemas[key] = nil
      end
    end
    for name in pairs(target.tool_registry.in_use or {}) do
      if name == "analyze"
        or name == "call"
        or name == "multicall"
        or name:match("^subagent__")
      then
        target.tool_registry.in_use[name] = nil
      end
    end
  end,
}
package.loaded["maxa.mcphub.native_servers.subagent.async_cancel"] = { register_chat = function() end }
package.loaded["maxa.config"] =
  { constants = { SYSTEM_ROLE = "system", USER_ROLE = "user", LLM_ROLE = "assistant" } }
package.loaded["maxa.interactions.chat"] = {
  new = function(opts)
    created_opts = opts
    return child
  end,
}
package.loaded["maxa.interactions.chat.tools.builtin.tools.builtin_analyze"] = nil
local tool = require("maxa.interactions.chat.tools.builtin.tools.builtin_analyze")

local function parent(vision)
  return {
    id = 111,
    bufnr = vim.api.nvim_create_buf(false, true),
    adapter = { type = "http", opts = { vision = vision } },
    settings = { model = "same" },
    cycle = 7,
    context_items = {},
    tool_registry = {
      schemas = { ["<tool>alpha</tool>"] = { name = "alpha" } },
      in_use = { alpha = true },
    },
    messages = {
      { role = "system", content = "prefix" },
      { role = "assistant", tool_calls = { { id = "call-analyze" }, { id = "sibling" } } },
    },
  }
end
local function request(params, chat)
  return {
    params = vim.tbl_extend("keep", params, { title = "Inspect prepared images" }),
    chat = chat,
    tool_call_id = chat and "call-analyze" or nil,
    caller = chat and { maxa_ai = { chat = chat, tool = { function_call = { id = "call-analyze" } } } } or nil,
  }
end
local function response()
  local r = {}
  function r:error(v)
    self.error_message = v
    return self
  end
  function r:text(v, m)
    self.text_value = v
    self.mimetype = m
    return self
  end
  function r:send()
    self.sent = true
    return self
  end
  return r
end

test("schema requires strict nonempty images array and exposes optional five-minute timeout", function()
  eq("images", tool.inputSchema.required[1])
  eq("string", tool.inputSchema.properties.title.type)
  eq(1, tool.inputSchema.properties.title.minLength)
  assert(vim.tbl_contains(tool.inputSchema.required, "title"), "title must be required")
  eq("array", tool.inputSchema.properties.images.type)
  eq(1, tool.inputSchema.properties.images.minItems)
  eq(false, tool.inputSchema.properties.images.items.additionalProperties)
  eq("path", tool.inputSchema.properties.images.items.required[1])
  eq(nil, tool.inputSchema.properties.path)
  eq(nil, tool.inputSchema.properties.detail)
  eq("number", tool.inputSchema.properties.timeout.type)
  eq(300, tool.inputSchema.properties.timeout.default)
  eq(9007199254740990, tool.inputSchema.properties.max_steps.maximum)
  contains(tool.inputSchema.properties.max_steps.description, "one corrective request")
  assert(not vim.tbl_contains(tool.inputSchema.required, "timeout"), "timeout must remain optional")
end)

test("image options are optional and nullable through JSON schema encoding", function()
  local image = vim.json.decode(vim.json.encode(tool.inputSchema)).properties.images.items
  eq(1, #image.required)
  eq("path", image.required[1])
  eq("string", image.properties.path.type)
  for _, name in ipairs({ "detail", "region", "target_long_edge", "resize_mode" }) do
    local property = image.properties[name]
    assert(vim.tbl_contains(property.type, "null"), name .. " must accept null")
    if property.enum then
      assert(vim.tbl_contains(property.enum, vim.NIL), name .. " enum must accept null")
    end
  end
  eq("original", image.properties.detail.default)
  eq("downscale_only", image.properties.resize_mode.default)
  eq(4, #image.properties.region.required)
end)

test("missing null blank and nonstring titles fail before image preparation", function()
  for _, case in ipairs({ {}, { value = vim.NIL }, { value = "" }, { value = " \n\t" }, { value = 7 }, { value = false } }) do
    reset()
    local r = response()
    local req = request({ images = { { path = "/one" } }, analysis_prompt = "analyze", max_steps = 1 }, parent(true))
    req.params.title = case.value
    tool.run(req, r)
    contains(r.error_message, "INVALID_ARGUMENT")
    contains(r.error_message, "title")
    eq(0, #prepared_calls)
    eq(nil, created_opts)
  end
end)

test("timeout defaults to 300 seconds and accepts an explicit override", function()
  for _, case in ipairs({ { input = nil, expected = 300 }, { input = 12.5, expected = 12.5 } }) do
    reset()
    local r = response()
    local params = {
      images = { { path = "/one" } },
      analysis_prompt = "analyze",
      max_steps = 1,
    }
    params.timeout = case.input
    tool.run(request(params, parent(true)), r)
    eq(nil, r.error_message)
    eq(case.expected, installed_opts.timeout)
  end
end)

test("max_steps reserves one safe-integer slot for the corrective request", function()
  reset()
  local r = response()
  tool.run(request({
    images = { { path = "/one" } },
    analysis_prompt = "analyze",
    max_steps = 9007199254740991,
  }, parent(true)), r)
  contains(r.error_message, "INVALID_ARGUMENT")
  contains(r.error_message, "9007199254740990")
  eq(0, #prepared_calls)
end)

test("invalid timeouts fail before image preparation", function()
  for _, timeout in ipairs({ 0, -1, 0 / 0, math.huge, "300" }) do
    reset()
    local r = response()
    tool.run(
      request({
        images = { { path = "/one" } },
        analysis_prompt = "analyze",
        max_steps = 1,
        timeout = timeout,
      }, parent(true)),
      r
    )
    contains(r.error_message, "INVALID_ARGUMENT")
    contains(r.error_message, "timeout")
    eq(0, #prepared_calls)
  end
end)

test("explicit null image options reach preparation as omitted values", function()
  reset()
  local r = response()
  tool.run(
    request({
      images = {
        { path = "/one", detail = vim.NIL, region = vim.NIL, target_long_edge = vim.NIL, resize_mode = vim.NIL },
      },
      analysis_prompt = "analyze",
      max_steps = 1,
    }, parent(true)),
    r
  )
  eq(nil, r.error_message)
  eq(1, #prepared_calls)
  for _, name in ipairs({ "detail", "region", "target_long_edge", "resize_mode" }) do
    eq(nil, prepared_calls[1][name])
  end
  eq(1, submit_count)
end)

test("empty nonarray sparse and old single-image inputs fail before preparation", function()
  for _, params in ipairs({
    { images = {}, analysis_prompt = "x", max_steps = 1 },
    { images = "bad", analysis_prompt = "x", max_steps = 1 },
    { path = "/one", analysis_prompt = "x", max_steps = 1 },
    { images = { [1] = { path = "/one" }, [3] = { path = "/three" } }, analysis_prompt = "x", max_steps = 1 },
  }) do
    reset()
    local r = response()
    tool.run(request(params, parent(true)), r)
    contains(r.error_message, "INVALID_ARGUMENT")
    eq(0, #prepared_calls)
    eq(nil, created_opts)
  end
end)

test("invalid later image is indexed and all validation precedes preparation", function()
  reset()
  local r = response()
  tool.run(
    request(
      { images = { { path = "/one" }, { path = "/two", extra = true } }, analysis_prompt = "x", max_steps = 1 },
      parent(true)
    ),
    r
  )
  contains(r.error_message, "images[2]")
  eq(0, #prepared_calls)
  eq(nil, created_opts)
end)

test("later preparation failure is indexed and prevents child creation", function()
  reset()
  local r = response()
  tool.run(
    request(
      { images = { { path = "/one" }, { path = "/bad" } }, analysis_prompt = "x", max_steps = 1 },
      parent(true)
    ),
    r
  )
  contains(r.error_message, "IMAGE_PREPARATION_FAILED")
  contains(r.error_message, "images[2]")
  eq(2, #prepared_calls)
  eq(nil, created_opts)
end)

test("ordered duplicate paths keep distinct IDs options details and one child", function()
  reset()
  local source = parent(true)
  local region = { x = 0, y = 0, w = 50, h = 100 }
  local r = response()
  tool.run(
    request({
      images = {
        { path = "/same", detail = "low", region = region },
        {
          path = "/same",
          detail = "high",
          target_long_edge = 40,
        },
      },
      analysis_prompt = "compare jointly",
      max_steps = 2,
    }, source),
    r
  )
  eq(1, submit_count)
  eq(2, #prepared_calls)
  eq("user", child.messages[#child.messages].role)
  contains(child.messages[#child.messages].content, "compare jointly")
  eq("assistant", created_opts.messages[#created_opts.messages].role)
  eq("", created_opts.messages[#created_opts.messages].content)
  eq("low", prepared_calls[1].detail)
  eq("high", prepared_calls[2].detail)
  eq("user", child.messages[2].role)
  contains(child.messages[2].content, "[FORK BOUNDARY]")
  eq("BASE64-1", child.messages[3].content)
  eq("BASE64-2", child.messages[4].content)
  eq("<image>temporary-image-analysis-1</image>", child.messages[3].context.id)
  eq("<image>temporary-image-analysis-2</image>", child.messages[4].context.id)
  eq("low", child.messages[3].context.detail)
  eq("high", child.messages[4].context.detail)
  contains(child.messages[5].content, "compare jointly")
  contains(child.messages[5].content, '"image_index":1')
  contains(child.messages[5].content, '"image_index":2')
  eq("Temporary image analysis", created_opts.title)
  assert(not child.messages[5].content:find("Inspect prepared images", 1, true), "display title leaked into analysis task")
end)

test("child requires final text and documents the one-request empty-response reserve", function()
  reset()
  local r = response()
  tool.run(
    request({
      images = { { path = "/one" } },
      analysis_prompt = "analyze",
      max_steps = 1,
    }, parent(true)),
    r
  )
  eq(nil, r.error_message)
  eq(1, submit_count)
  contains(child.messages[2].content, "one nonempty final assistant text response")
  contains(child.messages[2].content, "max_steps + 1")
  assert(not child.messages[2].content:find("report", 1, true), "removed tool instruction remains")
end)

test("missing exact tool-call identity is rejected before preparation", function()
  reset()
  local source = parent(true)
  local r = response()
  local req = request({ images = { { path = "/one" } }, analysis_prompt = "identity", max_steps = 2 }, source)
  req.tool_call_id = nil
  tool.run(req, r)
  contains(r.error_message, "CALLER_REQUIRED")
  contains(r.error_message, "tool-call identity")
  eq(0, #prepared_calls)
  eq(nil, created_opts)
end)

test("direct recursive analyze_image is rejected before preparation", function()
  reset()
  local source = parent(true)
  source._maxa_hidden_image_analysis = true
  local r = response()
  tool.run(
    request({ images = { { path = "/one" } }, analysis_prompt = "recurse", max_steps = 2 }, source),
    r
  )
  contains(r.error_message, "RECURSIVE_ANALYSIS_FORBIDDEN")
  eq(0, #prepared_calls)
  eq(nil, created_opts)
end)

test("hidden child registry removes direct delegation and recursive tools", function()
  reset()
  local source = parent(true)
  for _, name in ipairs({
    "analyze",
    "subagent__ask_llm",
    "subagent__run_agent",
    "subagent__fork_agent",
    "subagent__resume_agent",
    "subagent__multi_agent",
    "call",
    "multicall",
  }) do
    source.tool_registry.schemas["<tool>" .. name .. "</tool>"] = { name = name }
    source.tool_registry.in_use[name] = true
  end
  local r = response()
  tool.run(
    request({ images = { { path = "/one" } }, analysis_prompt = "safe", max_steps = 2 }, source),
    r
  )
  for name in pairs(child.tool_registry.in_use) do
    if name:find("subagent__", 1, true)
      or name == "analyze"
      or name == "call"
      or name == "multicall"
    then
      error("blocked tool remained: " .. name)
    end
  end
end)

test("terminal result exposes exact ordered images metadata array", function()
  reset()
  local r = response()
  tool.run(
    request({
      images = { { path = "/one", detail = "low" }, { path = "/two", detail = "high" } },
      analysis_prompt = "x",
      max_steps = 1,
    }, parent(true)),
    r
  )
  installed_opts.on_terminal("completed", "# finding", 1, 1)
  eq("# finding", r.text_value:match("\n%-%-%-\n(.*)"))
  contains(r.text_value, "1. /one")
  contains(r.text_value, "2. /two")
  contains(r.text_value, "detail: low")
  contains(r.text_value, "detail: high")
  eq(nil, r.text_value:find("steps_used", 1, true))
  eq(nil, r.text_value:find("max_steps", 1, true))
end)

test("timeout terminal state returns a dedicated timeout error", function()
  reset()
  local r = response()
  tool.run(
    request({
      images = { { path = "/one" } },
      analysis_prompt = "x",
      max_steps = 2,
      timeout = 1,
    }, parent(true)),
    r
  )
  installed_opts.on_terminal("timed_out", "image analysis exceeded 1 seconds", 1, 2)
  contains(r.error_message, "TIMEOUT: image analysis exceeded 1 seconds")
  contains(r.error_message, "steps_used=1, max_steps=2")
end)

print(string.format("analyze_image tests: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
