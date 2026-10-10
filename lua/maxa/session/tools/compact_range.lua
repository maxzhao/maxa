-- compact_range: 压缩会话的多个区间（支持当前会话和历史会话）
-- 支持两种操作: summarize (LLM摘要), delete (删除)
-- 需要先调用 probe_messages 获取消息索引

local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local compaction_messages = require("maxa.session.compaction_messages")
local loaded_items = require("maxa.session.loaded_items")
local compact_utils = require("maxa.session.slash_commands.compact_utils")
local session_trace = require("maxa.session.session_trace")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

-- 操作类型常量
local ACTION_SUMMARIZE = "summarize"
local ACTION_DELETE = "delete"

-- LLM 请求超时（毫秒），plenary curl 默认仅 10 秒，摘要生成需要更长时间
local function compact_opts() return require("maxa.config").runtime().compaction end

-- 并发 summarize 批次等待超时（毫秒）

-- 多 range 连续调用 LLM 时的间隔（毫秒），避免触发 adapter 频率限制

-- summarize 请求的最大并发数
-- 1: 保持现有串行语义与固定延迟限流
-- >1: 允许最多 N 个无依赖 summarize 并发
-- 0: 不设上限（实际并发仍受依赖约束）

-- 摘要生成 prompt 模板
local SUMMARY_PROMPTS = {
  -- 前段压缩：为后续对话提供背景铺垫
  head = [[你正在总结对话的**开头部分**。此区间之后的消息将被保留。

你的摘要应作为后续保留消息的**背景上下文**。

## 关键要求
- 专注于建立上下文：项目设置、初始需求、早期做出的关键决策
- 突出保留消息可能引用的任何信息
- 以清晰的过渡点结束，与后续内容衔接

## 需要排除的内容
- 会话压缩请求、token 警告、session 工具操作
- 关于会话管理的元操作

## 摘要结构
- "初始上下文"：项目背景、用户的原始目标、环境设置
- "关键决策"：重要的技术决策及其理由
- "已建立的模式"：已商定的代码模式、约定或方法
- "过渡点"：此部分结束时的状态/主题（用于与保留消息衔接）

%s

<conversation_to_summarize>%s</conversation_to_summarize>]],

  -- 中段压缩：承上启下，保持连贯性
  middle = [[你正在总结对话的**中间部分**。此区间前后的消息都将被保留。

你的摘要必须**桥接**保留的部分，保持叙事连贯性。

## 关键要求
- 引用之前的内容（作为上下文提供）以保持连贯性
- 总结此中间部分完成的工作
- 为后续内容（作为上下文提供）建立上下文
- 确保摘要在保留部分之间自然衔接

## 需要排除的内容
- 会话压缩请求、token 警告、session 工具操作
- 关于会话管理的元操作

## 摘要结构
- "承接内容"：简要引用上一部分结束的位置
- "完成的工作"：此部分的主要成果
- "关键变更"：修改的文件、解决的问题、做出的决策
- "引出内容"：此部分结束时的主题/状态（与后续保留消息衔接）

%s

<conversation_to_summarize>%s</conversation_to_summarize>]],

  -- 末段压缩：总结近期工作，便于继续
  tail = [[你正在总结对话的**末尾部分**。此区间之前的消息将被保留。

你的摘要应捕获**近期工作**并提供清晰的继续点。

## 关键要求
- 引用之前的内容（作为上下文提供）以保持连贯性
- 专注于最近的工作、当前状态和下一步
- 提供足够的细节以便立即恢复工作

## 需要排除的内容
- 会话压缩请求、token 警告、session 工具操作
- 关于会话管理的元操作

## 摘要结构
- "近期工作"：此部分完成的内容（如相关，包含代码片段）
- "当前状态"：目前的进展——什么在工作、什么待处理
- "活跃上下文"：当前正在处理的文件、未解决的问题
- "下一步"：从这里继续的清晰可执行项
- "支持引用"：逐字引用，准确显示工作停止的位置

%s

<conversation_to_summarize>%s</conversation_to_summarize>]],

  -- 完整会话压缩（原有逻辑，作为 fallback）
  full = [[你的任务是创建到目前为止对话的详细摘要，密切关注用户的明确请求和你之前的操作。
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

<conversation>%s</conversation>]],
}

--- 检查消息是否为对话消息（排除 system 和 context 嵌入）
---@param msg table 消息对象
---@return boolean 是否为对话消息
local function is_conversation_message(msg)
  -- 排除 system 消息
  if msg.role == "system" then
    return false
  end
  -- 排除 context 嵌入的 user 消息（带 context 属性）
  if msg.role == "user" and msg.context then
    return false
  end
  -- user（无 context）、llm、tool 都算对话消息
  return true
end

--- 判断压缩位置类型（基于对话消息，排除 system 和 context）
---@param messages table[] 消息列表
---@param start_index number 起始索引
---@param end_index number 结束索引
---@return "head"|"middle"|"tail"|"full" 压缩位置类型
local function determine_compression_type(messages, start_index, end_index)
  -- 统计区间前的对话消息数
  local conversation_before = 0
  for i = 1, start_index - 1 do
    if is_conversation_message(messages[i]) then
      conversation_before = conversation_before + 1
    end
  end

  -- 统计区间后的对话消息数
  local conversation_after = 0
  for i = end_index + 1, #messages do
    if is_conversation_message(messages[i]) then
      conversation_after = conversation_after + 1
    end
  end

  local has_before = conversation_before > 0
  local has_after = conversation_after > 0

  if not has_before and not has_after then
    return "full"
  elseif not has_before and has_after then
    return "head"
  elseif has_before and has_after then
    return "middle"
  else -- has_before and not has_after
    return "tail"
  end
