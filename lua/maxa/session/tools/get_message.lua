-- get_message: 根据索引获取单条消息
local history_core = require("maxa.session.history_core")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

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

--- 格式化单条消息用于输出
--- 根据消息类型只保留有价值的信息
---@param msg table 原始消息
---@param index number 消息原始索引 (1-based)
---@param mode string "full" 或 "summary"
---@return table 格式化后的消息
local function format_message(msg, index, mode)
  local is_summary = (mode == "summary")
  local formatted = { index = index }

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

  -- tool_responses / tool_errors: 工具返回，只需要 content (+ is_error)
  if msg.role == "tool" then
    formatted.content = is_summary and truncate_content(msg.content, SUMMARY_MAX_LENGTH) or msg.content
    if msg.tools and msg.tools.is_error then
      formatted.is_error = true
    end
    return formatted
  end

  -- conversation: 对话消息，只需要 role + content
  formatted.role = msg.role
  formatted.content = is_summary and truncate_content(msg.content, SUMMARY_MAX_LENGTH) or msg.content
  return formatted
end

--- 获取单条消息的处理函数
---@param req table 请求对象
---@param res table 响应对象
local function get_message(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local index = params.index
  local mode = param_utils.default(params.mode, "full") -- 默认全部内容

  -- 参数验证: mode
  if mode ~= "full" and mode ~= "summary" then
    return res:error("get_message: mode must be 'full' or 'summary'")
  end

  -- 参数验证: index 必需
  if index == nil then
    return res:error("get_message: index is required")
  end
  if type(index) ~= "number" or index < 1 then
    return res:error("get_message: index must be a positive number (1-based)")
  end
  index = math.floor(index)

  -- 获取消息列表
  local messages
  local source_type -- "current" 或 "saved"

  if not save_id or save_id == "" then
    -- 从当前会话获取
    if not req.caller or not req.caller.maxa_ai then
      return res:error(
        "get_message: No current session found (must be called from a Maxa AI chat or provide save_id)"
      )
    end

    local chat = req.caller.maxa_ai.chat
    if not chat or not chat.messages then
      return res:error("get_message: Current session has no messages")
    end

    messages = chat.messages
    source_type = "current"
    save_id = chat.opts and chat.opts.save_id or nil
  else
    -- 从保存的会话文件读取
    local chat_data, err = history_core.read_chat(save_id)
    if not chat_data then
      return res:error("get_message: Failed to read chat - " .. (err or "unknown error"))
    end
    messages = chat_data.messages or {}
    source_type = "saved"
  end
  local total_count = #messages

  -- 边界检查
  if index > total_count then
    return res:error(string.format("get_message: index %d out of range (total: %d)", index, total_count))
  end

  -- 获取并格式化消息
  local msg = messages[index]
  local result = history_core.create_response({
    source = source_type,
    save_id = save_id,
    total_count = total_count,
    mode = mode,
    message = format_message(msg, index, mode),
  })

  return res:text(vim.json.encode(result)):send()
end

return {
  name = "get_message",
  description = "Return one message by 1-based index from current or saved chat, with optional content truncation.",

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Saved chat ID; omitted reads current chat.",
      },
      index = {
        type = "number",
        description = "Required 1-based message index.",
      },
      mode = {
        type = "string",
        enum = { "full", "summary" },
        description = "full returns complete content; summary truncates content to 300 chars.",
      },
    },
    required = { "index" },
  },

  handler = get_message,
}
