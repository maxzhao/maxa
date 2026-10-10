-- Runtime-owned 95% token decision, routed by ordinary vs SubAgent Chat.
local M = {}

local function policy()
  local opts = require("maxa.config").runtime().lifecycle.token_decision
  local function bound(value, ceiling)
    value = tonumber(value)
    return value and math.max(1, math.min(math.floor(value), ceiling)) or ceiling
  end
  return {
    threshold_percent = bound(opts.threshold_percent, 95),
    primary_finish_rounds = bound(opts.primary_finish_rounds, 8),
    emergency_finish_rounds = bound(opts.emergency_finish_rounds, 3),
  }
end
local FINISH_MESSAGE =
  "当前会话已达到 token 风险阈值。不要回复或确认本条通知，请立即收尾，不再扩展工作范围；完成必要验证，说明结果与未完成事项，然后结束本次执行。最多剩余 %d 轮。不得自行调用压缩工具或发起会话压缩；本通知不授权压缩，只有用户明确选择“压缩并继续”才允许运行时执行压缩。"
local EMERGENCY_FINISH_MESSAGE =
  "Token 已耗尽，请立即收尾。不得自行调用压缩工具或发起会话压缩；本通知不授权压缩，只有用户明确选择“压缩并继续”才允许运行时执行压缩。"
local HANDOFF_MESSAGE =
  "用户已明确选择“交接到新会话继续”，授权本次主会话交接。请加载 subagent，按其 Main-Session Handoff 流程将必要目标、约束、决策、修改、错误、验证结果和下一步整理到 .maxa/drafts/，以文件消息传递并预加载必要 Ability/指导，然后使用一次独立同步 run 调用 @subagent:run_agent，run_mode=handoff，让新的主会话继续当前工作并直接负责验证与交付。不要复制完整旧历史，不要改为普通子代理委派；本选择不授权压缩，也不授权后续自动交接。"

local CHILD_HANDOFF_MESSAGE =
  "用户已明确选择“交接到新会话继续”，授权本次子会话交接。请加载 subagent，按 Child-Session Handoff 流程将必要目标、约束、决策、修改、错误、验证结果和下一步整理到 .maxa/drafts/，以文件消息传递并预加载必要 Ability/指导，然后使用一次独立同步 run 调用 @subagent:run_agent，run_mode=handoff。接替会话必须仍是同一当前调用父会话的子代理，父工具继续等待其最终结果。不要复制完整旧历史，不要创建孙会话或升级主会话；本选择不授权压缩，也不授权后续自动交接。"

local function can_handoff(chat)
  local identity = require("maxa.session.agent_identity")
  if identity.is_main(chat) then
    return not require("maxa.session.history_core").is_unsavable_save_id(identity.save_id(chat))
  end
  return chat._subagent_executor ~= nil
    and require("maxa.mcphub.native_servers.subagent.session_handoff").is_child_eligible(chat)
end

local STATE_KEY = "_maxa_token_decision_state"
local TRIGGERED_KEY = "_maxa_token_decision_triggered"
local CALLBACKS_KEY = "_maxa_token_decision_callbacks_installed"
local PATCHED_KEY = "_maxa_token_decision_patched"
local CLOSED_KEY = "_maxa_token_decision_closed"
local CANCELLED_KEY = "_maxa_token_decision_cancelled"
local BUDGET_STOP_OWNER = "token_finish_budget"

local active = {}
local setup_done = false
local exiting = false

local function notify(message, level)
  vim.notify("[token-decision] " .. message, level or vim.log.levels.INFO)
end

local function get_chat(bufnr)
  local ok, cc = pcall(require, "maxa")
  if not ok or type(cc.buf_get_chat) ~= "function" then
    return nil
  end
  local found, chat = pcall(cc.buf_get_chat, bufnr)
  return found and type(chat) == "table" and chat or nil
end

local function soft_stop()
  return require("maxa.lifecycle.chat_soft_stop")
end

local function live(chat, state)
  return not exiting and chat[STATE_KEY] == state and not state.terminal and vim.api.nvim_buf_is_valid(chat.bufnr)
end

local function is_subagent(chat)
  if type(chat) ~= "table" or chat._maxa_hidden_image_analysis then
    return false
  end
  return require("maxa.session.agent_identity").is_subagent(chat)
end

local function finish_round_limit(state)
  return state.finish_stage == "emergency" and policy().emergency_finish_rounds or policy().primary_finish_rounds
