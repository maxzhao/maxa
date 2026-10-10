-- filepath: lua/maxa/lifecycle/session_trace_lifecycle_test.lua
-- Run with: nvim --headless -l lua/maxa/lifecycle/session_trace_lifecycle_test.lua

local history_core = require("maxa.session.history_core")
local session_trace = require("maxa.session.session_trace")
local lifecycle = require("maxa.lifecycle.session_trace_lifecycle")

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

local function assert_table(value, msg)
  if type(value) ~= "table" then
    error((msg or "expected table") .. ": got " .. type(value))
  end
end

local original_get_history_dir = history_core.get_history_dir
local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")
history_core.get_history_dir = function()
  local history_dir = tmp_root .. "/.maxa/history"
  vim.fn.mkdir(history_dir .. "/chats", "p")
  return history_dir
end

local function new_tracked_chat(root_trace_id, save_id)
  root_trace_id = root_trace_id or "lifecycle_root"
  save_id = save_id or root_trace_id
  session_trace.ensure_manifest(root_trace_id, {})
  local chat = {
    id = "chat_" .. save_id,
    bufnr = 100,
    opts = { save_id = save_id },
    _meta = {},
    messages = {},
  }
  local membership = session_trace.set_membership(
    chat,
    session_trace.create_root_membership(root_trace_id, { span_id = "span_" .. save_id })
  )
  assert_table(membership, "membership")
  return chat, membership
end

local function events(root_trace_id)
  local result = session_trace.read_events(root_trace_id)
  assert_table(result, "events")
  return result
end

print("\n=== Testing session session trace lifecycle ===\n")

test("manual submit marker records only visible manual user prompt", function()
  local chat = new_tracked_chat("manual_root")
  table.insert(chat.messages, { role = "user", content = "fragment", _meta = { inserted_from_fragment = "frag-1" } })
  lifecycle.mark_submit(chat, { is_user_input = true, auto_submit = false, user_message = "manual prompt" })
  table.insert(chat.messages, { role = "user", content = "hidden", opts = { visible = false } })
  table.insert(chat.messages, { role = "user", content = "manual prompt" })

  local result, err = lifecycle._test.capture_submitted(chat)
  assert_table(result, err)
  assert_eq(true, result.appended, "manual prompt appended")

  local durable = events("manual_root")
  assert_eq(1, #durable, "one event")
  assert_eq("main_turn.user_prompt", durable[1].kind, "event kind")
  assert_eq("manual prompt", durable[1].message.content, "prompt content")
  assert_eq(3, durable[1].message.message_index, "message index")
end)

test("auto submit and regenerate do not record user prompts", function()
  local chat = new_tracked_chat("auto_root")

  lifecycle.mark_submit(chat, { is_user_input = false, auto_submit = true, user_message = "ignored" })
  table.insert(chat.messages, { role = "user", content = "auto continuation" })
  local result = lifecycle._test.capture_submitted(chat)
  assert_true(result == nil, "auto_submit should not append")

  lifecycle.mark_submit(chat, { is_user_input = false, auto_submit = false, user_message = "regenerate" })
  table.insert(chat.messages, { role = "user", content = "regenerate continuation" })
  result = lifecycle._test.capture_submitted(chat)
  assert_true(result == nil, "regenerate/programmatic should not append")

  local durable = events("auto_root")
  assert_eq(0, #durable, "no prompt events")
end)

test("done records final assistant reply after content is available", function()
  local chat = new_tracked_chat("reply_root")
  table.insert(chat.messages, { role = "user", content = "prompt" })
  table.insert(chat.messages, { role = "llm", content = "tool call", tool_calls = { { id = "c1" } } })
  table.insert(chat.messages, { role = "llm", content = "final reply" })

  local result, err = lifecycle._test.capture_done(chat)
  assert_table(result, err)
  assert_eq(true, result.appended, "reply appended")

  local durable = events("reply_root")
  assert_eq(1, #durable, "one reply event")
  assert_eq("main_turn.agent_reply", durable[1].kind, "event kind")
  assert_eq("final reply", durable[1].message.content, "reply content")
  assert_eq(3, durable[1].message.message_index, "reply index")
end)

test("stopped response records empty agent_error and suppresses duplicate done capture", function()
  local chat = new_tracked_chat("stopped_root")
  table.insert(chat.messages, { role = "user", content = "prompt" })

  local result, err = lifecycle._test.capture_stopped(chat)
  assert_table(result, err)
  assert_eq(true, result.appended, "stopped error appended")
  lifecycle._test.capture_done(chat)

  local durable = events("stopped_root")
  assert_eq(1, #durable, "one stopped event")
  assert_eq("main_turn.agent_error", durable[1].kind, "event kind")
  assert_eq("stopped", durable[1].status, "status")
  assert_eq("", durable[1].message.content, "empty content")
  assert_eq(2, durable[1].message.message_index, "synthetic index after prompt")
end)

test("error done without assistant content records empty agent_error", function()
  local chat = new_tracked_chat("error_root")
  chat.status = "error"
  chat._last_http_error = "HTTP 500"
  table.insert(chat.messages, { role = "user", content = "prompt" })

  local result, err = lifecycle._test.capture_done(chat)
  assert_table(result, err)
  assert_eq(true, result.appended, "error appended")

  local durable = events("error_root")
  assert_eq(1, #durable, "one error event")
  assert_eq("main_turn.agent_error", durable[1].kind, "event kind")
  assert_eq("error", durable[1].status, "status")
  assert_eq("HTTP 500", durable[1].reason, "reason")
  assert_eq("", durable[1].message.content, "empty content")
end)

test("untracked chats do not write lifecycle events", function()
  session_trace.ensure_manifest("untracked_root", {})
  local chat = { opts = { save_id = "untracked_root" }, messages = {} }
  lifecycle.mark_submit(chat, { is_user_input = true, auto_submit = false, user_message = "prompt" })
  table.insert(chat.messages, { role = "user", content = "prompt" })
  lifecycle._test.capture_submitted(chat)
  lifecycle._test.capture_stopped(chat)
  lifecycle._test.capture_done(chat)
  assert_eq(0, #events("untracked_root"), "no events for untracked chat")
end)

history_core.get_history_dir = original_get_history_dir
vim.fn.delete(tmp_root, "rf")

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
