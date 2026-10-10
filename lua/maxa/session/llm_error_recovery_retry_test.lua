-- filepath: lua/maxa/session/llm_error_recovery_retry_test.lua
-- Unit test: delayed rate-limit recovery keeps one timer/request chain per chat.
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
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

vim.g.maxa_test_mode = true
local recovery = require("maxa.session.llm_error_recovery")
local trigger = recovery._test_trigger_rate_limited_retry

print("\n=== Testing llm_error_recovery retry serialization ===\n")

test("deduplicates repeated rate-limit completion and never replaces another active request", function()
  local original_timer_start = vim.fn.timer_start
  local original_timer_stop = vim.fn.timer_stop
  local original_notify = vim.notify
  local callbacks = {}
  local next_timer = 100

  vim.fn.timer_start = function(_, callback, _)
    next_timer = next_timer + 1
    callbacks[next_timer] = callback
    return next_timer
  end
  vim.fn.timer_stop = function(id)
    callbacks[id] = nil
    return 1
  end
  vim.notify = function() end

  local submit_count = 0
  local chat = {
    bufnr = vim.api.nvim_create_buf(false, true),
    id = 1,
    ui = { unlock_buf = function() end },
    submit = function(self)
      submit_count = submit_count + 1
      self.current_request = { real = true }
    end,
  }

  local ok, err = pcall(function()
    assert_equal(true, trigger(chat, "my_oai"), "first trigger")
    local retry_timer = chat._network_retry_timer
    local wait_request = chat.current_request
    assert_equal(1, chat._rate_limited_retry_count, "first trigger increments once")

    assert_equal(true, trigger(chat, "my_oai"), "duplicate trigger")
    assert_equal(retry_timer, chat._network_retry_timer, "duplicate keeps the original timer")
    assert_equal(wait_request, chat.current_request, "duplicate keeps the original wait request")
    assert_equal(1, chat._rate_limited_retry_count, "duplicate does not consume a retry")

    chat.current_request = { other = true }
    callbacks[retry_timer]()
    vim.wait(50, function() return false end)
    assert_equal(0, submit_count, "stale timer does not replace or parallelize another request")
  end)

  vim.fn.timer_start = original_timer_start
  vim.fn.timer_stop = original_timer_stop
  vim.notify = original_notify
  pcall(vim.api.nvim_buf_delete, chat.bufnr, { force = true })
  if not ok then
    error(err)
  end
end)

test("soft stop cancels a pending retry and prevents a new retry chain", function()
  local original_timer_start = vim.fn.timer_start
  local original_timer_stop = vim.fn.timer_stop
  local original_notify = vim.notify
  local callbacks = {}
  local stopped = {}
  local next_timer = 200

  vim.fn.timer_start = function(_, callback, _)
    next_timer = next_timer + 1
    callbacks[next_timer] = callback
    return next_timer
  end
  vim.fn.timer_stop = function(id)
    stopped[id] = true
    callbacks[id] = nil
    return 1
  end
  vim.notify = function() end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local chat = {
    bufnr = bufnr,
    id = 2,
    ui = { unlock_buf = function() end },
    submit = function() error("soft-stopped retry must not submit") end,
  }

  local ok, err = pcall(function()
    assert_equal(true, trigger(chat, "my_oai"), "retry starts before soft stop")
    local timer = chat._network_retry_timer
    assert_equal(true, timer ~= nil, "retry timer exists")

    chat._maxa_soft_stop_completed = true
    assert_equal(true, recovery.cancel_pending_retry(chat, "soft_stop"), "pending retry cancelled")
    assert_equal(true, stopped[timer], "retry timer stopped")
    assert_equal(nil, chat._network_retry_timer, "retry timer cleared")
    assert_equal(false, chat._network_retry_pending, "retry pending cleared")
    assert_equal(false, trigger(chat, "my_oai"), "soft stop blocks a new retry")
  end)

  vim.fn.timer_start = original_timer_start
  vim.fn.timer_stop = original_timer_stop
  vim.notify = original_notify
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if not ok then
    error(err)
  end
end)

test("new runtime continuation re-enables retry after initial soft stop", function()
  local old_start, old_stop, old_notify = vim.fn.timer_start, vim.fn.timer_stop, vim.notify
  local timers, serial = {}, 300
  vim.fn.timer_start = function(_, callback) serial = serial + 1; timers[serial] = callback; return serial end
  vim.fn.timer_stop = function(id) timers[id] = nil end
  vim.notify = function() end
  local chat = { bufnr = vim.api.nvim_create_buf(false, true), id = 3,
    ui = { unlock_buf = function() end }, submit = function(self) self.submits = (self.submits or 0) + 1; self.current_request = {} end }
  local ok, err = pcall(function()
    recovery.cancel_pending_retry(chat, "soft_stop")
    assert_equal(true, chat._network_retry_cancelled, "initial stop cancels recovery")
    recovery.begin_runtime_continuation(chat)
    assert_equal(false, chat._network_retry_cancelled, "new operation releases recovery")
    assert_equal(true, trigger(chat, "my_oai"), "first finishing error schedules retry")
    timers[chat._network_retry_timer]()
    vim.wait(20, function() return false end)
    assert_equal(1, chat.submits, "retry dispatch occurs")
  end)
  vim.fn.timer_start, vim.fn.timer_stop, vim.notify = old_start, old_stop, old_notify
  vim.api.nvim_buf_delete(chat.bufnr, { force = true })
  if not ok then error(err) end
end)

test("finishing context errors and compact_self cannot silently compress", function()
  local old_decision, old_notify = package.loaded["maxa.lifecycle.chat_token_threshold_decision"], vim.notify
  package.loaded["maxa.lifecycle.chat_token_threshold_decision"] = { is_finishing = function() return true end }
  vim.notify = function() end
  local ok, err = pcall(function()
    for _, self_compact in ipairs({ false, true }) do
      local chat = {
        adapter = { name = "test", protocol = "openai_responses", opts = {} },
        messages = {}, ui = {}, status = "error", _has_submitted = true,
        _last_stream_error = "context_length_exceeded: Your input exceeds the context window",
        _self_compact_requested = self_compact,
        submit = function() error("must not resubmit") end, stop = function() end,
        done = function(self) self.normal_done = true end,
      }
      recovery._test_hook_chat_done(chat)
      chat:done(nil, nil, nil)
      assert_equal(true, chat.normal_done, "error finalizes rather than compresses")
      assert_equal(nil, chat._auto_compact_in_progress, "no compression")
    end
  end)
  package.loaded["maxa.lifecycle.chat_token_threshold_decision"], vim.notify = old_decision, old_notify
  if not ok then error(err) end
end)

if failed > 0 then
  error(string.format("%d test(s) failed", failed))
end
print(string.format("\n%d tests passed\n", passed))
