local TOKEN_WARNING_STATE_KEY = "session_admin_token_warning"
local runtime_state_by_chat_id = {}

local THRESHOLDS = {
  -- { value = 75, level = "medium" },
  -- { value = 85, level = "high" },
  { value = 95, level = "critical" },
}

local function format_tokens(value)
  local n = tonumber(value)
  if not n then
    return "unknown"
  end
  n = math.floor(n)
  local s = tostring(n)
  local result = ""
  for i = 1, #s do
    result = result .. s:sub(i, i)
    if (#s - i) % 3 == 0 and i ~= #s then
      result = result .. ","
    end
  end
  return result
end

local function get_warning_usage(status, chat)
  local tokens = status and status.tokens or nil
  local used = tokens and tonumber(tokens.used) or nil
  local limit = tokens and tonumber(tokens.limit) or nil

  local adapter = chat and chat.adapter or nil
  if type(adapter) == "table" then
    local ok, model_limits = pcall(require, "maxa.session.model_limits")
    if ok then
      local model_name = model_limits.get_model_name(adapter)
      local adapter_name = type(adapter.name) == "string" and adapter.name or nil
      limit = model_limits.get_warning_threshold(model_name, adapter_name) or limit
    end
  end

  local percent
  if used and limit and limit > 0 then
    percent = math.floor((used / limit) * 100 + 0.5)
  else
    percent = tokens and tonumber(tokens.percent) or nil
  end
  return percent, limit
end

local function clear_warning_state(chat, chat_id)
  if chat_id then
    runtime_state_by_chat_id[chat_id] = nil
  end
  if chat then
    chat._session_admin_token_warning = nil
    if chat._meta then
      chat._meta[TOKEN_WARNING_STATE_KEY] = nil
    end
  end
end

local function get_threshold(percent)
  if not percent then
    return nil, nil
  end

  local matched = nil
  for _, threshold in ipairs(THRESHOLDS) do
    if percent >= threshold.value then
      matched = threshold
    end
  end
  if not matched then
    return nil, nil
  end
  return matched.level, matched.value
end

local function get_chat(ctx)
  if not ctx or not ctx.bufnr then
    return nil
  end

  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or not maxa_ai.buf_get_chat then
    return nil
  end

  local chat = maxa_ai.buf_get_chat(ctx.bufnr)
  if type(chat) ~= "table" then
    return nil
  end
  return chat
end

local function get_warning_state(chat, chat_id)
  if not chat then
    return runtime_state_by_chat_id[chat_id]
  end

  local runtime_state = chat._session_admin_token_warning
  if type(runtime_state) == "table" then
    return runtime_state
  end

  local meta_state = chat._meta and chat._meta[TOKEN_WARNING_STATE_KEY]
  if type(meta_state) == "table" then
    chat._session_admin_token_warning = meta_state
    return meta_state
  end

  return nil
end

local function already_warned(chat, chat_id, threshold)
  local state = get_warning_state(chat, chat_id)
  if not state then
    return false
  end

  local max_threshold = tonumber(state.max_threshold)
  if max_threshold and max_threshold >= threshold then
    return true
  end

  local warned = type(state.warned) == "table" and state.warned or {}
  return warned[tostring(threshold)] == true
end

local function mark_warned(chat, chat_id, threshold)
  local state = get_warning_state(chat, chat_id) or {}
  state.warned = type(state.warned) == "table" and state.warned or {}
  state.max_threshold = math.max(tonumber(state.max_threshold) or 0, threshold)

  -- 首次直达高档时，低档视为已覆盖，避免压缩后以外的降档重复提示。
  for _, item in ipairs(THRESHOLDS) do
    if item.value <= threshold then
      state.warned[tostring(item.value)] = true
    end
  end

  if chat_id then
    runtime_state_by_chat_id[chat_id] = state
  end

  if chat then
    chat._session_admin_token_warning = state
    chat._meta = chat._meta or {}
    chat._meta[TOKEN_WARNING_STATE_KEY] = state
  end
end

local function build_notice(status, level, percent, warning_limit)
  local tokens = status and status.tokens or {}
  local used = format_tokens(tokens.used)
  local limit = format_tokens(warning_limit or tokens.limit)
  local source = tokens.source or "unknown"
  local message_count = status and status.message_count or nil
  local json_bytes = status and status.messages_json_bytes or nil

  local base = string.format(
    "当前会话 token 使用约为 %s / %s（%s%%，source=%s）。",
    used,
    limit,
    tostring(percent or "unknown"),
    tostring(source)
  )
  if message_count or json_bytes then
    base = base
      .. string.format(
        "消息数=%s，messages_json_bytes=%s。",
        tostring(message_count or "unknown"),
        tostring(json_bytes or "unknown")
      )
  end

  if level == "critical" then
    return table.concat({
      "⚠️ [Token 95%] " .. base,
      "",
      '上下文已进入高风险区。进入 token 警告阶段后，若仍需继续执行，应调用 `@session:compact_self` 并提供 `instructions`。',
      "优先级：",
      "1. 如果当前任务即将自然完成，可以先控制输出并完成当前小阶段。",
      '2. 如果仍需继续较长工作，立即调用 `@session:compact_self` 并提供 `instructions`。',
      "3. 压缩后自检关键任务信息是否仍在上下文中；如缺失，主动重新加载。",
      "",
      "若调用 `compact_self`，`instructions` 必须明确保留：本轮用户请求原文、用户目标、任务约束、规则文档、当前方案、已修改文件、当前错误、关键决策和下一步计划。",
    }, "\n")
  elseif level == "high" then
    return table.concat({
      "⚠️ [Token 85%] " .. base,
      "",
      "上下文已接近高风险区。接下来应减少大段读取、长日志和冗长输出。",
      '如果本轮后仍需继续探索或进入新阶段，应调用 `@session:compact_self` 并提供 `instructions`。',
      "`instructions` 需保留本轮用户请求原文、当前任务目标、关键约束、已修改文件、当前错误、关键决策和下一步计划。",
    }, "\n")
  end

  return table.concat({
    "ℹ️ [Token 75%] " .. base,
    "",
    '上下文开始偏高。继续执行时请控制输出长度，避免无必要的大文件/大日志读取；若后续还要进入较长新阶段，应调用 `@session:compact_self`，并在 instructions 中保留本轮用户请求和关键任务信息。',
  }, "\n")
end

local function token_warning_meta(threshold, level)
  return {
    tag = "token_warning",
    source = "session.ToolCallsCompleted",
    threshold = threshold,
    level = level,
  }
end

return {
  load = "startup",
  scope = "global",
  inject_at = "pre",
  enabled = false,
  opts = {
    visible = false,
    ephemeral = true,
    meta = {
      tag = "token_warning",
      source = "session.ToolCallsCompleted",
    },
  },

  render = function(ctx)
    local status = ctx.data and ctx.data._session_status or nil
    local chat = get_chat(ctx)
    local percent, warning_limit = get_warning_usage(status, chat)
    local level, threshold = get_threshold(percent)
    if not level or not threshold then
      clear_warning_state(chat, ctx.chat_id)
      return nil
    end
    if already_warned(chat, ctx.chat_id, threshold) then
      return nil
    end
    mark_warned(chat, ctx.chat_id, threshold)

    local notice = build_notice(status, level, percent, warning_limit)
    local commitment
    if level == "critical" then
      commitment = table.concat({
        "我已进入 token 高风险处理状态：",
        "- 我会优先判断当前上下文相关性，并控制输出。",
        '- 若仍需继续较长工作，我会直接调用 `@session:compact_self` 并提供 `instructions`。',
        "- 我会在 instructions 中明确保留关键任务信息，并在压缩恢复后自检。",
        "- 处理完该 token 风险判断后，我会继续当前用户提交的任务。",
      }, "\n")
    elseif level == "high" then
      commitment = table.concat({
        '我会控制后续上下文增长；如果继续执行存在 token 风险，我会调用 `@session:compact_self` 并提供 `instructions`。',
        "完成该判断后，我会继续当前用户提交的任务。",
      }, "\n")
    else
      commitment =
        '我会注意控制上下文增长；如果后续继续工作存在 token 风险，我会调用 `@session:compact_self` 并提供 `instructions`；现在继续当前用户提交的任务。'
    end

    local meta = token_warning_meta(threshold, level)
    return {
      { role = "user", content = notice, _meta = meta },
      { role = "llm", content = commitment, _meta = meta },
    }
  end,
}
