-- get_messages: 按角色过滤读取会话消息，输出统一为 JSON
local history_core = require("maxa.session.history_core")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local is_tool_error = history_core.is_tool_error

-- 摘要模式的内容长度限制
local SUMMARY_MAX_LENGTH = 300
local TRUNCATE_SUFFIX = "...[truncated]"

--- 截断内容到指定长度
---@param content string|nil 原始内容
---@param max_length number 最大长度
---@return string|nil 截断后的内容
local function truncate_content(content, max_length)
  if not content or type(content) ~= "string" then
    return content
  end
  if #content <= max_length then
    return content
  end
  return content:sub(1, max_length - #TRUNCATE_SUFFIX) .. TRUNCATE_SUFFIX
end

-- 外部 role → CC 内部 role 映射
local ROLE_MAP = {
  user = "user",
  assistant = "llm",
  system = "system",
  tool = "tool",
}

--- 构建 tool_call_id → call info 的映射表（用于 tool_error 关联上下文）
---@param messages table[] 消息列表
---@return table map {[call_id] = {name, arguments, index}}
local function build_tool_call_map(messages)
  local map = {}
  for i, msg in ipairs(messages) do
    if (msg.role == "llm" or msg.role == "assistant") and msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        local call_id = call.call_id or call.id
        if call_id and call["function"] then
          map[call_id] = {
            name = call["function"].name,
            arguments = call["function"].arguments,
            index = i,
          }
        end
      end
    end
  end
  return map
end

--- 格式化单条消息用于输出
---@param msg table 原始消息
---@param index number 消息原始索引 (1-based)
---@param mode string "full" 或 "summary"
---@param call_info table|nil tool_error 关联的 call 信息
---@return table 格式化后的消息
local function format_message(msg, index, mode, call_info)
  local formatted = { index = index }
  local is_summary = (mode == "summary")

  -- tool_error 模式：包含错误内容 + 关联的工具调用上下文
  if call_info then
    formatted.is_error = true
    formatted.content = is_summary and truncate_content(msg.content, SUMMARY_MAX_LENGTH) or msg.content
    formatted.call = {
      name = call_info.name,
      arguments = call_info.arguments,
    }
    return formatted
  end

  -- tool_requests: LLM 发起的工具调用，只需要 calls (name + arguments)
  if msg.role == "llm" and msg.tools and msg.tools.calls then
    formatted.calls = {}
    for _, call in ipairs(msg.tools.calls) do
      local func = call["function"]
      if func then
        table.insert(formatted.calls, {
          name = func.name,
          arguments = func.arguments,
        })
      end
    end
    return formatted
  end

  -- tool_responses: 工具返回，只需要 content (+ is_error)
  if msg.role == "tool" then
    formatted.content = is_summary and truncate_content(msg.content, SUMMARY_MAX_LENGTH) or msg.content
    if is_tool_error(msg) then
      formatted.is_error = true
    end
    return formatted
  end

  -- conversation: 对话消息，role + content
  -- 将 CC 内部 "llm" 映射为外部 "assistant"
  formatted.role = msg.role == "llm" and "assistant" or msg.role
  formatted.content = is_summary and truncate_content(msg.content, SUMMARY_MAX_LENGTH) or msg.content
  return formatted
end

--- 按 role 过滤消息
---@param messages table[] 原始消息列表
---@param role string|nil 外部 role 值
---@return table[] filtered {{_original_index, msg}, ...}
local function filter_by_role(messages, role)
  local filtered = {}

  for i, msg in ipairs(messages) do
    local include = false

    if not role then
      -- 无过滤：返回全部
      include = true
    elseif role == "conversation" then
      -- user（无 context）+ llm（无 tool_calls）
      if msg.role == "user" and not msg.context then
        include = true
      elseif msg.role == "llm" and not (msg.tools and msg.tools.calls) then
        include = true
      end
    elseif role == "tool_error" then
      -- 仅失败的 tool 消息
      if msg.role == "tool" and is_tool_error(msg) then
        include = true
      end
    else
      -- 直接角色映射
      local internal_role = ROLE_MAP[role]
      if internal_role and msg.role == internal_role then
        include = true
      end
    end

    if include then
      table.insert(filtered, { _original_index = i, msg = msg })
    end
  end

  return filtered
end

--- 获取消息的处理函数
---@param req table 请求对象
---@param res table 响应对象
local function get_messages(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local role = params.role
  local skip = param_utils.default(params.skip, 0)
  local take = params.take
  local mode = param_utils.default(params.mode, "summary")

  -- 参数验证: mode
  if mode ~= "full" and mode ~= "summary" then
    return res:error("get_messages: mode must be 'full' or 'summary'")
  end

  -- 参数验证: skip
  if type(skip) ~= "number" or skip < 0 then
    return res:error("get_messages: skip must be a non-negative number")
  end
  skip = math.floor(skip)

  -- 参数验证: take
  if take ~= nil then
    if type(take) ~= "number" or take < 1 then
      return res:error("get_messages: take must be a positive number")
    end
    take = math.floor(take)
  end

  -- 参数验证: role
  if role then
    local valid_roles = {
      user = true,
      assistant = true,
      system = true,
      tool = true,
      conversation = true,
      tool_error = true,
    }
    if not valid_roles[role] then
      return res:error(
        "get_messages: role must be one of: user, assistant, system, tool, conversation, tool_error"
      )
    end
  end

  -- 获取消息列表
  local messages
  local source_type

  if not save_id or save_id == "" then
    if not req.caller or not req.caller.maxa_ai then
      return res:error(
        "get_messages: No current session found (must be called from a Maxa AI chat or provide save_id)"
      )
    end
    local chat = req.caller.maxa_ai.chat
    if not chat or not chat.messages then
      return res:error("get_messages: Current session has no messages")
    end
    messages = chat.messages
    source_type = "current"
    save_id = chat.opts and chat.opts.save_id or nil
  else
    local chat_data, err = history_core.read_chat(save_id)
    if not chat_data then
      return res:error("get_messages: Failed to read chat - " .. (err or "unknown error"))
    end
    messages = chat_data.messages or {}
    source_type = "saved"
  end

  local total_count = #messages

  -- 按 role 过滤
  local filtered = filter_by_role(messages, role)
  local filtered_count = #filtered

  -- tool_error 模式需要 call map 来关联上下文
  local tool_call_map
  if role == "tool_error" then
    tool_call_map = build_tool_call_map(messages)
  end

  -- 分页 (skip/take)
  local range_start = skip + 1
  local range_end = take and (skip + take) or filtered_count

  if range_start > filtered_count then
    range_start = filtered_count + 1
  end
  if range_end > filtered_count then
    range_end = filtered_count
  end

  -- 格式化消息
  local result_messages = {}
  for i = range_start, range_end do
    local item = filtered[i]
    if item then
      local call_info = nil
      -- tool_error: 关联对应的 tool call 上下文
      if role == "tool_error" and tool_call_map then
        local call_id = (item.msg.tools and item.msg.tools.call_id) or item.msg.tool_call_id
        if call_id then
          call_info = tool_call_map[call_id]
        end
      end
      table.insert(result_messages, format_message(item.msg, item._original_index, mode, call_info))
    end
  end

  -- 构建响应（统一 JSON 格式）
  local result = history_core.create_response({
    source = source_type,
    save_id = save_id,
    messages = result_messages,
    total_count = total_count,
    filtered_count = filtered_count,
    returned_count = #result_messages,
    role = role,
    mode = mode,
    skip = skip,
    take = take,
  })

  return res:text(vim.json.encode(result)):send()
end

return {
  name = "get_messages",
  description = "Read paged messages from current or saved chat, optionally role-filtered; returns JSON.",

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Saved chat ID; omitted reads current chat.",
      },
      role = {
        type = "string",
        enum = { "user", "assistant", "system", "tool", "conversation", "tool_error" },
        description = "Role filter: user, assistant, system, tool, conversation, or tool_error with call name/arguments.",
      },
      skip = {
        type = "number",
        description = "Number of filtered messages to skip; default 0.",
      },
      take = {
        type = "number",
        description = "Maximum filtered messages to return after skip.",
      },
      mode = {
        type = "string",
        enum = { "full", "summary" },
        description = "summary truncates content to 300 chars; full returns complete content.",
      },
    },
    required = {},
  },

  handler = get_messages,
}
