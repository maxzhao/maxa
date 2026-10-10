-- llm_error_recovery.lua: LLM 错误恢复与 compact_self 后台调度模块
-- 监听所有 Chat 创建事件，处理 token limit 救援压缩、网络/限流重试、reasoning 签名污染修复，
-- 并在 LLM 调用 compact_self 后于当前回合 done 阶段触发静默压缩。
--
-- Token 阈值提醒已迁移到 session 的 ChatSubmitted AbilityHook（inject_at=pre）。
local M = {}

-- 是否已初始化
M._initialized = false

local token_usage = require("maxa.session.token_usage")

-- 共享错误分类与重试配置
local error_handler = require("maxa.session.llm_error_handler")
local history_core = require("maxa.session.history_core")

local function is_unsavable_chat(chat)
  local save_id = chat and chat.opts and chat.opts.save_id or nil
  return history_core.is_unsavable_save_id(save_id)
end

-- 错误模式和重试配置已移至 maxa.session.llm_error_handler 统一维护

--- 获取 adapter 名称
---@param adapter table adapter 对象
---@return string|nil adapter 名称
local function get_adapter_name(adapter)
  if not adapter then
    return nil
  end
  -- 优先使用 adapter.name
  if adapter.name and type(adapter.name) == "string" then
    return adapter.name
  end
  -- 其次尝试 adapter.schema.name
  if adapter.schema and adapter.schema.name then
    return adapter.schema.name
  end
  return nil
end

---@param adapter table|nil adapter 对象
---@return boolean
local function is_supported_openai_responses_backend(adapter)
  return error_handler.is_supported_openai_responses_backend(adapter)
end

local function capture_adapter_stream_error(chat, data)
  local adapters = require("maxa.adapters")
  local parse_error = adapters.get_handler(chat.adapter, "parse_error")
  if type(parse_error) ~= "function" then
    return
  end
  local ok, stream_error = pcall(parse_error, chat.adapter, data)
  if ok and type(stream_error) == "string" and stream_error ~= "" then
    chat._last_http_error = stream_error
    chat._last_http_error_time = vim.loop.now()
    chat._last_stream_error = stream_error
  end
end

-- Forward declaration (定义在后面)
local estimate_tokens

--- 估算消息的 token 数量
--- 中文和代码混合内容约 2.5 字符 ≈ 1 token
--- reasoning 按 adapter_form_messages 的实际发送规则计数：
---   - _meta.reasoning_tainted 的不计入（被剥离）
---   - 仅计入最近 MAX_REASONING_TURNS 轮 user 消息之后的 reasoning
---@param messages table 消息列表
---@return number 估算的 token 数量
estimate_tokens = function(messages)
  local total_chars = 0

  -- 计算 reasoning 的截断点（与 adapter_form_messages 逻辑一致）
  local max_turns = require("maxa.adapters.behavior").MAX_REASONING_TURNS
  local reasoning_cutoff_idx = 0 -- 此索引之前的 reasoning 不计入
  if max_turns and max_turns > 0 then
    local user_count = 0
    for i = #messages, 1, -1 do
      if messages[i].role == "user" then
        user_count = user_count + 1
        if user_count >= max_turns then
          reasoning_cutoff_idx = i
          break
        end
      end
    end
  end

  for i, msg in ipairs(messages) do
    if msg.content then
      total_chars = total_chars + #msg.content
    end
    -- tool_calls 也计入
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc["function"]
        if fn and fn.arguments then
          total_chars = total_chars + #fn.arguments
        end
      end
    end
    -- reasoning 计入（排除 tainted 和超出轮数截断的）
    if msg.reasoning and msg.reasoning.content then
      local tainted = msg._meta and msg._meta.reasoning_tainted
      local before_cutoff = max_turns ~= nil and i < reasoning_cutoff_idx
      if not tainted and not before_cutoff then
        total_chars = total_chars + #msg.reasoning.content
      end
    end
  end
  -- 中文和代码混合内容约 2.5 字符 ≈ 1 token
  return math.floor(total_chars / 2.5)
end


-- =============================================================================
-- Adapter 特定检测策略
-- =============================================================================

-- COPILOT_INVALID_SIGNATURE_PATTERNS 已移至 maxa.session.llm_error_handler

--- 检测结果类型
---@alias DetectResult "token_limit" | "network_issue" | "rate_limited" | "invalid_signature" | "permanent" | nil

--- 检测策略: kiro_anthropic
--- 基于 output 为空且 token 使用率判断是 token 超限还是网络问题
--- kiro_anthropic 在 token 超限时返回空 output，status 为 success
---@param chat table Chat 实例
---@param context table 检测上下文 {output_empty, status, last_error, has_tools}
---@return DetectResult 检测结果: "token_limit" | "network_issue" | nil
local function detect_kiro_anthropic(chat, context)
  -- 仅当 output 为空时才检测
  if not context.output_empty then
    return nil
  end

  -- 如果有 tool_calls，这是正常的工具调用响应，不是问题
  if context.has_tools then
    return nil
  end

  -- kiro_anthropic: status 必须为 "success" 才进行检测
  -- 空 status 或其他状态不处理（可能是取消、超时等）
  if context.status ~= "success" then
    return nil
  end

  local usage = token_usage.get_usage(chat)
  local usage_ratio = usage and usage.ratio

  -- 如果共享 token 数据不可用，回退到消息估算值；分母仍使用共享 context window 规则。
  if not usage_ratio and chat.messages then
    local max_tokens = token_usage.get_context_window(chat)
    if max_tokens then
      local tokens = estimate_tokens(chat.messages)
      if tokens > 0 then
        usage_ratio = tokens / max_tokens
      end
    end
  end

  -- 使用率 >= 80% 且 output 为空时，判定为 token 超限
  if usage_ratio and usage_ratio >= 0.80 then
    return "token_limit"
  end

  -- status 为 success 但 output 为空且 token < 80%，判定为网络问题
  return "network_issue"
end