end

local function clear_active(chat, state, opts)
  opts = opts or {}
  state.terminal = true
  if active[chat.bufnr] == state then
    active[chat.bufnr] = nil
  end
  if chat[STATE_KEY] == state then
    chat[STATE_KEY] = nil
  end

  local waiters = state.completion_waiters or {}
  state.completion_waiters = nil
  if opts.resolve_completion == false or #waiters == 0 then
    return
  end
  local function resolve_when_idle()
    if exiting or not chat.bufnr or not vim.api.nvim_buf_is_valid(chat.bufnr) then
      return
    end
    if soft_stop().is_busy(chat) then
      vim.defer_fn(resolve_when_idle, 50)
      return
    end
    for _, callback in ipairs(waiters) do
      local ok, err = pcall(callback, chat)
      if not ok then
        notify("deferred completion callback failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end
  vim.schedule(resolve_when_idle)
end

function M.is_finishing(chat)
  local state = type(chat) == "table" and chat[STATE_KEY]
  return state ~= nil and not state.terminal and state.phase == "finishing"
end

-- SubAgent controllers normally treat on_completed as terminal. A token
-- decision can start at the preceding tool boundary after the next request is
-- already queued, so that completion belongs to this state machine until its
-- automatic finish or final user decision owns the terminal response.
function M.defer_completion(chat, callback)
  if type(chat) ~= "table" or type(callback) ~= "function" then
    return false
  end
  local state = chat[STATE_KEY]
  if not state or state.terminal or (state.phase ~= "waiting" and state.phase ~= "final_waiting") then
    return false
  end
  state.completion_waiters = state.completion_waiters or {}
  table.insert(state.completion_waiters, callback)
  return true
end

local function warning_usage(status, chat)
  local tokens = status and status.tokens or nil
  local used = tokens and tonumber(tokens.used) or nil
  local limit = tokens and tonumber(tokens.limit) or nil
  local adapter = chat and chat.adapter or nil
  if type(adapter) == "table" then
    local ok, limits = pcall(require, "maxa.session.model_limits")
    if ok then
      local model = limits.get_model_name(adapter)
      local name = type(adapter.name) == "string" and adapter.name or nil
      limit = limits.get_warning_threshold(model, name) or limit
    end
  end
  local percent
  if used and limit and limit > 0 then
    percent = math.floor((used / limit) * 100 + 0.5)
  else
    percent = tokens and tonumber(tokens.percent) or nil
  end
  return percent, used, limit
end

local function cancel_ask(chat, state)
  if not state.request_id or state.result_received then
    return
  end
  pcall(function()
    require("maxa.interactions.chat.tools.builtin.runtime.ask").cancel(
      chat,
      "token threshold decision cancelled",
      state.request_id
    )
  end)
end

local function fail_closed(chat, state, detail)
  if not live(chat, state) then
    return
  end
  clear_active(chat, state)
  cancel_ask(chat, state)
  -- Do not replace an in-progress drain with an idle latch: that would skip
  -- retry/loop cleanup and the pending tool completion boundary.
  local stop = soft_stop()
  if not stop.is_requested(chat) then
    stop.latch(chat)
  end
  notify(detail, vim.log.levels.ERROR)
end

local begin_finish
local start_final_prompt

local function finish_if_idle(chat, state)
  vim.schedule(function()
    if not live(chat, state) or state.phase ~= "finishing" or state.dispatching or state.rounds == 0 then
      return
    end
    if soft_stop().is_busy(chat) or chat._network_retry_timer or chat._network_retry_pending then
      return
    end
    local stop = soft_stop()
    if state.natural_done and not state.budget_blocked and not state.failed then
      if stop.is_owned_by(chat, BUDGET_STOP_OWNER) then
        stop.release(chat)
      end
      if not stop.is_latched(chat) then
        clear_active(chat, state)
        return
      end
    end
    if state.rounds >= finish_round_limit(state) or state.failed then
      -- The exhausted budget owns the boundary even if an ordinary user stop
      -- was toggled away while the request/tool batch was draining.
      stop.request_at_boundary(chat, BUDGET_STOP_OWNER)
    end
    if stop.is_requested(chat) then
      stop.finish(chat, "token_finish_ready")
    end
    if live(chat, state) and state.phase == "finishing" then
      clear_active(chat, state)
    end
  end)
end

begin_finish = function(chat, state, stage)
  -- A runtime finish request owns the next SubAgent completion instead of the
  -- response/tool boundary that triggered the threshold transition.
  state.completion_waiters = nil
  chat._maxa_token_decision_last_action = "finish"
  state.phase = "finishing"
  state.finish_stage = stage or "primary"
  state.rounds = 0
  state.natural_done = false
  state.budget_blocked = false
  state.failed = false
  state.applying = nil
  chat[CANCELLED_KEY] = nil
  local content = state.finish_stage == "emergency" and EMERGENCY_FINISH_MESSAGE
    or FINISH_MESSAGE:format(policy().primary_finish_rounds)
  local tag = state.finish_stage == "emergency" and "token_threshold_emergency_finish" or "token_threshold_finish"
  local ok, err = pcall(function()
    local config = require("maxa.config")
    chat:add_message({ role = config.constants.USER_ROLE, content = content }, {
      visible = false,
      _meta = { tag = tag },
      context = { token_threshold_decision = { action = "finish", stage = state.finish_stage } },
    })
    require("maxa.session.llm_error_recovery").begin_runtime_continuation(chat)
    soft_stop().release(chat)
    chat:submit({ auto_submit = true })
  end)
  if not ok then
    fail_closed(chat, state, "收尾启动失败: " .. tostring(err))
  elseif live(chat, state) and state.rounds == 0 then
    fail_closed(chat, state, "收尾未能发起模型请求")
  end
end

local function begin_compact(chat, state)
  -- Compaction resumes with a fresh model request; discard the completion that
  -- preceded the decision and let the resumed response complete normally.
  state.completion_waiters = nil
  chat._maxa_token_decision_last_action = "compact"
  state.phase = "compacting"
  soft_stop().release(chat)
  local ok, started = pcall(function()
    require("maxa.session.llm_error_recovery").begin_runtime_continuation(chat)
    return require("maxa.session.handoff_compaction").start(chat, function()
      -- The shared controller submits the successor; never resubmit this source.
      if live(chat, state) then clear_active(chat, state, { resolve_completion = false }) end
    end, function(err)
      fail_closed(chat, state, "压缩失败: " .. tostring(err))
    end)
  end)
  if not ok or started == false then
    fail_closed(chat, state, "压缩未能启动: " .. tostring(started))
  end
end

local function begin_continue(chat, state)
  chat._maxa_token_decision_last_action = "continue"
  state.phase = "continue_resume"
  soft_stop().release(chat)
  local ok, err = pcall(function()
    if state.instruction then
      local config = require("maxa.config")
      chat:add_message({ role = config.constants.USER_ROLE, content = state.instruction }, {
        visible = false,
        _meta = { tag = "token_threshold_user_instruction" },
        context = { token_threshold_decision = { action = "continue", source = "user_instruction" } },
      })
    end
    require("maxa.session.llm_error_recovery").begin_runtime_continuation(chat)
    chat:submit({ auto_submit = true })
  end)
  if not ok then
    fail_closed(chat, state, "继续会话失败: " .. tostring(err))
  elseif live(chat, state) then
    fail_closed(chat, state, "继续会话未能发起模型请求")
  end
end

local function apply_selection(chat, state)
  if not live(chat, state) or not state.selection or not state.soft_stopped or state.applying then
    return
  end
  state.applying = true
  -- SoftStopped fires inside finish()/tools_done(). Let that stack unwind
  -- before starting a new request or replacing history through compression.
  vim.schedule(function()
    if not live(chat, state) then
      return
    end
    if state.selection == "interrupt" then
      local terminal_subagent = state.phase == "final_waiting"
      chat._maxa_token_decision_last_action = "interrupt"
      clear_active(chat, state)
      notify("已按用户决策中断；可稍后手动提交继续。")
      if terminal_subagent and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
        vim.schedule(function()
          chat:dispatch("on_completed", { status = "token_threshold_interrupt" })
        end)
      end
    elseif state.selection == "compact" then
      begin_compact(chat, state)
    elseif state.selection == "finish" then
      begin_finish(chat, state, "primary")
    elseif state.selection == "handoff" then
      if not can_handoff(chat) then return fail_closed(chat, state, "只有可恢复的主会话或活动子代理可以交接") end
      state.completion_waiters = nil
      state.instruction = state.subagent and CHILD_HANDOFF_MESSAGE or HANDOFF_MESSAGE
      begin_continue(chat, state)
    else
      begin_continue(chat, state)
    end
  end)
end

local function selection_from_ask_result(value, allowed, accept_instruction)
  local selected = value
  if type(value) == "string" then
    selected = value:match('^用户选择了"([^"]+)"$') or value
  end
  local action = allowed[selected]
  if action then
    return type(action) == "string" and action or selected
  end
  if accept_instruction and type(selected) == "string" and vim.trim(selected) ~= "" then
    return "continue", selected
  end
  return nil
end

local function cancel(chat, state, destroyed, wait)
  if state.terminal then
    return
  end
  state.cancelled = true
  chat[CANCELLED_KEY] = true
  if destroyed then
    chat[CLOSED_KEY] = true
  end
  clear_active(chat, state, { resolve_completion = false })
  cancel_ask(chat, state)
  if not destroyed then
    local stop = soft_stop()
    stop.latch(chat)
    -- Other on_cancelled callbacks may clear the soft-stop latch. Reinstate
    -- only if no later manual submission has started a new operation.
    vim.schedule(function()
      if not exiting and not chat[STATE_KEY] and not stop.is_busy(chat) then
        stop.latch(chat)
      end
    end)
  end
end

local function install_chat_callbacks(chat)
  if chat[CALLBACKS_KEY] then
    return
  end
  chat[CALLBACKS_KEY] = true
  chat:add_callback("on_closed", function(self)
    self[CLOSED_KEY] = true
    if self[STATE_KEY] then
      cancel(self, self[STATE_KEY], true, false)
    end
  end)
  chat:add_callback("on_cancelled", function(self)
    self[CANCELLED_KEY] = true
    if self[STATE_KEY] then
      cancel(self, self[STATE_KEY], false, false)
    end
  end)
  chat:add_callback("on_ready", function(self)
    local state = self[STATE_KEY]
    if state and state.phase == "finishing" then
      finish_if_idle(self, state)
    end
  end)
end

local function start_prompt(chat, state, final_subagent_prompt)
  local message
  local choices
  local timeout
  local allowed
  if final_subagent_prompt then
    message = string.format(
      "⚠️ [Maxa] 子代理自动收尾预算已耗尽\nToken: %s / %s (%s%%)\n请选择后续操作。\n5 分钟内未选择，将自动中断当前会话。",
      tostring(state.used or "unknown"),
      tostring(state.limit or "unknown"),
      tostring(state.percent)
    )
    choices = {
      {
        { label = "🛑 中断当前会话", value = "interrupt" },
        { label = "🗜️ 压缩并继续", value = "compact" },
      },
    }
    timeout = 300
    allowed = { interrupt = true, compact = true }
    if can_handoff(chat) then
      table.insert(choices[1], { label = "🔀 交接到新会话继续", value = "handoff" })
      allowed.handoff = true
    end
  else
    message = string.format(
      "⚠️ [Maxa] 当前会话已达到 token 阈值\nToken: %s / %s (%s%%)\n请选择后续操作，或直接通过 Telegram / 当前 Chat 回复处理要求。",
      tostring(state.used or "unknown"),
      tostring(state.limit or "unknown"),
      tostring(state.percent)
    )
    choices = {
      {
        { label = "尽快收尾", value = "token 超限了，需要尽快收尾" },
        { label = "🗜️ 压缩并继续", value = "compact" },
        { label = "🛑 中断当前会话", value = "interrupt" },
      },
    }
    timeout = 0
    allowed = {
      ["token 超限了，需要尽快收尾"] = "finish",
      compact = true,
      continue = true,
      interrupt = true,
    }
    if can_handoff(chat) then
      table.insert(choices[1], { label = "🔀 交接到新会话继续", value = "handoff" })
      allowed.handoff = true
    end
  end

  state.request_id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(chat.bufnr)):sub(1, 32)
  local started, err = require("maxa.interactions.chat.tools.builtin.runtime.ask").start(chat, {
    mode = "choice",
    message = message,
    choices = choices,
    timeout = timeout,
  }, function(ok, value)
    if not live(chat, state) or state.result_received then
      return
    end
    state.result_received = true
    if not ok then
      if final_subagent_prompt and value == "ask timed out" then
        state.selection = "interrupt"
        return apply_selection(chat, state)
      end
      return fail_closed(chat, state, "ask 决策失败: " .. tostring(value))
    end
    state.selection, state.instruction = selection_from_ask_result(value, allowed, not final_subagent_prompt)
    if not state.selection then
      return fail_closed(chat, state, "ask 返回未知选择: " .. tostring(value))
    end
    apply_selection(chat, state)
  end, {
    request_id = state.request_id,
    internal = true,
  })
  if not started then
    fail_closed(chat, state, "无法启动 ask 决策: " .. tostring(err))
  end
