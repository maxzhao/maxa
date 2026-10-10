-- Run: nvim --headless -u NONE -l lua/maxa/adapters/http/openai_responses_extensions/deepseek_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary) == 1 then vim.opt.runtimepath:append(plenary) end
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local standard = require("maxa.adapters.http.openai_responses")
local deepseek = require("maxa.adapters.http.openai_responses_extensions.deepseek")
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
local function factory()
  return vim.deepcopy(standard)
end

print("\n=== DeepSeek Responses extension conformance ===\n")

test("extend requires and returns a function and base factory runs once per adapter", function()
  local ok = pcall(deepseek.extend, {})
  eq(false, ok)
  local calls = 0
  local decorated = deepseek.extend(function()
    calls = calls + 1
    return factory()
  end)
  eq("function", type(decorated))
  decorated()
  eq(1, calls)
end)

test("request removes unsupported fields but preserves supported sampling and reasoning effort", function()
  local adapter = deepseek.extend(factory)()
  local params = {
    store = false,
    previous_response_id = "resp",
    metadata = { source = "chat" },
    include = { "reasoning.encrypted_content" },
    background = true,
    stream_options = { include_usage = true },
    prompt_cache_key = "cache",
    reasoning = { effort = "high", summary = "auto" },
    text = { verbosity = "low", format = { type = "text" } },
    temperature = 0.2,
    top_p = 0.9,
    top_logprobs = 3,
    max_output_tokens = 100,
    tool_choice = "auto",
  }
  local result = adapter.handlers.request.build_parameters(adapter, params, {})
  eq(nil, result.store)
  eq(nil, adapter.parameters.store)
  eq(nil, result.previous_response_id)
  eq(nil, result.metadata)
  eq(nil, result.include)
  eq(nil, result.background)
  eq(nil, result.stream_options)
  eq(nil, result.prompt_cache_key)
  eq(nil, result.reasoning.summary)
  eq("high", result.reasoning.effort)
  eq(nil, result.text.verbosity)
  eq("text", result.text.format.type)
  eq(0.2, result.temperature)
  eq(0.9, result.top_p)
  eq(3, result.top_logprobs)
  eq(100, result.max_output_tokens)
end)