--- 检查 messages 末尾是否为 tool result
--- 工具执行完后 LLM 返回空文本是正常行为（模型无话可说），不应判定为网络问题
---@param chat table Chat 实例
---@return boolean 末尾是否为 tool result
local function last_message_is_tool_result(chat)
  if not chat.messages or #chat.messages == 0 then
    return false
  end
  local last_msg = chat.messages[#chat.messages]
  return last_msg.role == "tool"
end

---Detect failures surfaced by retained OpenAI Responses-compatible backends.
---@param chat table Chat instance
---@param context table Detection context
---@return DetectResult
local function detect_openai_responses(chat, context)
  if context.last_error then
    -- 统一分类 HTTP 错误。
    local error_type = error_handler.classify_http_error(context.last_error, chat.adapter)
    -- 已识别类型直接返回（token_limit, invalid_signature, network_issue）。
    -- nil（未识别错误）也直接返回 → 不重试
    return error_type
  end

  -- The HTTP client marked an error but no detailed response was captured.
  -- 此时 output 为空且 HTTP hook 可能未捕获到错误详情（如 curl SSL 错误）
  -- 典型场景：curl: (92) SSL 证书错误
  if context.status == "error" and context.output_empty then
    return "network_issue"
  end

  -- An empty successful response without tool calls is a transient backend failure.
  if context.output_empty and not context.has_tools and not context.last_error then
    -- 如果 messages 末尾是 tool result，说明是工具执行完后 LLM 的正常空响应
    -- 不应判定为网络问题（模型可能对工具结果无话可说）
    if last_message_is_tool_result(chat) then
      return nil
    end
    -- 非工具结果后的空响应 = 网络/初始化问题
    -- 典型场景：Timeout waiting for models（setup 阶段超时，不走 HTTP 错误路径）
    return "network_issue"
  end

  -- 兜底：空响应 + 无 tool_calls = 异常，宁可重试
  -- 不带 tool 的空消息是不允许的，一般出现就是错误
  -- 典型场景：未知类型的 HTTP 错误 + output 为空
  if context.output_empty and not context.has_tools then
    return "network_issue"
  end

  return nil
end

-- 支持的 adapter 检测策略映射表
local ADAPTER_DETECTORS = {
  kiro_anthropic = detect_kiro_anthropic,
  kiro_anthropic_thinking = detect_kiro_anthropic,
}

--- 解析 adapter 对应的检测器
---OpenAI Responses gateways share the same protocol-level detector.
---@param adapter table
---@return function|nil
local function resolve_detector(adapter)
  local adapter_name = get_adapter_name(adapter)
  if not adapter_name then
    return nil
  end

  -- 精确匹配优先
  local detector = ADAPTER_DETECTORS[adapter_name]
  if detector then
    return detector
  end

  -- 协议级匹配：OpenAI Responses 后端共享同一检测策略，provider 专有错误由 llm_error_handler 继续细分
  if is_supported_openai_responses_backend(adapter) then
    return detect_openai_responses
  end
  return nil
end

--- 检测问题类型
---@param chat table Chat 实例
---@param context table 检测上下文 {output_empty, status, last_error}
---@return DetectResult 检测结果: "token_limit" | "network_issue" | nil
local function detect_issue(chat, context)
  if not chat then
    return nil
  end

  local adapter_name = get_adapter_name(chat.adapter)
  if not adapter_name then
    return nil
  end

  local detector = resolve_detector(chat.adapter)
  if not detector then
    -- 不支持的 adapter，不进行自动检测
    return nil
  end

  return detector(chat, context)
end

--- 执行静默压缩
---@param chat table Chat 实例
---@param on_success function 成功回调
---@param on_error function 失败回调
---@param opts table|nil 额外选项（会与 { auto_submit = true } 合并）
local function execute_silent_compact(chat, on_success, on_error, opts)
  local ok, compaction = pcall(require, "maxa.session.handoff_compaction")
  if not ok then return on_error("无法加载 handoff_compaction: " .. tostring(compaction)) end
  -- Commit restores orchestration before closing the source; continuation is
  -- owned solely by the successor, not a delayed submit on this Chat.
  return compaction.start(chat, on_success, on_error, opts or {})
end

--- 获取网络重试延迟（秒）
---@param retry_count number 当前重试次数（0-based）
---@return number 延迟秒数
local function get_retry_delay(retry_count)
  return error_handler.get_retry_delay(error_handler.TYPES.NETWORK, retry_count) or 10
end

--- 取消挂起的重试 timer
---@param chat table Chat 实例
local function cancel_retry_timer(chat)
  if chat._network_retry_timer then
    pcall(vim.fn.timer_stop, chat._network_retry_timer)
    chat._network_retry_timer = nil
  end
  if chat._rate_limited_countdown_timer then
    pcall(vim.fn.timer_stop, chat._rate_limited_countdown_timer)
    chat._rate_limited_countdown_timer = nil
  end
end

--- 触发网络重试
---@param chat table Chat 实例
---@param adapter_name string adapter 名称
---@return boolean 是否触发了重试
local function fire_retry_state_changed(chat, retry_count, max_retries, adapter_name)
  if not chat or not chat.bufnr then
    return
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = "MaxaAIChatRetryStateChanged",
    data = {
      bufnr = chat.bufnr,
      id = chat.id,
      retry_count = retry_count or 0,
      max_retries = max_retries,
      adapter = adapter_name,
    },
  })
end

local function soft_stop_latched(chat)
  local ok, soft_stop = pcall(require, "maxa.lifecycle.chat_soft_stop")
  return ok and soft_stop and type(soft_stop.is_latched) == "function" and soft_stop.is_latched(chat)
end

local function token_finishing(chat)
  local decision = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
  return decision and decision.is_finishing(chat) or false
end