end

--- 提取消息的简要摘要（用于上下文提示）
---@param messages table[] 消息列表
---@param start_idx number 起始索引
---@param end_idx number 结束索引
---@param max_chars number 最大字符数
---@return string 简要摘要
local function extract_brief_context(messages, start_idx, end_idx, max_chars)
  local parts = {}
  local total_chars = 0

  for i = start_idx, end_idx do
    local msg = messages[i]
    if msg then
      local role = msg.role == "llm" and "assistant" or msg.role
      if role == "user" or role == "assistant" then
        local content = msg.content or ""
        -- 截取前 200 字符作为预览
        local preview = content:sub(1, 200)
        if #content > 200 then
          preview = preview .. "..."
        end
        local line = string.format("[%s]: %s", role, preview)
        total_chars = total_chars + #line
        if total_chars > max_chars then
          table.insert(parts, "... (more messages)")
          break
        end
        table.insert(parts, line)
      end
    end
  end

  return table.concat(parts, "\n")
end

--- 构建上下文提示信息
---@param messages table[] 消息列表
---@param start_index number 压缩区间起始
---@param end_index number 压缩区间结束
---@param compression_type "head"|"middle"|"tail"|"full" 压缩类型
---@return string 上下文提示
local function build_context_hint(messages, start_index, end_index, compression_type)
  local hints = {}

  if compression_type == "middle" or compression_type == "tail" then
    -- 提供前面保留消息的简要上下文
    local before_start = math.max(1, start_index - 5)
    local before_end = start_index - 1
    if before_end >= before_start then
      local before_context = extract_brief_context(messages, before_start, before_end, 800)
      table.insert(
        hints,
        string.format(
          [[## Context: Messages BEFORE this range (preserved)
These messages come before the section you're summarizing:

%s]],
          before_context
        )
      )
    end
  end

  if compression_type == "middle" or compression_type == "head" then
    -- 提供后面保留消息的简要上下文
    local after_start = end_index + 1
    local after_end = math.min(#messages, end_index + 5)
    if after_end >= after_start then
      local after_context = extract_brief_context(messages, after_start, after_end, 800)
      table.insert(
        hints,
        string.format(
          [[## Context: Messages AFTER this range (preserved)
These messages come after the section you're summarizing:

%s]],
          after_context
        )
      )
    end
  end

  return table.concat(hints, "\n\n")
end

--- 构建对话字符串（仅压缩区间内的消息）
--- 图片消息替换为占位符（避免 base64 浪费 token）
---@param messages table[] 消息列表
---@param start_index number 起始索引
---@param end_index number 结束索引
---@return string 对话字符串
local function create_conversation(messages, start_index, end_index)
  local compact_utils = require("maxa.session.slash_commands.compact_utils")
  local parts = {}
  for i = start_index, end_index do
    local msg = messages[i]
    if msg then
      local role = msg.role == "llm" and "assistant" or msg.role
      -- 只处理 user 和 assistant 消息
      if role == "user" or role == "assistant" then
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
  end
  return table.concat(parts, "")
end

--- 同步调用 LLM 生成摘要（流式 HTTP + vim.wait 同步等待）
--- HTTP 层流式避免网关超时，Lua 层 vim.wait 保持同步语义
---@param adapter_name string adapter 名称
---@param prompt string 完整的 prompt（已包含对话内容）
---@param model_name string|nil 模型名称
---@param caller_chat table|nil 调用方 chat（用于共享 token_limit 重试计数器）
---@return string|nil summary 摘要内容
---@return string|nil error 错误信息
local SUMMARY_SYSTEM_PROMPT = "You are a precise text summarization assistant. Follow the user's instructions exactly."

local function generate_summary_sync(adapter_name, prompt, model_name, temperature, reasoning_effort, caller_chat)
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
    return nil, adapter_err
  end

  local messages = {
    { role = "system", content = SUMMARY_SYSTEM_PROMPT },
    { role = "user", content = prompt },
  }
  return streaming_llm.streaming_request_sync(adapter, messages, {
    timeout = compact_opts().summarize_timeout_ms,
    caller_chat = caller_chat,
  })
end

--- 异步调用 LLM 生成摘要（流式 HTTP + 回调）
---@param adapter_name string
---@param prompt string
---@param model_name string|nil
---@param caller_chat table|nil
---@param callback fun(summary:string|nil, err:string|nil)
local function generate_summary_async(adapter_name, prompt, model_name, temperature, reasoning_effort, caller_chat, callback)
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

  local messages = {
    { role = "system", content = SUMMARY_SYSTEM_PROMPT },
    { role = "user", content = prompt },
  }
  streaming_llm.streaming_request(adapter, messages, {
    timeout = compact_opts().summarize_timeout_ms,
    caller_chat = caller_chat,
  }, function(content, err)
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

--- 解析索引（支持负数索引，-1 表示最后一条）
---@param idx number 索引值
---@param total_count number 总消息数
---@return number 解析后的正数索引
local function resolve_index(idx, total_count)
  if idx < 0 then
    return total_count + idx + 1
  end
  return idx
end

local function snapshot_ranges(ranges)
  local result = {}
  for _, range in ipairs(ranges or {}) do
    table.insert(result, {
      start_index = range.start_index,
      end_index = range.end_index,
      action = range.action,
      original_index = range.original_index,
    })
  end
  return result
end

local function build_tool_error(error_type, message, extra)
  local payload = {
    status = "error",
    error_type = error_type,
    retryable = compact_utils.is_retryable_compact_range_error_type(error_type),
    message = message,
  }
  if extra then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  return payload
end

local function respond_tool_error(res, error_type, message, extra)
  return res:error(vim.json.encode(build_tool_error(error_type, message, extra))):send()
end

--- 验证区域数组（包含排序、tool call 配对保护、summarize overlap 合并）
---@param ranges table[] 区域数组
---@param total_count number 总消息数
---@param messages table[] 消息列表（用于 tool call 配对检查）
---@return table[]|nil normalized_ranges 规范化后的区域数组
---@return table|nil error_payload 结构化错误
---@return table|nil adjustments 范围调整说明
local function validate_ranges(ranges, total_count, messages)
  if not ranges or type(ranges) ~= "table" or #ranges == 0 then
    return nil,
      build_tool_error(
        compact_utils.COMPACT_RANGE_ERROR_TYPES.RANGES_REQUIRED,
        "ranges array is required (at least 1 range)",
        { suggested_action = "provide_ranges_array" }
      ),
      nil
  end

  local prepared = {}
  local all_adjustments = {}

  for i, range in ipairs(ranges) do
    local start_idx = range.start_index
    local end_idx = range.end_index
    local action = range.action

    if not start_idx or not end_idx then
      return nil,
        build_tool_error(
          compact_utils.COMPACT_RANGE_ERROR_TYPES.RANGES_REQUIRED,
          string.format("range[%d]: start_index and end_index are required", i),
          { range_index = i, suggested_action = "provide_start_and_end_index" }
        ),
        nil
    end

    start_idx = resolve_index(start_idx, total_count)
    end_idx = resolve_index(end_idx, total_count)

    if action ~= ACTION_SUMMARIZE and action ~= ACTION_DELETE then
      return nil,
        build_tool_error(
          compact_utils.COMPACT_RANGE_ERROR_TYPES.INVALID_ACTION,
          string.format("range[%d]: action must be 'summarize' or 'delete'", i),
          { range_index = i, suggested_action = "use_supported_action" }
        ),
        nil
    end

    if start_idx < 1 or start_idx > total_count then
      return nil,
        build_tool_error(
          compact_utils.COMPACT_RANGE_ERROR_TYPES.INVALID_INDEX,
          string.format("range[%d]: invalid start_index %d (total: %d)", i, start_idx, total_count),
          { range_index = i, suggested_action = "reprobe_or_fix_index" }
        ),
        nil
    end

    if end_idx < start_idx or end_idx > total_count then
      return nil,
        build_tool_error(
          compact_utils.COMPACT_RANGE_ERROR_TYPES.INVALID_INDEX,
          string.format("range[%d]: invalid end_index %d (start: %d, total: %d)", i, end_idx, start_idx, total_count),
          { range_index = i, suggested_action = "reprobe_or_fix_index" }
        ),
        nil
    end

    if messages then
      local safe_start, safe_end, adjustments = compaction_messages.get_safe_range_for_tool_pairs(messages, start_idx, end_idx)
      if #adjustments > 0 then
        for _, adj in ipairs(adjustments) do
          adj.range_index = i
          table.insert(all_adjustments, adj)
        end
        start_idx = safe_start
        end_idx = safe_end
      end
    end

    table.insert(prepared, {
      start_index = start_idx,
      end_index = end_idx,
      action = action,
      original_index = i,
    })
  end

  table.sort(prepared, function(a, b)
    if a.start_index == b.start_index then
      if a.end_index == b.end_index then
        return a.original_index < b.original_index
      end
      return a.end_index < b.end_index
    end
    return a.start_index < b.start_index
  end)

  for sorted_index, range in ipairs(prepared) do
    if range.original_index ~= sorted_index then
      table.insert(all_adjustments, {
        type = "reorder",
        reason = string.format(
          "range[%d] reordered to sorted position %d (%d-%d)",
          range.original_index,
          sorted_index,
          range.start_index,
          range.end_index
        ),
        original_index = range.original_index,
        sorted_index = sorted_index,
      })
    end
  end

  local normalized = {}
  for _, range in ipairs(prepared) do
    local prev = normalized[#normalized]
    if prev and range.start_index <= prev.end_index then
      if prev.action == ACTION_SUMMARIZE and range.action == ACTION_SUMMARIZE then
        local old_end = prev.end_index
        prev.end_index = math.max(prev.end_index, range.end_index)
        prev.original_indices = prev.original_indices or { prev.original_index }
        table.insert(prev.original_indices, range.original_index)
        table.insert(all_adjustments, {
          type = "merge_overlap",
          reason = string.format(
            "merged overlapping summarize ranges range[%d] (%d-%d) into range[%d] (%d-%d)",
            range.original_index,
            range.start_index,
            range.end_index,
            prev.original_index,
            prev.start_index,
            prev.end_index
          ),
          merged_into = prev.original_index,
          merged_from = range.original_index,
          old_end = old_end,
          new_end = prev.end_index,
        })
      else
        return nil,
          build_tool_error(
            compact_utils.COMPACT_RANGE_ERROR_TYPES.RANGE_OVERLAP_AFTER_NORMALIZATION,
            string.format(
              "range[%d]: start_index %d must be > previous end_index %d (ranges must be ordered and non-overlapping after normalization)",
              range.original_index,
              range.start_index,
              prev.end_index
            ),
            {
              range_index = range.original_index,
              previous_range = snapshot_ranges({ prev })[1],
              current_range = snapshot_ranges({ range })[1],
              normalized_ranges = snapshot_ranges(normalized),
              adjustments = all_adjustments,
              suggested_action = "reorder_or_merge_ranges",
              suggested_ranges = snapshot_ranges(prepared),
            }
          ),
          all_adjustments
      end
    else
      table.insert(normalized, {
        start_index = range.start_index,
        end_index = range.end_index,
        action = range.action,
        original_index = range.original_index,
      })
    end
  end

  return snapshot_ranges(normalized), nil, all_adjustments
end

--- 处理单个 summarize 区域
---@param messages table[] 当前消息列表（处理中的）
---@param range table 区域配置
---@param adapter_name string adapter 名称
---@param model_name string|nil 模型名称
---@param temperature number|nil 温度
---@param caller_chat table|nil 调用方 chat（用于共享 token_limit 重试计数器）
---@return table|nil result 处理结果 {preserved_messages, summary_message, llm_confirm}
---@return string|nil error 错误信息
local function prepare_summarize_range(messages, range)
  local start_index = range.start_index
  local end_index = range.end_index

  local conversation = create_conversation(messages, start_index, end_index)
  if conversation == "" then
    return nil, string.format("No conversation content in range %d-%d", start_index, end_index)
  end

  local compression_type = determine_compression_type(messages, start_index, end_index)
  local context_hint = build_context_hint(messages, start_index, end_index, compression_type)
  local prompt_template = SUMMARY_PROMPTS[compression_type]

  local prompt
  if compression_type == "full" then
    prompt = string.format(prompt_template, conversation)
  else
    prompt = string.format(prompt_template, context_hint, conversation)
  end

  local preserved_messages = compaction_messages.filter_range_messages_for_compact(messages, start_index, end_index)

  return {
    range = range,
    start_index = start_index,
    end_index = end_index,
    prompt = prompt,
    compression_type = compression_type,
    preserved_messages = preserved_messages,
  },
    nil
end

local function build_summarize_result(prepared, summary)
  local summary_intro
  if prepared.compression_type == "head" then
    summary_intro = string.format(
      "以下是对话开始部分（消息 %d-%d）的背景摘要：",
      prepared.start_index,
      prepared.end_index
    )
  elseif prepared.compression_type == "middle" then
    summary_intro = string.format(
      "以下是对话中间部分（消息 %d-%d）的摘要：",
      prepared.start_index,
      prepared.end_index
    )
  elseif prepared.compression_type == "tail" then
    summary_intro =
      string.format("以下是近期对话（消息 %d-%d）的摘要：", prepared.start_index, prepared.end_index)
  else
    summary_intro =
      string.format("以下是对话（消息 %d-%d）的摘要：", prepared.start_index, prepared.end_index)
  end

  local summary_message = {
    role = "user",
    content = string.format("%s\n\n%s\n\n", summary_intro, summary),
    _meta = {
      tag = "compact_summary",
      compression_type = prepared.compression_type,
    },
  }

  local confirm_content
  if prepared.compression_type == "head" then
    confirm_content = "我已了解对话的背景上下文，让我们继续之前的讨论。"
  elseif prepared.compression_type == "tail" then
    confirm_content = "我已了解近期的工作进展，准备好继续。请问需要处理什么任务？"
  else
    confirm_content = "我已阅读对话摘要，准备好继续我们的讨论。"
  end

  return {
    preserved_messages = prepared.preserved_messages,
    summary_message = summary_message,
    llm_confirm = {
      role = "llm",
      content = confirm_content,
    },
    compression_type = prepared.compression_type,
    summary_preview = summary:sub(1, 300) .. (summary:len() > 300 and "..." or ""),
  }
end

local function process_summarize_range(messages, range, adapter_name, model_name, temperature, reasoning_effort, caller_chat)
  local prepared, prepare_err = prepare_summarize_range(messages, range)
  if not prepared then
    return nil, prepare_err
  end

  local summary, llm_err =
    generate_summary_sync(adapter_name, prepared.prompt, model_name, temperature, reasoning_effort, caller_chat)
  if not summary then
    return nil, "Failed to generate summary - " .. (llm_err or "unknown error")
  end

  return build_summarize_result(prepared, summary), nil
end

---@param messages table[]
---@param batch_ranges table[]
---@param adapter_name string
---@param model_name string|nil
---@param temperature number|nil
---@param caller_chat table|nil
---@return table[]|nil
---@return string|nil
local function process_summarize_batch_async(
  messages,
  batch_ranges,
  adapter_name,
  model_name,
  temperature,
  reasoning_effort,
  caller_chat
)
  local prepared_batch = {}
  for index, range in ipairs(batch_ranges) do
    local prepared, prepare_err = prepare_summarize_range(messages, range)
    if not prepared then
      return nil, prepare_err
    end
    prepared_batch[index] = prepared
  end

  local pending = #prepared_batch
  local first_err = nil
  local results = {}

  for index, prepared in ipairs(prepared_batch) do
    generate_summary_async(
      adapter_name,
      prepared.prompt,
      model_name,
      temperature,
      reasoning_effort,
      caller_chat,
      function(summary, err)
        if err and not first_err then
          first_err = "Failed to generate summary - " .. err
        elseif summary then
          results[index] = build_summarize_result(prepared, summary)
        end
        pending = pending - 1
      end
    )
  end

  local completed = vim.wait(compact_opts().batch_wait_ms, function()
    return pending == 0
  end, 50)

  if not completed then
    return nil, string.format("Timed out waiting for summarize batch (%d pending)", pending)
  end

  if first_err then
    return nil, first_err
  end

  return results, nil
end

--- 处理单个 delete 区域
---@param messages table[] 当前消息列表
---@param range table 区域配置
---@return table result 处理结果 {preserved_messages}
local function process_delete_range(messages, range)
  local start_index = range.start_index
  local end_index = range.end_index

  -- 使用统一的过滤规则提取区间内需要保留的消息
  local preserved_messages = compaction_messages.filter_range_messages_for_compact(messages, start_index, end_index)

  return {
    preserved_messages = preserved_messages,
  }
end

--- 解析 summarize 最大并发数
---@param value number|nil
---@return number
local function resolve_max_concurrency(value)
  local concurrency = tonumber(value) or compact_opts().max_concurrency
  if concurrency == 0 then
    return math.huge
  end
  if concurrency < 1 then
    return 1
  end
  return math.floor(concurrency)
end

--- 判断前方 summarize range 是否依赖后方 summarize range 的摘要结果
--- 采用保守策略：只要后方摘要回写可能进入前方 prompt 的后文窗口，即视为依赖
---@param messages table[]
---@param front_range table
---@param back_range table
---@return boolean
local function has_prompt_dependency(messages, front_range, back_range)
  if not messages or not front_range or not back_range then
    return true
  end

  if front_range.action ~= ACTION_SUMMARIZE or back_range.action ~= ACTION_SUMMARIZE then
    return false
  end

  -- 仅讨论前方 range 对后方 range 的依赖；若顺序不成立，按无依赖处理
  if front_range.start_index >= back_range.start_index then
    return false
  end

  -- 当前实现中，后方 summarize 完成后会插入 2 条消息（summary_message + llm_confirm）
  -- 如果这两条回写消息可能落入前方 range 的 after-context 窗口，则前方 prompt 依赖后方结果
  local after_window_end = math.min(#messages, front_range.end_index + 5)
  local inserted_summary_index = back_range.start_index
  local inserted_confirm_index = back_range.start_index + 1

  if inserted_summary_index <= after_window_end or inserted_confirm_index <= after_window_end then
    return true
  end

  -- 保守策略：若后方 range 紧邻前方 range，视为依赖，避免遗漏 compression_type/保留消息分布影响
  if back_range.start_index <= front_range.end_index + 5 then
    return true
  end

  return false
end

--- 规划 summarize 批次
--- 仅对彼此无 prompt 依赖的 summarize range 分批；delete 由主流程继续串行处理
---@param messages table[]
---@param summarize_ranges table[]
---@param max_concurrency number|nil
---@return table[]
local function plan_summarize_batches(messages, summarize_ranges, max_concurrency)
  local limit = resolve_max_concurrency(max_concurrency)
  local batches = {}

  for _, range in ipairs(summarize_ranges or {}) do
    local placed = false
    for _, batch in ipairs(batches) do
      if #batch < limit then
        local has_dependency = false
        for _, existing in ipairs(batch) do
          if has_prompt_dependency(messages, range, existing) or has_prompt_dependency(messages, existing, range) then
            has_dependency = true
            break
          end
        end
        if not has_dependency then
          table.insert(batch, range)
          placed = true
          break
        end
      end
    end

    if not placed then
      table.insert(batches, { range })
    end
  end

  return batches
end

--- compact_range 工具处理函数
---@param req table 请求对象
---@param res table 响应对象
local function apply_range_result(working_messages, range, action, result)
  local new_working = {}

  for j = 1, range.start_index - 1 do
    table.insert(new_working, working_messages[j])
  end

  if result.preserved_messages then
    for _, msg in ipairs(result.preserved_messages) do
      table.insert(new_working, msg)
    end
  end

  if action == ACTION_SUMMARIZE then
    table.insert(new_working, result.summary_message)
    table.insert(new_working, result.llm_confirm)
  end

  for j = range.end_index + 1, #working_messages do
    table.insert(new_working, working_messages[j])
  end

  return new_working
end

local function compact_range(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local ranges = params.ranges
  local mode = param_utils.default(params.mode, compaction_messages.COMPRESS_MODE.AUTO)

  -- 压缩会话 save_id 校验
  local caller_chat = req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  if caller_chat and caller_chat._compact_target_save_id then
    local expected = caller_chat._compact_target_save_id
    if not save_id or save_id == "" then
      return respond_tool_error(
        res,
        compact_utils.COMPACT_RANGE_ERROR_TYPES.SAVE_ID_MISMATCH,
        string.format("compact_range: save_id is required for compression. Use: '%s'", expected),
        { expected_save_id = expected, suggested_action = "use_expected_save_id" }
      )
    end
    if save_id ~= expected then
      return respond_tool_error(
        res,
        compact_utils.COMPACT_RANGE_ERROR_TYPES.SAVE_ID_MISMATCH,
        string.format("compact_range: Invalid save_id '%s'. Expected: '%s'", save_id, expected),
        { expected_save_id = expected, actual_save_id = save_id, suggested_action = "use_expected_save_id" }
      )
    end
  end

  -- 单次调用保护：compact_range 成功后不允许重复调用
  if caller_chat and caller_chat._compact_range_succeeded then
    return respond_tool_error(
      res,
      compact_utils.COMPACT_RANGE_ERROR_TYPES.UNKNOWN,
      "compact_range: already succeeded. Task is complete — stop making more compact_range calls.",
      { retryable = false, suggested_action = "stop_after_success" }
    )
  end

  -- 获取消息来源
  local source, source_err = history_session.get_messages_source(save_id, req.caller)
  if not source then
    return respond_tool_error(
      res,
      compact_utils.COMPACT_RANGE_ERROR_TYPES.SOURCE_ERROR,
      "compact_range: " .. source_err,
      { retryable = false, suggested_action = "fix_session_source" }
    )
  end

  local messages = source.messages
  local total_count = #messages
  local chat = source.chat
  local chat_data = source.chat_data
  local actual_save_id = source.save_id

  -- 验证区域数组（返回规范化后的 ranges，包含 tool call 配对保护）
  local normalized_ranges, validate_err, range_adjustments = validate_ranges(ranges, total_count, messages)
  if validate_err then
    if type(validate_err) == "table" then
      validate_err.message = "compact_range: " .. (validate_err.message or "validation failed")
      return res:error(vim.json.encode(validate_err)):send()
    end
    return respond_tool_error(
      res,
      compact_utils.COMPACT_RANGE_ERROR_TYPES.UNKNOWN,
      "compact_range: " .. tostring(validate_err),
      { retryable = false }
    )
  end

  local protected_prefix_count = compaction_messages.get_protected_prefix_count(source)
  if protected_prefix_count > 0 then
    for i, range in ipairs(normalized_ranges) do
      local protected_err = compaction_messages.validate_range_against_protected_prefix(
        range.start_index,
        range.end_index,
        protected_prefix_count,
        "compact_range"
      )
      if protected_err then
        protected_err.range_index = i
        protected_err.normalized_ranges = snapshot_ranges(normalized_ranges)
        return res:error(vim.json.encode(protected_err)):send()
      end
    end
  end

  -- 如果有范围调整，记录日志
  if range_adjustments and #range_adjustments > 0 then
    vim.notify(
      string.format("[compact_range] 自动调整了 %d 个范围以保护 tool call 配对", #range_adjustments),
      vim.log.levels.INFO
    )
  end

  -- 从统一配置获取摘要专用 adapter
  -- adapter = "inherit" 时，继承当前/目标会话的 adapter 与 settings.model
  local mcp_config = require("maxa.mcphub.native_servers.config")
  local summary_cfg, summary_err = mcp_config.get_runtime_adapter("summary", {
    chat = chat,
    chat_data = chat_data,
  })
  if not summary_cfg then
    return respond_tool_error(
      res,
      compact_utils.COMPACT_RANGE_ERROR_TYPES.UNKNOWN,
      "compact_range: failed to load summary adapter config - " .. tostring(summary_err),
      { retryable = false, suggested_action = "fix_summary_adapter_config" }
    )
  end

  local function resolve_inherited_summary_config()
    local inherited_adapter = nil
    local inherited_model = nil
    local inherited_temperature = nil

    if chat and chat.adapter then
      inherited_adapter = chat.adapter.name
    end

    if chat and chat.settings and chat.settings.model then
      inherited_model = chat.settings.model
    elseif chat and chat.adapter then
      inherited_model = chat.adapter.model and chat.adapter.model.name or nil
    end

    if (not inherited_adapter or inherited_adapter == "") and chat_data then
      inherited_adapter = chat_data.adapter
    end

    if not inherited_model and chat_data and chat_data.settings then
      inherited_model = chat_data.settings.model
    end

    if chat and chat.settings and chat.settings.temperature ~= nil then
      inherited_temperature = chat.settings.temperature
    elseif chat_data and chat_data.settings then
      inherited_temperature = chat_data.settings.temperature
    end

    return inherited_adapter, inherited_model, inherited_temperature
  end

  local adapter_name = summary_cfg.adapter
  local model_name = summary_cfg.model
  local temperature = summary_cfg.temperature
  if summary_cfg.inherit then
    adapter_name, model_name, temperature = resolve_inherited_summary_config()
    model_name = summary_cfg.model or model_name
    if summary_cfg.temperature ~= nil then
      temperature = summary_cfg.temperature
    end
    if not adapter_name or adapter_name == "" then
      return respond_tool_error(
        res,
        compact_utils.COMPACT_RANGE_ERROR_TYPES.UNKNOWN,
        "compact_range: failed to inherit adapter from parent session",
        { retryable = false, suggested_action = "use_explicit_summary_adapter" }
      )
    end
  end

  -- 从后往前处理每个区域，收集处理结果
  -- 使用 working_messages 作为工作副本
  local working_messages = vim.deepcopy(messages)
  local range_results = {}
  local max_summarize_concurrency = resolve_max_concurrency(params.max_summarize_concurrency)

  local last_llm_call = false -- 是否上一轮做过 LLM 调用

  local i = #normalized_ranges
  while i >= 1 do
    local range = normalized_ranges[i]
    local action = range.action
    local result, err

    if action == ACTION_SUMMARIZE and max_summarize_concurrency > 1 then
      local summarize_segment = {}
      local range_to_index = {}
      local j = i
      while j >= 1 and normalized_ranges[j].action == ACTION_SUMMARIZE do
        local segment_range = normalized_ranges[j]
        table.insert(summarize_segment, segment_range)
        range_to_index[segment_range] = j
        j = j - 1
      end

      local batches = plan_summarize_batches(working_messages, summarize_segment, max_summarize_concurrency)
      for _, batch in ipairs(batches) do
        local batch_results, batch_err = process_summarize_batch_async(
          working_messages,
          batch,
          adapter_name,
          model_name,
          temperature,
          summary_cfg.reasoning_effort,
          caller_chat
        )
        if batch_err then
          local batch_index = range_to_index[batch[1]] or i
          return respond_tool_error(
            res,
            compact_utils.COMPACT_RANGE_ERROR_TYPES.SUMMARY_GENERATION_FAILED,
            string.format("compact_range: range[%d] - %s", batch_index, batch_err),
            { range_index = batch_index, suggested_action = "retry_or_reprobe_ranges" }
          )
        end

        for batch_pos, batch_range in ipairs(batch) do
          local global_index = range_to_index[batch_range]
          local batch_result = batch_results[batch_pos]
          range_results[global_index] = batch_result
          working_messages = apply_range_result(working_messages, batch_range, ACTION_SUMMARIZE, batch_result)
        end
      end

      last_llm_call = true
      i = j
    else
      if action == ACTION_SUMMARIZE then
        if last_llm_call then
          vim.wait(compact_opts().rate_limit_delay_ms)
        end
        result, err = process_summarize_range(
          working_messages,
          range,
          adapter_name,
          model_name,
          temperature,
          summary_cfg.reasoning_effort,
          caller_chat
        )
        last_llm_call = true
        if err then
          return respond_tool_error(
            res,
            compact_utils.COMPACT_RANGE_ERROR_TYPES.SUMMARY_GENERATION_FAILED,
            string.format("compact_range: range[%d] - %s", i, err),
            { range_index = i, suggested_action = "retry_or_reprobe_ranges" }
          )
        end
      elseif action == ACTION_DELETE then
        result = process_delete_range(working_messages, range)
      end

      range_results[i] = result
      working_messages = apply_range_result(working_messages, range, action, result)
      i = i - 1
    end
  end

  -- Global cleanup for committed Abilities and ordinary context files.
  local clean_config = {}
  if type(params.clean_abilities) == "table" and #params.clean_abilities > 0 then
    clean_config.abilities = params.clean_abilities
  end
  if type(params.clean_contexts) == "table" and #params.clean_contexts > 0 then
    clean_config.contexts = params.clean_contexts
  end
  local context_cleanup_count = 0
  if next(clean_config) then
    local ctx_cleaned, ctx_removed = loaded_items.clean_context_items(working_messages, clean_config)
    context_cleanup_count = (ctx_removed.abilities or 0) + (ctx_removed.contexts or 0) + (ctx_removed.tool_pairs or 0)
    if context_cleanup_count > 0 then
      vim.notify(
        string.format("[compact_range] 清理了 %d 个 context 相关消息", context_cleanup_count),
        vim.log.levels.INFO
      )
    end
    working_messages = ctx_cleaned
  end

  -- 🔄 Context 去重：相同 context.id 只保留最后一条（force_reload 场景）
  working_messages = compaction_messages.dedup_context_messages(working_messages)

  -- 🔒 最终清理：移除所有孤立的 tool 消息（双向检查）
  local cleaned_messages, removed_info = compaction_messages.clean_orphan_tool_messages(working_messages)
  if #removed_info > 0 then
    vim.notify(
      string.format("[compact_range] 清理了 %d 个孤立的 tool 消息", #removed_info),
      vim.log.levels.DEBUG
    )
  end
  working_messages = cleaned_messages

  -- 添加空的用户消息作为当前输入区域
  table.insert(working_messages, {
    role = "user",
    content = "",
  })

  local after_count = #working_messages

  local archive_result, archive_err = session_trace.archive_compression_ranges(source, normalized_ranges, {
    tool_name = "compact_range",
    mode = mode,
  })
  if not archive_result then
    return respond_tool_error(
      res,
      compact_utils.COMPACT_RANGE_ERROR_TYPES.APPLY_ERROR,
      "compact_range: failed to archive trace compression range - " .. tostring(archive_err),
      { retryable = false, suggested_action = "inspect_trace_archive_failure" }
    )
  end

  -- 应用压缩结果
  local apply_result, apply_err = history_session.apply_compression_result({
    messages = working_messages,
    mode = mode,
    source = source,
    adapter_name = adapter_name,
    on_new_session = function(new_chat)
      vim.notify(
        string.format(
          "[compact_range] 处理 %d 个区域. 总计: %d → %d",
          #normalized_ranges,
          total_count,
          after_count
        ),
        vim.log.levels.INFO
      )
    end,
  })

  if apply_err then
    return respond_tool_error(
      res,
      compact_utils.COMPACT_RANGE_ERROR_TYPES.APPLY_ERROR,
      "compact_range: " .. apply_err,
      { retryable = false, suggested_action = "inspect_apply_failure" }
    )
  end

  local applied_result, applied_err = session_trace.append_compression_applied(source, {
    tool_name = "compact_range",
    mode = mode,
    action = apply_result.action,
    new_save_id = apply_result.save_id,
    original_save_id = apply_result.original_save_id,
    pending = apply_result.pending,
    archives = archive_result.archives,
    stats = {
      total_before = total_count,
      total_after = after_count,
      ranges_processed = #normalized_ranges,
      context_items_cleaned = context_cleanup_count,
      range_adjustments = range_adjustments and #range_adjustments or 0,
    },
  })
  if not applied_result then
    return respond_tool_error(
      res,
      compact_utils.COMPACT_RANGE_ERROR_TYPES.APPLY_ERROR,
      "compact_range: compression applied but failed to append trace event - " .. tostring(applied_err),
      { retryable = false, suggested_action = "inspect_trace_event_failure" }
    )
  end

  -- 构建区域处理结果摘要
  local ranges_summary = {}
  for i, range in ipairs(normalized_ranges) do
    local result = range_results[i]
    local summary_item = {
      range = string.format("%d-%d", range.start_index, range.end_index),
      action = range.action,
    }
    if range.action == ACTION_SUMMARIZE and result then
      summary_item.compression_type = result.compression_type
      summary_item.summary_preview = result.summary_preview
    end
    table.insert(ranges_summary, summary_item)
  end

  -- 返回结果
  local response_data = {
    source = source.source_type,
    save_id = actual_save_id,
    mode = mode,
    action = apply_result.action,
    stats = {
      total_before = total_count,
      total_after = after_count,
      ranges_processed = #normalized_ranges,
      context_items_cleaned = context_cleanup_count,
      range_adjustments = range_adjustments and #range_adjustments or 0,
    },
    ranges = ranges_summary,
    adjustments = range_adjustments,
  }

  -- 如果是新建模式且生成了新 save_id
  if apply_result.save_id then
    response_data.new_save_id = apply_result.save_id
  end
  if apply_result.original_save_id then
    response_data.original_save_id = apply_result.original_save_id
  end

  -- 压缩会话结果拦截：将 new_save_id 写入 caller chat 标记，
  -- 供显式压缩工具调用方读取（不依赖 LLM 文本解析）
  if caller_chat and caller_chat._compact_target_save_id and apply_result.save_id then
    caller_chat._compact_result_save_id = apply_result.save_id
    caller_chat._compact_range_succeeded = true -- 单次调用保护标记
  end

  local result = history_core.create_response(response_data)
  return res:text(vim.json.encode(result)):send()
end

return {
  _test = {
    generate_summary_sync = generate_summary_sync,
    resolve_max_concurrency = resolve_max_concurrency,
    has_prompt_dependency = has_prompt_dependency,
    plan_summarize_batches = plan_summarize_batches,
    validate_ranges = validate_ranges,
    build_tool_error = build_tool_error,
  },
  name = "compact_range",
  description = table.concat({
    "Process ordered, non-overlapping ranges in a current or saved chat.",
    "Actions: summarize via LLM or delete; system messages are preserved.",
    "Use probe_messages first to locate indices; positive indices are 1-based and negative indices count from the end.",
    "Optional clean_abilities/clean_contexts remove committed capability/context state globally, not only inside ranges.",
    "Modes: auto (current→new, saved→overwrite), overwrite, new.",
  }, " "),

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
      ranges = {
        type = "array",
        description = "Ordered, non-overlapping ranges to summarize or delete.",
        items = {
          type = "object",
          properties = {
            start_index = {
              type = "number",
              description = "Range start index from probe_messages; positive indices are 1-based.",
            },
            end_index = {
              type = "number",
              description = "Range end index from probe_messages; -1 means last message.",
            },
            action = {
              type = "string",
              enum = { "summarize", "delete" },
              description = "summarize via LLM or delete messages; system messages are preserved.",
            },
          },
          required = { "start_index", "end_index", "action" },
        },
        minItems = 1,
      },
      max_summarize_concurrency = {
        type = "number",
        description = "Summarize concurrency: 1 serial, >1 limited parallel, 0 unlimited upper bound but dependency-constrained.",
      },
      clean_abilities = {
        type = "array",
        items = { type = "string" },
        description = "Ability identifiers to remove globally, including revision contexts and catalog-bearing tool-call pairs.",
      },
      clean_contexts = {
        type = "array",
        items = { type = "string" },
        description = "Context file paths to remove globally, including context messages and tool-call pairs.",
      },
    },
    required = { "ranges" },
  },

  handler = compact_range,
}
