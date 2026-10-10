-- get_chat_summary: 获取会话摘要信息
local history_core = require("maxa.session.history_core")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local session_status = require("maxa.session.session_status")

return {
  name = "get_chat_summary",
  description = "Return saved chat metadata, role/tool counts, used tool names, and context_status.",

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Required saved chat ID.",
      },
    },
    required = { "save_id" },
  },

  handler = function(req, res)
    local params = param_utils.normalize(req.params)
    local save_id = params.save_id

    -- 参数验证
    if not save_id or save_id == "" then
      return res:error("Missing required parameter: save_id")
    end

    -- 读取会话数据
    local chat_data, err = history_core.read_chat(save_id)
    if not chat_data then
      return res:error("Failed to load chat: " .. (err or "unknown error"))
    end

    -- 提取基本信息
    local settings = chat_data.settings or {}
    local messages = chat_data.messages or {}

    -- 统计消息类型
    local stats = history_core.count_message_types(messages)

    -- 提取使用的工具名称（去重）
    local tools_used_set = {}
    local tools_used = {}

    for _, msg in ipairs(messages) do
      -- 检查 LLM 消息中的工具调用
      if msg.role == "llm" and msg.tools and msg.tools.calls then
        for _, call in ipairs(msg.tools.calls) do
          local func = call["function"]
          if func and func.name then
            local tool_name = func.name
            if not tools_used_set[tool_name] then
              tools_used_set[tool_name] = true
              table.insert(tools_used, tool_name)
            end
          end
        end
      end
    end

    -- 构建响应
    local summary = {
      save_id = chat_data.save_id or save_id,
      title = chat_data.title or history_core.get_chat_title(messages),
      updated_at = chat_data.updated_at,
      model = settings.model,
      adapter = chat_data.adapter,
      statistics = {
        total_messages = stats.total,
        user_messages = stats.user,
        llm_messages = stats.llm,
        tool_calls = stats.tool_calls,
        tool_errors = stats.tool_errors,
        system_messages = stats.system,
      },
      tools_used = tools_used,
      context_status = session_status.to_llm(session_status.from_chat_data(chat_data, save_id)),
    }

    return res:text(vim.json.encode(history_core.create_response(summary)))
  end,
}