local function trigger_network_retry(chat, adapter_name)
  if soft_stop_latched(chat) then
    return false
  end
  -- 同一次请求可能从 stream error 和 done 两条路径重复完成。已有等待 timer 时
  -- 必须复用该重试，不能再创建一个并行提交链。
  if chat._network_retry_timer then
    return true
  end

  -- 初始化重试计数
  chat._network_retry_count = chat._network_retry_count or 0

  -- 检查是否超过最大重试次数
  local network_config = error_handler.RETRY_CONFIGS.network_issue
  if chat._network_retry_count >= network_config.max_retries then
    local detail = chat._network_retry_last_detail or "no detail captured"
    vim.notify(
      string.format(
        "[llm_error_recovery] ❌ 网络重试已达上限 (%d 次)，停止重试。adapter: %s, 诊断: %s",
        network_config.max_retries,
        adapter_name,
        detail
      ),
      vim.log.levels.ERROR
    )
    -- 重置计数，让用户下次手动提交时可以重新开始
    chat._network_retry_count = 0
    chat._network_retry_pending = false
    chat._network_retry_last_detail = nil
    fire_retry_state_changed(chat, 0, network_config.max_retries, adapter_name)
    -- 设置耗尽标记，让 repeat 等循环机制知道这次 on_completed 是空响应
    -- 标记会在下次成功响应时由 reset_network_retry 清除
    chat._network_retry_exhausted = true
    return false
  end

  -- 计算延迟
  local delay = get_retry_delay(chat._network_retry_count)
  chat._network_retry_count = chat._network_retry_count + 1

  local detail = chat._network_retry_last_detail or ""
  vim.notify(
    string.format(
      "[llm_error_recovery] 检测到网络问题（%s），%d 秒后重试 (%d/%d)... [%s]",
      adapter_name,
      delay,
      chat._network_retry_count,
      network_config.max_retries,
      detail
    ),
    vim.log.levels.INFO
  )

  -- 设置重试标记，防止 submit hook 重置计数
  chat._network_retry_pending = true
  fire_retry_state_changed(chat, chat._network_retry_count, network_config.max_retries, adapter_name)

  -- 关键：手动重置 chat 状态，模拟 done() 方法的状态清理
  -- done() 会做: self.current_request = nil + reset()
  -- reset() 会做: self.status = "" + self.ui:unlock_buf()
  -- 注意：设置虚拟 current_request 而非 nil，使 stop keymap guard 通过，
  -- 让用户可以通过 Ctrl+C → stop() → done(status="stopped") 取消等待。
  local retry_wait_request = { cancel = function() end }
  chat.current_request = retry_wait_request
  chat.status = ""
  chat.ui:unlock_buf()

  -- 延迟后重新提交（保存 timer id 以支持 Ctrl+C 取消）
  local retry_timer
  retry_timer = vim.fn.timer_start(delay * 1000, function()
    if chat._network_retry_timer == retry_timer then
      chat._network_retry_timer = nil
    end
    vim.schedule(function()
      -- 只允许仍持有本次等待占位符的 timer 提交。若其他机制已经发起请求，
      -- 不能清空其 current_request，否则会让同一会话并行执行多个请求。
      if chat.current_request ~= retry_wait_request then
        return
      end
      chat.current_request = nil

      -- 检查 chat 是否仍然有效且未被用户取消
      if not (chat and chat.submit) or chat._network_retry_cancelled then
        return
      end

      -- 防御：重试 submit 不能静默失败。之前这里直接调用 chat:submit，若 submit
      -- wrapper/MaxaAI 内部抛错，错误只会出现在 schedule callback 中，重试链路
      -- 就此断开，表现为“工具完成后提示 1/5 重试，然后不再运转”。
      local ok_submit, submit_err = pcall(function()
        chat:submit({ auto_submit = true })
      end)

      if not ok_submit then
        chat._network_retry_last_detail = "retry_submit_error=" .. tostring(submit_err)
        vim.notify(
          string.format("[llm_error_recovery] 网络重试提交失败（%s）: %s", adapter_name, tostring(submit_err)),
          vim.log.levels.ERROR
        )
        -- 继续走统一网络重试上限逻辑，避免静默卡死
        trigger_network_retry(chat, adapter_name)
        return
      end

      -- 如果 submit 返回后没有创建 current_request，说明被某个 wrapper early-return。
      -- 这不是正常的 HTTP 失败路径，done hook 不会再被触发，因此需要显式继续重试/报错。
      if not chat.current_request and not soft_stop_latched(chat) then
        chat._network_retry_last_detail = "retry_submit_no_request"
        vim.notify(
          string.format("[llm_error_recovery] 网络重试未发起请求（%s），继续重试", adapter_name),
          vim.log.levels.WARN
        )
        trigger_network_retry(chat, adapter_name)
      end
    end)
  end)
  chat._network_retry_timer = retry_timer

  return true
end

--- 在 chat buffer 中显示等待消息（extmark 虚拟文本）
---@param chat table Chat 实例
---@param message string 等待消息文本
---@return number|nil extmark_id
local function show_wait_message(chat, message)
  if not chat.bufnr or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return nil
  end

  -- pcall because buffer may be locked by MaxaAI
  local ok, mark_id = pcall(function()
    local ns = vim.api.nvim_create_namespace("llm_retry_wait")
    local line_count = vim.api.nvim_buf_line_count(chat.bufnr)

    -- Append a blank line and place the virtual text there
    vim.api.nvim_buf_set_lines(chat.bufnr, line_count, line_count, false, { "" })
    local id = vim.api.nvim_buf_set_extmark(chat.bufnr, ns, line_count, 0, {
      virt_text = { { message, "DiagnosticWarn" } },
      virt_text_pos = "overlay",
    })

    -- Auto-scroll to bottom
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == chat.bufnr then
        pcall(vim.api.nvim_win_set_cursor, win, { line_count + 1, 0 })
      end
    end

    return id
  end)

  return ok and mark_id or nil
end

