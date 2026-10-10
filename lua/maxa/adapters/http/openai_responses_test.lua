-- Run: nvim --headless -u NONE -l lua/maxa/adapters/http/openai_responses_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary) == 1 then vim.opt.runtimepath:append(plenary) end
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local adapter = require("maxa.adapters.http.openai_responses")
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
  assert(vim.deep_equal(expected, actual), string.format("%s\nexpected=%s\nactual=%s", message or "mismatch", vim.inspect(expected), vim.inspect(actual)))
end
local function contains(value, expected)
  assert(type(value) == "string" and value:find(expected, 1, true), string.format("expected %s in %s", expected, vim.inspect(value)))
end
local function instance(stream)
  return {
    opts = { stream = stream ~= false, tools = true, vision = true },
    roles = { llm = "assistant", user = "user", tool = "tool" },
    available_tools = adapter.available_tools,
    temp = {},
  }
end
local function function_schema(name, parameters)
  return {
    type = "function",
    ["function"] = { name = name, description = name, parameters = parameters },
  }
end

print("\n=== OpenAI Responses adapter conformance ===\n")

test("setup uses the selected model opts for stream, vision, and tools", function()
  local self = vim.deepcopy(adapter)
  self.schema.model.default = "non_stream"
  self.schema.model.choices.non_stream = {
    opts = { stream = false, has_vision = false, has_function_calling = false },
  }
  adapter.handlers.lifecycle.setup(self)
  eq(false, self.opts.stream)
  eq(false, self.parameters.stream)
  eq(false, self.opts.vision)
  eq(false, self.opts.tools)
end)

test("parse_error and parse_chat share terminal error decoding", function()
  local self = instance(true)
  local raw = 'event: error\ndata: {"type":"response.failed","response":{"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"too long","param":"input"}}}'
  local classification = adapter.handlers.response.parse_error(self, raw)
  contains(classification, "context_length_exceeded")
  contains(classification, "invalid_request_error")
  contains(classification, "too long")
  local result = adapter.handlers.response.parse_chat(self, raw, {})
  eq("error", result.status)
  eq("context_length_exceeded", result.output.error.code)
  eq(nil, adapter.handlers.response.parse_error(self, 'data: {"type":"response.output_text.delta","delta":"x"}'))
  eq(nil, adapter.handlers.response.parse_error(self, "data: [DONE]"))

  local top_level = 'data: {"type":"error","code":"context_length_exceeded","message":"top level too long","param":"input"}'
  local top_level_classification = adapter.handlers.response.parse_error(self, top_level)
  contains(top_level_classification, "context_length_exceeded")
  contains(top_level_classification, "top level too long")
  local top_level_result = adapter.handlers.response.parse_chat(self, top_level, {})
  eq("context_length_exceeded", top_level_result.output.error.code)
  eq("top level too long", top_level_result.output.error.message)
  eq("input", top_level_result.output.error.param)

  for _, fixture in ipairs({
    {
      object = "response",
      status = "incomplete",
      incomplete_details = { reason = "max_output_tokens" },
      output = {},
      expected = "max_output_tokens",
    },
    {
      object = "response",
      status = "failed",
      error = { type = "server_error", code = "server_error", message = "failed body" },
      output = {},
      expected = "server_error",
    },
  }) do
    self.opts.stream = false
    self.temp.openai_responses = { response_id = "stale" }
    self._maxa_stream_chat_bufnr = 42
    local body_error = adapter.handlers.response.parse_chat(self, vim.json.encode(fixture), {})
    eq("error", body_error.status)
    eq(fixture.expected, body_error.output.error.code)
    eq(nil, self.temp.openai_responses.response_id)
    eq(nil, self._maxa_stream_chat_bufnr)
  end

  self.opts.stream = false
  local invalid_body = adapter.handlers.response.parse_chat(self, vim.json.encode({ type = "response", status = "completed", output = {} }), {})
  eq("error", invalid_body.status)
  eq("invalid_response", invalid_body.output.error.code)
end)

