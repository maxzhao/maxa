local COLLAPSE_RECOMMENDATION_STATE_KEY = "session_admin_collapse_recommendation"

local function get_status(ctx)
  return ctx and ctx.data and ctx.data._session_status or nil
end

local function should_consider_collapse(status)
  local tokens = status and status.tokens or {}
  local percent = tonumber(tokens.percent) or 0

  -- Hard lower token bound: collapse recommendation is only allowed after the
  -- session has reached a meaningful token pressure level.
  return percent >= 20
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
  return type(chat) == "table" and chat or nil
end

local function current_turn_key(ctx)
  local status = get_status(ctx)
  return table.concat({
    tostring(ctx and ctx.chat_id or "unknown"),
    tostring(status and status.message_count or "unknown"),
    tostring(status and status.messages_json_bytes or "unknown"),
  }, ":")
end

local function already_prompted_this_turn(chat, key)
  if not chat or not key then
    return false
  end
  local state = chat._session_admin_collapse_recommendation
  return type(state) == "table" and state.last_key == key
end

local function mark_prompted(chat, key)
  if not chat or not key then
    return
  end
  local state = { last_key = key }
  chat._session_admin_collapse_recommendation = state
  chat._meta = chat._meta or {}
  chat._meta[COLLAPSE_RECOMMENDATION_STATE_KEY] = state
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
      tag = "collapse_recommendation",
      source = "session.ChatSubmitted",
    },
  },

  render = function(ctx)
    if not (ctx.data and ctx.data.is_user_input == true) then
      return nil
    end

    local status = get_status(ctx)
    if not should_consider_collapse(status) then
      return nil
    end

    local chat = get_chat(ctx)
    local key = current_turn_key(ctx)
    if already_prompted_this_turn(chat, key) then
      return nil
    end
    mark_prompted(chat, key)

    local user_instruction = table.concat({
      "[Collapse 压缩推荐检查]",
      "在处理本轮用户请求前，先快速判断：当前用户任务是否与最近的大段历史会话关联不大，且旧上下文可安全摘要。",
      "",
      "规则：",
      "- 如果当前任务与最近历史高度相关、正在连续调试/实现，或上下文仍需保留：不要提压缩，直接继续用户任务。",
      "- 如果当前任务明显是新主题/新阶段，且最近历史大多可摘要：可以建议先执行 `collapse` 模式压缩，但必须先询问用户，不能自行调用压缩工具。",
      "- 如果用户不同意压缩或未明确同意：继续执行用户当前任务。",
      "- 这里只能推荐 `collapse`，不要推荐或主动使用 `destructive`。",
    }, "\n")

    local llm_commitment = table.concat({
      "我会静默做一次 collapse 相关性判断：",
      "- 相关性高或不值得压缩 → 不输出检查结果，直接继续用户任务。",
      "- 相关性低且压缩有价值 → 简短询问用户是否先进行 collapse 压缩。",
      "- 未获用户明确同意前，我不会调用任何压缩工具。",
    }, "\n")

    return {
      { role = "user", content = user_instruction, _meta = { tag = "collapse_recommendation" } },
      { role = "llm", content = llm_commitment, _meta = { tag = "collapse_recommendation" } },
    }
  end,
}