--- 清除等待消息
---@param chat table Chat 实例
local function clear_wait_message(chat)
  if not chat.bufnr or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return
  end

  local ns = vim.api.nvim_create_namespace("llm_retry_wait")
  pcall(vim.api.nvim_buf_clear_namespace, chat.bufnr, ns, 0, -1)

  -- Remove the blank line we added (last line if empty)
  -- pcall because buffer may be locked by MaxaAI
  pcall(function()
    local line_count = vim.api.nvim_buf_line_count(chat.bufnr)
    if line_count > 0 then
      local last_line = vim.api.nvim_buf_get_lines(chat.bufnr, line_count - 1, line_count, false)
      if last_line[1] and last_line[1] == "" then
        vim.api.nvim_buf_set_lines(chat.bufnr, line_count - 1, line_count, false, {})
      end
    end
  end)
end

--- 重置网络重试计数
---@param chat table Chat 实例
local function reset_network_retry(chat)
  cancel_retry_timer(chat)
  chat._network_retry_count = 0
  chat._network_retry_pending = false
  chat._network_retry_cancelled = false
  chat._network_retry_last_detail = nil
  chat._network_retry_exhausted = nil
  chat._rate_limited_retry_count = 0
  clear_wait_message(chat)
  fire_retry_state_changed(chat, 0)
end

--- 触发 rate_limited 延迟重试
--- 使用 llm_error_handler 的统一重试策略，期间在 chat buffer 显示倒计时
---@param chat table Chat 实例
---@param adapter_name string adapter 名称
---@return boolean 是否触发了重试
local function trigger_rate_limited_retry(chat, adapter_name)
  if soft_stop_latched(chat) then
    return false
  end
  -- done/stream error 可能针对同一次失败重复进入；只允许一个等待 timer。
  if chat._network_retry_timer then
    return true
  end

  -- 初始化重试计数
  chat._rate_limited_retry_count = chat._rate_limited_retry_count or 0
  local rl_config = error_handler.RETRY_CONFIGS.rate_limited

  if chat._rate_limited_retry_count >= rl_config.max_retries then
    vim.notify(
      string.format(
        "[llm_error_recovery] ❌ Rate limited 重试已达上限 (%d 次)，停止重试。adapter: %s",
        rl_config.max_retries,
        adapter_name
      ),
      vim.log.levels.ERROR
    )
    chat._rate_limited_retry_count = 0
    chat._network_retry_exhausted = true
    fire_retry_state_changed(chat, 0, rl_config.max_retries, adapter_name)
    return false
  end

  local delay = error_handler.get_retry_delay(error_handler.TYPES.RATE_LIMITED, chat._rate_limited_retry_count)
  if not delay then
    vim.notify(
      string.format(
        "[llm_error_recovery] ❌ Rate limited 重试已达上限 (%d 次)，停止重试。adapter: %s",
        rl_config.max_retries,
        adapter_name
      ),
      vim.log.levels.ERROR
    )
    chat._rate_limited_retry_count = 0
    chat._network_retry_exhausted = true
    fire_retry_state_changed(chat, 0, rl_config.max_retries, adapter_name)
    return false
  end

  chat._rate_limited_retry_count = chat._rate_limited_retry_count + 1
  fire_retry_state_changed(chat, chat._rate_limited_retry_count, rl_config.max_retries, adapter_name)

  -- 手动重置 chat 状态
  -- 注意：设置虚拟 current_request 而非 nil，使 stop keymap guard 通过，
  -- 让用户可以通过 Ctrl+C → stop() → done(status="stopped") 取消等待。
  local retry_wait_request = { cancel = function() end }
  chat.current_request = retry_wait_request
  chat.status = ""
  chat.ui:unlock_buf()

  -- 显示初始等待消息
  local remaining = delay
  show_wait_message(
    chat,
    string.format("⏳ 所有账户被限流，%d 秒后重试 (%d/%d)...", remaining, chat._rate_limited_retry_count, rl_config.max_retries)
  )

  -- 倒计时更新 timer (每 10 秒更新一次)。10 秒等待无需刷新，避免 repeat=0 的边界行为。
  if delay > 10 then
    chat._rate_limited_countdown_timer = vim.fn.timer_start(10000, function()
      remaining = remaining - 10
      if remaining > 0 and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
        vim.schedule(function()
          clear_wait_message(chat)
          show_wait_message(chat, string.format("⏳ 所有账户被限流，%d 秒后重试...", remaining))
        end)
      end
    end, { ["repeat"] = math.floor(delay / 10) - 1 })
  end

  -- 主重试 timer
  local retry_timer
  retry_timer = vim.fn.timer_start(delay * 1000, function()
    if chat._network_retry_timer == retry_timer then
      chat._network_retry_timer = nil
    end
    if chat._rate_limited_countdown_timer then
      pcall(vim.fn.timer_stop, chat._rate_limited_countdown_timer)
      chat._rate_limited_countdown_timer = nil
    end
    vim.schedule(function()
      -- 只有仍持有本次等待占位符时才能提交；其他请求已经接管会话时直接放弃。
      if chat.current_request ~= retry_wait_request then
        return
      end
      clear_wait_message(chat)
      chat.current_request = nil
      if not (chat and chat.submit) or chat._network_retry_cancelled then
        return
      end

      vim.notify(
        string.format("[llm_error_recovery] ⏳ Rate limited 重试中... adapter: %s", adapter_name),
        vim.log.levels.INFO
      )
      chat._network_retry_pending = true
      local ok_submit, submit_err = pcall(function()
        chat:submit({ auto_submit = true })
      end)
      if not ok_submit then
        chat._network_retry_last_detail = "rate_limited_retry_submit_error=" .. tostring(submit_err)
        vim.notify(
          string.format("[llm_error_recovery] Rate limited 重试提交失败（%s）: %s", adapter_name, tostring(submit_err)),
          vim.log.levels.ERROR
        )
        trigger_rate_limited_retry(chat, adapter_name)
        return
      end
      if not chat.current_request and not soft_stop_latched(chat) then
        chat._network_retry_last_detail = "rate_limited_retry_submit_no_request"
        trigger_rate_limited_retry(chat, adapter_name)
      end
    end)
  end)
  chat._network_retry_timer = retry_timer

  vim.notify(
    string.format(
      "[llm_error_recovery] ⏳ 所有账户被限流（%s），%d 秒后重试 (%d/%d)",
      adapter_name,
      delay,
      chat._rate_limited_retry_count,
      rl_config.max_retries
    ),
    vim.log.levels.WARN
  )

  return true
