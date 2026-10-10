-- search_messages: 搜索会话消息内容（纯文本匹配）
local history_core = require("maxa.session.history_core")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

local SUMMARY_MAX_LENGTH = 300
local TRUNCATE_SUFFIX = "...[truncated]"

--- 获取匹配位置周围的上下文片段
---@param content string|nil 完整内容
---@param query_lower string 小写查询词
---@param max_len number 最大片段长度
---@return string|nil snippet
local function get_match_snippet(content, query_lower, max_len)
  if not content or type(content) ~= "string" then
    return nil
  end

  local pos = content:lower():find(query_lower, 1, true)
  if not pos then
    -- 没找到匹配（可能是 tool name/arguments 匹配），截断返回
    if #content <= max_len then
      return content
    end
    return content:sub(1, max_len - #TRUNCATE_SUFFIX) .. TRUNCATE_SUFFIX
  end

  -- 在匹配位置周围取上下文
  local context_chars = math.floor((max_len - #query_lower) / 2)
  local start_pos = math.max(1, pos - context_chars)
  local end_pos = math.min(#content, pos + #query_lower + context_chars)

  local snippet = ""
  if start_pos > 1 then
    snippet = "..."
  end
  snippet = snippet .. content:sub(start_pos, end_pos)
  if end_pos < #content then
    snippet = snippet .. "..."
  end

  return snippet
end

-- 外部 role → CC 内部 role
local ROLE_MAP = {
  user = "user",
  assistant = "llm",
  tool = "tool",
}

--- 检查消息内容是否包含查询文本（大小写不敏感，纯字符串匹配）
---@param msg table 消息对象
---@param query_lower string 小写查询词
---@return boolean
local function content_matches(msg, query_lower)
  -- 文本内容
  if msg.content and type(msg.content) == "string" then
    if msg.content:lower():find(query_lower, 1, true) then
      return true
    end
  end

  -- 工具调用：搜索函数名 + 参数
  if msg.tools and msg.tools.calls then
    for _, call in ipairs(msg.tools.calls) do
      local func = call["function"]
      if func then
        if func.name and func.name:lower():find(query_lower, 1, true) then
          return true
        end
        if func.arguments and type(func.arguments) == "string" and func.arguments:lower():find(query_lower, 1, true) then
          return true
        end
      end
    end
  end

  return false
end

--- 搜索消息处理函数
---@param req table 请求对象
---@param res table 响应对象
local function search_messages(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local query = params.query
  local role = params.role
  local max_results = param_utils.default(params.max_results, 5)
  local mode = param_utils.default(params.mode, "summary")

  -- 验证 query
  if not query or query == "" then
    return res:error("search_messages: query is required")
  end

  -- 验证 mode
  if mode ~= "full" and mode ~= "summary" then
    return res:error("search_messages: mode must be 'full' or 'summary'")
  end

  -- 验证 role
  if role then
    if not ROLE_MAP[role] then
      return res:error("search_messages: role must be one of: user, assistant, tool")
    end
  end

  -- 验证 max_results
  if type(max_results) ~= "number" or max_results < 1 then
    return res:error("search_messages: max_results must be a positive number")
  end
  max_results = math.floor(max_results)

  -- 获取消息
  local messages, source_type
  if not save_id or save_id == "" then
    if not req.caller or not req.caller.maxa_ai then
      return res:error("search_messages: No current session found (must be called from a Maxa AI chat or provide save_id)")
    end
    local chat = req.caller.maxa_ai.chat
    if not chat or not chat.messages then
      return res:error("search_messages: Current session has no messages")
    end
    messages = chat.messages
    source_type = "current"
    save_id = chat.opts and chat.opts.save_id or nil
  else
    local chat_data, err = history_core.read_chat(save_id)
    if not chat_data then
      return res:error("search_messages: Failed to read chat - " .. (err or "unknown error"))
    end
    messages = chat_data.messages or {}
    source_type = "saved"
  end

  local query_lower = query:lower()
  local matches = {}

  for i, msg in ipairs(messages) do
    -- 角色过滤
    if role then
      local internal_role = ROLE_MAP[role]
      if msg.role ~= internal_role then
        goto continue
      end
    end

    -- 内容匹配
    if content_matches(msg, query_lower) then
      local match_entry = {
        index = i,
        role = msg.role == "llm" and "assistant" or msg.role,
      }

      if mode == "summary" then
        match_entry.snippet = get_match_snippet(msg.content, query_lower, SUMMARY_MAX_LENGTH)
      else
        match_entry.content = msg.content
      end

      -- 工具调用信息
      if msg.tools and msg.tools.calls then
        match_entry.tool_calls = {}
        for _, call in ipairs(msg.tools.calls) do
          local func = call["function"]
          if func then
            table.insert(match_entry.tool_calls, { name = func.name })
          end
        end
      end

      -- 错误标记
      if msg.role == "tool" and history_core.is_tool_error(msg) then
        match_entry.is_error = true
      end

      table.insert(matches, match_entry)

      if #matches >= max_results then
        break
      end
    end

    ::continue::
  end

  local result = history_core.create_response({
    source = source_type,
    save_id = save_id,
    query = query,
    role = role,
    total_messages = #messages,
    matches = matches,
    returned_count = #matches,
    max_results = max_results,
    truncated = #matches >= max_results,
  })

  return res:text(vim.json.encode(result)):send()
end

return {
  name = "search_messages",
  description = "Search current or saved chat by case-insensitive plain string across content, tool names, and tool arguments; returns snippets or full matches.",

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Saved chat ID; omitted searches current chat.",
      },
      query = {
        type = "string",
        description = "Plain string query; case-insensitive across content, tool names, and tool arguments.",
      },
      role = {
        type = "string",
        enum = { "user", "assistant", "tool" },
        description = "Optional role filter.",
      },
      max_results = {
        type = "number",
        description = "Maximum matches; default 5.",
      },
      mode = {
        type = "string",
        enum = { "full", "summary" },
        description = "summary returns snippets around matches; full returns complete message content.",
      },
    },
    required = { "query" },
  },

  handler = search_messages,
}
