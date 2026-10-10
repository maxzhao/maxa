-- filepath: lua/maxa/session/tools/collapse_tail_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/tools/collapse_tail_test.lua

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
    error(msg or "expected true")
  end
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local collapse_tail = require("maxa.session.tools.collapse_tail")
local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local session_trace = require("maxa.session.session_trace")

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

local function sample_messages()
  return {
    { role = "user", content = "m1 stable" },
    { role = "assistant", content = "m2 stable" },
    { role = "user", content = "m3 collapse start" },
    { role = "tool", content = "m4 tool result", tools = { call_id = "call-1" } },
    { role = "user", content = "m5 image", _meta = { tag = "image" } },
    { role = "user", content = "m6 context", _meta = { tag = "context_file", path = "x.md" } },
  }
end

local function duplicate_ability_messages()
  return {
    {
      role = "assistant",
      content = "",
      tools = {
        calls = {
          {
            id = "old-load",
            ["function"] = {
              name = "load",
              arguments = vim.json.encode({ target = "demo" }),
            },
          },
        },
      },
    },
    { role = "tool", content = "old load ok", tools = { call_id = "old-load" } },
    {
      role = "user",
      content = "old tools",
      context = { id = "ability:revision:demo" },
      _meta = { tag = "ability_revision", ability = { kind = "revision", name = "demo", catalog_call_id = "old-load" } },
    },
    { role = "user", content = "work before collapse" },
    {
      role = "assistant",
      content = "",
      tools = {
        calls = {
          {
            id = "new-load",
            ["function"] = {
              name = "load",
              arguments = vim.json.encode({ target = "demo" }),
            },
          },
        },
      },
    },
    { role = "tool", content = "new load ok", tools = { call_id = "new-load" } },
    {
      role = "user",
      content = "new tools",
      context = { id = "ability:revision:demo" },
      _meta = { tag = "ability_revision", ability = { kind = "revision", name = "demo", catalog_call_id = "new-load" } },
    },
  }
end

print("\n=== Testing collapse_tail ===\n")