end

--- 触发 LLM 主动请求的压缩流程 (Layer 2: compact_self)
---@param chat table Chat 实例
---@param original_done function 原始 done 方法
---@param output any 输出
---@param reasoning any 推理
---@param tools any 工具
---@param meta any 元数据
---@param opts any 选项
---@param instructions string LLM 提供的压缩指示
local function trigger_self_compact(chat, original_done, output, reasoning, tools, meta, opts, instructions)
  vim.notify("[llm_error_recovery] LLM 主动请求压缩 (compact_self)", vim.log.levels.INFO)

  chat._auto_compact_in_progress = true
  chat._last_http_error = nil

  local original_dispatch = chat.dispatch

  chat.dispatch = function(dispatch_self, event, ...)
    if dispatch_self._auto_compact_in_progress then
      if event == "on_completed" or event == "on_error" then
        return dispatch_self
      end
    end
    return original_dispatch(dispatch_self, event, ...)
  end

  -- 调用原始 done 以重置 chat 状态
  -- ⚠️ 关键 1：传 nil 替代 tools，避免 MaxaAI 再次执行 tool_calls
  -- 工具已由 MCPHub 工具系统在 done() 之前执行过。若传入 tools，
  -- MaxaAI 的 done() 会调用 self.tools:execute()（异步），
  -- 与后续的 do_compact 并行修改 messages → 竞态条件。
  -- ⚠️ 保留 output 和 reasoning：LLM 在调用 compact_self 后输出的文本
  -- 通常包含进度总结和后续工作规划，是有价值的上下文。
  -- output 文本仍作为来源上下文保留；交接执行器按来源索引选择原始记录，
  -- 最终 handoff goal 明确恢复业务任务而非继续压缩。
  original_done(chat, output, reasoning, nil, meta, opts)

  -- 执行静默压缩（带 LLM 压缩指示）
  execute_silent_compact(chat, function()
    chat.dispatch = original_dispatch
    chat._auto_compact_in_progress = nil
    vim.notify("[llm_error_recovery] compact_self 压缩完成，继续执行", vim.log.levels.INFO)
  end, function(compact_err)
    chat.dispatch = original_dispatch
    chat._auto_compact_in_progress = nil

    local error_msg = string.format("[compact_self] 压缩失败: %s", tostring(compact_err))
    vim.notify("[llm_error_recovery] " .. error_msg, vim.log.levels.ERROR)

    chat._auto_compact_error = error_msg
    chat:dispatch("on_error", error_msg)
  end, { instructions = instructions })
end

--- 触发自动压缩流程
---@param chat table Chat 实例
---@param original_done function 原始 done 方法
---@param output any 输出
---@param reasoning any 推理
---@param tools any 工具
---@param meta any 元数据
---@param opts any 选项
---@param adapter_name string adapter 名称
local function trigger_token_limit_compact(chat, original_done, output, reasoning, tools, meta, opts, adapter_name)
  vim.notify(
    string.format("[llm_error_recovery] 检测到 token 超限（%s），正在自动压缩...", adapter_name),
    vim.log.levels.INFO
  )

  -- 设置标记
  chat._auto_compact_in_progress = true

  -- 清除捕获的错误信息
  chat._last_http_error = nil

  -- =====================================================================
  -- 关键：临时 Hook dispatch 方法，阻止超限时的 on_completed 被分发
  -- 只拦截压缩期间的这一次 on_completed，压缩完成后恢复正常流程
  -- =====================================================================
  local original_dispatch = chat.dispatch

  chat.dispatch = function(dispatch_self, event, ...)
    -- 压缩进行中：阻止 on_completed 和 on_error
    if dispatch_self._auto_compact_in_progress then
      if event == "on_completed" or event == "on_error" then
        return dispatch_self
      end
    end
    return original_dispatch(dispatch_self, event, ...)
  end

  -- 调用原始 done 以重置 chat 状态（MaxaAI 会调用 reset()）
  -- on_completed/on_error 会被我们的 hook 拦截，不会触发 agent_executor 的回调
  -- ⚠️ 传 nil 替代 tools，防御性修复：token 超限时 tools 通常为空，
  -- 但若 LLM 在同一回合既超限又返回了 tool_calls，传入 tools 会导致竞态。
  original_done(chat, output, reasoning, nil, meta, opts)

  -- 执行静默压缩
  execute_silent_compact(chat, function()
    -- 成功：恢复 dispatch，清除标记
    -- 压缩完成后，ensure_user_message_and_submit 会调用 chat:submit()
    -- 后续流程完全正常，不需要任何额外拦截
    chat.dispatch = original_dispatch
    chat._auto_compact_in_progress = nil
    vim.notify("[llm_error_recovery] 压缩完成，继续执行", vim.log.levels.INFO)
  end, function(compact_err)
    -- 失败：恢复 dispatch，清除标记
    chat.dispatch = original_dispatch
    chat._auto_compact_in_progress = nil

    -- 构建明确的错误信息
    local error_msg =
      string.format("[Token 超限] 会话因 token 超限无法继续，自动压缩失败: %s", tostring(compact_err))
    vim.notify("[llm_error_recovery] " .. error_msg, vim.log.levels.ERROR)

    -- 设置错误标记，让 agent_executor 的 on_error 回调能获取到错误信息
    chat._auto_compact_error = error_msg

    -- 触发 on_error 而非 on_completed，让父代理知道是错误退出
    chat:dispatch("on_error", error_msg)
  end)
end

--- 检查 output 是否为空
---@param output any 输出
---@return boolean 是否为空
local function check_output_empty(output)
  if not output then
    return true
  elseif type(output) == "table" then
    if vim.tbl_isempty(output) then
      return true
    else
      local all_empty = true
      for _, v in ipairs(output) do
        if v and v ~= "" then
          all_empty = false
          break
        end
      end
      return all_empty
    end
  elseif type(output) == "string" then
    return output == ""
  end
  return false
