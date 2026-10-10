-- Run: nvim --headless -u NONE -l lua/maxa/session/llm_error_recovery_openai_responses_test.lua
-- Unit test: adapter-normalized protocol errors retain recovery classification policy.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary) == 1 then vim.opt.runtimepath:append(plenary) end
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local responses = require("maxa.adapters.http.openai_responses")
local error_handler = require("maxa.session.llm_error_handler")
local adapter = {
  handlers = responses.handlers,
  roles = responses.roles,
  opts = { stream = true },
  protocol = "openai_responses",
  quota = { provider = "sub2api" },
}
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name .. ": " .. tostring(err))
  end
end
local function eq(expected, actual, message)
  assert(expected == actual, string.format("%s: expected=%s actual=%s", message or "mismatch", vim.inspect(expected), vim.inspect(actual)))
end
local function classify(raw)
  local normalized = responses.handlers.response.parse_error(adapter, raw)
  return normalized, error_handler.classify_http_error(normalized, adapter)
end

print("\n=== Adapter-normalized Responses recovery errors ===\n")

test("context length remains token_limit for nested and top-level official errors", function()
  local error_text, kind = classify('event: error\ndata: {"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"too long","param":"input"}}')
  assert(error_text:find("context_length_exceeded", 1, true))
  eq(error_handler.TYPES.TOKEN_LIMIT, kind)

  error_text, kind = classify('data: {"type":"error","code":"context_length_exceeded","message":"top level too long","param":"input"}')
  assert(error_text:find("context_length_exceeded", 1, true))
  assert(error_text:find("top level too long", 1, true))
  eq(error_handler.TYPES.TOKEN_LIMIT, kind)
end)

test("usage and upstream failures remain network issues", function()
  local _, usage_kind = classify('data: {"type":"response.failed","error":{"code":"response.failed","message":"The usage limit has been reached","type":"usage_limit_reached"}}')
  eq(error_handler.TYPES.NETWORK, usage_kind)
  local _, upstream_kind = classify('data: {"type":"response.failed","error":{"code":"upstream_error","message":"Upstream request failed","type":"response.failed"}}')
  eq(error_handler.TYPES.NETWORK, upstream_kind)
end)

test("incomplete reason is normalized before policy", function()
  local error_text = responses.handlers.response.parse_error(adapter, 'data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}')
  assert(error_text:find("max_output_tokens", 1, true))
end)

test("recovery module exposes no Responses wire decoder", function()
  vim.g.maxa_test_mode = true
  package.loaded["maxa.session.llm_error_recovery"] = nil
  local recovery = require("maxa.session.llm_error_recovery")
  eq(nil, rawget(recovery, "_test_extract_openai_responses_stream_error"))
end)

test("unsupported parameter errors are permanent, not signature or network failures", function()
  local _, kind = classify('data: {"type":"error","error":{"type":"invalid_request_error","code":"unsupported_parameter","message":"Bad Request: supplied input item IDs require persisted-item lookup","param":"input"}}')
  eq(error_handler.TYPES.PERMANENT, kind)
end)

