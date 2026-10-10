-- compact_full: 全量压缩会话（支持当前会话和历史会话），生成摘要并过滤消息
local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local compaction_messages = require("maxa.session.compaction_messages")
local compact_utils = require("maxa.session.slash_commands.compact_utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

-- LLM 请求超时（毫秒），plenary curl 默认仅 10 秒，摘要生成需要更长时间

-- 摘要生成 prompt (复用自 /compact 命令)
local SUMMARY_PROMPT =
  [[你的任务是创建到目前为止对话的详细摘要，密切关注用户的明确请求和你之前的操作。
此摘要应全面捕获技术细节、代码模式和架构决策，这些对于在不丢失上下文的情况下继续开发工作至关重要。

## 重要：需要从摘要中排除的内容

不要在摘要中包含以下任何内容——这些是关于会话管理的元操作，而非实际工作内容：

1. **会话压缩请求**：用户要求压缩/精简当前会话
2. **Token 阈值警告**：关于达到或超过 token 限制的消息
3. **session 工具操作**：加载 session 服务器、调用 compact_session 工具等
4. **此摘要请求本身**：生成此摘要的指令

仅专注于对话中讨论的实际技术工作、代码更改、问题解决和用户需求。

## 摘要结构

"摘要"应为 Markdown 格式。必须包含以下部分，每个部分都有 Markdown 标题：

- "主要请求和意图"：详细捕获用户的所有明确请求和意图。排除任何与会话压缩相关的请求。
- "关键技术概念"：列出讨论的所有重要技术概念、技术和框架。
- "文件和代码部分"：列举检查、修改或创建的具体文件和代码部分。特别注意最近的消息，在适用时包含完整代码片段，并总结此文件读取或编辑的重要性。
- "问题解决"：记录已解决的问题和任何正在进行的故障排除工作。
- "待处理任务"：概述你被明确要求处理的任何待处理任务。排除会话压缩任务。
- "当前工作"：详细描述在此摘要请求之前正在进行的工作，特别注意用户和助手的最近消息。在适用时包含文件名和代码片段。如果最近的工作是关于会话压缩，请描述之前的工作。
- "可选的下一步"：列出与你最近工作相关的下一步。重要：确保此步骤与用户的明确请求以及你在此摘要请求之前正在处理的任务直接一致。如果你的上一个任务已结束，则仅在与用户请求明确一致时才列出下一步。不要在未先与用户确认的情况下开始处理无关请求。
- "支持引用"：如果有下一步，逐字引用最近对话，准确显示你正在处理的任务和停止的位置。

请根据到目前为止的对话提供摘要，遵循此结构并确保响应的精确性和全面性。

仅输出 Markdown 摘要正文，不添加额外评论或解释，也不要用代码围栏包裹整个答案。引用代码时使用四个反引号和适当的语言标识符。

需要总结的对话和相应消息如下：

<conversation>%s</conversation>]]

--- 检查消息是否包含 compact_session 工具调用
---@param msg table 消息对象
---@return boolean 是否包含 compact_session 工具调用
local function is_compact_tool_call(msg)
  if msg.role ~= "assistant" and msg.role ~= "llm" then
    return false
  end
  local content = msg.content or ""
  -- 检查是否包含 compact_session 工具调用的特征
  return content:match("compact_session") ~= nil or content:match("session__compact_session") ~= nil
end

--- 构建对话字符串 (复用自 /compact 命令的 create_conversation)
--- 排除最后的 compact_session 工具调用消息，避免压缩 LLM 看到"正在执行压缩"的指令
--- 图片消息替换为占位符（避免 base64 浪费 token）
---@param messages table[] 消息列表
---@return string 对话字符串
local function create_conversation(messages)
  local compact_utils = require("maxa.session.slash_commands.compact_utils")
  local parts = {}
  local msg_list = messages or {}

  -- 从后向前找到最后一条 compact_session 工具调用消息的索引
  local exclude_from = #msg_list + 1
  for i = #msg_list, 1, -1 do
    local msg = msg_list[i]
    if is_compact_tool_call(msg) then
      exclude_from = i
      break
    end
    -- 只检查最后几条消息（工具调用通常在最后）
    if #msg_list - i > 3 then
      break
    end
  end

  for i, msg in ipairs(msg_list) do
    -- 排除 compact_session 工具调用及其后的消息
    if i >= exclude_from then
      break
    end
    -- 只处理 user 和 assistant/llm 消息
    if msg.role == "user" or msg.role == "assistant" or msg.role == "llm" then
      local role = msg.role == "llm" and "assistant" or msg.role
      -- 图片消息：替换 base64 为占位符
      local content
      if compact_utils.is_image_message(msg) then
        content = compact_utils.IMAGE_PLACEHOLDER
      else
        content = msg.content or ""
      end
      table.insert(parts, string.format('<message role="%s">%s</message>', role, content))
    end
  end
  return table.concat(parts, "")
end

--- 异步流式调用 LLM 生成摘要（使用 shared/streaming_llm 模块）
--- 避免 send_sync 的 UI 阻塞和网关 60s 超时问题
---@param adapter_name string adapter 名称
---@param conversation string 对话字符串
---@param model_name string|nil 模型名称
---@param temperature number|nil 温度
---@param callback function 回调 function(summary: string|nil, err: string|nil)
local function generate_summary_async(adapter_name, conversation, model_name, temperature, reasoning_effort, callback)
  local streaming_llm = require("maxa.mcphub.native_servers.shared.streaming_llm")

  local adapter, adapter_err = streaming_llm.create_streaming_adapter(adapter_name, model_name, temperature)
  if adapter then
    local reasoning_settings =
      require("maxa.mcphub.native_servers.config").get_reasoning_effort_settings(adapter, reasoning_effort)
    if reasoning_settings then
      adapter:map_schema_to_params(vim.tbl_deep_extend("force", adapter:make_from_schema(), reasoning_settings))
    end
  end
  if not adapter then
    callback(nil, adapter_err)
    return
  end

  local prompt = string.format(SUMMARY_PROMPT, conversation)
  local messages = {
    { role = "system", content = "You are a precise text summarization assistant. Follow the user's instructions exactly." },
    { role = "user", content = prompt },
  }

  streaming_llm.streaming_request(adapter, messages, { timeout = require("maxa.config").runtime().compaction.summarize_timeout_ms }, function(content, err)
    if err then
      callback(nil, err)
      return
    end
    if not content or content == "" then
      callback(nil, "No text content in LLM response")
      return
    end
    callback(content, nil)
  end)
end

--- 应用摘要结果（从异步回调中调用）
---@param res table 响应对象
---@param summary string 摘要内容
---@param messages table[] 原始消息
---@param before_count number 压缩前消息数
---@param mode string 压缩模式
---@param source table 消息来源
---@param actual_save_id string 会话 ID
---@param adapter_name string adapter 名称
local function apply_summary(res, summary, messages, before_count, mode, source, actual_save_id, adapter_name)
  local protected_prefix_count = compaction_messages.get_protected_prefix_count(source)
  local protected_messages = {}
  local compressible_messages = messages
  if protected_prefix_count > 0 then
    for i = 1, math.min(protected_prefix_count, #messages) do
      table.insert(protected_messages, vim.deepcopy(messages[i]))
    end
    compressible_messages = {}
    for i = protected_prefix_count + 1, #messages do
      table.insert(compressible_messages, messages[i])
    end
  end

  -- 5. 过滤消息（使用公共模块的统一规则）
  local filtered_messages = compaction_messages.filter_messages_for_compact(compressible_messages)
  if #protected_messages > 0 then
    local combined = protected_messages
    for _, msg in ipairs(filtered_messages) do
      table.insert(combined, msg)
    end
    filtered_messages = combined
  end

  -- 6. 添加摘要消息
  table.insert(filtered_messages, {
    role = "user",
    content = string.format("以下是我们之前对话的摘要：\n\n%s\n\n", summary),
    _meta = {
      tag = "compact_summary",
    },
  })

  -- 7. 添加 LLM 确认消息
  table.insert(filtered_messages, {
    role = "llm",
    content = "我已阅读对话摘要，准备好继续我们的讨论。请问需要处理什么任务？",
  })

  -- 8. 添加空的用户消息作为当前输入区域
  table.insert(filtered_messages, {
    role = "user",
    content = "",
  })

  local after_count = #filtered_messages

  -- 应用压缩结果
  local apply_result, apply_err = history_session.apply_compression_result({
    messages = filtered_messages,
    mode = mode,
    source = source,
    adapter_name = adapter_name,
    on_new_session = function(new_chat)
      vim.notify(
        string.format("[compact_full] 全量压缩完成. 总计: %d → %d", before_count, after_count),
        vim.log.levels.INFO
      )
    end,
  })

  if apply_err then
    return res:error("compact_full: " .. apply_err)
  end

  -- 计算压缩统计
  local compression_ratio = before_count > 0 and string.format("%.1f%%", (1 - after_count / before_count) * 100) or "0%"

  -- 返回结果
  local response_data = {
    source = source.source_type,
    save_id = actual_save_id,
    mode = mode,
    action = apply_result.action,
    stats = {
      before_count = before_count,
      after_count = after_count,
      compression_ratio = compression_ratio,
    },
    summary_preview = summary:sub(1, 500) .. (summary:len() > 500 and "..." or ""),
  }

  if apply_result.save_id then
    response_data.new_save_id = apply_result.save_id
  end
  if apply_result.original_save_id then
    response_data.original_save_id = apply_result.original_save_id
  end

  local result = history_core.create_response(response_data)
  return res:text(vim.json.encode(result)):send()
end

--- compact_full 工具处理函数
--- 支持当前会话和历史会话的全量压缩
---@param req table 请求对象
---@param res table 响应对象
local function compact_full(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local mode = param_utils.default(params.mode, compaction_messages.COMPRESS_MODE.AUTO)

  -- 获取消息来源
  local source, source_err = history_session.get_messages_source(save_id, req.caller)
  if not source then
    return res:error("compact_full: " .. source_err)
  end

  local messages = source.messages
  local before_count = #messages
  local chat = source.chat
  local chat_data = source.chat_data
  local actual_save_id = source.save_id

  -- 检查是否有足够的消息需要压缩
  if before_count < 3 then
    return res:error("compact_full: Not enough messages to compact (minimum 3)")
  end

  -- 从统一配置获取摘要专用 adapter
  local mcp_config = require("maxa.mcphub.native_servers.config")
  local summary_cfg, summary_err = mcp_config.get_runtime_adapter("summary", {
    chat = chat,
    chat_data = chat_data,
  })
  if not summary_cfg then
    return res:error("compact_full: failed to load summary adapter config - " .. tostring(summary_err))
  end
  local adapter_name = summary_cfg.adapter
  local model_name = summary_cfg.model
  local temperature = summary_cfg.temperature

  if summary_cfg.inherit then
    adapter_name = (chat and chat.adapter and chat.adapter.name) or (chat_data and chat_data.adapter) or nil
    model_name = (chat and chat.settings and chat.settings.model)
      or (chat and chat.adapter and chat.adapter.model and chat.adapter.model.name)
      or (chat_data and chat_data.settings and chat_data.settings.model)
      or nil
    temperature = (chat and chat.settings and chat.settings.temperature)
      or (chat_data and chat_data.settings and chat_data.settings.temperature)
      or nil
    model_name = summary_cfg.model or model_name
    if summary_cfg.temperature ~= nil then
      temperature = summary_cfg.temperature
    end

    if not adapter_name or adapter_name == "" then
      return res:error("compact_full: failed to inherit adapter from parent session")
    end
  end

  local protected_prefix_count = compaction_messages.get_protected_prefix_count(source)
  if protected_prefix_count >= before_count then
    return res:error(
      string.format(
        "compact_full: protected initial prefix covers all messages (protected range: %s, first compressible index: %d)",
        compaction_messages.format_protected_range(protected_prefix_count),
        compaction_messages.get_first_compressible_index(protected_prefix_count)
      )
    )
  end

  local messages_to_summarize = messages
  if protected_prefix_count > 0 then
    messages_to_summarize = {}
    for i = protected_prefix_count + 1, #messages do
      table.insert(messages_to_summarize, messages[i])
    end
    if #messages_to_summarize < 2 then
      return res:error(
        string.format(
          "compact_full: not enough compressible messages after protected prefix (protected range: %s, first compressible index: %d)",
          compaction_messages.format_protected_range(protected_prefix_count),
          compaction_messages.get_first_compressible_index(protected_prefix_count)
        )
      )
    end
  end

  -- 构建对话字符串
  local conversation = create_conversation(messages_to_summarize)
  if conversation == "" then
    return res:error("compact_full: No conversation content to summarize")
  end

  -- 异步调用 LLM 生成摘要（MCP tool handler 支持异步回调，不阻塞 UI）
  generate_summary_async(
    adapter_name,
    conversation,
    model_name,
    temperature,
    summary_cfg.reasoning_effort,
    function(summary, llm_err)
      if not summary then
        return res:error("compact_full: Failed to generate summary - " .. (llm_err or "unknown error"))
      end

      -- 以下逻辑在回调中异步执行
      vim.schedule(function()
        apply_summary(res, summary, messages, before_count, mode, source, actual_save_id, adapter_name)
      end)
    end
  )
  -- handler 返回 nil，MCPHub 等待 callback
end


return {
  name = "compact_full",
  description = "Compress a current or saved chat into one compact_summary message while preserving system messages and tagged user context. Modes: auto (current→new, saved→overwrite), overwrite, new.",

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Chat session ID. If not provided, operates on the current session.",
      },
      mode = {
        type = "string",
        enum = { "auto", "overwrite", "new" },
        description = "auto (default: current→new, saved→overwrite), overwrite, or new (create new save_id).",
      },
    },
    required = {},
  },

  handler = compact_full,
}
