-- filepath: lua/maxa/session/tools/compact_range_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/tools/compact_range_test.lua

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

local function assert_true(value, msg)
  if not value then
    error(msg or "expected true, got false")
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local compact_range = require("maxa.session.tools.compact_range")
local compact_utils = require("maxa.session.slash_commands.compact_utils")
local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local mcp_config = require("maxa.mcphub.native_servers.config")
local session_trace = require("maxa.session.session_trace")
local validate_ranges = compact_range._test.validate_ranges
local generate_summary_sync = compact_range._test.generate_summary_sync

local original_get_history_dir = history_core.get_history_dir
local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")
history_core.get_history_dir = function()
  local history_dir = tmp_root .. "/.maxa/history"
  vim.fn.mkdir(history_dir .. "/chats", "p")
  return history_dir
end

local function fake_response()
  local response = { text_value = nil, error_value = nil }
  function response:text(value)
    self.text_value = value
    return self
  end
  function response:error(value)
    self.error_value = value
    return self
  end
  function response:send()
    return self
  end
  return response
end

print("\n=== Testing compact_range.validate_ranges ===\n")

test("summary generation should apply global reasoning effort to adapter settings", function()
  local streaming_llm = require("maxa.mcphub.native_servers.shared.streaming_llm")
  local original_create = streaming_llm.create_streaming_adapter
  local original_request = streaming_llm.streaming_request_sync
  local captured = {}
  local adapter = {
    schema = {
      ["reasoning.effort"] = { default = "xhigh", mapping = "parameters" },
    },
    parameters = {},
  }
  function adapter:make_from_schema()
    return { ["reasoning.effort"] = "xhigh" }
  end
  function adapter:map_schema_to_params(settings)
    captured.settings = vim.deepcopy(settings)
    self.parameters.reasoning = { effort = settings["reasoning.effort"] }
    return self
  end

  streaming_llm.create_streaming_adapter = function(adapter_name, model_name, temperature)
    captured.adapter_name = adapter_name
    captured.model_name = model_name
    captured.temperature = temperature
    return adapter, nil
  end
  streaming_llm.streaming_request_sync = function(resolved_adapter)
    captured.parameters = vim.deepcopy(resolved_adapter.parameters)
    return "summary", nil
  end

  local ok, summary, err = pcall(generate_summary_sync, "summary-adapter", "prompt", "summary-model", 0.5, "none", nil)
  streaming_llm.create_streaming_adapter = original_create
  streaming_llm.streaming_request_sync = original_request

  assert_true(ok, summary)
  assert_equal(nil, err)
  assert_equal("summary", summary)
  assert_equal("none", captured.settings["reasoning.effort"], "summary reasoning effort")
  assert_equal("none", captured.parameters.reasoning.effort, "mapped summary reasoning effort")
end)