end

start_final_prompt = function(chat, state)
  if not live(chat, state) then
    return
  end
  state.phase = "final_waiting"
  state.soft_stopped = true
  state.selection = nil
  state.instruction = nil
  state.applying = nil
  state.result_received = nil
  state.request_id = nil
  start_prompt(chat, state, true)
end

function M.check(chat, status)
  if type(chat) ~= "table" or exiting or chat[CLOSED_KEY] or chat._maxa_hidden_image_analysis
    or chat._handoff_compaction_runner then
    return false
  end
  local percent, used, limit = warning_usage(status, chat)
  if not percent then
    return false
  end
  if percent < policy().threshold_percent then
    if chat[STATE_KEY] == nil then
      chat[TRIGGERED_KEY] = nil
    end
    return false
  end
  if chat[TRIGGERED_KEY] or chat[STATE_KEY] then
    return false
  end

  local state = {
    chat = chat,
    phase = "waiting",
    percent = percent,
    used = used,
    limit = limit,
    subagent = is_subagent(chat),
  }
  chat._maxa_token_decision_last_action = nil
  chat[TRIGGERED_KEY] = true
  chat[STATE_KEY] = state
  active[chat.bufnr] = state
  install_chat_callbacks(chat)
  local stop = soft_stop()
  stop.request_at_boundary(chat)
  state.soft_stopped = stop.is_latched(chat) and not stop.is_requested(chat)
  if state.subagent then
    if state.soft_stopped then
      vim.schedule(function()
        if live(chat, state) then
          begin_finish(chat, state, "primary")
        end
      end)
    end
  else
    local ok, err = pcall(start_prompt, chat, state, false)
    if not ok then
      fail_closed(chat, state, "无法启动 ask 决策: " .. tostring(err))
    end
  end
  return true