test("collapse tail with empty preserve_indices keeps prefix and summary only", function()
  local result, info, err = collapse_tail.build_collapsed_messages(sample_messages(), {
    collapse_start_index = 3,
    preserve_indices = {},
    summary_text = "summary",
  })
  assert_true(not err, err)
  assert_eq(3, #result, "message count")
  assert_eq("m1 stable", result[1].content, "prefix 1")
  assert_eq("m2 stable", result[2].content, "prefix 2")
  assert_eq("assistant", result[3].role, "summary role")
  assert_eq("summary", result[3].content, "summary content")
  assert_eq("collapse_summary", result[3]._meta.tag, "summary tag")
  assert_eq(3, result[3]._meta.collapsed_range.start_index, "range start")
  assert_eq(6, result[3]._meta.collapsed_range.end_index, "range end")
  assert_eq(6, info.total_before, "total before")
  assert_eq(3, info.total_after, "total after")
end)

test("collapse tail preserves selected messages after summary in original order", function()
  local result, _, err = collapse_tail.build_collapsed_messages(sample_messages(), {
    collapse_start_index = 3,
    preserve_indices = { 4, 6 },
    summary_text = "summary",
  })
  assert_true(not err, err)
  assert_eq(5, #result, "message count")
  assert_eq("summary", result[3].content, "summary")
  assert_eq("m4 tool result", result[4].content, "preserved tool")
  assert_eq("m6 context", result[5].content, "preserved context")
  assert_eq(4, result[3]._meta.preserved_indices[1], "preserved index 1")
  assert_eq(6, result[3]._meta.preserved_indices[2], "preserved index 2")
end)

test("collapse tail allows special messages to be collapsed by default", function()
  local result, _, err = collapse_tail.build_collapsed_messages(sample_messages(), {
    collapse_start_index = 4,
    preserve_indices = {},
    summary_text = "summary",
  })
  assert_true(not err, err)
  assert_eq(4, #result, "message count")
  assert_eq("m3 collapse start", result[3].content, "prefix before special range")
  assert_eq("summary", result[4].content, "summary replaces tool/image/context")
end)

test("collapse tail deduplicates repeated Ability context and keeps latest load", function()
  local result, info, err = collapse_tail.build_collapsed_messages(duplicate_ability_messages(), {
    collapse_start_index = 4,
    preserve_indices = { 5, 6, 7 },
    summary_text = "summary",
  })
  assert_true(not err, err)
  assert_eq(4, #result, "deduped message count")
  assert_eq("summary", result[1].content, "summary remains first after old load pair removed")
  assert_eq("new-load", result[2].tools.calls[1].id, "latest load call kept")
  assert_eq("new load ok", result[3].content, "latest load result kept")
  assert_eq("new tools", result[4].content, "latest Ability context kept")
  assert_eq(4, info.total_after, "total after reflects dedup")
end)

test("collapse_start_index must be before last message", function()
  local _, _, err = collapse_tail.build_collapsed_messages(sample_messages(), {
    collapse_start_index = 6,
    preserve_indices = {},
    summary_text = "summary",
  })
  assert_true(err and err:match("< last message index"), "expected invalid start error")
end)

test("preserve_indices must be inside collapse range", function()
  local _, _, err = collapse_tail.build_collapsed_messages(sample_messages(), {
    collapse_start_index = 3,
    preserve_indices = { 2 },
    summary_text = "summary",
  })
  assert_true(err and err:match("out of collapse range"), "expected out of range error")
end)

test("preserve_indices must reject duplicates", function()
  local _, _, err = collapse_tail.build_collapsed_messages(sample_messages(), {
    collapse_start_index = 3,
    preserve_indices = { 4, 4 },
    summary_text = "summary",
  })
  assert_true(err and err:match("duplicate"), "expected duplicate error")
end)

test("preserve_indices must be strictly increasing", function()
  local _, _, err = collapse_tail.build_collapsed_messages(sample_messages(), {
    collapse_start_index = 3,
    preserve_indices = { 6, 4 },
    summary_text = "summary",
  })
  assert_true(err and err:match("strictly increasing"), "expected order error")
end)

test("handler archives tracked collapse tail before saving and records new save id", function()
  session_trace.ensure_manifest("collapse_archive_root", {})
  local source = {
    source_type = "saved",
    save_id = "collapse_source",
    messages = {
      { role = "user", content = "collapse prompt" },
      { role = "assistant", content = "collapse reply" },
      { role = "tool", content = "tool result", tools = { call_id = "call-1" } },
      { role = "user", content = "preserve prompt" },
    },
    chat_data = { save_id = "collapse_source", _meta = {}, adapter = "test-adapter" },
  }
  session_trace.set_membership(
    source.chat_data,
    session_trace.create_root_membership("collapse_archive_root", { span_id = "span_collapse_archive" })
  )

  local original_get_source = history_session.get_messages_source
  local original_save = history_session.save_messages_to_history
  history_session.get_messages_source = function(save_id)
    assert_eq("collapse_source", save_id, "save_id")
    return source, nil
  end
  local saved_new_id = nil
  history_session.save_messages_to_history = function(messages, new_save_id, chat_data)
    local events = session_trace.read_events("collapse_archive_root")
    assert_eq(1, #events, "archive event exists before save")
    assert_eq("compression.archive_created", events[1].kind, "archive event kind")
    assert_eq(4, events[1].range.end_index, "archive end index")
    assert_eq(3, events[1].archive.turn_count, "archive turn count")
    assert_eq("collapse_source", chat_data._meta.session_trace.root_trace_id and events[1].source.save_id, "source save recorded")
    saved_new_id = new_save_id
    assert_eq(2, #messages, "collapsed summary plus preserved message count")
    return true, nil
  end

  local res = fake_response()
  collapse_tail.handler({ params = {
    save_id = "collapse_source",
    collapse_start_index = 1,
    preserve_indices = { 4 },
    summary_text = "summary",
  } }, res)

  history_session.get_messages_source = original_get_source
  history_session.save_messages_to_history = original_save

  assert_true(not res.error_value, res.error_value)
  local decoded = vim.json.decode(res.text_value)
  assert_eq(saved_new_id, decoded.data.new_save_id, "response new save id")
  local events = session_trace.read_events("collapse_archive_root")
  assert_eq(2, #events, "archive plus applied")
  assert_eq("compression.applied", events[2].kind, "applied event kind")
  assert_eq("collapse_source", events[2].compression.original_save_id, "old save recorded")
  assert_eq(saved_new_id, events[2].compression.new_save_id, "new save recorded")
end)

history_core.get_history_dir = original_get_history_dir
vim.fn.delete(tmp_root, "rf")

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
