-- Run: nvim --headless -u NONE -l lua/maxa/lifecycle/chat_token_threshold_integration_test.lua
-- Real installed Maxa AI Chat/HTTP + project wrappers; fake network and TG.
vim.opt.rtp:append(vim.fn.getcwd())
for _, plugin in ipairs({ "plenary.nvim" }) do
  vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/" .. plugin)
end
vim.g.maxa_test_mode = true
local function eq(a, b)
  assert(a == b, "expected " .. vim.inspect(a) .. ", got " .. vim.inspect(b))
end
local function flush()
  vim.wait(20, function()
    return false
  end)
end
vim.notify = function() end
local config = require("maxa.config")
config.display.chat.auto_scroll = true
config.opts.log_level = "OFF"
local asks = {}
local ask_runtime = {}
function ask_runtime.start(chat, params, callback, opts)
  local ask = { chat = chat, params = vim.deepcopy(params), callback = callback, request_id = opts and opts.request_id }
  asks[#asks + 1] = ask
  return true, ask.request_id
end
function ask_runtime.submit(_, opts)
  return not (type(opts) == "table" and opts.auto_submit == true)
end
function ask_runtime.cancel(_, _, request_id)
  for _, ask in ipairs(asks) do
    if ask.request_id == request_id then
      ask.cancelled = true
      return true
    end
  end
  return false
end
package.loaded["maxa.interactions.chat.tools.builtin.runtime.ask"] = ask_runtime
local Chat = require("maxa.interactions.chat")
local Client = require("maxa.http")
local adapters = require("maxa.adapters")
local requests, pending, raw_requests, compacted = 0, {}, {}, 0
local chats = {}
package.loaded["maxa"] = {
  buf_get_chat = function(buf)
    return chats[buf]
  end,
}
package.loaded["maxa.session.session_identity"] = {
  resolve = function()
    return { project_root = "/project", save_id = "integration" }
  end,
}
package.loaded["maxa.session.model_limits"] = {
  get_model_name = function()
    return "test"
  end,
  get_warning_threshold = function()
    return 200
  end,
  get_context_window = function()
    return 200
  end,
}
package.loaded["maxa.mcphub.native_servers.config"] = {}
package.loaded["maxa.abilities.hooks.fire"] = { fire_sync = function() end, fire = function() end }
package.loaded["maxa.lifecycle.session_trace_lifecycle"] = { mark_submit = function() end }
package.loaded["maxa.session.slash_commands.compact_silent"] = {
  do_compact = function()
    compacted = compacted + 1
  end,
}
local function resolve_ask(ask, selected, error_name)
  if error_name == "timeout" then
    ask.callback(false, "ask timed out")
  elseif error_name then
    ask.callback(false, error_name)
  else
    ask.callback(true, '用户选择了"' .. selected .. '"')
  end
end
Client.static.methods.post.default = function(opts)
  requests = requests + 1
  pending[#pending + 1] = opts
  raw_requests[#raw_requests + 1] = vim.deepcopy(opts.raw)
  return {
    args = {},
    shutdown = function()
      error("no hard cancellation")
    end,
  }
end
local adapter = adapters.resolve("openai")
adapter.name = "test"
adapter.url = "http://127.0.0.1/never-sent"
adapter.env = {}
adapter.headers = {}
adapter.opts.stream = true
adapter.raw = { "--retry", "5" }
adapter.handlers =
  { lifecycle = {
    setup = function()
      return true
    end,
  }, request = {}, response = {}, tools = {} }
adapter.features.tokens = true
adapter.handlers.response.parse_tokens = function(self)
  self._total_tokens = 123
  self._last_usage = { total_tokens = 123 }
  return 123
end
adapter.handlers.response.parse_chat = function(_, data, tools)
  if data == "tool" then
    tools[1] = { id = "call", type = "function", ["function"] = { name = "test", arguments = "{}" } }
  end
  return { status = "success", output = { role = "assistant", content = data == "tool" and "" or data } }
end
adapter.handlers.tools.format_calls = function(_, tools)
  return tools
end
local stop = require("maxa.lifecycle.chat_soft_stop")
stop.setup()
local decision = require("maxa.lifecycle.chat_token_threshold_decision")
decision.setup()
require("maxa.lifecycle.chat_submitted_event").setup()
local recovery = require("maxa.session.llm_error_recovery")
local function new_chat(subagent)
  local buf = vim.api.nvim_create_buf(true, true)
  local recursion_depth = 1
  if subagent == false then
    recursion_depth = nil
  end
  local chat = setmetatable({
    bufnr = buf,
    id = buf,
    adapter = vim.deepcopy(adapter),
    messages = {},
    callbacks = {},
    settings = {},
    cycle = 1,
    header_line = 1,
    _last_role = "user",
    tools = {},
    tool_registry = { schemas = {} },
    context = { render = function() end },
    ui = { unlock_buf = function() end, add_line_break = function() end, display_tokens = function() end },
    add_buf_message = function() end,
    update_metadata = function() end,
    _subagent_recursion_depth = recursion_depth,
  }, { __index = Chat })
  chats[buf] = chat
  chat.tools.refresh = function() end
  chat.tools.execute = function(self)
    self.tool = {}
    self.pending = true
  end
  chat:add_message({ role = "user", content = "work" })
  chat:add_message({ role = "tool", content = "completed batch" })
  recovery._test_hook_chat_done(chat)
  return chat
end
local function start(chat)
  local asks_before = #asks
  eq(true, decision.check(chat, { tokens = { used = 190 } }))
  chat:submit({
    auto_submit = true,
    callback = function()
      chat:tools_done({ auto_submit = true })
    end,
  })
  flush()
  eq(asks_before, #asks)
  eq(true, decision.is_finishing(chat))
end
local function respond_tool(chat)
  pending[#pending].stream(nil, "tool")
  flush()
  pending[#pending].callback({ status = 200 })
  flush()
  eq(true, chat.tools.pending)
  chat.tools.pending = false
  chat.tools.tool = nil
  chat:add_message({ role = "tool", content = "paired result" })
  chat:submit({
    auto_submit = true,
    callback = function()
      chat:tools_done({ auto_submit = true })
    end,
  })
  flush()
end
local chat = new_chat()
local routed_start = requests
start(chat)
eq(routed_start + 1, requests)
for _ = 2, 8 do
  respond_tool(chat)
end
eq(routed_start + 8, requests)
eq(true, decision.should_cancel_tool_batch(chat))
respond_tool(chat)
eq(routed_start + 9, requests)
eq("token_threshold_emergency_finish", chat.messages[#chat.messages]._meta.tag)
eq(true, chat.messages[#chat.messages].content:find("不得自行调用压缩工具", 1, true) ~= nil)
eq(true, chat.messages[#chat.messages].content:find("只有用户明确选择“压缩并继续”", 1, true) ~= nil)
for _ = 2, 3 do
  eq(true, decision.should_cancel_tool_batch(chat))
  respond_tool(chat)
end
eq(routed_start + 11, requests)
respond_tool(chat)
eq(routed_start + 11, requests)
eq(false, decision.is_finishing(chat))
local final_ask = asks[#asks]
eq(300, final_ask.params.timeout)
eq("interrupt", final_ask.params.choices[1][1].value)
eq("compact", final_ask.params.choices[1][2].value)
resolve_ask(final_ask, nil, "timeout")
flush()
eq("interrupt", chat._maxa_token_decision_last_action)
eq(true, stop.is_latched(chat))
for i = routed_start + 1, #raw_requests do
  local raw = raw_requests[i]
  eq("--retry", raw[#raw - 1])
  eq("0", raw[#raw])
end
eq("5", chat.adapter.raw[2])
eq(0, compacted)
eq(123, chat.adapter._total_tokens)
eq(123, chat.adapter._last_usage.total_tokens)
print("PASS real Chat/HTTP SubAgent 8+3 routing + final timeout interrupt")

-- Ordinary finish reuses the primary dispatch budget, but exhaustion interrupts
-- directly instead of entering the SubAgent emergency/compact decision.
local ordinary = new_chat(false)
local ordinary_start = requests
local ordinary_asks = #asks
eq(true, decision.check(ordinary, { tokens = { used = 190 } }))
local ordinary_ask = asks[#asks]
eq(ordinary_asks + 1, #asks)
eq(3, #ordinary_ask.params.choices[1])
ordinary:submit({
  auto_submit = true,
  callback = function()
    ordinary:tools_done({ auto_submit = true })
  end,
})
flush()
eq(ordinary_start, requests)
resolve_ask(ordinary_ask, "token 超限了，需要尽快收尾")
flush()
eq(ordinary_start + 1, requests)
eq(true, decision.is_finishing(ordinary))
eq(true, ordinary.messages[#ordinary.messages].content:find("不得自行调用压缩工具", 1, true) ~= nil)
for _ = 2, 8 do
  respond_tool(ordinary)
end
eq(ordinary_start + 8, requests)
eq(true, decision.should_cancel_tool_batch(ordinary))
local asks_before_ordinary_stop = #asks
respond_tool(ordinary)
flush()
eq(ordinary_start + 8, requests)
eq(asks_before_ordinary_stop, #asks)
eq(false, decision.is_finishing(ordinary))
eq("interrupt", ordinary._maxa_token_decision_last_action)
eq(true, stop.is_latched(ordinary))
for _, message in ipairs(ordinary.messages) do
  assert(message._meta == nil or message._meta.tag ~= "token_threshold_emergency_finish")
end
print("PASS real Chat/HTTP ordinary eight-request finish interrupts without emergency or compact")

-- Real dispatch setup failure has a handle but no job and consumes no round.
local broken = new_chat()
broken.adapter.handlers.lifecycle.setup = function()
  return false
end
local broken_start = requests
eq(true, decision.check(broken, { tokens = { used = 190 } }))
broken:tools_done({ auto_submit = true })
flush()
eq(broken_start, requests)
eq(false, decision.is_finishing(broken))
eq(true, stop.is_latched(broken))
print("PASS real adapter setup failure does not count/continue")

-- The outer submit hook must not open any manual dialog while waiting.
local waiting = new_chat(false)
local waiting_start = requests
eq(true, decision.check(waiting, { tokens = { used = 190 } }))
local old_confirm = vim.fn.confirm
vim.fn.confirm = function()
  error("pending decision must precede manual dialog")
end
waiting:submit({})
eq(waiting_start, requests)
vim.fn.confirm = old_confirm
waiting:dispatch("on_closed")
print("PASS real auto-restore rejects manual side effects while waiting")
-- Host reset-only done emits no callbacks; the terminal budget still clears.
local empty = new_chat()
start(empty)
empty.status = ""
empty:done(nil, nil, nil)
flush()
eq(false, decision.is_finishing(empty))
eq(true, stop.is_latched(empty))
print("PASS real reset-only empty-status completion clears budget")

-- Eighth plain text naturally completes, retaining token-parser writeback.
local natural = new_chat()
local before = requests
start(natural)
for _ = 2, 8 do
  respond_tool(natural)
end
pending[#pending].stream(nil, "finished")
flush()
pending[#pending].callback({ status = 200 })
flush()
eq(before + 8, requests)
eq(false, decision.is_finishing(natural))
eq(false, stop.is_latched(natural))
eq(123, natural.adapter._total_tokens)
print("PASS real eighth plain response completes naturally with adapter usage preserved")
-- Real recovery retry callbacks dispatch through the same budget, without
-- advancing wall time or contacting a provider.
local old_start, old_stop = vim.fn.timer_start, vim.fn.timer_stop
local timers, serial = {}, 900
vim.fn.timer_start = function(_, cb)
  serial = serial + 1
  timers[serial] = cb
  return serial
end
vim.fn.timer_stop = function(id)
  timers[id] = nil
end
local retrying = new_chat()
retrying.adapter.name = "responses_gateway"
retrying.adapter.backend = { protocol = "openai_responses" }
local retry_start = requests
start(retrying)
retrying._last_http_error = "Connection timed out"
retrying._last_http_error_time = vim.uv.now()
retrying.status = "error"
retrying:done(nil, nil, nil)
eq(true, retrying._network_retry_timer ~= nil)
eq(true, decision.is_finishing(retrying))
timers[retrying._network_retry_timer]()
flush()
eq(retry_start + 2, requests)
for _ = 3, 8 do
  respond_tool(retrying)
end
retrying._last_http_error = "Connection timed out"
retrying._last_http_error_time = vim.uv.now()
retrying.status = "error"
retrying:done(nil, nil, nil)
flush()
eq(retry_start + 8, requests)
eq(nil, retrying._network_retry_timer)
eq(false, decision.is_finishing(retrying))
eq(true, stop.is_latched(retrying))
print("PASS real recovery first retry counts and eighth failure cannot retry")

local signature = new_chat()
signature.adapter.name = "responses_gateway"
signature.adapter.backend = { protocol = "openai_responses" }
local sig_start = requests
start(signature)
signature:add_message({ role = "llm", content = "prior", reasoning = { content = "reason" } })
signature._last_http_error = "Invalid signature in thinking block"
signature._last_http_error_time = vim.uv.now()
signature.status = "error"
signature:done(nil, nil, nil)
flush()
eq(true, decision.is_finishing(signature))
vim.wait(150, function()
  return requests == sig_start + 2
end)
eq(sig_start + 2, requests)
for _ = 3, 8 do
  respond_tool(signature)
end
signature:add_message({ role = "llm", content = "new", reasoning = { content = "reason" } })
signature._last_http_error = "Invalid signature in thinking block"
signature._last_http_error_time = vim.uv.now()
signature.status = "error"
signature:done(nil, nil, nil)
vim.wait(150, function()
  return false
end)
eq(sig_start + 8, requests)
eq(false, decision.is_finishing(signature))
eq(true, stop.is_latched(signature))
print("PASS real signature-repair idle gap retains budget and eighth repair stops")

-- A threshold detected after a child request has already started must own the
-- completion boundary. The executor must not return/close the child before the
-- automatic finish response completes in that same Chat.
local child = new_chat()
local child_result
local child_start = requests
require("maxa.mcphub.native_servers.subagent.tools.agent_executor").execute({
  chat = child,
  on_complete = function(result)
    child_result = result
  end,
})
vim.wait(100, function()
  return requests == child_start + 1
end)
eq(child_start + 1, requests)
eq(true, decision.check(child, { tokens = { used = 190 } }))
local child_asks = #asks
pending[#pending].stream(nil, "response before token decision")
flush()
pending[#pending].callback({ status = 200 })
vim.wait(1200, function()
  return child_result ~= nil
end)
eq(nil, child_result)
eq(child_asks, #asks)
vim.wait(100, function()
  return requests == child_start + 2
end)
eq(child_start + 2, requests)
eq("token_threshold_finish", child.messages[#child.messages]._meta.tag)
pending[#pending].stream(nil, "finished automatically")
flush()
pending[#pending].callback({ status = 200 })
vim.wait(1500, function()
  return child_result ~= nil
end)
eq("finished automatically", child_result.content)
eq("completed", child_result.finish_reason)
print("PASS subagent executor waits for automatic finish before completing child")

vim.fn.timer_start, vim.fn.timer_stop = old_start, old_stop
print("9 integration checks passed")
