-- Run with: nvim --headless -u NONE -l lua/maxa/lifecycle/chat_token_threshold_decision_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local passed, failed = 0, 0
local function eq(expected, actual)
  if expected ~= actual then
    error("expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual), 2)
  end
end
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
local function flush()
  vim.wait(10, function()
    return false
  end)
end
local notifications, asks, chats = {}, {}, {}
vim.notify = function(msg)
  notifications[#notifications + 1] = msg
end
local ask_runtime = {}
function ask_runtime.start(chat, params, callback, opts)
  local ask = {
    chat = chat,
    params = vim.deepcopy(params),
    callback = callback,
    request_id = opts and opts.request_id,
    internal = opts and opts.internal,
  }
  asks[#asks + 1] = ask
  return true, ask.request_id
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
local Chat = {}
Chat.__index = Chat
function Chat:add_callback(event, cb)
  self.callbacks[event] = self.callbacks[event] or {}
  table.insert(self.callbacks[event], cb)
end
function Chat:dispatch(event)
  for _, cb in ipairs(self.callbacks[event] or {}) do
    cb(self)
  end
end
function Chat:add_message(msg, opts)
  table.insert(self.messages, { role = msg.role, content = msg.content, context = opts.context, _meta = opts._meta })
end
function Chat:_submit_http()
  local allowed, token = decision.before_dispatch(self, "_submit_http")
  if not allowed then return nil end
  if self.start_error then
    error("adapter setup failed")
  end
  if self.no_job then
    self.current_request = { id = "no-job" }
    return
  end
  self.requests = self.requests + 1
  self.raw_at_dispatch = vim.deepcopy(self.adapter.raw)
  self.current_request = {
    job = {},
    cancel = function()
      error("must not hard-cancel")
    end,
  }
  return decision.after_dispatch(self, token, true, self.current_request)
end
function Chat:submit(opts)
  opts = opts or {}
  if not stop.before_submit(self, opts) or decision.blocks_submit(self, opts) then
    return nil
  end
  if self.current_request then
    return
  end
  if opts.callback then
    opts.callback()
  end
  self.status = "success"
  self:dispatch("on_submitted")
  return self:_submit_http({})
end
function Chat:tools_done(opts)
  opts = opts or {}
  local converted, finalize = stop.before_tools_done(self, opts)
  opts = converted
  self.current_tool = nil
  self.tools.tool = nil
  if not opts.auto_submit then
    self:dispatch("on_ready")
  end
  stop.after_tools_done(self, finalize)
end
function Chat:done(_, _, tools)
  local state, reset_only = decision.before_done(self)
  self.current_request = nil
  if tools then
    self.tools.tool = {}
    return
  end
  self:dispatch("on_ready")
  vim.api.nvim_exec_autocmds("User", { pattern = "MaxaAIChatDone", data = { bufnr = self.bufnr } })
  decision.after_done(self, state, reset_only)
end
package.loaded["maxa.interactions.chat"] = Chat
package.loaded["maxa"] = {
  buf_get_chat = function(buf)
    return chats[buf]
  end,
}
package.loaded["maxa.config"] = {
  constants = { USER_ROLE = "user" },
  runtime = function()
    return { lifecycle = { token_decision = { threshold_percent = 95, primary_finish_rounds = 8, emergency_finish_rounds = 3 } } }
  end,
}
package.loaded["maxa.session.session_identity"] = {
  resolve = function()
    return { project_root = "/project", save_id = "session" }
  end,
}
package.loaded["maxa.session.model_limits"] = {
  get_model_name = function()
    return "model"
  end,
  get_warning_threshold = function()
    return 200
  end,
}
package.loaded["maxa.session.llm_error_recovery"] = {
  cancel_pending_retry = function(chat)
    chat._network_retry_cancelled = true
    chat._network_retry_timer = nil
  end,
  begin_runtime_continuation = function(chat)
    chat._network_retry_cancelled = false
  end,
}
stop = require("maxa.lifecycle.chat_soft_stop")
stop.setup()
decision = require("maxa.lifecycle.chat_token_threshold_decision")
assert(package.loaded["maxa.interactions.chat.tools.builtin.runtime.ask"] == ask_runtime)
decision.setup()
local function new_chat(subagent)
  local buf = vim.api.nvim_create_buf(false, true)
  local chat = setmetatable({
    bufnr = buf,
    adapter = { name = "test", type = "http", raw = { "--retry", "5" } },
    callbacks = {},
    messages = { { role = "tool", content = "completed" } },
    requests = 0,
    tools = {},
    draft = "user input remains",
    ui = { unlock_buf = function() end },
    _subagent_recursion_depth = subagent and 1 or nil,
  }, Chat)
  chats[buf] = chat
  return chat
end
local function reach_safe_stop(chat)
  chat:submit({
    auto_submit = true,
    callback = function()
      chat:tools_done({ auto_submit = true })
    end,
  })
  flush()
end
local function start_ordinary(chat)
  eq(true, decision.check(chat, { tokens = { used = 190, limit = 200 } }))
  local ask = asks[#asks]
  assert(ask, "ask was not synchronously started; notifications=" .. vim.inspect(notifications))
  reach_safe_stop(chat)
  eq(0, chat.requests)
  eq(true, stop.is_latched(chat))
  return ask
end
local function start_subagent(chat)
  local asks_before = #asks
  eq(true, decision.check(chat, { tokens = { used = 190, limit = 200 } }))
  reach_safe_stop(chat)
  eq(asks_before, #asks)
  eq(1, chat.requests)
  eq(true, decision.is_finishing(chat))
end
local function result(ask, selected, error_name)
  if error_name == "timeout" then
    ask.callback(false, "ask timed out")
  elseif error_name then
    ask.callback(false, error_name)
  elseif selected then
    assert(ask, "ask was not started; notifications=" .. vim.inspect(notifications))
    ask.callback(true, '用户选择了"' .. selected .. '"')
  else
    ask.callback(true, "")
  end
  flush()
end
local function finish_response(chat)
  chat.current_request = nil
  chat:done()
  flush()
end
local function finishing()
  local chat = new_chat(true)
  start_subagent(chat)
  return chat
end
local function ordinary_finishing()
  local chat = new_chat()
  local ask = start_ordinary(chat)
  result(ask, "token 超限了，需要尽快收尾")
  eq(1, chat.requests)
  eq(true, decision.is_finishing(chat))
  return chat
end
local function next_tool_round(chat)
  chat:done(nil, nil, { "tool1", "tool2" })
  table.insert(chat.messages, { role = "tool", content = "tool1 result" })
  table.insert(chat.messages, { role = "tool", content = "tool2 result" })
  chat.tools.tool = nil -- real Orchestrator clears this before ToolsFinished
  chat:submit({
    auto_submit = true,
    callback = function()
      chat:tools_done({ auto_submit = true })
    end,
  })
  flush()
end

local function finish_tool_batch_at_budget(chat)
  chat:done(nil, nil, { "tool1", "tool2" })
  table.insert(chat.messages, { role = "tool", content = "cancelled tool1" })
  table.insert(chat.messages, { role = "tool", content = "cancelled tool2" })
  chat.tools.tool = nil
  chat:tools_done({ auto_submit = true })
  flush()
end

local function exhaust_primary(chat)
  for _ = 2, 8 do
    next_tool_round(chat)
  end
  eq(8, chat.requests)
  eq(true, stop.is_requested(chat))
  eq(true, decision.should_cancel_tool_batch(chat))
  finish_tool_batch_at_budget(chat)
  eq(9, chat.requests)
  eq(true, decision.is_finishing(chat))
  eq("token_threshold_emergency_finish", chat.messages[#chat.messages]._meta.tag)
  eq(
    "Token 已耗尽，请立即收尾。不得自行调用压缩工具或发起会话压缩；本通知不授权压缩，只有用户明确选择“压缩并继续”才允许运行时执行压缩。",
    chat.messages[#chat.messages].content
  )
  eq(nil, chat.messages[#chat.messages].content:find("3", 1, true))
end

local function exhaust_emergency(chat)
  for _ = 2, 3 do
    eq(true, decision.should_cancel_tool_batch(chat))
    next_tool_round(chat)
  end
  eq(11, chat.requests)
  eq(true, stop.is_requested(chat))
  finish_tool_batch_at_budget(chat)
  eq(11, chat.requests)
  eq(false, decision.is_finishing(chat))
  return asks[#asks]
end

test("warning limit, rounding, threshold and missing-status rearm", function()
  local chat = new_chat()
  eq(95, decision._test_warning_usage({ tokens = { used = 189, limit = 100 } }, chat))
  eq(false, decision.check(chat, { tokens = { used = 188 } }))
  local ask = start_ordinary(chat)
  result(ask, "interrupt")
  decision.check(chat, {})
  eq(false, decision.check(chat, { tokens = { used = 190 } }))
  decision.check(chat, { tokens = { used = 188 } })
  eq(true, decision.check(chat, { tokens = { used = 190 } }))
  chat:dispatch("on_closed")
end)

test("ordinary threshold asks indefinitely with finish, compact and interrupt", function()
  local chat = new_chat()
  local before = #asks
  local ask = start_ordinary(chat)
  eq(before + 1, #asks)
  eq(false, decision.check(chat, { tokens = { used = 200 } }))
  eq("choice", ask.params.mode)
  eq(0, ask.params.timeout)
  eq(1, #ask.params.choices)
  eq(4, #ask.params.choices[1])
  eq("尽快收尾", ask.params.choices[1][1].label)
  eq("token 超限了，需要尽快收尾", ask.params.choices[1][1].value)
  eq("compact", ask.params.choices[1][2].value)
  eq("interrupt", ask.params.choices[1][3].value)
  eq("🔀 交接到新会话继续", ask.params.choices[1][4].label)
  eq("handoff", ask.params.choices[1][4].value)
  eq(nil, ask.params.message:find("5 分钟", 1, true))
  eq(true, ask.params.message:find("Telegram / 当前 Chat", 1, true) ~= nil)
  eq(true, ask.internal)
  eq(1, #chat.messages)
  result(ask, "interrupt")
  eq(nil, decision._test_active()[chat.bufnr])
  chat:submit({})
  eq(1, chat.requests)
end)

test("ordinary continue waits for the safe stop and resumes without injected warning", function()
  local chat = new_chat()
  eq(true, decision.check(chat, { tokens = { used = 190 } }))
  local ask = asks[#asks]
  local state = decision._test_active()[chat.bufnr]
  result(ask, "continue")
  eq(0, chat.requests)
  eq("continue", state.selection)
  chat:tools_done({ auto_submit = true })
  flush()
  eq(1, chat.requests)
  eq(1, #chat.messages)
  eq("user input remains", chat.draft)
  eq("5", chat.raw_at_dispatch[2])
  eq("5", chat.adapter.raw[2])
  eq(nil, decision._test_active()[chat.bufnr])
end)

test("ordinary Telegram button and Chat text become exact safe-boundary instructions", function()
  local pending = new_chat()
  eq(true, decision.check(pending, { tokens = { used = 190 } }))
  local ask = asks[#asks]
  result(ask, "继续完成当前工作")
  eq(0, pending.requests)
  eq(1, #pending.messages)
  pending:tools_done({ auto_submit = true })
  flush()
  eq(1, pending.requests)
  eq(2, #pending.messages)
  eq("继续完成当前工作", pending.messages[2].content)
  eq("token_threshold_user_instruction", pending.messages[2]._meta.tag)
  eq("user input remains", pending.draft)

  local direct = new_chat()
  local direct_ask = start_ordinary(direct)
  direct_ask.callback(true, "完成必要验证后直接收尾")
  flush()
  eq(1, direct.requests)
  eq(2, #direct.messages)
  eq("完成必要验证后直接收尾", direct.messages[2].content)
  eq("token_threshold_user_instruction", direct.messages[2]._meta.tag)
  eq(nil, decision._test_active()[direct.bufnr])
end)

test("ordinary timeout, transport, cancellation and empty results fail closed", function()
  for _, kind in ipairs({ "timeout", "HTTP request timed out", "cancelled", "empty" }) do
    local chat = new_chat()
    local ask = start_ordinary(chat)
    if kind == "empty" then
      result(ask, nil)
    else
      result(ask, nil, kind)
    end
    eq(0, chat.requests)
    eq(1, #chat.messages)
    eq(true, stop.is_latched(chat))
    eq(nil, decision._test_active()[chat.bufnr])
  end
end)

test("ordinary interrupt resolves deferred completion after safe stop", function()
  local chat = new_chat()
  eq(true, decision.check(chat, { tokens = { used = 190 } }))
  local ask = asks[#asks]
  local completed = 0
  eq(true, decision.defer_completion(chat, function()
    completed = completed + 1
  end))
  reach_safe_stop(chat)
  result(ask, "interrupt")
  flush()
  eq(1, completed)
  eq(nil, decision._test_active()[chat.bufnr])
end)

test("SubAgent threshold injects finish immediately without ask", function()
  local chat = new_chat(true)
  local before = #asks
  start_subagent(chat)
  eq(before, #asks)
  eq(2, #chat.messages)
  eq("token_threshold_finish", chat.messages[2]._meta.tag)
  eq(true, chat.messages[2].content:find("最多剩余 8 轮", 1, true) ~= nil)
  eq(true, chat.messages[2].content:find("不得自行调用压缩工具", 1, true) ~= nil)
  eq(true, chat.messages[2].content:find("只有用户明确选择“压缩并继续”", 1, true) ~= nil)
  eq("0", chat.raw_at_dispatch[#chat.raw_at_dispatch])
end)

test("hidden image analysis keeps its independent max_steps controller", function()
  local chat = new_chat(true)
  chat._maxa_hidden_image_analysis = true
  local before = #asks
  eq(false, decision.check(chat, { tokens = { used = 200 } }))
  eq(before, #asks)
  eq(nil, decision._test_active()[chat.bufnr])
end)

test("ordinary finish uses eight requests then interrupts without emergency or compact", function()
  local chat = ordinary_finishing()
  eq("token_threshold_finish", chat.messages[2]._meta.tag)
  eq(true, chat.messages[2].content:find("不得自行调用压缩工具", 1, true) ~= nil)
  for _ = 2, 8 do
    next_tool_round(chat)
  end
  eq(8, chat.requests)
  eq(true, stop.is_requested(chat))
  eq(true, decision.should_cancel_tool_batch(chat))
  local asks_before = #asks
  finish_tool_batch_at_budget(chat)
  eq(8, chat.requests)
  eq(asks_before, #asks)
  eq(false, decision.is_finishing(chat))
  eq("interrupt", chat._maxa_token_decision_last_action)
  eq(true, stop.is_latched(chat))
  for _, message in ipairs(chat.messages) do
    assert(message._meta == nil or message._meta.tag ~= "token_threshold_emergency_finish")
  end
  chat:submit({})
  eq(9, chat.requests)
end)

test("ordinary explicit compact is exclusive and resumes once", function()
  local compact_count = 0
  local success
  package.loaded["maxa.session.handoff_compaction"] = {
    start = function(_, done)
      compact_count = compact_count + 1
      success = done
      return true
    end,
  }
  local chat = new_chat()
  local ask = start_ordinary(chat)
  result(ask, "compact")
  eq(1, compact_count)
  eq(false, decision.is_finishing(chat))
  eq(1, #chat.messages)
  chat:submit({ auto_submit = true })
  eq(0, chat.requests)
  success()
  -- The controller submits the successor; this decision never resubmits source.
  eq(0, chat.requests)
  eq(nil, decision._test_active()[chat.bufnr])
end)

test("primary budget transitions to hidden emergency finish instead of terminating", function()
  local chat = finishing()
  exhaust_primary(chat)
  eq(true, decision.should_cancel_tool_batch(chat))
end)

test("emergency budget is internal and ends in two-choice 300s ask", function()
  local chat = finishing()
  exhaust_primary(chat)
  local ask = exhaust_emergency(chat)
  eq("choice", ask.params.mode)
  eq(300, ask.params.timeout)
  eq(1, #ask.params.choices)
  eq(2, #ask.params.choices[1])
  eq("interrupt", ask.params.choices[1][1].value)
  eq("compact", ask.params.choices[1][2].value)
  eq(true, ask.params.message:find("5 分钟内未选择", 1, true) ~= nil)
  eq(true, stop.is_latched(chat))
end)

test("final SubAgent unknown free text remains fail closed", function()
  local chat = finishing()
  exhaust_primary(chat)
  local ask = exhaust_emergency(chat)
  result(ask, "继续帮我处理")
  flush()
  eq(11, chat.requests)
  eq(nil, decision._test_active()[chat.bufnr])
  eq(true, stop.is_latched(chat))
end)

test("final SubAgent ask timeout interrupts and completes terminal callback", function()
  local chat = finishing()
  exhaust_primary(chat)
  local ask = exhaust_emergency(chat)
  local completed = 0
  chat:add_callback("on_completed", function()
    completed = completed + 1
  end)
  result(ask, nil, "timeout")
  flush()
  eq(1, completed)
  eq("interrupt", chat._maxa_token_decision_last_action)
  eq(nil, decision._test_active()[chat.bufnr])
  eq(11, chat.requests)
end)

test("final SubAgent compact is exclusive and resumes once", function()
  local compact_count = 0
  local success
  package.loaded["maxa.session.handoff_compaction"] = {
    start = function(_, done)
      compact_count = compact_count + 1
      success = done
      return true
    end,
  }
  local chat = finishing()
  exhaust_primary(chat)
  local ask = exhaust_emergency(chat)
  result(ask, "compact")
  eq(1, compact_count)
  chat:submit({ auto_submit = true })
  eq(11, chat.requests)
  success()
  eq(11, chat.requests)
  eq(nil, decision._test_active()[chat.bufnr])
end)

test("busy submissions do not consume the primary dispatch budget", function()
  local chat = finishing()
  for _ = 1, 15 do
    chat:submit({ auto_submit = true })
  end
  eq(1, chat.requests)
  for _ = 2, 8 do
    chat.current_request = nil
    chat:submit({ auto_submit = true })
  end
  eq(8, chat.requests)
  chat.current_request = nil
  chat:submit({ auto_submit = true })
  eq(8, chat.requests)
end)

test("natural response completes during ordinary, primary or emergency finish", function()
  local ordinary = ordinary_finishing()
  ordinary:done()
  flush()
  eq(false, decision.is_finishing(ordinary))
  eq(false, stop.is_latched(ordinary))

  local primary = finishing()
  primary:done()
  flush()
  eq(false, decision.is_finishing(primary))
  eq(false, stop.is_latched(primary))

  local emergency = finishing()
  exhaust_primary(emergency)
  emergency:done()
  flush()
  eq(false, decision.is_finishing(emergency))
  eq(false, stop.is_latched(emergency))
end)

test("SubAgent startup failure counts no request and fails closed", function()
  for _, kind in ipairs({ "start_error", "no_job" }) do
    local chat = new_chat(true)
    chat[kind] = true
    eq(true, decision.check(chat, { tokens = { used = 190 } }))
    reach_safe_stop(chat)
    eq(0, chat.requests)
    eq(false, decision.is_finishing(chat))
    eq(true, stop.is_latched(chat))
    eq("5", chat.adapter.raw[2])
  end
end)

test("local close and buffer deletion reject late ordinary ask results", function()
  for _, event in ipairs({ "on_closed", "BufDelete" }) do
    local chat = new_chat()
    local ask = start_ordinary(chat)
    if event == "BufDelete" then
      vim.api.nvim_buf_delete(chat.bufnr, { force = true })
    else
      chat:dispatch(event)
    end
    result(ask, "continue")
    eq(0, chat.requests)
    eq(nil, decision._test_active()[chat.bufnr])
    eq(true, ask.cancelled)
  end
end)

if failed > 0 then
  error(string.format("%d tests failed, %d passed", failed, passed))
end
print(string.format("%d tests passed", passed))
