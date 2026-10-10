-- Run: nvim --headless -u NONE -l lua/maxa/lifecycle/chat_request_watchdog_retry_limit_test.lua
-- Focused request-watchdog, configuration and final curl-argument contracts.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("✓ " .. name)
  else failed = failed + 1; print("✗ " .. name .. ": " .. tostring(err)) end
end
local function eq(expected, actual) assert(vim.deep_equal(expected, actual), vim.inspect({ expected, actual })) end
local watchdog = require("maxa.lifecycle.chat_request_watchdog")
local config = require("maxa.config")
local Client = require("maxa.http")
local responses = require("maxa.adapters.http.openai_responses")
local opts = { first_response_timeout_ms = 100, response_idle_timeout_ms = 200, tool_args_idle_timeout_ms = 300 }
local function request(options)
  local chat = { bufnr = vim.api.nvim_create_buf(false, true) }
  local handle = { id = tostring(chat.bufnr), timeout = function(err) chat.error = err end }
  watchdog.start(chat, handle, options or opts)
  return chat, handle, watchdog._sessions()[chat.bufnr]
end
local function cleanup(chat) watchdog.finish(chat); vim.api.nvim_buf_delete(chat.bufnr, { force = true }) end

local function transport(raw, connect)
  local adapter = require("maxa.adapters.http").new(vim.deepcopy(responses))
  adapter.name, adapter.raw, adapter.opts.stream = "watchdog-test", raw, true
  local captured, stopped, progress, errors, done = nil, 0, {}, {}, 0
  local client = Client.new({ adapter = adapter, opts = {
    schedule = function(fn) fn() end, schedule_wrap = function(fn) return fn end,
    post = function(request_opts)
      captured = request_opts
      return { shutdown = function() stopped = stopped + 1 end }
    end,
  } })
  local original = config.runtime().lifecycle.watchdog
  config.runtime().lifecycle.watchdog = watchdog.options({ connect_timeout_ms = connect })
  local handle = client:send({ messages = {} }, { interaction = "chat", silent = true,
    on_progress = function(observation) progress[#progress + 1] = observation end,
    on_error = function(err) errors[#errors + 1] = err end,
    on_done = function() done = done + 1 end,
  })
  config.runtime().lifecycle.watchdog = original
  return handle, captured, progress, errors, function() return stopped, done end
end

test("actual config composition preserves canonical/legacy precedence and validates stages", function()
  config.setup({ maxa = { lifecycle = { watchdog = { no_message_warn_after_ms = 50,
    no_progress_warn_after_ms = 60, response_idle_timeout_ms = -1 } } } })
  local value = config.runtime().lifecycle.watchdog
  eq(180000, value.connect_timeout_ms); eq(50, value.first_response_timeout_ms)
  eq(-1, value.response_idle_timeout_ms); eq(60, value.tool_args_idle_timeout_ms)
  for _, invalid in ipairs({ 0, -2, math.huge, "180000" }) do
    eq(false, pcall(config.setup, { maxa = { lifecycle = { watchdog = { first_response_timeout_ms = invalid } } } }))
  end
  eq(false, pcall(watchdog.options, { check_interval_ms = -1 }))
  config.configure_early({ defaults = { chat = "test" }, presets = { test = { type = "chat", adapter = "test" } },
    lifecycle = { watchdog = { no_message_warn_after_ms = 70, no_progress_warn_after_ms = 80 } } })
  config.setup({ maxa = { lifecycle = { watchdog = { response_idle_timeout_ms = 90 } } } })
  eq(70, config.runtime().lifecycle.watchdog.first_response_timeout_ms)
  eq(90, config.runtime().lifecycle.watchdog.response_idle_timeout_ms)
  eq(80, config.runtime().lifecycle.watchdog.tool_args_idle_timeout_ms)
end)

test("first-output expiry reports once and empty observations do not refresh", function()
  local chat, handle, session = request()
  local baseline = session.last
  watchdog.observe(chat, handle.id, { bytes = 0, first_output = true, usage = { output_tokens = 1 } })
  eq(baseline, session.last)
  session.last = session.last - 110
  session.check(); session.check()
  eq("chat_communication_timeout", chat.error.code); eq("first_response", chat.error.phase)
  eq(false, watchdog.is_active(chat)); cleanup(chat)
end)

test("text/reasoning and genuine tool transitions select one idle phase", function()
  local chat, handle, session = request()
  watchdog.observe(chat, handle.id, { bytes = 2 })
  eq("response", session.phase)
  session.last = session.last - 150; session.check(); eq(nil, chat.error)
  watchdog.observe(chat, handle.id, { bytes = 4, phase = "tool_args", tool_started = true, tool_id = "call" })
  eq("tool_args", session.phase)
  local baseline = session.last
  watchdog.observe(chat, handle.id, { bytes = 4, phase = "tool_args", tool_started = true, tool_id = "call" })
  eq(baseline, session.last)
  session.last = session.last - 250; session.check(); eq(nil, chat.error)
  watchdog.observe(chat, handle.id, { bytes = 0, phase = "response", tool_done = true, tool_id = "call" })
  eq("response", session.phase)
  baseline = session.last
  watchdog.observe(chat, handle.id, { bytes = 0, phase = "response", tool_done = true, tool_id = "call" })
  eq(baseline, session.last)
  session.last = session.last - 210; session.check(); eq("response", chat.error.phase); cleanup(chat)
end)

test("disabled phase does not disable other phases; tools/visibility do not own requests", function()
  local chat, handle, session = request(vim.tbl_extend("force", opts, { first_response_timeout_ms = -1 }))
  session.last = session.last - 1000; session.check(); eq(nil, chat.error)
  vim.api.nvim_exec_autocmds("User", { pattern = "MaxaAIChatHidden", data = { bufnr = chat.bufnr } })
  eq(true, watchdog.is_active(chat))
  watchdog.observe(chat, handle.id, { bytes = 1, phase = "tool_args" })
  session.last = session.last - 310; session.check(); eq("tool_args", chat.error.phase)
  cleanup(chat)
  chat, handle, session = request({ first_response_timeout_ms = -1, response_idle_timeout_ms = -1, tool_args_idle_timeout_ms = -1 })
  eq(nil, session.timer); chat._closed = true; session.check(); eq(false, watchdog.is_active(chat)); cleanup(chat)
end)

test("old request progress/completion cannot clear a replacement", function()
  local chat, handle = request()
  watchdog.start(chat, { id = "new", timeout = function() end }, opts)
  local session = watchdog._sessions()[chat.bufnr]
  watchdog.observe(chat, handle.id, { bytes = 4 }); watchdog.finish(chat, handle.id)
  eq("first_response", session.phase); eq(true, watchdog.is_active(chat)); cleanup(chat)
end)

test("Chat curl policy replaces legacy options without mutating adapter raw", function()
  local raw = { "--connect-timeout", "30", "--connect-timeout=40", "--speed-limit", "1", "--speed-time=60",
    "-m10", "-Y", "2", "-y60", "--max-time", "120", "--retry", "5", "--retry-max-time", "150", "--http1.1" }
  local original = vim.deepcopy(raw)
  local handle, captured = transport(raw, 2500)
  eq({ "--retry", "3", "--retry-delay", "1", "--keepalive-time", "60", "--tcp-nodelay", "--no-buffer",
    "--retry", "5", "--retry-max-time", "150", "--http1.1", "--connect-timeout", "2.5", "--noproxy", "*" }, captured.raw)
  eq(original, raw); handle.cancel()
  handle, captured = transport(raw, -1)
  for _, arg in ipairs(captured.raw) do assert(not arg:find("connect-timeout", 1, true)); assert(not arg:find("speed-", 1, true)) end
  handle.cancel()
end)

test("transport timeout/error settles once and blocks late progress/error/done", function()
  local handle, captured, progress, errors, state = transport({}, -1)
  captured.stream(nil, 'data: {"type":"response.output_text.delta","delta":"working"}')
  eq(1, #progress)
  eq(true, handle.timeout({ message = "Chat communication timed out", code = "chat_communication_timeout" }))
  captured.stream(nil, 'data: {"type":"response.output_text.delta","delta":"late"}')
  captured.on_error({ message = "late curl error" }); captured.callback({ status = 200 })
  eq(1, #progress); eq(1, #errors); eq(false, handle.timeout({ message = "again" }))
  local stopped, done = state(); eq(1, stopped); eq(0, done)
  eq("error", handle.status())
  handle, captured, _, errors = transport({}, -1)
  captured.on_error({ message = "upstream 504" }); eq(1, #errors)
end)

test("protocol adapters identify text, reasoning and tool-argument phases", function()
  local parse = responses.handlers.response.parse_metrics
  local function wire(value) return 'data: ' .. vim.json.encode(value) end
  eq("tool_args", parse({}, wire({ type = "response.function_call_arguments.delta", delta = "{" })).phase)
  eq("response", parse({}, wire({ type = "response.reasoning_summary_text.delta", delta = "thinking" })).phase)
  eq(true, parse({}, wire({ type = "response.function_call_arguments.done", item_id = "a" })).tool_done)
  local anthropic = require("maxa.adapters.http.anthropic").handlers.parse_metrics
  eq("tool_args", anthropic({}, wire({ type = "content_block_delta", delta = { type = "input_json_delta", partial_json = "{" } })).phase)
  eq("response", anthropic({}, wire({ type = "content_block_delta", delta = { type = "thinking_delta", thinking = "thinking" } })).phase)
  local openai = require("maxa.adapters.http.openai").handlers.parse_metrics
  eq("tool_args", openai({}, wire({ choices = { { delta = { tool_calls = { { index = 0, ["function"] = { arguments = "{" } } } } } } })).phase)
  eq(true, openai({}, wire({ choices = { { finish_reason = "tool_calls", delta = {} } } })).tool_done_all)
  eq(openai, require("maxa.adapters.http.gemini").handlers.parse_metrics)
end)

watchdog.reset_setup()
if failed > 0 then error(string.format("%d test(s) failed", failed)) end
print(string.format("\n%d tests passed\n", passed))