end

--- Hook chat 的 _submit_http 方法，捕获 HTTP 错误信息到 chat 对象
--- 这样每个 chat 实例都有自己的错误信息，避免多会话冲突
---@param chat table Chat 实例
local function hook_submit_http_for_error_capture(chat)
  local original_submit_http = chat._submit_http
  if not original_submit_http then
    return
  end

  chat._submit_http = function(self, payload)
    -- 清除上次的错误信息
    self._last_http_error = nil
    self._last_http_error_time = nil
    self._last_http_status = nil

    self._last_stream_error = nil

    -- 获取 HTTP client 模块
    local http_ok, http_module = pcall(require, "maxa.http")
    if not http_ok then
      return original_submit_http(self, payload)
    end

    -- 获取原始的 Client.new
    local original_new = http_module.new
    if not original_new then
      return original_submit_http(self, payload)
    end

    -- 临时 hook http.new，注入我们的 on_error 包装
    local chat_ref = self -- 保存 chat 引用
    http_module.new = function(args)
      local client = original_new(args)
      if not client then
        return client
      end

      -- Capture callbacks only while their owning request remains active.
      local request_settled = false
      local original_send = client.send
      client.send = function(client_self, send_payload, opts)
        opts = opts or {}
        local original_on_error = opts.on_error

        local original_on_chunk = opts.on_chunk
        local original_on_done = opts.on_done
        opts.on_done = function(data, meta)
          if request_settled then return end
          request_settled = true
          if original_on_done then return original_on_done(data, meta) end
        end

        if require("maxa.adapters").get_handler(chat_ref.adapter, "parse_error") then
          opts.on_chunk = function(data, meta)
            if request_settled then return end
            capture_adapter_stream_error(chat_ref, data)
            if original_on_chunk then
              return original_on_chunk(data, meta)
            end
          end
        end

        -- 包装 on_error，捕获错误信息
        opts.on_error = function(err, meta)
          if request_settled then return end
          request_settled = true
          -- 存储错误信息到 chat 对象
          local error_str = error_handler.extract_error_string(err)
          if error_str and error_str ~= "" then
            chat_ref._last_http_error = error_str
            chat_ref._last_http_error_time = vim.loop.now()
          end
          -- 捕获 HTTP status code（用于区分 400 vs 其他错误）
          if type(err) == "table" then
            chat_ref._last_http_status = err.status or (type(err.stderr) == "table" and err.stderr.status) or nil
          end

          -- 调用原始 on_error
          if original_on_error then
            return original_on_error(err, meta)
          end
        end

        local handle = original_send(client_self, send_payload, opts)
        if handle and handle.cancel then
          local cancel = handle.cancel
          handle.cancel = function(...)
            request_settled = true
            return cancel(...)
          end
        end
        return handle
      end

      return client
    end

    -- 调用原始 _submit_http
    local ok, result = pcall(original_submit_http, self, payload)

    -- Restore even if request setup fails.
    http_module.new = original_new
    if not ok then error(result) end
    return result
  end
end

--- 判断 chat 是否需要安装 done hook
--- Layer 1 (token warning) 和 Layer 2 (compact_self) 只依赖 done hook，
--- 不要求 adapter 有专用 issue detector。
---@param chat table Chat 实例
---@return boolean
local function should_hook_chat(chat)
  local adapter = chat and chat.adapter
  local adapter_name = get_adapter_name(adapter)
  if not adapter_name then
    return false
  end

  -- 有 issue detector 的 adapter：需要 done hook 处理自动重试/自动压缩
  if resolve_detector(adapter) then
    return true
  end

  -- 其余只要支持 token 计数，也需要 done hook 处理 compact_self 自我压缩请求。
  if adapter and adapter.features and adapter.features.tokens then
    return true
  end

  return false
end