end

local function call_callback(opts)
  if type(opts) == "table" and type(opts.callback) == "function" then
    local ok, err = pcall(opts.callback)
    if not ok then
      notify("auto-submit callback failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

function M.blocks_submit(chat, opts)
  if type(chat) == "table" and chat[CLOSED_KEY] then
    call_callback(opts)
    return true
  end
  if type(chat) == "table" and chat[CANCELLED_KEY] then
    if type(opts) == "table" and opts.auto_submit ~= true and not soft_stop().is_busy(chat) then
      chat[CANCELLED_KEY] = nil
    else
      call_callback(opts)
      return true
    end
  end
  local state = type(chat) == "table" and chat[STATE_KEY]
  if not state or state.terminal then
    return false
  end
  if
    (state.phase == "compact_resume" or state.phase == "continue_resume")
    and (not opts or opts.auto_submit == true)
  then
    return false
  end
  local limit = state.phase == "finishing" and finish_round_limit(state) or nil
  if state.phase ~= "finishing" or state.rounds >= limit then
    if state.phase == "waiting" and not state.soft_stopped then
      soft_stop().request_at_boundary(chat)
    end
    if state.phase == "finishing" then
      state.budget_blocked = true
    end
    call_callback(opts)
    if state.phase == "waiting" and not state.soft_stopped and not soft_stop().is_busy(chat) then
      soft_stop().finish(chat, "token_decision_waiting")
    elseif state.phase == "finishing" then
      finish_if_idle(chat, state)
    end
    return true
  end
  return false
end

function M.before_dispatch(chat, method)
  if M.blocks_submit(chat) then
    return false
  end
  local state = chat[STATE_KEY]
  if not state then
    return true
  end
  if state.phase == "compact_resume" or state.phase == "continue_resume" then
    clear_active(chat, state, { resolve_completion = false })
    return true
  end
  state.dispatching = true
  state.natural_done = false
  state.failed = false
  local adapter, raw = chat.adapter, chat.adapter.raw
  if method == "_submit_http" then
    adapter.raw = vim.list_extend(vim.deepcopy(raw or {}), { "--retry", "0" })
  end
  return true, { state = state, adapter = adapter, raw = raw, method = method }
end

function M.after_dispatch(chat, token, ok, result)
  if not token then
    return ok and result or nil
  end
  token.adapter.raw = token.raw
  token.state.dispatching = false
  if not live(chat, token.state) then
    return ok and result or nil
  end
  local handle = chat.current_request
  if not ok or not handle or (token.method == "_submit_http" and not handle.job) then
    chat.current_request = nil
    fail_closed(chat, token.state, "收尾模型请求未启动: " .. tostring(ok and "no request job" or result))
    if chat.ui then
      chat.ui:unlock_buf()
    end
    return nil
  end
  token.state.rounds = token.state.rounds + 1
  if token.state.rounds == finish_round_limit(token.state) then
    soft_stop().request_at_boundary(chat, BUDGET_STOP_OWNER)
  end
  return result
end

function M.should_cancel_tool_batch(chat)
  local state = type(chat) == "table" and chat[STATE_KEY]
  if not state or state.terminal or state.phase ~= "finishing" then
    return false
  end
  if state.finish_stage == "emergency" then
    return state.subagent
  end
  return state.finish_stage == "primary" and state.rounds >= policy().primary_finish_rounds
end

function M.should_resume_cancelled_tool_batch(chat)
  local state = type(chat) == "table" and chat[STATE_KEY]
  return state ~= nil
    and not state.terminal
    and state.phase == "finishing"
    and state.finish_stage == "emergency"
    and state.rounds < policy().emergency_finish_rounds
end

function M.before_done(chat)
  local state = chat[STATE_KEY]
  local reset_only = not chat.status or chat.status == ""
  if state and state.phase == "finishing" then
    state.failed = reset_only or chat.status == "error" or chat.status == "cancelling"
  end
  return state, reset_only
end

function M.after_done(chat, state, reset_only)
  if state and state.phase == "finishing" and reset_only then
    finish_if_idle(chat, state)
  end
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  local group = vim.api.nvim_create_augroup("MaxaTokenThresholdDecision", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AbilityHookToolCallsCompleted",
    callback = function(args)
      local data = args.data or {}
      local chat = get_chat(data.bufnr)
      if chat then
        M.check(chat, data._session_status)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIChatSoftStopped",
    callback = function(args)
      local state = active[(args.data or {}).bufnr]
      if not state then
        return
      end
      if state.phase == "finishing" then
        if
          state.natural_done
          and not state.budget_blocked
          and not state.failed
          and soft_stop().is_owned_by(state.chat, BUDGET_STOP_OWNER)
        then
          soft_stop().release(state.chat)
          return clear_active(state.chat, state)
        end
        if state.failed then
          return clear_active(state.chat, state)
        end
        if state.finish_stage == "primary" and state.rounds >= policy().primary_finish_rounds then
          if not state.subagent then
            state.chat._maxa_token_decision_last_action = "interrupt"
            clear_active(state.chat, state)
            notify("主会话收尾预算已耗尽，已中断；可稍后手动提交继续。")
            return
          end
          state.phase = "emergency_pending"
          return vim.schedule(function()
            if live(state.chat, state) then
              begin_finish(state.chat, state, "emergency")
            end
          end)
        end
        if state.finish_stage == "emergency" and state.rounds >= policy().emergency_finish_rounds then
          state.phase = "final_prompt_pending"
          return vim.schedule(function()
            if live(state.chat, state) then
              start_final_prompt(state.chat, state)
            end
          end)
        end
        clear_active(state.chat, state)
      elseif state.phase == "waiting" then
        state.soft_stopped = true
        if state.subagent then
          state.phase = "primary_pending"
          vim.schedule(function()
            if live(state.chat, state) then
              begin_finish(state.chat, state, "primary")
            end
          end)
        else
          apply_selection(state.chat, state)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIChatDone",
    callback = function(args)
      local state = active[(args.data or {}).bufnr]
      if state and state.phase == "finishing" then
        state.natural_done = true
        finish_if_idle(state.chat, state)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      local state = active[args.buf]
      if state then
        cancel(state.chat, state, true, false)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      exiting = true
      for _, state in pairs(vim.tbl_values(active)) do
        cancel(state.chat, state, true, true)
      end
    end,
  })
end

function M.reset_setup()
  for _, state in pairs(vim.tbl_values(active)) do
    if state.chat then
      cancel(state.chat, state, true, false)
    end
  end
  active = {}
  setup_done = false
  exiting = false
end

function M._test_warning_usage(status, chat)
  return warning_usage(status, chat)
end

function M._test_active()
  return active
end

return M
