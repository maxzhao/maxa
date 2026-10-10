-- get_session_stats: 会话结构概览（一次调用返回完整统计）
-- 避免多次调用 get_messages / lua 拼凑信息

local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local session_status = require("maxa.session.session_status")

-- ═══════════════════════════════════════════════════════════
-- 消息分类与统计
-- ═══════════════════════════════════════════════════════════

--- 判断消息是否包含 tool_calls
---@param msg table
---@return boolean
local function has_tool_calls(msg)
  if msg.tool_calls and #msg.tool_calls > 0 then
    return true
  end
  if msg.tools and msg.tools.calls and #msg.tools.calls > 0 then
    return true
  end
  return false
end

--- 统计消息分布
---@param messages table[]
---@return table counts, table meta_tags
local function analyze_messages(messages)
  local counts = {
    total = #messages,
    system = 0,
    user = 0,
    llm = 0,
    tool_call = 0,
    tool_result = 0,
  }

  local meta_tags = {}

  for _, msg in ipairs(messages) do
    local role = msg.role

    -- 角色计数
    if role == "system" then
      counts.system = counts.system + 1
    elseif role == "user" then
      counts.user = counts.user + 1
    elseif role == "assistant" or role == "llm" then
      if has_tool_calls(msg) then
        counts.tool_call = counts.tool_call + 1
      else
        counts.llm = counts.llm + 1
      end
    elseif role == "tool" then
      counts.tool_result = counts.tool_result + 1
    end

    -- _meta tag 统计
    local meta = msg._meta or (msg.opts and msg.opts._meta) or {}
    if meta.tag then
      meta_tags[meta.tag] = (meta_tags[meta.tag] or 0) + 1
    end
  end

  return counts, meta_tags
end

-- ═══════════════════════════════════════════════════════════
-- Handler
-- ═══════════════════════════════════════════════════════════

local function handler(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local source_type, messages, adapter_name, model_name, token_current
  local chat_data_for_status, chat_for_status

  if save_id then
    -- 历史会话：从文件加载
    local history_api = history_session.get_history_api()
    if not history_api then
      return res:error("History API not available"):send()
    end
    local chat_data = history_api.load_chat(save_id)
    if not chat_data then
      return res:error("Session not found: " .. save_id):send()
    end

    chat_data_for_status = chat_data
    source_type = "saved"
    messages = chat_data.messages or {}
    adapter_name = chat_data.adapter or "unknown"
    model_name = chat_data.settings and chat_data.settings.model or nil

    -- 估算 token（无实时数据）
    local total_chars = 0
    for _, msg in ipairs(messages) do
      if type(msg.content) == "string" then
        total_chars = total_chars + #msg.content
      end
    end
    token_current = math.floor(total_chars / 4) -- 粗略估算
  else
    -- 当前会话
    local caller = req.caller
    local chat = caller and caller.maxa_ai and caller.maxa_ai.chat

    if not chat then
      -- 回退：尝试 last_chat
      local cc = require("maxa")
      chat = cc.last_chat and cc.last_chat()
    end

    if not chat then
      return res:error("No active chat session"):send()
    end

    chat_for_status = chat
    source_type = "current"
    messages = chat.messages or {}
    save_id = chat.opts and chat.opts.save_id or nil

    -- adapter 信息
    local adapter = chat.adapter
    if adapter then
      adapter_name = adapter.name or "unknown"
      if adapter.model and type(adapter.model) == "table" and type(adapter.model.name) == "string" then
        model_name = adapter.model.name
      elseif adapter.schema and adapter.schema.model then
        local default = adapter.schema.model.default
        if type(default) == "function" then
          local ok, value = pcall(default, adapter)
          if ok and type(value) == "string" then
            model_name = value
          end
        elseif type(default) == "string" then
          model_name = default
        end
      end
      -- 使用 _total_tokens（与 UI 显示一致），回退到 ui.tokens
      if adapter._total_tokens and adapter._total_tokens > 0 then
        token_current = adapter._total_tokens
      end
    else
      adapter_name = "unknown"
    end

    -- 回退到 ui.tokens (total_tokens)
    if not token_current then
      token_current = chat.ui and chat.ui.tokens or 0
    end
  end

  -- 消息分析
  local counts, meta_tags = analyze_messages(messages)

  local context_status = session_status.to_llm(
    chat_for_status and session_status.from_chat(chat_for_status)
      or session_status.from_chat_data(chat_data_for_status, save_id)
  )

  -- 构建 token_usage（保持旧字段，但复用 context_status，避免双源不一致）
  local status_tokens = context_status and context_status.tokens or {}
  local token_usage = {
    current = status_tokens.used or token_current,
  }
  if source_type == "saved" or status_tokens.source == "estimated" then
    token_usage.estimated = true
  end
  if status_tokens.limit then
    token_usage.context_window = status_tokens.limit
  end
  if status_tokens.percent then
    token_usage.ratio = string.format("%d%%", status_tokens.percent)
  end

  -- 构建响应
  local result = {
    save_id = save_id,
    source = source_type,
    adapter = adapter_name,
    model = model_name,
    message_counts = counts,
    meta_tags = meta_tags,
    token_usage = token_usage,
    context_status = context_status,
  }

  return res:text(vim.json.encode(history_core.create_response(result))):send()
end

return {
  name = "get_session_stats",
  description = "Return session statistics: role counts, _meta tag distribution, context_status/token_usage, and loaded-item counts.",
  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Saved chat ID; omitted analyzes current chat.",
      },
    },
  },
  handler = handler,
}