test("should reorder ranges into ascending order", function()
  local normalized, err, adjustments = validate_ranges({
    { start_index = 10, end_index = 12, action = "summarize" },
    { start_index = 2, end_index = 5, action = "delete" },
  }, 20)

  assert_true(err == nil, "should not return error")
  assert_equal(2, normalized[1].start_index)
  assert_equal(10, normalized[2].start_index)
  assert_true(#adjustments >= 1, "should record reorder adjustment")
end)

test("should merge overlapping summarize ranges", function()
  local normalized, err = validate_ranges({
    { start_index = 5, end_index = 10, action = "summarize" },
    { start_index = 8, end_index = 12, action = "summarize" },
  }, 20)

  assert_true(err == nil, "should not return error")
  assert_equal(1, #normalized)
  assert_equal(5, normalized[1].start_index)
  assert_equal(12, normalized[1].end_index)
end)

test("should return structured retryable error for conflicting overlap", function()
  local normalized, err = validate_ranges({
    { start_index = 5, end_index = 10, action = "delete" },
    { start_index = 8, end_index = 12, action = "summarize" },
  }, 20)

  assert_true(normalized == nil, "normalized should be nil")
  assert_true(type(err) == "table", "error should be structured payload")
  assert_equal(compact_utils.COMPACT_RANGE_ERROR_TYPES.RANGE_OVERLAP_AFTER_NORMALIZATION, err.error_type)
  assert_true(err.retryable == true, "overlap after normalization should be retryable")
  assert_true(type(err.suggested_ranges) == "table" and #err.suggested_ranges >= 1, "should include suggested_ranges")
end)

test("should merge summarize ranges after tool-pair safety expansion", function()
  local messages = {
    { role = "user", content = "a" },
    {
      role = "assistant",
      tools = {
        calls = {
          {
            id = "call_1",
            ["function"] = { name = "demo", arguments = "{}" },
          },
        },
      },
    },
    { role = "tool", content = "ok", tools = { call_id = "call_1" } },
    { role = "user", content = "b" },
    { role = "user", content = "c" },
    { role = "user", content = "d" },
  }

  local normalized, err, adjustments = validate_ranges({
    { start_index = 1, end_index = 2, action = "summarize" },
    { start_index = 3, end_index = 6, action = "summarize" },
  }, #messages, messages)

  assert_true(err == nil, "should not return error")
  assert_equal(1, #normalized)
  assert_equal(1, normalized[1].start_index)
  assert_equal(6, normalized[1].end_index)
  assert_true(#adjustments >= 1, "should record safety expansion or merge adjustments")
end)

test("handler archives tracked delete ranges before apply and records applied event", function()
  session_trace.ensure_manifest("compact_archive_root", {})
  local source = {
    source_type = "saved",
    save_id = "compact_source",
    messages = {
      { role = "user", content = "delete prompt" },
      { role = "assistant", content = "delete reply" },
      { role = "tool", content = "tool output", tools = { call_id = "call-1" } },
      { role = "user", content = "kept prompt" },
    },
    chat_data = { save_id = "compact_source", _meta = {} },
  }
  session_trace.set_membership(
    source.chat_data,
    session_trace.create_root_membership("compact_archive_root", { span_id = "span_compact_archive" })
  )

  local original_get_source = history_session.get_messages_source
  local original_apply = history_session.apply_compression_result
  local original_get_runtime_adapter = mcp_config.get_runtime_adapter
  history_session.get_messages_source = function(save_id)
    assert_equal("compact_source", save_id, "save_id")
    return source, nil
  end
  history_session.apply_compression_result = function(params)
    local events = session_trace.read_events("compact_archive_root")
    assert_equal(1, #events, "archive event exists before apply")
    assert_equal("compression.archive_created", events[1].kind, "archive event kind")
    assert_equal(2, events[1].archive.turn_count, "archive turn count")
    assert_equal("compact_source", events[1].source.save_id, "archive source save")
    assert_equal(2, #params.messages, "delete range plus trailing input message applied")
    return { action = "overwrite", save_id = "compact_source" }, nil
  end
  mcp_config.get_runtime_adapter = function()
    return { adapter = "test-adapter", model = "test-model" }, nil
  end

  local res = fake_response()
  compact_range.handler({ params = { save_id = "compact_source", mode = "overwrite", ranges = {
    { start_index = 1, end_index = 3, action = "delete" },
  } } }, res)

  history_session.get_messages_source = original_get_source
  history_session.apply_compression_result = original_apply
  mcp_config.get_runtime_adapter = original_get_runtime_adapter

  assert_true(not res.error_value, res.error_value)
  local events = session_trace.read_events("compact_archive_root")
  assert_equal(2, #events, "archive plus applied")
  assert_equal("compression.applied", events[2].kind, "applied event kind")
  assert_equal("compact_source", events[2].compression.source_save_id, "applied old save")
end)

history_core.get_history_dir = original_get_history_dir
vim.fn.delete(tmp_root, "rf")

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