test("terminal stream errors finish Chat once even when transport completion follows", function()
  local Chat = require("maxa.interactions.chat")
  local Client = require("maxa.http")
  local recovery = require("maxa.session.llm_error_recovery")
  local original_send, original_notify = Client.send, vim.notify
  local callbacks
  Client.send = function(_, _, opts)
    callbacks = opts
    return { cancel = function() end }
  end
  vim.notify = function() end
  local self = require("maxa.adapters.http").new(vim.deepcopy(responses))
  self.name, self.protocol = "test", "openai_responses"
  self.opts.stream = true
  local chat = setmetatable({
    bufnr = vim.api.nvim_create_buf(false, true), id = 1,
    adapter = self, settings = {}, messages = { { role = "user", content = "continue" } },
    ui = { unlock_buf = function() end }, _has_submitted = true,
    submit = function() error("permanent error must not retry") end,
    stop = function() end,
    done = function(value)
      value.done_count = (value.done_count or 0) + 1
      value.status = ""
    end,
  }, { __index = Chat })
  local ok, err = pcall(function()
    recovery._test_hook_chat_done(chat)
    chat:_submit_http({ messages = chat.messages })
    callbacks.on_chunk('data: {"type":"error","error":{"type":"invalid_request_error","code":"unsupported_parameter","message":"Supplied input item IDs require persisted-item lookup that is not supported by rustponsesapi.","param":"input"}}')
    eq(1, chat.done_count, "stream error finalizes immediately")
    callbacks.on_done(nil)
    eq(1, chat.done_count, "transport completion must not finalize again")
    eq(nil, chat._network_retry_timer, "transport completion must not schedule an empty-response retry")
  end)
  recovery.cancel_pending_retry(chat, "test cleanup")
  Client.send, vim.notify = original_send, original_notify
  vim.api.nvim_buf_delete(chat.bufnr, { force = true })
  if not ok then error(err) end
end)

test("watchdog timeout cancels transport and enters exactly one existing network retry", function()
  local Chat = require("maxa.interactions.chat")
  local Client = require("maxa.http")
  local recovery = require("maxa.session.llm_error_recovery")
  local watchdog = require("maxa.lifecycle.chat_request_watchdog")
  local defaults = Client.static.methods
  local post, schedule, wrap = defaults.post.default, defaults.schedule.default, defaults.schedule_wrap.default
  local timer_start, timer_stop, notify = vim.fn.timer_start, vim.fn.timer_stop, vim.notify
  local captured, stopped, timers = nil, 0, 0
  defaults.post.default = function(opts)
    captured = opts
    return { shutdown = function() stopped = stopped + 1 end }
  end
  defaults.schedule.default = function(fn) fn() end
  defaults.schedule_wrap.default = function(fn) return fn end
  vim.fn.timer_start = function() timers = timers + 1; return 100 + timers end
  vim.fn.timer_stop, vim.notify = function() end, function() end
  local self = require("maxa.adapters.http").new(vim.deepcopy(responses))
  self.name, self.protocol, self.opts.stream = "timeout-test", "openai_responses", true
  local chat = setmetatable({
    bufnr = vim.api.nvim_create_buf(false, true), id = "timeout-test", adapter = self,
    settings = {}, messages = { { role = "user", content = "continue" } },
    ui = { unlock_buf = function() end }, _has_submitted = true,
    submit = function() error("retry timer must not submit immediately") end,
    stop = function() error("timeout must not use user-stop") end,
    done = function() error("timeout must enter pending recovery") end,
  }, { __index = Chat })
  local ok, err = pcall(function()
    recovery._test_hook_chat_done(chat)
    chat:_submit_http({ messages = chat.messages })
    local session = watchdog._sessions()[chat.bufnr]
    session.last = session.last - session.opts.first_response_timeout_ms - 1
    session.check(); session.check()
    eq(1, stopped); eq(1, timers); eq(1, chat._network_retry_count)
    eq(false, watchdog.is_active(chat))
    local waiting = chat.current_request
    captured.stream(nil, 'data: {"type":"response.output_text.delta","delta":"late"}')
    captured.on_error({ message = "late curl failure" }); captured.callback({ status = 200 })
    eq(1, timers); eq(waiting, chat.current_request)
    assert(chat._network_retry_last_detail:find("Chat communication timed out", 1, true))
    eq(nil, chat._last_http_error)
  end)
  recovery.cancel_pending_retry(chat, "test cleanup")
  watchdog.finish(chat)
  defaults.post.default, defaults.schedule.default, defaults.schedule_wrap.default = post, schedule, wrap
  vim.fn.timer_start, vim.fn.timer_stop, vim.notify = timer_start, timer_stop, notify
  vim.api.nvim_buf_delete(chat.bufnr, { force = true })
  if not ok then error(err) end
end)

if failed > 0 then error(string.format("%d test(s) failed", failed)) end
print(string.format("\n%d tests passed\n", passed))
