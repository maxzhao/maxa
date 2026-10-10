-- filepath: lua/maxa/session/tools/compact_self_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/tools/compact_self_test.lua

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

local compact_self = require("maxa.session.tools.compact_self")
local history_core = require("maxa.session.history_core")

local function make_res()
  return {
    result_error = nil,
    result_text = nil,
    error = function(self, err)
      self.result_error = err
      return self
    end,
    text = function(self, text)
      self.result_text = text
      return self
    end,
    send = function(self)
      return self
    end,
  }
end

local function call_handler(params, chat)
  local res = make_res()
  compact_self.handler({
    params = params or {},
    caller = {
      maxa_ai = {
        chat = chat,
      },
    },
  }, res)
  return res
end

local function make_chat()
  return {
    opts = {
      save_id = "normal-session",
    },
    adapter = {
      features = {
        tokens = true,
      },
    },
  }
end

print("\n=== Testing compact_self request ===\n")

test("instructions schema should require recoverable task state", function()
  local description = compact_self.inputSchema.properties.instructions.description
  assert_true(description:match("latest user request and goal"), "should name the current goal")
  assert_true(description:match("completed and unfinished work"), "should name task progress")
  assert_true(description:match("ordered next steps"), "should name recovery steps")
  assert_true(description:match("changed files"), "should name changed files")
  assert_true(description:match("validation status"), "should name validation state")
  assert_true(description:match("current errors or blockers"), "should name blockers")
  assert_true(description:match("summarized or deleted"), "should describe compressible history")
end)

test("input schema should expose instructions only", function()
  assert_true(compact_self.inputSchema.properties.mode == nil, "mode is removed")
  assert_eq(1, #compact_self.inputSchema.required, "required field count")
  assert_eq("instructions", compact_self.inputSchema.required[1], "required instructions")
end)

test("instructions-only request should be recorded", function()
  local chat = make_chat()
  local res = call_handler({ instructions = "保留关键上下文" }, chat)
  assert_true(not res.result_error, "should accept without mode")
  assert_true(chat._self_compact_requested == true, "request flag")
  assert_eq("保留关键上下文", chat._self_compact_instructions, "instructions")
  assert_true(chat._self_compact_mode == nil, "no mode state")
end)

test("legacy extra mode must not change the configured route", function()
  local chat = make_chat()
  local res = call_handler({ instructions = "x", mode = "collapse" }, chat)
  assert_true(not res.result_error, "legacy extra field is ignored")
  assert_true(chat._self_compact_mode == nil, "no mode state")
end)

test("temporary/unsavable chat should reject compression", function()
  local chat = make_chat()
  chat.opts.save_id = history_core.make_unsavable_save_id("scratch")
  local res = call_handler({ instructions = "x", mode = "collapse" }, chat)
  assert_true(res.result_error and res.result_error:match("temporary/unsavable"), "expected temporary chat error")
  assert_true(chat._self_compact_requested == nil, "request flag should not be set")
end)

test("adapter without token counting should still reject compression", function()
  local chat = { adapter = { features = {} } }
  local res = call_handler({ instructions = "x", mode = "collapse" }, chat)
  assert_true(res.result_error and res.result_error:match("does not support token counting"), "expected token counting error")
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
