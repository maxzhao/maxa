-- Run with: nvim --headless -u NONE -l lua/maxa/lifecycle/chat_soft_stop_test.lua

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

local soft_stopped_events = {}
local soft_stopped_autocmd = vim.api.nvim_create_autocmd("User", {
  pattern = "MaxaAIChatSoftStopped",
  callback = function(args)
    table.insert(soft_stopped_events, args.data)
  end,
})

local Chat = {}
Chat.__index = Chat

function Chat.submit(self, opts)
  if not require("maxa.lifecycle.chat_soft_stop").before_submit(self, opts) then
    return nil
  end
  self.original_submit_called = (self.original_submit_called or 0) + 1
  self.original_submit_opts = opts
  return "submitted"
end

function Chat.tools_done(self, opts)
  local soft_stop = require("maxa.lifecycle.chat_soft_stop")
  local converted, finalize = soft_stop.before_tools_done(self, opts)
  self.original_tools_done_called = (self.original_tools_done_called or 0) + 1
  self.original_tools_done_opts = converted
  soft_stop.after_tools_done(self, finalize)
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
package.loaded["maxa.lifecycle.chat_soft_stop"] = nil
local soft_stop = require("maxa.lifecycle.chat_soft_stop")
soft_stop._test_reset_patch()
soft_stop.setup()

local keys = soft_stop._test_keys()

local function new_chat(extra)
  extra = extra or {}
  return setmetatable(vim.tbl_extend("force", {
    callbacks = {},
    original_submit_called = 0,
    original_tools_done_called = 0,
  }, extra), Chat)
end

print("\n=== Testing chat_soft_stop ===\n")

test("request toggles only for active work", function()
  notifications = {}
  local idle = new_chat()
  assert_equal(false, soft_stop.request(idle), "idle request should not arm")
  assert_equal(nil, idle[keys.requested], "idle request flag")
  assert_truthy(notifications[#notifications].message:find("No active", 1, true), "idle notification")

  local chat = new_chat({ current_request = { cancel = function() end } })
  assert_equal(true, soft_stop.request(chat), "busy request should arm")
  assert_equal(true, chat[keys.requested], "request flag")
  assert_equal(true, soft_stop.is_requested(chat), "is_requested")

  assert_equal(false, soft_stop.request(chat), "second request should clear")
  assert_equal(nil, chat[keys.requested], "request flag cleared")
end)

test("auto-submit without callback is blocked and finalizes", function()
  notifications = {}
  local chat = new_chat({
    current_request = { cancel = function() end },
  })
  soft_stop.request(chat)
  chat.current_request = nil

  local result = chat:submit({ auto_submit = true })
  assert_equal(nil, result, "blocked auto-submit result")
  assert_equal(0, chat.original_submit_called, "original submit should not run")
  assert_equal(nil, chat[keys.requested], "request flag cleared")
  assert_equal(true, chat[keys.completed], "completed marker")
end)

test("tool auto-submit callback runs reset/tools_done but provider submit is blocked", function()
  notifications = {}
  local chat = new_chat({
    current_request = { cancel = function() end },
  })
  soft_stop.request(chat)
  chat.current_request = nil

  local callback_called = 0
  local result = chat:submit({
    auto_submit = true,
    callback = function()
      callback_called = callback_called + 1
      chat:tools_done({ auto_submit = true })
    end,
  })

  assert_equal(nil, result, "blocked auto-submit result")
  assert_equal(1, callback_called, "callback should run")
  assert_equal(0, chat.original_submit_called, "original submit should not run")
  assert_equal(1, chat.original_tools_done_called, "tools_done should run")
  assert_equal(false, chat.original_tools_done_opts.auto_submit, "tools_done converted to manual-ready boundary")
  assert_equal(nil, chat[keys.requested], "request flag cleared")
  assert_equal(true, chat[keys.completed], "completed marker")
end)

test("delayed auto-submit remains blocked after soft stop completes", function()
  local chat = new_chat({ [keys.completed] = true })
  local result = chat:submit({ auto_submit = true })
  assert_equal(nil, result, "delayed auto-submit result")
  assert_equal(0, chat.original_submit_called, "delayed auto-submit should not run")
  assert_equal(true, chat[keys.completed], "completed latch remains armed")

  chat:tools_done({ auto_submit = true })
  assert_equal(1, chat.original_tools_done_called, "delayed tools_done still finalizes UI")
  assert_equal(false, chat.original_tools_done_opts.auto_submit, "delayed tools_done disables continuation")
  assert_equal(true, chat[keys.completed], "tools_done preserves completed latch")
end)

test("manual submit after completed soft stop releases latch and proceeds", function()
  local chat = new_chat({ [keys.completed] = true })
  local result = chat:submit({})
  assert_equal("submitted", result, "manual submit result")
  assert_equal(1, chat.original_submit_called, "original submit called")
  assert_equal(nil, chat[keys.completed], "completed latch cleared")
end)

test("on_ready callback finalizes after the ready transition clears busy state", function()
  local scheduled = {}
  local original_schedule = vim.schedule
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end

  local ok, err = pcall(function()
    soft_stopped_events = {}
    local chat = new_chat({
      bufnr = vim.api.nvim_get_current_buf(),
      id = 42,
      current_request = { cancel = function() end },
    })
    soft_stop.request(chat)
    assert_equal(true, chat[keys.ready_callback], "ready callbacks installed")

    -- A ready callback may run before current_request is cleared.
    chat:dispatch("on_ready")
    assert_equal(true, chat[keys.requested], "request remains armed during ready callback")
    assert_equal(1, #scheduled, "completion check scheduled")

    chat.current_request = nil
    scheduled[1]()
    assert_equal(nil, chat[keys.requested], "request cleared after ready transition")
    assert_equal(true, chat[keys.completed], "completed after ready transition")
    assert_equal(1, #soft_stopped_events, "soft stopped event count")
    assert_equal(chat.bufnr, soft_stopped_events[1].bufnr, "soft stopped event bufnr")
    assert_equal(chat.id, soft_stopped_events[1].id, "soft stopped event chat id")
    assert_equal("ready", soft_stopped_events[1].reason, "soft stopped event reason")
  end)

  vim.schedule = original_schedule
  if not ok then
    error(err, 0)
  end
end)

test("trusted tool/dispatch boundary can arm while idle without toggling", function()
  local chat = new_chat({ bufnr = vim.api.nvim_get_current_buf() })
  assert_equal(false, soft_stop.is_busy(chat), "tool cleanup already removed active handle")
  assert_equal(true, soft_stop.request_at_boundary(chat), "trusted boundary arms")
  assert_equal(true, soft_stop.request_at_boundary(chat), "duplicate remains armed")
  assert_equal(true, soft_stop.is_requested(chat), "not toggled off")
  chat:submit({ auto_submit = true, callback = function() chat:tools_done({ auto_submit = true }) end })
  assert_equal(0, chat.original_submit_called, "no provider continuation")
  assert_equal(false, chat.original_tools_done_opts.auto_submit, "safe finalization")
  assert_equal(true, soft_stop.is_latched(chat), "manual-resumable stop")
end)

soft_stop._test_reset_patch()
vim.api.nvim_del_autocmd(soft_stopped_autocmd)

if failed > 0 then
  error(string.format("%d test(s) failed", failed))
end

print(string.format("\n%d tests passed\n", passed))
