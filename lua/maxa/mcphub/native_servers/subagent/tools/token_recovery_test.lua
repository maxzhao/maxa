-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/token_recovery_test.lua
-- 运行方式: nvim --headless -l lua/maxa/mcphub/native_servers/subagent/tools/token_recovery_test.lua

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

local function assert_nil(value, msg)
  if value ~= nil then
    error(string.format("%s: expected nil, got %s", msg or "assertion failed", tostring(value)))
  end
end

local token_recovery = require("maxa.mcphub.native_servers.subagent.tools.token_recovery")
local history_core = require("maxa.session.history_core")

print("\n=== Testing subagent token_recovery ===\n")

test("detect_token_error should match common context limit errors", function()
  assert_true(token_recovery.detect_token_error("maximum context length exceeded"), "expected max context match")
  assert_true(token_recovery.detect_token_error({ message = "input is too long" }), "expected table message match")
end)

test("unsavable save_id should be recognized by token_recovery", function()
  local save_id = history_core.make_unsavable_save_id("run_agent")
  assert_true(token_recovery.is_unsavable_save_id(save_id), "expected unsavable save_id")
end)

test("prepare_run_agent_recovery should reject unsavable save_id", function()
  local save_id = history_core.make_unsavable_save_id("run_agent")
  local info, err = token_recovery.prepare_run_agent_recovery(save_id, "token limit exceeded")
  assert_nil(info, "recovery info")
  assert_true(err and err:match("temporary/unsavable"), "expected unsavable error")
end)

test("prepare_fork_agent_recovery should reject unsavable parent_save_id", function()
  local save_id = history_core.make_unsavable_save_id("scratch")
  local info, err = token_recovery.prepare_fork_agent_recovery(save_id, "token limit exceeded")
  assert_nil(info, "recovery info")
  assert_true(err and err:match("temporary/unsavable"), "expected unsavable error")
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
