-- filepath: lua/maxa/session/history_modules_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/history_modules_test.lua

local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local compaction_messages = require("maxa.session.compaction_messages")
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


print("\n=== Testing session history modules ===\n")

test("strip_token_warning_messages should remove only _meta tagged token warnings", function()
  local cleaned = compaction_messages.strip_token_warning_messages({
    {
      role = "user",
      content = "token warning user",
      _meta = { tag = "token_warning", threshold = 90 },
    },
    {
      role = "assistant",
      content = "token warning assistant",
      _meta = { tag = "token_warning", threshold = 90 },
    },
    {
      role = "assistant",
      content = "normal assistant",
    },
    {
      role = "user",
      content = "normal user",
      _meta = { tag = "other_tag" },
    },
  })

  assert_equal(2, #cleaned, "should remove only token_warning messages")
  assert_equal("normal assistant", cleaned[1].content, "should preserve normal assistant message")
  assert_equal("normal user", cleaned[2].content, "should preserve non-token-warning meta message")
end)

test("strip_token_warning_messages should remove legacy ChatSubmitted hook messages", function()
  local cleaned = compaction_messages.strip_token_warning_messages({
    {
      role = "user",
      content = "legacy warning",
      context = {
        skill_hook = {
          path = "/home/user/.config/nvim/skills/session-admin/hooks/ChatSubmitted.lua",
          event = "ChatSubmitted",
        },
      },
    },
    {
      role = "assistant",
      content = "keep me",
      context = {
        skill_hook = {
          path = "/home/user/.config/nvim/skills/other/hooks/ChatSubmitted.lua",
          event = "ChatSubmitted",
        },
      },
    },
  })

  assert_equal(1, #cleaned, "should remove only session-admin ChatSubmitted legacy warning")
  assert_equal("keep me", cleaned[1].content, "normal hook message should remain")
end)

test("strip_runtime_control_messages should remove restart-resume control messages", function()
  local cleaned = compaction_messages.strip_runtime_control_messages({
    {
      role = "user",
      content = "resume",
      _meta = { tag = "nvim_restart_resume" },
    },
    {
      role = "user",
      content = "mcphub resume",
      _meta = { tag = "mcphub_restart_resume" },
    },
    {
      role = "user",
      content = "normal",
    },
  })

  assert_equal(1, #cleaned, "runtime control messages should be stripped")
  assert_equal("normal", cleaned[1].content, "normal user message should remain")
end)

test("save_messages_to_history should strip token warnings and reset token warning metadata", function()
  local captured_chat = nil
  local original_get_history_api = history_session.get_history_api
  history_session.get_history_api = function()
    return {
      save_chat = function(chat_obj)
        captured_chat = chat_obj
      end,
    }
  end

  local ok, err = history_session.save_messages_to_history({
    {
      role = "user",
      content = "warning",
      _meta = { tag = "token_warning", threshold = 75 },
    },
    {
      role = "assistant",
      content = "keep me",
    },
    {
      role = "user",
      content = "resume",
      _meta = { tag = "nvim_restart_resume" },
    },
  }, "new_save", {
    title = "Test",
    _meta = {
      session_admin_token_warning = { max_threshold = 90 },
      keep = "yes",
    },
  }, "test-adapter")

  history_session.get_history_api = original_get_history_api

  assert_true(ok, err or "save_messages_to_history should succeed")
  assert_true(type(captured_chat) == "table", "saved chat should be captured")
  assert_equal(1, #captured_chat.messages, "token warning and runtime control messages should be stripped before save")
  assert_equal("keep me", captured_chat.messages[1].content, "normal message should remain")
  assert_equal(nil, captured_chat._meta.session_admin_token_warning, "token warning state should reset")
  assert_equal("yes", captured_chat._meta.keep, "unrelated metadata should remain")
end)

test("make_unsavable_save_id should create controlled invalid save_id", function()
  local save_id = history_core.make_unsavable_save_id("scratch")

  assert_true(type(save_id) == "string", "save_id should be a string")
  assert_true(save_id:match("/") ~= nil, "save_id should contain slash so history validation rejects it")
  assert_true(history_core.is_unsavable_save_id(save_id), "save_id should be recognized as unsavable")
  assert_true(history_core.is_unsavable_save_id(save_id, "scratch"), "save_id should match its namespace")
  assert_true(not history_core.is_unsavable_save_id(save_id, "rescue"), "save_id should not match another namespace")
end)

test("is_unsavable_save_id should reject arbitrary invalid save_id", function()
  assert_true(not history_core.is_unsavable_save_id("_rescue_/temp"), "legacy arbitrary invalid id is not controlled")
  assert_true(not history_core.is_unsavable_save_id("normal_save_id"), "normal save_id should not be unsavable")
  assert_true(not history_core.is_unsavable_save_id(nil), "nil should not be unsavable")
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
