-- Run with: nvim --headless -u NONE -l lua/maxa/lifecycle/chat_context_limit_stop_test.lua

package.path = table.concat({
  vim.fn.getcwd() .. "/lua/?.lua",
  vim.fn.getcwd() .. "/lua/?/init.lua",
  package.path,
}, ";")

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
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function assert_truthy(value, msg)
  if not value then
    error(msg or "expected truthy value", 2)
  end
end

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

local Chat = {}
Chat.__index = Chat

function Chat.submit(self, opts)
  if not require("maxa.lifecycle.chat_context_limit_stop").before_submit(self, opts) then
    return nil
  end
  self.original_submit_called = (self.original_submit_called or 0) + 1
  self.original_submit_opts = opts
  return "submitted"
end

function Chat.tools_done(self, opts)
  opts = require("maxa.lifecycle.chat_context_limit_stop").before_tools_done(self, opts)
  self.original_tools_done_called = (self.original_tools_done_called or 0) + 1
  self.original_tools_done_opts = opts
  return "tools_done"
end

function Chat.add_callback(self, event, callback)
  self.callbacks = self.callbacks or {}
  self.callbacks[event] = self.callbacks[event] or {}
  table.insert(self.callbacks[event], callback)
end

function Chat.dispatch(self, event)
  for _, callback in ipairs((self.callbacks and self.callbacks[event]) or {}) do
    callback(self)
  end
end

package.loaded["maxa.interactions.chat"] = Chat

local usage_by_chat = setmetatable({}, { mode = "k" })
package.loaded["maxa.session.token_usage"] = {
  get_usage = function(chat)
    return usage_by_chat[chat]
  end,
}

local soft_stop_requests = 0
package.loaded["maxa.lifecycle.chat_soft_stop"] = {
  is_busy = function(chat)
    return chat.busy == true or chat.current_request ~= nil or chat.current_tool ~= nil
  end,
  is_requested = function(chat)
    return chat.soft_stop_requested == true
  end,
  request = function(chat)
    soft_stop_requests = soft_stop_requests + 1
    chat.soft_stop_requested = true
    return true
  end,
}

package.loaded["maxa.lifecycle.chat_context_limit_stop"] = nil
local context_stop = require("maxa.lifecycle.chat_context_limit_stop")
context_stop._test_reset_patch()
context_stop.setup()
local keys = context_stop._test_keys()

local function new_chat(extra)
  extra = extra or {}
  return setmetatable(vim.tbl_extend("force", {
    callbacks = {},
    original_submit_called = 0,
    original_tools_done_called = 0,
  }, extra), Chat)
end

local function set_usage(chat, ratio)
  usage_by_chat[chat] = {
    tokens = ratio * 100000,
    context_window = 100000,
    ratio = ratio,
    percent = math.floor(ratio * 100 + 0.5),
  }
end

print("\n=== Testing chat_context_limit_stop ===\n")

test("parse validates absolute and relative targets", function()
  local target = context_stop._test_parse("50", { ratio = 0.25, tokens = 25, context_window = 100 })
  assert_equal(0.5, target.ratio, "absolute target ratio")
  assert_equal(50, target.percent, "absolute target percent")

  local relative = context_stop._test_parse("+10", { ratio = 0.25, tokens = 25, context_window = 100 })
  assert_equal(0.35, relative.ratio, "relative target ratio")
  assert_equal(35, relative.percent, "relative target percent")

  local below, below_err = context_stop._test_parse("20", { ratio = 0.25, tokens = 25, context_window = 100 })
  assert_equal(nil, below, "below current target")
  assert_truthy(below_err:find("below current", 1, true), "below current error")

  local over, over_err = context_stop._test_parse("+80", { ratio = 0.25, tokens = 25, context_window = 100 })
  assert_equal(nil, over, "relative over target")
  assert_truthy(over_err:find("exceed 100", 1, true), "relative over error")
end)

