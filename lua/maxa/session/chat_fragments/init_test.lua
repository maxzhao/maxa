-- filepath: lua/maxa/session/chat_fragments/init_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/chat_fragments/init_test.lua

local history_core = require("maxa.session.history_core")
local session_trace = require("maxa.session.session_trace")
local fragments = require("maxa.session.chat_fragments")
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
    error(msg or "expected true")
  end
end
local function with_temp_history(fn)
  local original_get_history_dir = history_core.get_history_dir
  local root = vim.fn.tempname()
  vim.fn.delete(root, "rf")
  vim.fn.mkdir(root, "p")
  history_core.get_history_dir = function()
    local history_dir = root .. "/.maxa/history"
    vim.fn.mkdir(history_dir .. "/chats", "p")
    return history_dir
  end
  local ok, err = pcall(fn, root)
  history_core.get_history_dir = original_get_history_dir
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

local function temp_root()
  local path = vim.fn.tempname()
  vim.fn.delete(path, "rf")
  vim.fn.mkdir(path, "p")
  return path
end

print("\n=== Testing session chat fragments ===\n")

test("make_fragment_id should produce stable file-safe ids", function()
  local id = fragments.make_fragment_id("My Fragment!", "2026-06-27T12:34:56Z")
  assert_equal("20260627123456-my-fragment", id, "id should include timestamp and slug")
end)

test("write/read/list fragment roundtrip should preserve full messages", function()
  local root = temp_root()
  local chat = {
    bufnr = 12,
    id = "chat-id",
    opts = { title = "Source Chat", save_id = "save-1" },
  }
  local messages = {
    { role = "user", content = "hello", _meta = { index = 1 }, transient = function() end },
    { role = "assistant", content = { content = "world", nested = { tool = true } } },
  }
  local fragment = fragments.build_fragment(chat, messages, {
    id = "test-fragment",
    title = "Test Fragment",
    description = "desc",
    tags = { "a", "b" },
    created_at = "2026-06-27T12:34:56Z",
  })
  local path, err = fragments.write_fragment(fragment, { root = root })
  assert_true(path ~= nil, "write should succeed: " .. tostring(err))

  local loaded, load_err = fragments.read_fragment(path)
  assert_true(loaded ~= nil, "read should succeed: " .. tostring(load_err))
  assert_equal("test-fragment", loaded.id, "id should roundtrip")
  assert_equal("hello", loaded.messages[1].content, "string content should roundtrip")
  assert_equal(nil, loaded.messages[1].transient, "function fields should be removed before JSON save")
  assert_equal("world", loaded.messages[2].content.content, "nested content should roundtrip")

  local listed = fragments.list_fragments({ root = root })
  assert_equal(1, #listed, "one fragment should be listed")
  assert_equal("Test Fragment", listed[1].title, "listed title should come from JSON")

  vim.fn.delete(root, "rf")
end)

test("append_fragment_to_chat should append and refresh metadata", function()
  local chat = {
    messages = {
      { role = "user", content = "existing", _meta = { index = 1 } },
    },
    tools = {},
  }
  local fragment = {
    schema_version = 1,
    id = "frag-1",
    messages = {
      { role = "assistant", content = "copied", id = "old-id", timestamp = "old-time", _meta = { index = 99, keep = true } },
      { role = "tool", content = { result = "ok" } },
    },
  }

  local ok, result = fragments.append_fragment_to_chat(chat, fragment, { skip_save = true })
  assert_true(ok, "append should succeed: " .. tostring(result))
  assert_equal(2, result.appended, "two messages should be appended")
  assert_equal(3, #chat.messages, "chat should contain existing plus appended")
  assert_equal(chat.messages, chat.tools.messages, "tools.messages should point at chat.messages")
  assert_equal(2, chat.messages[2]._meta.index, "first inserted message index should refresh")
  assert_equal(true, chat.messages[2]._meta.keep, "existing meta fields should be preserved")
  assert_equal("frag-1", chat.messages[2]._meta.inserted_from_fragment, "inserted fragment id should be recorded")
  assert_equal("fragment:frag-1:2", chat.messages[2].id, "existing message id should refresh")
  assert_true(chat.messages[2].timestamp ~= "old-time", "existing timestamp should refresh")
  assert_equal(3, chat.messages[3]._meta.index, "missing _meta should be created with new index")
  assert_equal("ok", chat.messages[3].content.result, "nested table content should be preserved")
end)


test("append_fragment_to_chat records trace action without natural turns", function()
  with_temp_history(function()
    session_trace.ensure_manifest("trace_fragment_root", {})
    local chat = {
      opts = { save_id = "tracked_chat" },
      _meta = {},
      messages = {
        { role = "user", content = "existing", _meta = { index = 1 } },
      },
      tools = {},
    }
    session_trace.set_membership(chat, {
      root_trace_id = "trace_fragment_root",
      root_save_id = "trace_fragment_root",
      span_id = "span_fragment",
      session_role = "root",
      active = true,
      started_at = 1,
    })
    local fragment = {
      schema_version = 1,
      id = "frag-trace",
      title = "Trace Fragment",
      _path = "/tmp/frag-trace.json",
      messages = {
        { role = "user", content = "inserted user" },
        { role = "assistant", content = "inserted assistant" },
      },
    }
    local ok, result = fragments.append_fragment_to_chat(chat, fragment, { skip_save = true })
    assert_true(ok, "append should succeed: " .. tostring(result))
    assert_equal(2, result.appended, "two messages should be appended")
    assert_equal(2, result.start_index, "result should report inserted start index")
    assert_equal(3, result.end_index, "result should report inserted end index")
    local events = session_trace.read_events("trace_fragment_root")
    assert_equal(1, #events, "only one action event should be recorded")
    assert_equal("fragment.inserted", events[1].kind, "event kind should be fragment.inserted")
    assert_equal("span_fragment", events[1].span_id, "event should use target span")
    assert_equal("frag-trace", events[1].fragment.id, "event should record fragment id")
    assert_equal(2, events[1].inserted_range.start_index, "event should record start index")
    assert_equal(3, events[1].inserted_range.end_index, "event should record end index")
    assert_equal(2, events[1].appended_count, "event should record appended count")
    assert_equal("frag-trace", chat.messages[2]._meta.inserted_from_fragment, "inserted message metadata should remain tagged")
  end)
end)

test("append_fragment_to_chat should reject busy chats without mutation", function()
  local chat = {
    current_request = true,
    messages = {
      { role = "user", content = "existing" },
    },
  }
  local fragment = {
    schema_version = 1,
    id = "frag",
    messages = {
      { role = "assistant", content = "new" },
    },
  }
  local ok, err = fragments.append_fragment_to_chat(chat, fragment, { skip_save = true })
  assert_equal(false, ok, "busy chat should be rejected")
  assert_true(type(err) == "string" and err:match("in progress"), "error should mention in-progress request")
  assert_equal(1, #chat.messages, "busy chat should not be mutated")
end)

test("validate_fragment should reject malformed fragments", function()
  local ok, err = fragments.validate_fragment({ schema_version = 1, messages = "not-array" })
  assert_equal(false, ok, "invalid messages should fail")
  assert_true(type(err) == "string" and err:match("messages"), "error should mention messages")
end)

print(string.format("\nResults: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