--- Hook 单个 chat 的 done 方法
---@param chat table Chat 实例
local function hook_chat_done(chat)
  -- 跳过已禁用自动压缩的会话
  if chat._auto_compact_disabled then
    return
  end

  -- 跳过已 hook 的会话
  if chat._auto_compact_hooked then
    return
  end

  -- 检查 adapter 类型
  local adapter_name = get_adapter_name(chat.adapter)

  -- 仅对需要 Layer 1/2/3 能力的 chat 安装 done hook
  if not should_hook_chat(chat) then
    return
  end

  chat._auto_compact_hooked = true

  -- Capture HTTP/SSE errors for OpenAI Responses-compatible backends.
  if is_supported_openai_responses_backend(chat.adapter) then
    hook_submit_http_for_error_capture(chat)
  end

  -- Hook submit 方法，用于区分用户主动提交和自动重试
  local original_submit = chat.submit
  chat.submit = function(self, ...)
    -- 标记：已经有过主动提交，启用网络重试检测
    self._has_submitted = true
    local submit_opts = select(1, ...) or {}
    -- A manual submit starts a new user-owned request after any previous soft
    -- stop/cancellation and must re-enable recovery for that new request.
    if submit_opts.auto_submit ~= true then
      self._network_retry_cancelled = false
    end
    -- 如果不是重试中，重置计数
    if not self._network_retry_pending then
      self._network_retry_count = 0
    end
    -- 清除重试标记
    self._network_retry_pending = false
    return original_submit(self, ...)
  end

  -- Hook stop 方法，防御层：确保等待重试期间 stop() 能正常执行
  -- 主修复在 trigger_*_retry 中设置虚拟 current_request，此处作为 fallback
  local original_stop = chat.stop
  chat.stop = function(self, ...)
    if self._network_retry_timer and not self.current_request then
      self.current_request = { cancel = function() end }
    end
    return original_stop(self, ...)
  end

  local original_done = chat.done
  chat.done = function(self, output, reasoning, tools, meta, opts)
    -- 再次检查（可能在回调注册后被标记）
    if self._auto_compact_disabled then
      if not self._enable_error_retry then
        return original_done(self, output, reasoning, tools, meta, opts)
      end
      -- _enable_error_retry 模式：仅启用 network/rate_limited 重试
      -- 跳过 Layer 1 (token warning) / Layer 2 (compact_self) / Layer 3 (auto compact)
    end

    -- 用户主动取消（Ctrl+C）：取消挂起的重试，跳过检测，直接走正常流程
    if opts and opts.status == "stopped" then
      cancel_retry_timer(self)
      self._network_retry_cancelled = true
      reset_network_retry(self)
      return original_done(self, output, reasoning, tools, meta, opts)
    end

    -- 子代理软中断（Ctrl+C on subagent buffer）：跳过网络问题检测
    -- window_manager.interrupt_handler 杀死 curl 后，on_error 回调会以空错误触发 done()
    -- Avoid treating the cancellation's empty output as a network issue.
    if self._subagent_interrupted then
      -- 清除已捕获的 HTTP 错误信息，防止影响下一次请求的检测
      self._last_http_error = nil
      self._last_http_error_time = nil
      self._last_http_status = nil
      return original_done(self, output, reasoning, tools, meta, opts)
    end

    -- Layer 2: LLM 主动请求压缩 (compact_self)
    if not self._auto_compact_disabled and self._self_compact_requested then
      local compact_instructions = self._self_compact_instructions or ""
      self._self_compact_requested = nil
      self._self_compact_instructions = nil
      if token_finishing(self) then
        vim.notify("[llm_error_recovery] 收尾通知不授权压缩，已跳过 compact_self", vim.log.levels.WARN)
        return original_done(self, output, reasoning, tools, meta, opts)
      end
      if is_unsavable_chat(self) then
        vim.notify(
          "[llm_error_recovery] 当前会话为 temporary/unsavable，会话历史不可保存，跳过 compact_self 自动压缩",
          vim.log.levels.WARN
        )
        return original_done(self, output, reasoning, tools, meta, opts)
      end
      trigger_self_compact(
        self,
        original_done,
        output,
        reasoning,
        tools,
        meta,
        opts,
        compact_instructions
      )
      return
    end

    -- 检查 output 是否为空
    local output_empty = check_output_empty(output)

    -- 获取 chat 对象上存储的 HTTP 错误信息
    local last_error = nil
    local last_http_status = nil
    if self._last_http_error and self._last_http_error_time then
      -- 检查错误是否在最近 5 秒内
      local now = vim.loop.now()
      if now - self._last_http_error_time < 5000 then
        last_error = self._last_http_error
        last_http_status = self._last_http_status
      end
      -- 清除已使用的错误信息
      self._last_http_error = nil
      self._last_http_error_time = nil
      self._last_http_status = nil
    end

    -- 检测问题类型
    local current_adapter_name = get_adapter_name(self.adapter)

    -- OpenAI Responses 中转后端 SSE error 兜底：
    -- 有些情况下 SSE error chunk 距离 done 超过 5 秒，会被上面的最近错误窗口过滤掉，
    -- 导致 context_length_exceeded 再次退化为空响应/network_issue。
    if not last_error and is_supported_openai_responses_backend(self.adapter) and self._last_stream_error then
      last_error = self._last_stream_error
    end
    self._last_stream_error = nil

    -- 检查是否有 tool_calls
    local has_tools = tools and not vim.tbl_isempty(tools)

    -- 构建检测上下文
    local context = {
      output_empty = output_empty,
      status = self.status,
      last_error = last_error,
      last_http_status = last_http_status,
      has_tools = has_tools,
    }

    local issue_type = detect_issue(self, context)

    if current_adapter_name and issue_type then
      if issue_type == "permanent" then
        reset_network_retry(self)
        self._network_retry_last_detail = "permanent_error=" .. tostring(last_error or "unknown")
      elseif issue_type == "invalid_signature" and not self._auto_compact_disabled and not soft_stop_latched(self) then
        -- Thinking 签名无效（账户切换导致）：在 _meta 中标记污染（epoch 边界）
        -- form_messages hook 会检查 _meta.reasoning_tainted，跳过这些消息的 reasoning
        -- 标记持久化到历史文件，跨 nvim 重启仍有效
        local tainted_count = 0
        for _, msg in ipairs(self.messages) do
          if msg.reasoning and not (msg._meta and msg._meta.reasoning_tainted) then
            msg._meta = msg._meta or {}
            msg._meta.reasoning_tainted = true
            tainted_count = tainted_count + 1
          end
        end
        if tainted_count == 0 then
          -- 所有 reasoning 已被标记污染，重试无意义（可能是其他原因的 400）
          -- 不重试，走正常错误流程
          vim.notify(
            string.format(
              "[llm_error_recovery] reasoning 已全部标记污染，400 错误非签名问题（%s）",
              current_adapter_name
            ),
            vim.log.levels.WARN
          )
        else
          vim.notify(
            string.format(
              "[llm_error_recovery] 检测到 reasoning 签名无效（%s），已标记 %d 条消息污染，重试中",
              current_adapter_name,
              tainted_count
            ),
            vim.log.levels.WARN
          )
          -- 重置 chat 状态并立即重试
          self.current_request = nil
          self.status = ""
          self.ui:unlock_buf()
          vim.defer_fn(function()
            if self and self.submit then
              self:submit({ auto_submit = true })
            end
          end, 100)
          return
        end
      elseif issue_type == "token_limit" then
        if token_finishing(self) then
          vim.notify("[llm_error_recovery] 收尾期间达到模型上下文上限，停止而不自动压缩", vim.log.levels.WARN)
        elseif self._auto_compact_disabled then
          vim.notify(
            string.format(
              "[llm_error_recovery] 检测到 token 超限（%s），但当前会话已禁用自动压缩，跳过自动压缩",
              current_adapter_name
            ),
            vim.log.levels.WARN
          )
        elseif is_unsavable_chat(self) then
          vim.notify(
            string.format(
              "[llm_error_recovery] 检测到 token 超限（%s），但当前会话为 temporary/unsavable，跳过自动压缩",
              current_adapter_name
            ),
            vim.log.levels.WARN
          )
        else
          -- Token 超限：重置重试计数，触发压缩
          reset_network_retry(self)
          trigger_token_limit_compact(self, original_done, output, reasoning, tools, meta, opts, current_adapter_name)
          return
        end
      elseif issue_type == "rate_limited" then
        -- Rate limited：使用共享的延迟重试预算。
        if self._has_submitted then
          local retried = trigger_rate_limited_retry(self, current_adapter_name)
          if retried then
            return
          end
        end
      elseif not issue_type and last_error and tostring(last_error):match("cyber_policy") then
        -- WebSee / OpenAI Responses 的策略类 SSE error 不是网络问题，不能无限重试；
        -- 但如果静默落到 original_done，Chat UI 会表现为“工具结束后不再运转”。
        -- 在这里显式提示并清理重试状态，让用户知道本轮停止的真实原因。
        reset_network_retry(self)
        vim.notify(
          string.format("[llm_error_recovery] 上游策略拒绝（%s），已停止自动续跑: %s", current_adapter_name, tostring(last_error)),
          vim.log.levels.ERROR
        )
      elseif issue_type == "network_issue" then
        -- 记录诊断详情，供重试耗尽时输出
        if last_error then
          -- 有明确的 HTTP 错误信息
          self._network_retry_last_detail = "http_error=" .. last_error
        elseif context.status == "error" then
          -- CC 标记了 error 但无 HTTP 错误详情（如 curl SSL 错误）
          self._network_retry_last_detail = "cc_status=error (no HTTP diagnostics available)"
        elseif output_empty and not context.has_tools then
          -- HTTP 成功但空响应 — 上游模型返回了空内容（可能是模型不可用、请求被截断等）
          self._network_retry_last_detail = "empty_response (HTTP OK but model returned no content)"
        else
          self._network_retry_last_detail =
            string.format("status=%s, output=%s", context.status or "nil", output_empty and "empty" or "present")
        end

        -- 网络问题：仅在本次会话有过主动提交时才重试
        -- 避免恢复历史会话时误触发重试
        if self._has_submitted then
          local retried = trigger_network_retry(self, current_adapter_name)
          if retried then
            -- 重试已触发，跳过 original_done
            return
          end
          -- 重试次数已用尽，继续正常流程
        end
      end
    end

    -- 成功响应或无问题：重置重试计数
    if not output_empty then
      reset_network_retry(self)
    end

    -- Token 阈值提醒已迁移到 session 的 ChatSubmitted AbilityHook（inject_at=pre），
    -- 这样提醒会在用户提交时进入本次 LLM 请求，而不是响应结束后滞后一轮注入。

    -- 调用原始 done
    return original_done(self, output, reasoning, tools, meta, opts)
  end