test("tools are copied, non-strict, and omit adapter builtins", function()
  local adapter = deepseek.extend(factory)()
  adapter.opts.tools = true
  local source = {
    demo = {
      type = "function",
      ["function"] = {
        name = "demo",
        description = "demo",
        parameters = { type = "object", properties = { optional = { type = "string", default = "x" } } },
      },
    },
    web_search = { name = "web_search", _meta = { adapter_tool = true } },
  }
  local original = vim.deepcopy(source)
  local tools = adapter.handlers.request.build_tools(adapter, { source }).tools
  eq(original, source, "source mutated")
  eq(1, #tools)
  eq("demo", tools[1].name)
  eq(nil, tools[1].strict)
  eq(nil, tools[1].parameters.required)
  eq("x", tools[1].parameters.properties.optional.default)
  eq(nil, adapter.schema["reasoning.summary"])
  eq(nil, adapter.schema.verbosity)
  eq(nil, adapter.available_tools.web_search)

  local flat = {
    type = "function",
    name = "flat",
    description = "flat",
    parameters = { type = "object", properties = { value = { type = "string" } } },
    strict = true,
  }
  local flat_original = vim.deepcopy(flat)
  local flat_result = adapter.handlers.request.build_tools(adapter, { { flat = flat } }).tools[1]
  eq(flat_original, flat, "flat source mutated")
  eq("flat", flat_result.name)
  eq(nil, flat_result.strict)
  eq(nil, flat_result.parameters.required)
end)

test("plaintext reasoning history is converted without mutating messages", function()
  local adapter = deepseek.extend(factory)()
  adapter.opts.vision = true
  local messages = {
    { role = "user", content = "question" },
    {
      role = "assistant",
      reasoning = { content = "thinking", encrypted_content = "must-not-send" },
      tools = { calls = { { id = "fc_1", call_id = "call_1", ["function"] = { name = "demo", arguments = "{}" } } } },
    },
    { role = "tool", tools = { id = "fc_1", call_id = "call_1" }, content = "result" },
  }
  local original = vim.deepcopy(messages)
  local result = adapter.handlers.request.build_messages(adapter, messages)
  eq(original, messages, "history mutated")
  eq("reasoning", result.input[2].type)
  eq("reasoning_text", result.input[2].content[1].type)
  eq("thinking", result.input[2].content[1].text)
  eq(nil, result.input[2].summary)
  eq(nil, result.input[2].encrypted_content)
end)

test("reasoning deltas render once and accompany tool-only continuation", function()
  local adapter = deepseek.extend(factory)()
  adapter.opts.stream = true
  adapter.roles = { llm = "assistant", tool = "tool" }
  local tools = {}
  adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.created","response":{"id":"resp_d"}}', tools)
  local first = adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.reasoning_text.delta","delta":"think"}', tools)
  eq("think", first.output.reasoning.content)
  local done = adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.reasoning_text.done","text":"thinking"}', tools)
  eq(nil, done)
  local item = adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.output_item.done","item":{"type":"reasoning","content":[{"type":"reasoning_text","text":"thinking"}]}}', tools)
  eq(nil, item)
  local tool_result = adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.output_item.done","item":{"type":"function_call","status":"completed","id":"fc_d","call_id":"call_d","name":"demo","arguments":"{}"}}', tools)
  eq(nil, tool_result.output.reasoning.content)
  eq("thinking", tool_result.output.reasoning._complete_content)
  eq(1, #tools)
  eq("fc_d", tools[1].id)
  eq("call_d", tools[1].call_id)

  local accumulated = {
    first.output.reasoning,
    tool_result.output.reasoning,
  }
  local stored = adapter.handlers.request.build_reasoning(adapter, accumulated)
  eq("thinking", stored.content)
  local messages = {
    { role = "user", content = "question" },
    { role = "assistant", reasoning = stored, tools = { calls = tools } },
    { role = "tool", tools = { id = "fc_d", call_id = "call_d" }, content = "result" },
  }
  local replay = adapter.handlers.request.build_messages(adapter, messages)
  local reasoning_items = {}
  for _, replay_item in ipairs(replay.input) do
    if replay_item.type == "reasoning" then reasoning_items[#reasoning_items + 1] = replay_item end
  end
  eq(1, #reasoning_items)
  eq("thinking", reasoning_items[1].content[1].text)
end)

test("full reasoning event emits once without deltas and state clears on terminal and exit", function()
  local adapter = deepseek.extend(factory)()
  adapter.opts.stream = true
  adapter.roles = { llm = "assistant", tool = "tool" }
  local tools = {}
  local first = adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.reasoning_text.done","text":"whole"}', tools)
  eq("whole", first.output.reasoning.content)
  eq(nil, adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.output_item.done","item":{"type":"reasoning","content":[{"type":"reasoning_text","text":"whole"}]}}', tools))
  adapter._maxa_stream_chat_bufnr = 42
  adapter._maxa_stream_chat_id = "chat_deepseek"
  adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.completed","response":{"status":"completed","output":[]}}', tools)
  eq(nil, adapter.temp.deepseek_responses.reasoning_text)
  eq(nil, adapter._maxa_stream_chat_bufnr)
  eq(nil, adapter._maxa_stream_chat_id)
  adapter.temp.deepseek_responses.reasoning_text = "stale"
  adapter.handlers.lifecycle.on_exit(adapter)
  eq(nil, adapter.temp.deepseek_responses.reasoning_text)
end)

test("terminal-only reasoning and completed tool persist exactly once", function()
  local adapter = deepseek.extend(factory)()
  adapter.opts.stream = true
  adapter.roles = { llm = "assistant", tool = "tool" }
  local tools, accumulated = {}, {}
  local terminal = adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.completed","response":{"id":"resp_terminal","status":"completed","output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"terminal thinking"}]},{"type":"function_call","status":"completed","id":"fc_terminal","call_id":"call_terminal","name":"demo","arguments":"{}"}]}}', tools)
  eq("terminal thinking", terminal.output.reasoning.content)
  accumulated[#accumulated + 1] = terminal.output.reasoning
  eq(1, #tools)
  local stored = adapter.handlers.request.build_reasoning(adapter, accumulated)
  eq("terminal thinking", stored.content)
  local replay = adapter.handlers.request.build_messages(adapter, {
    { role = "user", content = "question" },
    { role = "assistant", reasoning = stored, tools = { calls = tools } },
    { role = "tool", tools = { id = "fc_terminal", call_id = "call_terminal" }, content = "result" },
  })
  local count, text = 0, nil
  for _, replay_item in ipairs(replay.input) do
    if replay_item.type == "reasoning" then
      count = count + 1
      text = replay_item.content[1].text
    end
  end
  eq(1, count)
  eq("terminal thinking", text)
end)

test("non-streamed plaintext reasoning replaces standard summary interpretation", function()
  local adapter = deepseek.extend(factory)()
  adapter.opts.stream = false
  adapter.roles = { llm = "assistant", tool = "tool" }
  local result = adapter.handlers.response.parse_chat(adapter, vim.json.encode({
    object = "response",
    id = "resp_nonstream",
    status = "completed",
    output = {
      { type = "reasoning", content = { { type = "reasoning_text", text = "plain" } } },
      { type = "message", content = { { type = "output_text", text = "answer" } } },
    },
  }), {})
  eq("plain", result.output.reasoning.content)
  eq("answer", result.output.content)
end)

test("incomplete tool events are preserved for validation without executable parser output", function()
  local adapter = deepseek.extend(factory)()
  adapter.opts.stream = true
  adapter.roles = { llm = "assistant", tool = "tool" }
  local tools = {}
  adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.reasoning_text.delta","delta":"thinking"}', tools)
  local result = adapter.handlers.response.parse_chat(adapter, 'data: {"type":"response.output_item.done","item":{"type":"function_call","status":"incomplete","id":"fc_bad","call_id":"call_bad","name":"demo","arguments":"{}"}}', tools)
  eq(nil, result)
  eq(1, #tools)
  eq("incomplete", tools[1]._status)
end)

test("parallel decorated adapters keep plaintext reasoning isolated", function()
  local left, right = deepseek.extend(factory)(), deepseek.extend(factory)()
  left.opts.stream, right.opts.stream = true, true
  left.roles, right.roles = { llm = "assistant" }, { llm = "assistant" }
  left.handlers.response.parse_chat(left, 'data: {"type":"response.reasoning_text.delta","delta":"left"}', {})
  right.handlers.response.parse_chat(right, 'data: {"type":"response.reasoning_text.delta","delta":"right"}', {})
  eq("left", left.temp.deepseek_responses.reasoning_text)
  eq("right", right.temp.deepseek_responses.reasoning_text)
end)

if failed > 0 then error(string.format("%d test(s) failed", failed)) end
print(string.format("\n%d tests passed\n", passed))