test("arm stores target and installs lifecycle callbacks", function()
  notifications = {}
  local chat = new_chat()
  set_usage(chat, 0.25)

  assert_equal(true, context_stop.arm(chat, "50"), "arm result")
  assert_equal(true, chat[keys.active], "active flag")
  assert_equal(0.5, chat[keys.target_ratio], "target ratio")
  assert_equal(50, chat[keys.target_percent], "target percent")
  assert_equal(true, chat[keys.ready_callback], "ready callback installed")
  assert_truthy(notifications[#notifications].message:find("armed", 1, true), "armed notification")
end)

test("toggle cancels active listener without opening input", function()
  notifications = {}
  local input_calls = 0
  local original_input = vim.ui.input
  vim.ui.input = function(_, _)
    input_calls = input_calls + 1
  end

  local chat = new_chat()
  set_usage(chat, 0.25)
  context_stop.arm(chat, "50")
  assert_equal(false, context_stop.toggle(chat), "toggle cancel result")
  assert_equal(nil, chat[keys.active], "active cleared")
  assert_equal(0, input_calls, "no input opened")

  vim.ui.input = original_input
end)

test("toggle prompt arms from user input", function()
  notifications = {}
  local original_input = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("+10")
  end

  local chat = new_chat()
  set_usage(chat, 0.25)
  assert_equal(true, context_stop.toggle(chat), "toggle prompt result")
  assert_equal(true, chat[keys.active], "active flag")
  assert_equal(0.35, chat[keys.target_ratio], "relative target")

  vim.ui.input = original_input
end)

test("check below threshold does not trigger", function()
  soft_stop_requests = 0
  local chat = new_chat({ busy = true })
  set_usage(chat, 0.25)
  context_stop.arm(chat, "50")

  assert_equal(false, context_stop.check(chat, "manual"), "below threshold")
  assert_equal(true, chat[keys.active], "still active")
  assert_equal(0, soft_stop_requests, "no soft stop")
end)

test("submit boundary triggers one-shot soft stop when busy", function()
  notifications = {}
  soft_stop_requests = 0
  local chat = new_chat({ busy = true })
  set_usage(chat, 0.25)
  context_stop.arm(chat, "50")
  set_usage(chat, 0.51)

  local result = chat:submit({ auto_submit = true })
  assert_equal("submitted", result, "original submit still called")
  assert_equal(1, soft_stop_requests, "soft stop requested")
  assert_equal(nil, chat[keys.active], "active cleared")
  assert_equal(true, chat[keys.triggered], "triggered marker")

  chat:submit({ auto_submit = true })
  assert_equal(1, soft_stop_requests, "one-shot no second request")
end)

test("idle auto-submit at reached limit is blocked without soft stop", function()
  notifications = {}
  soft_stop_requests = 0
  local chat = new_chat({ busy = false })
  set_usage(chat, 0.25)
  context_stop.arm(chat, "50")
  set_usage(chat, 0.5)

  local callback_called = 0
  local result = chat:submit({
    auto_submit = true,
    callback = function()
      callback_called = callback_called + 1
    end,
  })
  assert_equal(nil, result, "auto-submit should be blocked")
  assert_equal(1, callback_called, "callback should run")
  assert_equal(0, chat.original_submit_called, "original submit should not run")
  assert_equal(0, soft_stop_requests, "no soft stop when idle")
  assert_equal(nil, chat[keys.active], "active cleared")
  assert_equal(true, chat[keys.triggered], "triggered marker")
end)

test("idle tools_done at reached limit is converted to manual ready boundary", function()
  notifications = {}
  soft_stop_requests = 0
  local chat = new_chat({ busy = false })
  set_usage(chat, 0.25)
  context_stop.arm(chat, "50")
  set_usage(chat, 0.5)

  local result = chat:tools_done({ auto_submit = true })
  assert_equal("tools_done", result, "tools_done result")
  assert_equal(1, chat.original_tools_done_called, "original tools_done called")
  assert_equal(false, chat.original_tools_done_opts.auto_submit, "auto_submit converted")
  assert_equal(0, soft_stop_requests, "no soft stop when idle")
  assert_equal(nil, chat[keys.active], "active cleared")
  assert_equal(true, chat[keys.triggered], "triggered marker")
end)

test("ready boundary completes without soft stop when idle", function()
  notifications = {}
  soft_stop_requests = 0
  local chat = new_chat({ busy = false })
  set_usage(chat, 0.25)
  context_stop.arm(chat, "50")
  set_usage(chat, 0.5)

  chat:dispatch("on_ready")
  assert_equal(0, soft_stop_requests, "no soft stop when idle")
  assert_equal(nil, chat[keys.active], "active cleared")
  assert_equal(true, chat[keys.triggered], "triggered marker")
  assert_truthy(notifications[#notifications].message:find("Listener completed", 1, true), "completed notification")
end)

test("unavailable usage fails closed", function()
  notifications = {}
  local chat = new_chat()
  usage_by_chat[chat] = nil

  assert_equal(false, context_stop.arm(chat, "50"), "arm unavailable")
  assert_equal(nil, chat[keys.active], "not active")
  assert_truthy(notifications[#notifications].message:find("unavailable", 1, true), "unavailable notification")
end)

context_stop._test_reset_patch()

if failed > 0 then
  error(string.format("%d test(s) failed", failed))
end

print(string.format("\n%d tests passed\n", passed))