end

--- Cancel pending automatic recovery without dispatching MaxaAI's hard-stop lifecycle.
---@param chat table
---@param reason? string
function M.cancel_pending_retry(chat, reason)
  if type(chat) ~= "table" then
    return false
  end
  local had_pending = chat._network_retry_timer ~= nil
    or chat._rate_limited_countdown_timer ~= nil
    or chat._network_retry_pending == true
  cancel_retry_timer(chat)
  chat._network_retry_pending = false
  chat._network_retry_cancelled = true
  chat._network_retry_count = 0
  chat._rate_limited_retry_count = 0
  chat._network_retry_last_detail = nil
  chat._network_retry_exhausted = nil
  clear_wait_message(chat)
  fire_retry_state_changed(chat, 0, nil, reason or "cancelled")
  return had_pending
end

-- A trusted new runtime operation (rather than a fake manual submit) may
-- resume recovery after the preceding soft-stop cancelled its retry chain.
function M.begin_runtime_continuation(chat)
  M.cancel_pending_retry(chat, "runtime_continuation")
  chat._network_retry_cancelled = false
end

--- 初始化全局监控
function M.setup()
  if M._initialized then
    return
  end
  M._initialized = true

  -- Hook 已存在的会话
  local ok, chat_module = pcall(require, "maxa.interactions.chat")
  if ok and chat_module.buf_get_chat then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "maxa_ai" then
        local success, chat = pcall(chat_module.buf_get_chat, buf)
        if success and chat then
          hook_chat_done(chat)
        end
      end
    end
  end

  -- 监听 MaxaAIChatCreated 事件
  vim.api.nvim_create_autocmd("User", {
    pattern = "MaxaAIChatCreated",
    callback = function(args)
      -- 获取 chat 对象
      local chat_ok, chat_mod = pcall(require, "maxa.interactions.chat")
      if not chat_ok then
        return
      end

      local bufnr = args.data and args.data.bufnr
      if not bufnr then
        return
      end

      local success, chat = pcall(chat_mod.buf_get_chat, bufnr)
      if success and chat then
        local cc_utils_ok, cc_utils = pcall(require, "maxa.session.compaction_messages")
        if cc_utils_ok and not chat.opts._history_restored then
          -- 仅对没有显式 protected-prefix 配置的新建运行时会话兜底保护“真正的初始前缀”。
          -- 注意：不要用 #chat.messages 作为兜底值；历史恢复、restart-resume 或某些创建时序下
          -- chat 创建时可能已经带有大量历史消息，把它们整体标成 protected prefix 会导致无法压缩。
          -- mark_current_messages_as_protected_prefix() 内部只推断开头 system/rules 基础消息。
          local has_explicit_protected_prefix = chat.opts
            and chat.opts[cc_utils.PROTECTED_PREFIX_FIELD] ~= nil
          local current_count = cc_utils.get_protected_prefix_count(chat)
          if
            not has_explicit_protected_prefix
            and current_count <= 0
            and chat.messages
            and #chat.messages > 0
          then
            cc_utils.mark_current_messages_as_protected_prefix(chat)
          end
        end
        hook_chat_done(chat)
      end
    end,
  })
end

function M.reset_setup()
  M._initialized = false
end

if vim.g.maxa_test_mode then
  M._test_trigger_rate_limited_retry = trigger_rate_limited_retry
  M._test_hook_chat_done = hook_chat_done
end
return M