test("incomplete function calls are preserved for Chat-owned validation", function()
  local self = instance(false)
  local tools = {}
  local result = adapter.handlers.response.parse_chat(self, vim.json.encode({
    object = "response",
    status = "incomplete",
    id = "resp_partial",
    incomplete_details = { reason = "max_output_tokens" },
    output = {
      {
        type = "function_call",
        status = "in_progress",
        id = "fc_partial",
        call_id = "call_partial",
        name = "write",
        arguments = [[{"path":"a","content":"unfinished]],
      },
    },
  }), tools)
  eq("success", result.status)
  eq(1, #tools)
  eq("fc_partial", tools[1].id)
  eq("call_partial", tools[1].call_id)
  eq([[{"path":"a","content":"unfinished]], tools[1]["function"].arguments)

  tools = {}
  result = adapter.handlers.response.parse_chat(self, vim.json.encode({
    object = "response",
    status = "incomplete",
    id = "resp_missing_identity",
    incomplete_details = { reason = "max_output_tokens" },
    output = {
      { type = "function_call", status = "in_progress", arguments = "{" },
    },
  }), tools)
  eq("success", result.status)
  eq(1, #tools)
  eq(nil, tools[1].id)
  eq(nil, tools[1].call_id)
  eq(nil, tools[1]["function"].name)
end)

test("streamed partial arguments survive response.incomplete", function()
  local self = instance(true)
  local tools = {}
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.created","response":{"id":"resp_stream"}}', tools)
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_stream","call_id":"call_stream","name":"write"}}', tools)
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_stream","call_id":"call_stream","delta":"{\\\"path\\\":\\\"a\\\""}', tools)
  local result = adapter.handlers.response.parse_chat(self, 'data: {"type":"response.incomplete","response":{"id":"resp_stream","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}', tools)
  eq("success", result.status)
  eq(1, #tools)
  eq('{"path":"a"', tools[1]["function"].arguments)
end)

test("all function schemas are non-strict and preserve source optional constraints", function()
  local source = function_schema("demo", { type = "object", properties = {
    optional = { type = { "string", "null" }, default = "a", enum = { "a", "b", vim.NIL } },
    required = { type = "integer", minimum = 1 },
    nested = { type = "array", items = { type = "object", properties = { value = { type = "boolean" } } } },
    choice = { oneOf = { { type = "string" }, { type = "integer" } } },
  }, required = { "required" } })
  local original = vim.deepcopy(source)
  local result = adapter.handlers.request.build_tools(instance(true), { { demo = source } }).tools[1]
  eq(original, source)
  eq(false, result.strict)
  eq(source["function"].parameters, result.parameters)
  eq({ "required" }, result.parameters.required)
  eq(nil, result.parameters.additionalProperties)
  eq(nil, result.parameters.properties.nested.items.required)
end)

test("fire encoded data boundary remains while arbitrary source objects are preserved", function()
  local schemas = {
    fire = function_schema("fire", { type = "object", properties = { event = { type = "string" }, data = { additionalProperties = true } }, required = { "event" } }),
    arbitrary = function_schema("arbitrary", { type = "object", properties = { data = { type = "object", additionalProperties = true } } }),
  }
  local original = vim.deepcopy(schemas)
  local by_name = {}
  for _, tool in ipairs(adapter.handlers.request.build_tools(instance(true), { schemas }).tools) do by_name[tool.name] = tool end
  eq(original, schemas)
  eq({ "string", "null" }, by_name.fire.parameters.properties.data.type)
  eq(true, by_name.arbitrary.parameters.properties.data.additionalProperties)
  eq(false, by_name.fire.strict)
end)

test("run requires title/command and label-free members only require command", function()
  local inventory = require("maxa.interactions.chat.tools.builtin")
  local schemas = {}
  for _, name in ipairs(inventory.names) do schemas[name] = function_schema(name, inventory.resolve(name).inputSchema) end
  local original = vim.deepcopy(schemas)
  local by_name = {}
  for _, tool in ipairs(adapter.handlers.request.build_tools(instance(true), { schemas }).tools) do
    eq(false, tool.strict)
    by_name[tool.name] = tool
  end
  eq(original, schemas)
  eq({ "title", "command" }, by_name.run.parameters.required)
  eq({ "command" }, by_name.multicall.parameters.properties.runs.items.required)
  eq(nil, by_name.multicall.parameters.properties.runs.items.properties.label)
  eq({ "string", "null" }, by_name.multicall.parameters.properties.runs.items.properties.title.type)
  eq(nil, by_name.run.parameters.properties.json_patches)
end)

test("malformed function envelopes fail locally", function()
  local ok = pcall(adapter.handlers.request.build_tools, instance(true), { { bad = { type = "function", name = "", parameters = {} } } })
  eq(false, ok)
  ok = pcall(adapter.handlers.request.build_tools, instance(true), { { bad = { type = "function", name = "bad", parameters = "invalid" } } })
  eq(false, ok)
end)

test("message serialization preserves id and call_id and never mutates history", function()
  local messages = {
    { role = "system", content = "rules" },
    {
      role = "assistant",
      reasoning = { id = "rs_123", content = "summary", encrypted_content = "opaque" },
      tools = { calls = { { id = "fc_123", call_id = "call_456", ["function"] = { name = "demo", arguments = "{}" } } } },
    },
    {
      role = "tool",
      tools = { id = "fc_123", call_id = "call_456" },
      content = "result",
      _meta = { image = { base64 = "aW1hZ2U=", mimetype = "image/png", detail = "high" } },
    },
    { role = "user", content = "continue" },
  }
  local original = vim.deepcopy(messages)
  local result = adapter.handlers.request.build_messages(instance(true), messages)
  eq(original, messages, "history mutated")
  eq("rules", result.instructions)
  eq("rs_123", result.input[1].id)
  eq("fc_123", result.input[2].id)
  eq("call_456", result.input[2].call_id)
  eq("call_456", result.input[3].call_id)
  eq("string", type(result.input[3].output))
  eq("input_image", result.input[4].content[2].type)
  eq("high", result.input[4].content[2].detail)
end)

test("dependency catalogs replay inline without sending locally generated item IDs", function()
  local abilities = require("maxa.session.abilities")
  local call_id = "call_ability_dependency_test"
  local item_id = "fc_ability_dependency_test"
  local call, result = abilities.synthetic_catalog_pair({
    name = "task-admin", digest = "test", catalog = "ability: task-admin",
  }, call_id, item_id)
  local messages = { call, result }
  local original = vim.deepcopy(messages)
  local request = adapter.handlers.request.build_messages(instance(true), messages)
  eq(original, messages, "history mutated")
  eq(2, #request.input)
  eq("function_call", request.input[1].type)
  eq(nil, request.input[1].id, "local catalog ID must not request provider lookup")
  eq(call_id, request.input[1].call_id)
  eq("load", request.input[1].name)
  eq({ target = "task-admin" }, vim.json.decode(request.input[1].arguments))
  eq("function_call_output", request.input[2].type)
  eq(call_id, request.input[2].call_id)
  eq("ability: task-admin", request.input[2].output)
end)

test("internal dependency provenance is omitted from request replay", function()
  local messages = {
    {
      role = "assistant",
      content = "",
      tools = { calls = { { id = "auto-mcp-subagent-1", ["function"] = { name = "load_server", arguments = "{}" } } } },
      _meta = { tag = "auto_skill_dependency_call" },
    },
    {
      role = "tool",
      content = "loaded",
      tools = { call_id = "auto-mcp-subagent-1" },
      _meta = { tag = "auto_skill_dependency_result" },
    },
    { role = "user", content = "dependency context" },
  }
  local original = vim.deepcopy(messages)
  local result = adapter.handlers.request.build_messages(instance(true), messages)
  eq(original, messages, "history mutated")
  eq(1, #result.input)
  eq("dependency context", result.input[1].content)
end)

test("missing call_id fails locally", function()
  local ok, err = pcall(adapter.handlers.request.build_messages, instance(true), {
    { role = "assistant", tools = { calls = { { id = "fc_only", ["function"] = { name = "demo", arguments = "{}" } } } } },
  })
  eq(false, ok)
  contains(err, "non-empty call_id")

  ok, err = pcall(adapter.handlers.request.build_messages, instance(true), {
    { role = "assistant", tools = { calls = { { call_id = "call_only", ["function"] = { name = "demo", arguments = "{}" } } } } },
  })
  eq(false, ok)
  contains(err, "non-empty id")

  ok, err = pcall(adapter.handlers.request.build_messages, instance(true), {
    { role = "assistant", tools = { calls = { { id = "fc_name", call_id = "call_name", ["function"] = { arguments = "{}" } } } } },
  })
  eq(false, ok)
  contains(err, "non-empty function name")

  ok, err = pcall(adapter.handlers.request.build_messages, instance(true), {
    { role = "assistant", tools = { calls = { { id = "fc_args", call_id = "call_args", ["function"] = { name = "demo", arguments = {} } } } } },
  })
  eq(false, ok)
  contains(err, "string arguments")
end)

test("non-streamed parsing traverses every item and completes only completed calls", function()
  local self = instance(false)
  local tools = {}
  local response = vim.json.encode({
    object = "response",
    id = "resp_1",
    status = "completed",
    output = {
      { type = "reasoning", id = "r_1", encrypted_content = "opaque", summary = { { type = "summary_text", text = "why" } } },
      { type = "function_call", status = "incomplete", id = "fc_bad", call_id = "call_bad", name = "bad", arguments = "{}" },
      { type = "function_call", id = "fc_missing_status", call_id = "call_missing_status", name = "missing_status", arguments = "{}" },
      { type = "message", content = { { type = "output_text", text = "hello " }, { type = "output_text", text = "world" } } },
      { type = "function_call", status = "completed", id = "fc_good", call_id = "call_good", name = "good", arguments = "{}" },
    },
  })
  self._maxa_stream_chat_bufnr = 42
  self._maxa_stream_chat_id = "chat_nonstream"
  local result = adapter.handlers.response.parse_chat(self, response, tools)
  eq("hello world", result.output.content)
  eq("why", result.output.reasoning.content)
  eq("opaque", result.output.reasoning.encrypted_content)
  eq(1, #tools)
  eq("fc_good", tools[1].id)
  eq("call_good", tools[1].call_id)
  eq(nil, self._maxa_stream_chat_bufnr)
  eq(nil, self._maxa_stream_chat_id)
end)

test("streamed completed tool is deduplicated and keeps reasoning", function()
  local self = instance(true)
  local tools = {}
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.created","response":{"id":"resp_2"}}', tools)
  local reasoning = adapter.handlers.response.parse_chat(self, 'data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"r_2","encrypted_content":"opaque","summary":[{"type":"summary_text","text":"think"}]}}', tools)
  eq("think", reasoning.output.reasoning.content)
  local tool_result = adapter.handlers.response.parse_chat(self, 'data: {"type":"response.output_item.done","item":{"type":"function_call","status":"completed","id":"fc_2","call_id":"call_2","name":"demo","arguments":"{}"}}', tools)
  eq(nil, tool_result.output.reasoning.content)
  eq("think", tool_result.output.reasoning._complete_content)
  eq("opaque", tool_result.output.reasoning.encrypted_content)
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.completed","response":{"id":"resp_2","status":"completed","output":[{"type":"function_call","status":"completed","id":"fc_2","call_id":"call_2","name":"demo","arguments":"{}"}]}}', tools)
  eq(1, #tools)
  eq("fc_2", tools[1].id)
  eq("call_2", tools[1].call_id)
  eq(nil, self.temp.openai_responses.response_id)
end)

test("streamed deltas are not duplicated by terminal full output", function()
  local self = instance(true)
  local tools = {}
  local text = adapter.handlers.response.parse_chat(self, 'data: {"type":"response.output_text.delta","delta":"answer"}', tools)
  local reasoning = adapter.handlers.response.parse_chat(self, 'data: {"type":"response.reasoning_summary_text.delta","delta":"think"}', tools)
  eq("answer", text.output.content)
  eq("think", reasoning.output.reasoning.content)
  local terminal = adapter.handlers.response.parse_chat(self, 'data: {"type":"response.completed","response":{"id":"resp_delta","status":"completed","output":[{"type":"reasoning","id":"r_delta","encrypted_content":"opaque","summary":[{"type":"summary_text","text":"think"}]},{"type":"message","content":[{"type":"output_text","text":"answer"}]}]}}', tools)
  eq("", terminal.output.content)
  eq(nil, terminal.output.reasoning.content)
  eq("think", terminal.output.reasoning._complete_content)
  eq("opaque", terminal.output.reasoning.encrypted_content)
  local stored = adapter.handlers.request.build_reasoning(self, { reasoning.output.reasoning, terminal.output.reasoning })
  eq("think", stored.content)
  eq("opaque", stored.encrypted_content)
end)

test("error terminals clear instance and stream identity state", function()
  local self = instance(true)
  self.temp.openai_responses = { response_id = "stale", reasoning = { content = "stale" } }
  self._maxa_stream_chat_bufnr = 42
  self._maxa_stream_chat_id = "chat_error"
  local result = adapter.handlers.response.parse_chat(self, 'data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"failed"}}}', {})
  eq("error", result.status)
  eq(nil, self.temp.openai_responses.response_id)
  eq(nil, self.temp.openai_responses.reasoning)
  eq(nil, self._maxa_stream_chat_bufnr)
  eq(nil, self._maxa_stream_chat_id)
end)

test("parallel adapter instances keep response state isolated", function()
  local left, right = instance(true), instance(true)
  adapter.handlers.response.parse_chat(left, 'data: {"type":"response.created","response":{"id":"resp_left"}}', {})
  adapter.handlers.response.parse_chat(right, 'data: {"type":"response.created","response":{"id":"resp_right"}}', {})
  local left_delta = adapter.handlers.response.parse_chat(left, 'data: {"type":"response.output_text.delta","delta":"left"}', {})
  local right_delta = adapter.handlers.response.parse_chat(right, 'data: {"type":"response.output_text.delta","delta":"right"}', {})
  eq("resp_left", left_delta.output.meta.response_id)
  eq("resp_right", right_delta.output.meta.response_id)
end)

test("tool argument lifecycle events retain normalized metadata", function()
  local self = instance(true)
  local bufnr = vim.api.nvim_create_buf(false, true)
  self._maxa_stream_chat_bufnr = bufnr
  self._maxa_stream_chat_id = "chat_1"
  local observed = {}
  local group = vim.api.nvim_create_augroup("OpenAIResponsesLifecycleTest", { clear = true })
  for _, event in ipairs({
    "MaxaAIToolCallArgumentsStarted",
    "MaxaAIToolCallArgumentsDelta",
    "MaxaAIToolCallArgumentsDone",
  }) do
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = event,
      callback = function(args) observed[#observed + 1] = { event = args.match, data = args.data } end,
    })
  end
  local tools = {}
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_evt","call_id":"call_evt","name":"demo"}}', tools)
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.function_call_arguments.delta","item_id":"fc_evt","call_id":"call_evt","output_index":2,"delta":"{\\"x\\":"}', tools)
  adapter.handlers.response.parse_chat(self, 'data: {"type":"response.function_call_arguments.done","item_id":"fc_evt","call_id":"call_evt","output_index":2,"arguments":"{\\"x\\":1}"}', tools)
  eq(3, #observed)
  eq("MaxaAIToolCallArgumentsStarted", observed[1].event)
  eq("chat_1", observed[1].data.id)
  eq("call_evt", observed[2].data.call_id)
  eq(5, observed[2].data.delta_length)
  eq(7, observed[3].data.arguments_length)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end)

if failed > 0 then error(string.format("%d test(s) failed", failed)) end
print(string.format("\n%d tests passed\n", passed))
