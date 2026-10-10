-- subagent MCP Server 的公用工具函数
local M = {}

-- ============================================================================
-- 递归深度管理
-- ============================================================================

--- Recursion depth metadata key on Maxa AI Chat objects.
M.RECURSION_DEPTH_KEY = "_subagent_recursion_depth"

--- 获取 Chat 的子代理递归深度。
--- 主会话没有该字段时视为 0；子代理 Chat 在创建后写入 parent_depth + 1。
--- @param chat table|nil Maxa AI Chat 实例
--- @return number depth 当前 Chat 所处子代理深度
function M.get_chat_recursion_depth(chat)
  if not chat then
    return 0
  end

  local depth = chat[M.RECURSION_DEPTH_KEY]
  if type(depth) ~= "number" then
    depth = chat._subagent_recursion_depth
  end
  if type(depth) ~= "number" or depth < 0 then
    return 0
  end
  return math.floor(depth)
end

--- 将新创建的子代理 Chat 标记为 parent_depth + 1。
--- @param parent_chat table|nil 父 Chat
--- @param child_chat table|nil 新创建的子代理 Chat
--- @return number depth 写入的子代理深度
function M.set_child_recursion_depth(parent_chat, child_chat)
  local depth = M.get_chat_recursion_depth(parent_chat) + 1
  if child_chat then
    child_chat[M.RECURSION_DEPTH_KEY] = depth
    child_chat._subagent_recursion_depth = depth
  end
  return depth
end

--- 检查是否可以从父 Chat 创建新的子代理（限制递归调用深度）。
--- @param tool_name string 要执行的工具名称
--- @param parent_chat table|nil 父 Chat 实例；nil 视为主会话 depth=0
--- @return boolean allowed 是否允许执行
--- @return string|nil error 错误消息（如果不允许）
function M.check_execution_allowed(tool_name, parent_chat)
  if parent_chat and parent_chat._maxa_hidden_image_analysis then
    return false,
      string.format(
        "Hidden image-analysis child cannot start '%s'; delegation and recursive analysis are disabled for its hard max_steps budget.",
        tostring(tool_name)
      )
  end
  local subagent_config = require("maxa.mcphub.native_servers.subagent.config")
  local max_depth = subagent_config.MAX_RECURSION_DEPTH
  local current_depth = M.get_chat_recursion_depth(parent_chat)

  if current_depth >= max_depth then
    return false,
      string.format(
        "Sub-agent recursion depth limit reached: cannot start '%s' from parent depth %d because max depth is %d. "
          .. "This prevents infinite nested sub-agent loops.",
        tool_name,
        current_depth,
        max_depth
      )
  end

  return true, nil
end

--- 兼容旧调用：深度改为绑定在 Chat 上，不再使用全局递增计数。
function M.mark_execution_start(_) end

--- 兼容旧调用：深度改为绑定在 Chat 上，不再使用全局递减计数。
function M.mark_execution_end() end

--- 获取当前执行状态（用于调试兼容）。
--- @return table 执行状态
function M.get_execution_state()
  return { active = false, tool = nil, depth = 0 }
end

--- 重置执行状态（用于测试或错误恢复；Chat 绑定深度无需全局重置）。
function M.reset_execution_state() end

M.WARMUP_MODES = { auto = true, force = true, disable = true }

--- 规范化 subagent warmup 参数。
--- @param value any
--- @return string|nil mode
--- @return string|nil error
function M.normalize_warmup_mode(value)
  if value == nil then
    return "auto", nil
  end
  if type(value) ~= "string" then
    return nil, "warmup must be one of: auto, force, disable"
  end
  if not M.WARMUP_MODES[value] then
    return nil, "warmup must be one of: auto, force, disable"
  end
  return value, nil
end

--- 为 chat 配置 session default_session_cache warmup。
--- mode=auto 时仍由 default_session_cache 自行判断是否符合默认对话特征；
--- mode=force 时使用调用方给出的 prefix_count 强制缓存该前缀。
--- @param chat table|nil
--- @param mode string|nil auto|force|disable
--- @param prefix_count number|nil
--- @param kind string|nil
--- @return boolean
function M.configure_chat_warmup(chat, mode, prefix_count, kind)
  if type(chat) ~= "table" then
    return false
  end
  local normalized = M.normalize_warmup_mode(mode)
  normalized = normalized or "auto"
  local ok, cache = pcall(require, "maxa.session.default_session_cache")
  if not ok or type(cache) ~= "table" or type(cache.configure_chat) ~= "function" then
    return false
  end
  return cache.configure_chat(chat, {
    mode = normalized,
    prefix_count = prefix_count,
    kind = kind,
  })
end

local WARMUP_SCHEMA_PROPERTY = {
  type = "string",
  enum = { "auto", "force", "disable" },
  default = "auto",
  description = "Prompt-cache warmup mode for fresh-prefix child sessions: auto uses default-session cache when eligible, force warms the fixed prefix, disable skips warmup/cache reuse.",
}

function M.warmup_schema_property()
  return vim.deepcopy(WARMUP_SCHEMA_PROPERTY)
end

-- ============================================================================
-- 参数验证函数
-- ============================================================================

--- 验证必需的字符串参数
--- @param value any 要验证的值
--- @param param_name string 参数名称
--- @return boolean, string|nil 是否有效，错误消息（如果无效）
function M.validate_required_string(value, param_name)
  if value == nil then
    return false, param_name .. " parameter is required. Please provide a valid value."
  end

  if type(value) ~= "string" then
    return false, param_name .. " parameter must be a string, got " .. type(value) .. "."
  end

  if value == "" or value:match("^%s*$") then
    return false, param_name .. " parameter cannot be empty. Please provide a valid value."
  end

  return true, nil
end

--- 验证可选的字符串参数
--- @param value any 要验证的值
--- @param param_name string 参数名称
--- @return boolean, string|nil 是否有效，错误消息（如果无效）
function M.validate_optional_string(value, param_name)
  if value == nil then
    return true, nil
  end

  if type(value) ~= "string" then
    return false, param_name .. " parameter must be a string, got " .. type(value) .. "."
  end

  return true, nil
end

--- 创建标准响应对象
--- @param data table 响应数据
--- @return table 格式化的响应对象
function M.create_response(data)
  return {
    success = true,
    data = data,
    timestamp = os.date("%Y-%m-%dT%H:%M:%S"),
  }
end

--- 创建带 recovery 元数据的错误消息（保持 MCP tool call 错误语义）
--- @param tool_name string 工具名称
--- @param error_msg any 错误消息
--- @param recovery table|nil 可恢复元数据（如 save_id/source_save_id/parent_save_id）
--- @return string message 错误消息；有 recovery 时追加 `| recovery={...}`
function M.format_recoverable_error(tool_name, error_msg, recovery)
  local message = M.format_error(tool_name, tostring(error_msg or "Unknown error"))

  local payload = {}
  if recovery and type(recovery) == "table" then
    for key, value in pairs(recovery) do
      if value ~= nil then
        payload[key] = value
      end
    end
  end

  if next(payload) then
    message = message .. " | recovery=" .. vim.json.encode(payload)
  end

  return message
end

--- 发送带 recovery 元数据的 MCP 错误响应；UI 仍显示工具调用失败
--- @param res table MCP 响应对象
--- @param tool_name string 工具名称
--- @param error_msg any 错误消息
--- @param recovery table|nil 可恢复元数据
function M.send_recoverable_error(res, tool_name, error_msg, recovery)
  res:error(M.format_recoverable_error(tool_name, error_msg, recovery))
end

--- 格式化错误消息
--- @param tool_name string 工具名称
--- @param error_msg string 错误消息
--- @return string 格式化的错误消息
function M.format_error(tool_name, error_msg)
  return tool_name .. ": " .. error_msg
end

--- 检查 MaxaAI 是否可用
--- @return boolean, string|nil 是否可用，错误消息（如果不可用）
function M.check_maxa_ai_available()
  local ok, _ = pcall(require, "maxa")
  if not ok then
    return false, "Maxa AI runtime is not available."
  end

  local bg_ok, _ = pcall(require, "maxa.interactions.background")
  if not bg_ok then
    return false, "Maxa AI Background module is not available."
  end

  return true, nil
end

--- 构建 LLM 消息格式
--- @param prompt string 用户提示词
--- @param system_prompt string|nil 系统提示词
--- @return table[] messages 消息数组
function M.build_messages(prompt, system_prompt)
  local messages = {}

  -- 添加 system 消息（如果提供）
  if system_prompt and system_prompt ~= "" then
    table.insert(messages, {
      role = "system",
      content = system_prompt,
    })
  end

  -- 添加 user 消息
  table.insert(messages, {
    role = "user",
    content = prompt,
  })

  return messages
end

--- 解析 LLM 响应
--- @param result table LLM 返回的结果
--- @return string|nil content 响应内容
--- @return string|nil error 错误消息
function M.parse_llm_response(result)
  if not result then
    return nil, "LLM returned empty response"
  end

  -- 检查响应状态
  if result.status ~= "success" then
    local error_msg = "LLM request failed"
    if result.error then
      error_msg = error_msg .. ": " .. tostring(result.error)
    end
    return nil, error_msg
  end

  -- 提取内容
  if result.output and result.output.content then
    return result.output.content, nil
  end

  return nil, "LLM response does not contain content"
end

--- 从 chat messages 中提取最终的 LLM 响应
--- @param messages table chat.messages 数组
--- @param start_index number|nil 可选的起始索引，只在此索引之后查找
--- @return string|nil 最终响应内容
function M.extract_final_response(messages, start_index)
  if not messages or #messages == 0 then
    return nil
  end

  -- 确定搜索的起始位置
  local search_start = start_index or 1

  -- 从后向前查找最后一个有内容的 assistant/llm 消息
  -- 跳过 content 为 nil 的消息（通常是工具调用消息）
  for i = #messages, search_start, -1 do
    local msg = messages[i]
    if msg.role == "assistant" or msg.role == "llm" then
      if msg.content and msg.content ~= "" then
        return msg.content
      end
      -- 如果 content 为 nil 但有 tools，继续查找上一条消息
    end
  end

  return nil
end

--- 从 forked chat messages 中提取子代理的响应
--- 专门用于 fork_agent，只在 fork 后的消息中查找
--- @param messages table chat.messages 数组
--- @param fork_start_index number fork 开始时的消息索引（fork 后添加的第一条消息的索引）
--- @return string|nil 最终响应内容
--- @return string|nil 调试信息
function M.extract_forked_response(messages, fork_start_index)
  if not messages or #messages == 0 then
    return nil, "empty messages"
  end

  if not fork_start_index or fork_start_index < 1 then
    return nil, "invalid fork_start_index"
  end

  -- 只在 fork 后的消息中查找
  -- fork_start_index 是 fork 时父会话的消息数量，所以子代理的消息从 fork_start_index + 1 开始
  local search_start = fork_start_index + 1

  if search_start > #messages then
    return nil, string.format("no messages after fork (fork_start=%d, total=%d)", fork_start_index, #messages)
  end

  -- 收集调试信息
  local debug_info = string.format("searching from %d to %d (total=%d)", search_start, #messages, #messages)

  -- 从后向前查找最后一个有内容的 assistant/llm 消息
  for i = #messages, search_start, -1 do
    local msg = messages[i]
    if msg.role == "assistant" or msg.role == "llm" then
      if msg.content and msg.content ~= "" then
        return msg.content, debug_info .. string.format(", found at %d", i)
      end
    end
  end

  -- 如果没找到，返回调试信息
  return nil, debug_info .. ", no valid response found"
end

--- 检查 Maxa AI Chat 模块是否可用
--- @return boolean, string|nil 是否可用，错误消息（如果不可用）
function M.check_chat_available()
  local ok, _ = pcall(require, "maxa")
  if not ok then
    return false, "Maxa AI runtime is not available."
  end

  local chat_ok, _ = pcall(require, "maxa.interactions.chat")
  if not chat_ok then
    return false, "Maxa AI Chat module is not available."
  end

  return true, nil
end

--- 验证 context 参数
--- @param context any context 数组
--- @return boolean, string|nil 是否有效，错误消息（如果无效）
function M.validate_context(context)
  if context == nil then
    return true, nil
  end

  if type(context) ~= "table" then
    return false, "'context' must be an array, got " .. type(context)
  end

  local valid_types = { file = true, symbols = true, url = true, image = true }

  for i, item in ipairs(context) do
    if type(item) ~= "table" then
      return false, string.format("context[%d] must be an object, got %s", i, type(item))
    end

    -- 验证 type 字段
    if not item.type then
      return false, string.format("context[%d] is missing 'type' field", i)
    end

    if not valid_types[item.type] then
      return false,
        string.format("context[%d] has invalid type '%s'. Valid types: file, symbols, url, image", i, item.type)
    end

    -- 根据 type 验证必需字段
    if item.type == "file" or item.type == "symbols" then
      if not item.path then
        return false, string.format("context[%d] (type='%s') is missing 'path' field", i, item.type)
      end
      -- path 可以是字符串或数组
      if type(item.path) ~= "string" and type(item.path) ~= "table" then
        return false, string.format("context[%d].path must be a string or array, got %s", i, type(item.path))
      end
    elseif item.type == "url" then
      if not item.url then
        return false, string.format("context[%d] (type='url') is missing 'url' field", i)
      end
      if type(item.url) ~= "string" then
        return false, string.format("context[%d].url must be a string, got %s", i, type(item.url))
      end
    elseif item.type == "image" then
      if not item.path then
        return false, string.format("context[%d] (type='image') is missing 'path' field", i)
      end
      if type(item.path) ~= "string" then
        return false, string.format("context[%d].path must be a string for image type, got %s", i, type(item.path))
      end
    end
  end

  return true, nil
end

--- 验证 messages 参数
--- @param messages any 要验证的 messages
--- @param opts table|nil 选项 { require_user = true (默认) }
--- @return boolean, string|nil 是否有效，错误消息（如果无效）
--- context 消息的合法 type 值
local VALID_CONTEXT_TYPES = { file = true, symbols = true, url = true, image = true }

function M.validate_messages(messages, opts)
  opts = opts or {}
  local require_user = opts.require_user ~= false -- 默认 true
  if opts.optional and (messages == nil or messages == vim.NIL) then
    return true, nil
  end
  if messages == nil or messages == vim.NIL then
    return false, "'messages' parameter is required. Please provide an array of message objects."
  end

  if type(messages) ~= "table" then
    return false, "'messages' must be an array, got " .. type(messages)
  end

  if #messages == 0 and not opts.optional then
    return false, "'messages' array cannot be empty. Please provide at least one message."
  end

  local has_user_message = false

  for i, msg in ipairs(messages) do
    if type(msg) ~= "table" then
      return false, string.format("messages[%d] must be an object, got %s", i, type(msg))
    end

    if not msg.role then
      return false, string.format("messages[%d] is missing 'role' field", i)
    end

    if type(msg.role) ~= "string" then
      return false, string.format("messages[%d].role must be a string, got %s", i, type(msg.role))
    end

    if msg.role == "context" then
      -- context 类型消息：验证 type 和对应字段
      if not msg.type then
        return false, string.format("messages[%d] (role='context') is missing 'type' field", i)
      end
      if not VALID_CONTEXT_TYPES[msg.type] then
        return false,
          string.format(
            "messages[%d] has invalid context type '%s'. Valid types: file, symbols, url, image",
            i,
            msg.type
          )
      end
      -- 根据 type 验证必需字段
      if msg.type == "file" or msg.type == "symbols" then
        if not msg.path then
          return false, string.format("messages[%d] (type='%s') is missing 'path' field", i, msg.type)
        end
        if type(msg.path) ~= "string" and type(msg.path) ~= "table" then
          return false, string.format("messages[%d].path must be a string or array, got %s", i, type(msg.path))
        end
      elseif msg.type == "url" then
        if not msg.url then
          return false, string.format("messages[%d] (type='url') is missing 'url' field", i)
        end
        if type(msg.url) ~= "string" then
          return false, string.format("messages[%d].url must be a string, got %s", i, type(msg.url))
        end
      elseif msg.type == "image" then
        if not msg.path then
          return false, string.format("messages[%d] (type='image') is missing 'path' field", i)
        end
        if type(msg.path) ~= "string" then
          return false, string.format("messages[%d].path must be a string for image type, got %s", i, type(msg.path))
        end
      end
    elseif msg.role == "tool_call" then
      if type(msg.name) ~= "string" or vim.trim(msg.name) == "" then
        return false, string.format("messages[%d].name must be a nonblank registered tool name", i)
      end
      if type(msg.args) ~= "table" or (next(msg.args) ~= nil and vim.islist(msg.args)) then
        return false, string.format("messages[%d].args must be a parameter object", i)
      end
      for key in pairs(msg) do
        if key ~= "role" and key ~= "name" and key ~= "args" then
          return false, string.format("messages[%d] (role='tool_call') has unsupported field '%s'", i, tostring(key))
        end
      end
    elseif msg.role == "user" or msg.role == "assistant" then
      -- 普通消息：验证 content
      if not msg.content then
        return false, string.format("messages[%d] is missing 'content' field", i)
      end
      if type(msg.content) ~= "string" then
        return false, string.format("messages[%d].content must be a string, got %s", i, type(msg.content))
      end
      if msg.role == "user" then
        has_user_message = true
      end
    else
      return false,
        string.format("messages[%d] has invalid role '%s'. Valid roles: user, assistant, context, tool_call", i, msg.role)
    end
  end

  if require_user and not has_user_message then
    return false, "'messages' must contain at least one message with role='user'"
  end

  return true, nil
end

--- 从 messages 数组中分离 context 消息和普通消息
--- @param messages table 原始 messages 数组（含 role="context" 条目）
--- @return table context_items context 条目数组（格式兼容 preload_context_to_messages）
--- @return table regular_messages 普通消息数组（role="user"/"assistant"）
function M.extract_context_from_messages(messages)
  local context_items = {}
  local regular_messages = {}

  for _, msg in ipairs(messages) do
    if msg.role == "context" then
      -- 转换为 preload_context_to_messages 期望的格式
      local item = { type = msg.type }
      if msg.path then
        item.path = msg.path
      end
      if msg.url then
        item.url = msg.url
      end
      table.insert(context_items, item)
    else
      table.insert(regular_messages, msg)
    end
  end

  return context_items, regular_messages
end

--- Resolve explicit background once; regular messages retain their original roles.
function M.prepare_background_messages(messages, project_root, opts)
  -- Real calls need the target Chat; defer this background without reading later
  -- context before earlier tools have completed. Legacy backgrounds keep their ordering.
  for _, message in ipairs(messages or {}) do
    if message.role == "tool_call" then
      return {}, {}, vim.deepcopy(messages)
    end
  end
  local context_items, regular_messages = M.extract_context_from_messages(messages or {})
  if project_root then
    context_items = vim.deepcopy(context_items)
    local function resolve(path)
      if path:match("^[/~]") or path:match("^%a:[/\\]") then return path end
      return vim.fs.joinpath(project_root, path)
    end
    for _, item in ipairs(context_items) do
      if type(item.path) == "table" then
        for i, path in ipairs(item.path) do item.path[i] = resolve(path) end
      elseif item.path then
        item.path = resolve(item.path)
      end
    end
  end
  local prepared = {}
  local ok, err = M.preload_context_to_messages(prepared, context_items, opts)
  if not ok and opts and opts.strict_files then return nil, nil, nil, err or "Failed to preload context" end
  vim.list_extend(prepared, M.sanitize_messages(regular_messages))
  return prepared, context_items
end

function M.reject_instructions(params, goal_field)
  if params.instructions ~= nil then
    return false, "instructions is unsupported; use " .. (goal_field or "goal_prompt") .. " as the final user goal"
  end
  return true, nil
end

-- Public selectors use preset; adapter remains an unambiguous legacy spelling.
function M.preset_key(params)
  if params.preset ~= nil and params.adapter ~= nil and params.preset ~= params.adapter then
    return nil, "preset and legacy adapter must not conflict"
  end
  return params.preset or params.adapter
end

function M.validate_adapter_key(adapter_key)
  if adapter_key == nil then return true, nil end
  if type(adapter_key) ~= "string" then
    return false, "adapter must be a string, got " .. type(adapter_key)
  end
  local preset, err = require("maxa.mcphub.native_servers.config").get_adapter(adapter_key)
  return preset ~= nil, err
end

--- 验证 inherit 模式与其他参数的互斥性
--- inherit=true 时不允许设置 soul 或兼容 Soul 参数；目标和工具限制不影响继承
--- @param params table 请求参数
--- @param effective_inherit boolean 最终的 inherit 值
--- @return boolean valid
--- @return string|nil error
function M.validate_inherit_exclusivity(params, effective_inherit)
  if not effective_inherit then
    return true, nil
  end

  local conflicts = {}
  if params.soul then
    table.insert(conflicts, "soul")
  end
  if params.soul_prompt then
    table.insert(conflicts, "soul_prompt")
  end
  if params.soul_file then
    table.insert(conflicts, "soul_file")
  end
  if #conflicts > 0 then
    return false,
      string.format(
        "inherit=true is mutually exclusive with %s. "
          .. "Either set inherit=false or remove these parameters. "
          .. "Hint: setting soul automatically implies inherit=false.",
        table.concat(conflicts, ", ")
      )
  end

  return true, nil
end

--- 推断 inherit 的有效值
--- 规则：
--- 1. 用户显式设置了 inherit → 使用用户值
--- 2. 用户设了 soul（或兼容 Soul 参数）→ false
--- 3. 有父 chat → true
--- 4. 无父 chat → false
--- @param params table 请求参数
--- @param has_parent_chat boolean 是否有父 chat
--- @return boolean effective_inherit
function M.infer_inherit_mode(params, has_parent_chat)
  params = require("maxa.mcphub.native_servers.shared.params").normalize(params)
  -- 用户显式设置了 inherit
  if params.inherit ~= nil then
    -- 无父 chat 时强制 false
    if params.inherit == true and not has_parent_chat then
      return false
    end
    return params.inherit
  end

  -- Soul override selects independent mode; goals/background/tools do not.
  if params.soul or params.soul_prompt or params.soul_file then
    return false
  end

  -- 有父 chat → 默认 true
  if has_parent_chat then
    return true
  end

  -- 无父 chat → false
  return false
end

--- 验证 tools 参数（用于 run_agent）
--- @param tools any 要验证的 tools
--- @return boolean, string|nil 是否有效，错误消息（如果无效）
--- 检查工具名是否为可注册的 Chat 工具。
--- First-party builtins use bare names. Ability targets are dispatched through `run(scope="tool")`.
---@param tool_name string
---@return boolean
local function is_registered_tool(tool_name)
  local tools_config = require("maxa.config").interactions.chat.tools
  return tool_name ~= "opts" and tool_name ~= "groups" and tools_config[tool_name] ~= nil
end

function M.validate_tools(tools)
  if tools == nil or tools == vim.NIL then
    return true, nil -- nil 表示使用默认工具
  end

  if type(tools) ~= "table" then
    return false, "'tools' must be an array, got " .. type(tools)
  end

  local invalid_tools = {}
  for i, tool in ipairs(tools) do
    if type(tool) ~= "string" then
      return false, string.format("tools[%d] must be a string, got %s", i, type(tool))
    end
    if not is_registered_tool(tool) then
      table.insert(invalid_tools, string.format("tools[%d]='%s'", i, tool))
    end
  end

  if #invalid_tools > 0 then
    return false,
      string.format(
        "Only registered Chat tools are allowed. "
          .. "Unknown tools: %s. Restrict this registry with bare first-party builtin names; Ability targets are dispatched through `run(scope=\"tool\")`.",
        table.concat(invalid_tools, ", ")
      )
  end

  return true, nil
end

-- ============================================================================
-- 子代理消息结构构建（任务边界 + 防嵌套）
-- ============================================================================

--- 追加子代理任务消息。
--- @param chat_messages table messages 数组（会被修改）
--- @param task_content string 任务内容文本
function M.append_sub_agent_tail(chat_messages, task_content)
  local cc_config = require("maxa.config")
  table.insert(chat_messages, {
    role = cc_config.constants.USER_ROLE,
    content = task_content,
  })
end

--- Build a UI-only copy whose trailing placeholder protects the real user task
--- from Chat UI rendering. Restore the API messages immediately after Chat.new().
--- @param chat_messages table[]
--- @return table[] render_messages
function M.build_sub_agent_render_messages(chat_messages)
  local cc_config = require("maxa.config")
  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = tool_display.build_render_messages(chat_messages)
  local canonical_index = {}
  for i, message in ipairs(chat_messages) do
    canonical_index[message] = i
  end
  for _, message in ipairs(render_messages) do
    local opts = message.opts
    local source = opts and opts._display_origin
    if source and canonical_index[source] then
      opts._display_origin = { render_index = canonical_index[source] }
    end
  end
  table.insert(render_messages, {
    role = cc_config.constants.LLM_ROLE,
    content = "",
    opts = { visible = false },
  })
  return render_messages
end

function M.bind_sub_agent_render_messages(chat)
  if chat and chat.ui and chat.ui.message_provenance then
    chat.ui.message_provenance:bind_render_indices(chat.messages)
  end
end

--- 构建非交互模式默认配置
--- @param overrides table|nil 可选的覆盖配置
--- @return table 非交互模式默认配置
function M.build_non_interactive_defaults(overrides)
  local defaults = {
    auto_submit = true, -- 自动提交消息
    intro_message = "", -- 无介绍消息
    auto_submit_success = true, -- 工具成功后自动继续
    auto_submit_errors = true, -- 工具失败后自动继续
    title_refresh_count = 999, -- 阻止 history 插件的标题 refresh
  }

  -- 合并覆盖配置
  if overrides and type(overrides) == "table" then
    for key, value in pairs(overrides) do
      defaults[key] = value
    end
  end

  -- 自动设置 title（如果调用者未显式设置）
  if not defaults.title then
    -- 尝试从 messages 提取
    if defaults.messages then
      for _, msg in ipairs(defaults.messages) do
        if msg.role == "user" and msg.content and msg.content ~= "" then
          defaults.title = msg.content:sub(1, 50)
          break
        end
      end
    end
    -- 兜底默认值
    defaults.title = defaults.title or "SubAgent Session"
  end

  return defaults
end

--- 验证 max_turns 参数（用于 run_agent）
--- @param max_turns any 要验证的 max_turns
--- @return boolean, string|nil 是否有效，错误消息（如果无效）
function M.validate_max_turns(max_turns)
  if max_turns == nil then
    return true, nil -- nil 表示使用默认值
  end

  if type(max_turns) ~= "number" then
    return false, "'max_turns' must be a number, got " .. type(max_turns)
  end

  if max_turns < 0 then
    return false, "'max_turns' must be >= 0, got " .. tostring(max_turns)
  end

  return true, nil
end

--- 归一化 max_turns 参数
--- @param max_turns number|nil 用户传入的 max_turns
--- @param default_value number|nil 默认值（通常为 math.huge）
--- @return number normalized 0/nil 均表示不限制，归一化为 default_value/math.huge
function M.normalize_max_turns(max_turns, default_value)
  if max_turns == nil or max_turns == vim.NIL or max_turns == 0 then
    return default_value or math.huge
  end
  return max_turns
end

-- ============================================================================
-- 父 Chat 继承函数
-- ============================================================================

--- 从父 chat 继承 adapter
--- @param parent_chat table|nil 父 chat 实例
--- @return table|nil inherited_adapter 深拷贝的 adapter，无父 chat 时返回 nil
function M.inherit_adapter_from_parent(parent_chat)
  if not parent_chat or not parent_chat.adapter then
    return nil
  end
  -- Inherit configuration, not the source Chat's last response usage. Fresh
  -- sessions can run preload tools (and token checks) before their first request.
  local adapter = vim.deepcopy(parent_chat.adapter)
  require("maxa.adapters.behavior").reset_usage(adapter)
  return adapter
end

--- 从父 chat 继承 tools 列表
--- @param parent_chat table|nil 父 chat 实例
--- @return string[]|nil inherited_tools 工具名称列表，无工具时返回 nil
function M.inherit_tools_from_parent(parent_chat)
  if not parent_chat or not parent_chat.tool_registry or not parent_chat.tool_registry.in_use then
    return nil
  end
  local tools = {}
  for tool_name, enabled in pairs(parent_chat.tool_registry.in_use) do
    if enabled then
      table.insert(tools, tool_name)
    end
  end
  if #tools == 0 then
    return nil
  end
  return tools
end

--- 从父 chat 继承 system_prompt
--- @param parent_chat table|nil 父 chat 实例
--- @return string|nil inherited_system_prompt 系统提示词内容
function M.inherit_system_prompt_from_parent(parent_chat)
  if not parent_chat or not parent_chat.messages then
    return nil
  end
  -- 新 Chat 分开发送 Runtime 和 Soul；旧历史只有一条合成消息。
  local base, soul
  for _, msg in ipairs(parent_chat.messages) do
    local tag = msg._meta and msg._meta.tag
    if tag == "system_prompt_from_config" then
      base = msg.content
    elseif tag == "soul_prompt_from_config" then
      soul = msg.content
    end
  end
  if base then
    return soul and table.concat({ base, soul }, "\n\n---\n\n") or base
  end
  -- 也检查 system role 的消息（可能是自定义 system prompt）
  local ok, cc_config = pcall(require, "maxa.config")
  if ok then
    for _, msg in ipairs(parent_chat.messages) do
      if msg.role == cc_config.constants.SYSTEM_ROLE and msg.content then
        return msg.content
      end
    end
  end
  return nil
end

--- 从父 chat 继承完整的 tool_registry（用于 fork_agent）
--- @param parent_chat table|nil 父 chat 实例
--- @param target_chat table 目标 chat 实例
--- @return boolean success 是否成功继承
function M.inherit_tool_registry(parent_chat, target_chat)
  if not parent_chat or not parent_chat.tool_registry then
    return false
  end
  if not target_chat or not target_chat.tool_registry then
    return false
  end

  target_chat.tool_registry.schemas = vim.deepcopy(parent_chat.tool_registry.schemas or {})
  target_chat.tool_registry.in_use = vim.deepcopy(parent_chat.tool_registry.in_use or {})

  -- 继承 flags（如果有）
  if parent_chat.tool_registry.flags then
    target_chat.tool_registry.flags = vim.deepcopy(parent_chat.tool_registry.flags)
  end

  return true
end

local HIDDEN_IMAGE_BLOCKED_TOOL_NAMES = {
  analyze = true,
  fork_agent = true,
  multi_agent = true,
  multicall = true,
  run_agent = true,
  resume_agent = true,
}

local function blocked_hidden_image_tool(name)
  name = tostring(name or "")
  local short = name:match(".*__(.+)$") or name
  return HIDDEN_IMAGE_BLOCKED_TOOL_NAMES[name] or HIDDEN_IMAGE_BLOCKED_TOOL_NAMES[short]
end

--- Remove direct delegation tools from a hidden image-analysis child registry.
--- Wrapper bypasses are rejected centrally by builtin tool_call_core.
--- @param chat table
function M.restrict_hidden_image_analysis_tools(chat)
  local registry = chat and chat.tool_registry
  if not registry then
    return
  end
  for key, schema in pairs(registry.schemas or {}) do
    local name = tostring(key):match("<tool>(.-)</tool>")
      or (type(schema) == "table" and (schema.name or (schema["function"] and schema["function"].name)))
    if blocked_hidden_image_tool(name) then
      registry.schemas[key] = nil
    end
  end
  for name in pairs(registry.in_use or {}) do
    if blocked_hidden_image_tool(name) then
      registry.in_use[name] = nil
    end
  end
end

--- 从父 chat 继承 context_items
--- @param parent_chat table|nil 父 chat 实例
--- @param target_chat table 目标 chat 实例
--- @return boolean success 是否成功继承
function M.inherit_context_items(parent_chat, target_chat)
  if not parent_chat or not parent_chat.context_items then
    return false
  end
  if not target_chat then
    return false
  end

  target_chat.context_items = vim.deepcopy(parent_chat.context_items)
  return true
end

--- 从父 chat 提取 context 数据（用于在 on_created callback 中添加）
--- 返回的数据可以直接用于 chat:add_context() 调用
--- @param parent_chat table 父 chat 实例
--- @return table[] context_data 提取的 context 数据数组
function M.extract_context_data(parent_chat)
  if not parent_chat then
    return {}
  end

  if not parent_chat.context_items or #parent_chat.context_items == 0 then
    return {}
  end

  local context_data = {}

  -- 遍历父 chat 的 context_items（排除 tool 类型）
  for _, item in ipairs(parent_chat.context_items) do
    if item.source ~= "tool" then
      -- 找到对应的消息内容
      local msg_content = nil
      if parent_chat.messages then
        for _, msg in ipairs(parent_chat.messages) do
          if msg.context and msg.context.id == item.id then
            msg_content = msg.content
            break
          end
        end
      end

      -- 如果找到了消息内容，添加到结果数组
      if msg_content then
        table.insert(context_data, {
          content = msg_content,
          source = item.source, -- "rules", "file", "buffer" 等
          id = item.id, -- "<rules>.maxa/AGENTS.md</rules>" 等
          path = item.path,
          visible = item.opts and item.opts.visible or false,
          opts = item.opts,
        })
      end
    end
  end

  return context_data
end

--- 从父 chat 提取 context messages（用于在 Chat.new 之前预加载）
--- @param parent_chat table|nil 父 chat 实例
--- @return table[] context_messages 提取的 context messages 数组
function M.extract_context_messages(parent_chat)
  if not parent_chat or not parent_chat.messages then
    return {}
  end

  local context_messages = {}
  for _, msg in ipairs(parent_chat.messages) do
    local is_context_msg = false

    -- 方式 1: 有 context.id 字段（链接到 context_items）
    if msg.context and msg.context.id then
      -- 排除 tool 相关的 context
      if not msg.context.id:match("^<tool>") then
        is_context_msg = true
      end
    end

    -- 方式 2: _meta.tag 表明是特定类型的上下文（排除 tool 和 system_prompt）
    if not is_context_msg and msg._meta and msg._meta.tag then
      local tag = msg._meta.tag
      if tag == "rules" or tag == "file" or tag == "buffer" or tag == "symbols" or tag:match("^slash_command") then
        is_context_msg = true
      end
    end

    if is_context_msg then
      -- 深拷贝消息，但重置 _meta 中的发送状态
      local copied_msg = vim.deepcopy(msg)
      if copied_msg._meta then
        copied_msg._meta.sent = false
        copied_msg._meta.cycle = nil
        copied_msg._meta.index = nil
      end
      table.insert(context_messages, copied_msg)
    end
  end

  return context_messages
end

--- 从父 chat 提取 context_items（过滤掉 tool 类型）
--- @param parent_chat table|nil 父 chat 实例
--- @return table[] context_items 提取的 context_items 数组
function M.extract_context_items(parent_chat)
  if not parent_chat or not parent_chat.context_items or #parent_chat.context_items == 0 then
    return {}
  end

  local filtered_items = {}
  for _, item in ipairs(parent_chat.context_items) do
    -- 只继承非 tool 类型的 context（rules、file、buffer 等）
    if item.source ~= "tool" then
      table.insert(filtered_items, vim.deepcopy(item))
    end
  end

  return filtered_items
end

--- 从父 chat 继承完整的 context（包括 context_items 和相关的 messages）
--- 这会将父 chat 中带有 context 的 messages 插入到子 chat 的 messages 开头
--- 注意：此函数在 Chat.new() 之后调用，可能无法正确工作（messages 已发送）
--- 推荐使用 extract_context_messages() 在 Chat.new() 之前预加载
--- @param parent_chat table|nil 父 chat 实例
--- @param target_chat table 目标 chat 实例
--- @return boolean success 是否成功继承
function M.inherit_context(parent_chat, target_chat)
  if not parent_chat or not target_chat then
    return false
  end

  -- 1. 继承 context_items（过滤掉 tool 类型，只保留 rules、file、buffer 等）
  if parent_chat.context_items and #parent_chat.context_items > 0 then
    local filtered_items = {}
    for _, item in ipairs(parent_chat.context_items) do
      -- 只继承非 tool 类型的 context（rules、file、buffer 等）
      if item.source ~= "tool" then
        table.insert(filtered_items, vim.deepcopy(item))
      end
    end
    if #filtered_items > 0 then
      target_chat.context_items = target_chat.context_items or {}
      vim.list_extend(target_chat.context_items, filtered_items)
    end
  end

  -- 2. 找出父 chat 中带有 context 的 messages（通常是 rules、buffers 等）
  -- 关键识别方式：
  --   a) msg.context.id 存在（链接到 context_items）
  --   b) msg._meta.tag 是 "rules"、"file"、"buffer" 等
  --   c) msg.opts.visible = false 的隐藏消息
  if parent_chat.messages then
    local context_messages = {}
    for _, msg in ipairs(parent_chat.messages) do
      local is_context_msg = false

      -- 方式 1: 有 context.id 字段（链接到 context_items）
      if msg.context and msg.context.id then
        -- 排除 tool 相关的 context
        if not msg.context.id:match("^<tool>") then
          is_context_msg = true
        end
      end

      -- 方式 2: _meta.tag 表明是特定类型的上下文（排除 tool 和 system_prompt）
      if not is_context_msg and msg._meta and msg._meta.tag then
        local tag = msg._meta.tag
        if tag == "rules" or tag == "file" or tag == "buffer" or tag == "symbols" or tag:match("^slash_command") then
          is_context_msg = true
        end
      end

      if is_context_msg then
        -- 深拷贝消息，但重置 _meta 中的发送状态
        local copied_msg = vim.deepcopy(msg)
        if copied_msg._meta then
          copied_msg._meta.sent = false
          copied_msg._meta.cycle = nil
          copied_msg._meta.index = nil
        end
        table.insert(context_messages, copied_msg)
      end
    end

    -- 3. 将 context messages 插入到子 chat 的 messages 开头（在 system prompt 之后）
    if #context_messages > 0 then
      -- 找到第一个非 system 消息的位置
      local insert_pos = 1
      local ok, cc_config = pcall(require, "maxa.config")
      if ok and target_chat.messages then
        for i, msg in ipairs(target_chat.messages) do
          if msg.role == cc_config.constants.SYSTEM_ROLE then
            insert_pos = i + 1
          else
            break
          end
        end
      end

      -- 逆序插入，保持原始顺序
      for i = #context_messages, 1, -1 do
        table.insert(target_chat.messages, insert_pos, context_messages[i])
      end
    end
  end

  return true
end

--- 获取父 chat 实例（通过当前 buffer）
--- @return table|nil parent_chat 父 chat 实例
--- @return number|nil original_bufnr 原始 buffer 号
function M.get_parent_chat_from_buffer()
  local ok, Chat = pcall(require, "maxa.interactions.chat")
  if not ok then
    return nil, nil
  end

  local original_bufnr = vim.api.nvim_get_current_buf()
  local parent_chat = Chat.buf_get_chat(original_bufnr)

  return parent_chat, original_bufnr
end

-- ============================================================================
-- Context 预加载函数
-- ============================================================================

--- 预加载 context 到 messages 数组
--- 支持 file、symbols、url、image 类型
--- @param messages table messages 数组（会被修改）
--- @param context table context 数组
--- @return boolean success 是否成功
function M.preload_context_to_messages(messages, context, opts)
  opts = opts or {}
  if not context or #context == 0 then
    return true
  end

  local ok_config, cc_config = pcall(require, "maxa.config")
  if not ok_config then
    return false
  end

  for _, item in ipairs(context) do
    if item.type == "file" then
      -- file 类型：读取文件内容并添加到 messages
      -- 注意：context:add 只注册 context_item，不会自动读取文件内容到 messages
      -- 因此必须在这里手动读取并插入
      local paths = type(item.path) == "table" and item.path or { item.path }
      for _, path in ipairs(paths) do
        local full_path = vim.fn.fnamemodify(path, ":p")
        -- Handoff files are required inputs; ordinary delegation remains best-effort.
        local ok_read, lines = pcall(vim.fn.readfile, full_path)
        if opts.strict_files and (not ok_read or not lines or #lines == 0 or table.concat(lines, "\n"):match("^%s*$")) then
          return false, "handoff context file is missing, unreadable or empty: " .. full_path
        end
        if ok_read then
          if lines and #lines > 0 then
            local content = table.concat(lines, "\n")
            -- 获取文件扩展名用于代码块语法高亮
            local ext = vim.fn.fnamemodify(full_path, ":e")
            local filetype = ext ~= "" and ext or "text"
            -- 格式化为带文件路径的代码块
            local file_content = string.format("File: `%s`\n```%s\n%s\n```", full_path, filetype, content)
            local context_id = "<file>" .. full_path .. "</file>"
            table.insert(messages, {
              role = cc_config.constants.USER_ROLE,
              content = file_content,
              opts = { visible = false },
              context = { id = context_id },
              _meta = { tag = "file" },
            })
          end
        end
      end
    elseif item.type == "symbols" then
      -- symbols 类型：需要 LSP 支持，在非交互模式下简化处理
      -- 读取文件内容作为 fallback（完整 symbols 提取需要 LSP）
      local paths = type(item.path) == "table" and item.path or { item.path }
      for _, path in ipairs(paths) do
        local full_path = vim.fn.fnamemodify(path, ":p")
        if vim.fn.filereadable(full_path) == 1 then
          local ok_read, lines = pcall(vim.fn.readfile, full_path)
          if ok_read and lines and #lines > 0 then
            local content = table.concat(lines, "\n")
            local ext = vim.fn.fnamemodify(full_path, ":e")
            local filetype = ext ~= "" and ext or "text"
            local symbols_content = string.format("Symbols from: `%s`\n```%s\n%s\n```", full_path, filetype, content)
            local context_id = "<symbols>" .. full_path .. "</symbols>"
            table.insert(messages, {
              role = cc_config.constants.USER_ROLE,
              content = symbols_content,
              opts = { visible = false },
              context = { id = context_id },
              _meta = { tag = "symbols" },
            })
          end
        end
      end
    elseif item.type == "url" then
      -- URL 简化处理：添加 URL 引用（完整获取需要异步 HTTP）
      local url = item.url
      local context_id = "<url>" .. url .. "</url>"
      table.insert(messages, {
        role = cc_config.constants.USER_ROLE,
        content = string.format("Reference URL: %s\n(Note: URL content not fetched in agent mode)", url),
        opts = { visible = false },
        context = { id = context_id },
        _meta = { tag = "url" },
      })
    elseif item.type == "image" then
      -- image 类型：使用 MaxaAI 的 images 工具编码图片
      local full_path = vim.fn.fnamemodify(item.path, ":p")
      if vim.fn.filereadable(full_path) == 1 then
        local ok_images, image_utils = pcall(require, "maxa.utils.images")
        if ok_images then
          local image = image_utils.encode_image({
            path = full_path,
            id = full_path,
          })
          if type(image) == "table" and image.base64 then
            local context_id = "<image>" .. full_path .. "</image>"
            table.insert(messages, {
              role = cc_config.constants.USER_ROLE,
              content = image.base64,
              opts = { visible = false },
              context = { id = context_id, mimetype = image.mimetype, path = full_path },
              _meta = { tag = "image" },
            })
          end
        end
      end
    end
  end

  return true
end

--- 将继承的 context 数据预加载到 messages（BOUNDARY 之前）
--- 用 system role 避免 ts_parse_buffer 错误（详见 subagent architecture.md "Context 继承"）
--- @param messages table messages 数组（会被修改）
--- @param inherited_context_data table[] extract_context_data() 返回的数据
--- @return boolean success 是否成功
function M.preload_inherited_context_to_messages(messages, inherited_context_data)
  if not inherited_context_data or #inherited_context_data == 0 then
    return true
  end

  local ok_config, cc_config = pcall(require, "maxa.config")
  if not ok_config then
    return false
  end

  for _, ctx_data in ipairs(inherited_context_data) do
    if ctx_data.content and ctx_data.content ~= "" then
      table.insert(messages, {
        role = cc_config.constants.SYSTEM_ROLE,
        content = ctx_data.content,
        opts = { visible = false },
        _meta = { tag = ctx_data.source or "inherited_context" },
      })
    end
  end

  return true
end

--- Reject retired role fields and ensure one effective Soul source.
function M.validate_soul_params(params, goal_field)
  local valid, err = M.reject_instructions(params, goal_field)
  if not valid then return false, err end
  if params.role_prompt ~= nil or params.role_file ~= nil then
    return false, "role_prompt and role_file are unsupported; use soul"
  end
  local is_absent = require("maxa.mcphub.native_servers.shared.params").is_absent
  local supplied = {}
  for _, key in ipairs({ "soul", "soul_prompt", "soul_file" }) do
    if not is_absent(params[key]) then
      if type(params[key]) ~= "string" or vim.trim(params[key]) == "" then
        return false, key .. " must be a nonblank string"
      end
      supplied[#supplied + 1] = key
    end
  end
  if #supplied > 1 then
    return false, "soul, soul_prompt, and soul_file are mutually exclusive"
  end
  return true
end

--- Child system composition contains only Runtime and the selected Soul.
function M.build_soul_system_prompt(config, ctx)
  config = config or {}
  local ok, result = pcall(require("maxa.prompts.runtime").GenerateSystemPrompt, ctx or {}, {
    soul = config.soul,
    soul_prompt = config.soul_prompt,
    soul_file = config.soul_file,
  })
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

-- ============================================================================
-- 子代理公共函数
-- ============================================================================

--- 从 adapter preset key 或父 chat 解析 Maxa AI adapter 实例
--- 未指定时继承父会话，否则使用 defaults.chat；显式 preset 字段覆盖父会话设置。
--- @param adapter_key string|nil adapter preset key（如 "fast", "powerful", "coding"）
--- @param parent_chat table|nil 父 chat 实例（用于继承 adapter/model）
--- @param _use_inherit boolean|nil 保留参数以兼容旧调用；不参与 adapter/model 决策
--- @return table|nil resolved_adapter Maxa AI adapter 实例
function M.resolve_adapter_by_key(adapter_key, parent_chat, _use_inherit)
  local adapters = require("maxa.adapters")
  local mcp_config = require("maxa.mcphub.native_servers.config")

  -- Omission inherits the source; no reserved named preset is required.
  local preset
  if adapter_key then preset = mcp_config.get_preset(adapter_key, "chat")
  elseif mcp_config.adapters.default_agent and mcp_config.adapters.default_agent.type == nil then preset = mcp_config.get_adapter("default_agent")
  else preset = { adapter = "inherit", inherit = true } end
  if not preset then
    return nil
  end

  local inherited = M.inherit_adapter_from_parent(parent_chat)
  local adapter_name = preset.adapter
  if not adapter_name or adapter_name == "inherit" then
    adapter_name = inherited and inherited.name or nil
  end

  if not adapter_name or adapter_name == "" then
    local fallback = mcp_config.get_default("chat")
    if not fallback then
      return nil
    end
    adapter_name = fallback.adapter
    preset = vim.tbl_deep_extend("keep", preset, fallback)
  end

  -- HTTP settings live in schema defaults / chat.settings, not adapter.model
  -- (which is model metadata) or adapter.temperature.
  local resolved = inherited and inherited.name == adapter_name and inherited or adapters.resolve(adapter_name)
  if not resolved then
    return nil
  end
  resolved = vim.deepcopy(resolved)
  local schema = resolved.schema or {}
  local settings = parent_chat and parent_chat.settings or {}
  for key, field in pairs(schema) do
    local value = settings[key]
    if value == nil and inherited and inherited.schema and inherited.schema[key] then
      value = inherited.schema[key].default
    end
    if value ~= nil then
      field.default = vim.deepcopy(value)
    end
  end
  for _, key in ipairs({ "model", "temperature" }) do
    if preset[key] ~= nil and schema[key] then
      schema[key].default = preset[key]
    end
  end
  local reasoning = mcp_config.get_reasoning_effort_settings(resolved, preset.thinking_mode)
  for key, value in pairs(reasoning or {}) do
    schema[key].default = value
  end
  return adapters.resolve(resolved)
end

--- 获取父 chat 实例
--- @param req table MCP 请求对象
--- @param original_bufnr number 原始 buffer 号
--- @return table|nil parent_chat 父 chat 实例
function M.get_parent_chat(req, original_bufnr)
  local ok, Chat = pcall(require, "maxa.interactions.chat")
  if not ok then
    return nil
  end

  -- 优先从 req.caller.maxa_ai.chat 获取（MCP 工具调用时）
  if req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat then
    return req.caller.maxa_ai.chat
  end

  -- 否则尝试从当前 buffer 获取
  return Chat.buf_get_chat(original_bufnr)
end

--- 创建 buffer context
--- @param bufnr number buffer 号
--- @return table buffer_context
function M.build_buffer_context(bufnr)
  return require("maxa.utils.context").get(bufnr)
end

--- 构建错误处理函数
--- @param tool_name string 工具名称
--- @param res table MCP 响应对象
--- @param win_mgr table|nil 窗口管理器
--- @param finished_flag table 完成标志 { value = boolean }
--- @return function error_handler
function M.build_error_handler(tool_name, res, win_mgr, finished_flag)
  return function(chat, err)
    if finished_flag.value then
      return
    end
    finished_flag.value = true

    local error_message = tool_name .. " execution failed"
    if err then
      if type(err) == "string" then
        error_message = error_message .. ": " .. err
      elseif type(err) == "table" and err.message then
        error_message = error_message .. ": " .. err.message
      end
    end

    -- 关闭 chat buffer 并切换回原来的窗口
    vim.schedule(function()
      if win_mgr then
        win_mgr:cleanup(chat)
      else
        chat:close()
      end
    end)

    res:error(M.format_error(tool_name, error_message))
  end
end

--- 检查 messages 中是否有 system prompt
--- @param chat_messages table messages 数组
--- @return boolean has_system_prompt
function M.check_has_system_prompt_in_messages(chat_messages)
  local ok, cc_config = pcall(require, "maxa.config")
  if not ok then
    return false
  end

  for _, msg in ipairs(chat_messages) do
    if msg.role == cc_config.constants.SYSTEM_ROLE then
      return true
    end
  end
  return false
end

--- 设置 chat_opts 的公共配置
--- @param chat_opts table chat 选项（会被修改）
--- @param chat_messages table messages 数组
--- @param agent_config table agent 配置
--- @param ignore_system_prompt boolean 是否忽略 system prompt
--- 在子代理 Chat 创建期间临时禁用 MaxaAI 的 close_last_chat 副作用。
---
--- 该 hook 必须严格限定在当前同步调用栈内：只包住我们自己的 Chat.new(...)
--- 调用，完成或失败都立即恢复原函数。不要把这个行为做成全局长期 patch，
--- 否则会影响与当前子代理方案无关的其他会话。
--- @param Chat table Maxa AI Chat 模块
--- @param fn function 要执行的创建逻辑
--- @return boolean ok
--- @return any result
function M.with_subagent_chat_creation(Chat, fn, opts)
  if not Chat or type(fn) ~= "function" then
    return false, "Invalid subagent chat creation wrapper arguments"
  end

  opts = opts or {}
  local original_close_last_chat = Chat.close_last_chat
  local previous_last_chat = opts.restore_last_chat and type(Chat.last_chat) == "function" and Chat.last_chat() or nil
  local original_ui_open
  local ui
  local ok, result

  local setup_ok, setup_err = xpcall(function()
    Chat.close_last_chat = function() end
    if opts.hidden then
      ui = require("maxa.interactions.chat.ui")
      original_ui_open = assert(ui.open, "MaxaAI UI.open is unavailable")
      ui.open = function(self)
        return self
      end
    end
    ok, result = xpcall(fn, debug.traceback)
  end, debug.traceback)

  Chat.close_last_chat = original_close_last_chat
  if ui and original_ui_open then
    ui.open = original_ui_open
  end
  if not setup_ok then
    ok, result = false, setup_err
  end
  if opts.restore_last_chat and type(Chat.last_chat) == "function" then
    for index = 1, 20 do
      local name = debug.getupvalue(Chat.last_chat, index)
      if not name then
        break
      end
      if name == "last_chat" then
        debug.setupvalue(Chat.last_chat, index, previous_last_chat)
        break
      end
    end
  end

  return ok, result
end

--- 创建 chat 实例并处理错误
--- @param chat_opts table chat 选项
--- @param tool_name string 工具名称
--- @param res table MCP 响应对象
--- @param win_mgr table|nil 窗口管理器
--- @return table|nil chat 实例，失败返回 nil
--- @return boolean success 是否成功
function M.create_chat_with_error_handling(chat_opts, tool_name, res, win_mgr)
  local ok, Chat = pcall(require, "maxa.interactions.chat")
  if not ok then
    res:error(M.format_error(tool_name, "Failed to load Maxa AI Chat module"))
    return nil, false
  end

  chat_opts.headless = true
  local create_ok, chat = M.with_subagent_chat_creation(Chat, function()
    return Chat.new(chat_opts)
  end, { hidden = true, restore_last_chat = true })

  if not create_ok then
    local err_msg = type(chat) == "string" and chat or "Unknown error during Chat creation"
    if win_mgr then
      win_mgr:restore_parent_window()
    end
    res:error(M.format_error(tool_name, "Failed to create Chat instance: " .. err_msg))
    return nil, false
  end

  if not chat then
    if win_mgr then
      win_mgr:restore_parent_window()
    end
    res:error(M.format_error(tool_name, "Failed to create Chat instance"))
    return nil, false
  end

  return chat, true
end

--- 应用 tools 覆盖（直接操作 tool_registry，不调用 context:add）
--- 详见 subagent architecture.md "工具继承"
--- @param chat table chat 实例
--- @param tools table 工具名称列表
--- @return boolean success 是否成功
function M.apply_tools_override(chat, tools)
  if not chat or not chat.tool_registry then
    return false
  end
  if tools == nil then
    tools = require("maxa.interactions.chat.tools.builtin").names
  end

  -- 清空现有工具
  chat.tool_registry:clear()

  -- 清空 context_items 中 source 为 "tool" 的项（tool_registry:clear 不会清理这些）
  if chat.context_items then
    chat.context_items = vim.tbl_filter(function(item)
      return item.source ~= "tool"
    end, chat.context_items)
  end

  -- 获取工具配置
  local cc_config = require("maxa.config")
  local tools_config = cc_config.interactions.chat.tools
  local Tools = require("maxa.interactions.chat.tools")

  -- 辅助函数：添加单个工具
  local function add_tool(tool_name, tool_config)
    local resolved_tool = Tools.resolve(tool_config)
    if resolved_tool and resolved_tool.schema then
      local id = "<tool>" .. tool_name .. "</tool>"
      -- 设置 schema 和 in_use
      chat.tool_registry.schemas[id] = resolved_tool.schema
      chat.tool_registry.in_use[tool_name] = true
      -- 不调用 context:add()（子代理 buffer 无 role header 会导致崩溃）
    end
  end

  -- 添加指定的工具
  for _, tool_name in ipairs(tools) do
    local tool_config = tool_name ~= "groups" and tool_name ~= "opts" and tools_config[tool_name]
    if tool_config then
      add_tool(tool_name, tool_config)
    end
  end

  return true
end

--- 创建窗口管理器（如果有父 chat）
--- @param parent_chat table|nil 父 chat 实例
--- @param original_bufnr number 原始 buffer 号
--- @return table|nil win_mgr 窗口管理器
function M.create_window_manager(parent_chat, original_bufnr)
  return {
    restore_parent_window = function() end,
    setup_child_window = function() end,
    cleanup = function(_, chat)
      if chat then chat:close() end
    end,
  }
end

--- 设置窗口布局
--- @param win_mgr table|nil 窗口管理器
--- @param chat table chat 实例
function M.setup_window_layout(win_mgr, chat)
  if win_mgr then
    win_mgr:restore_parent_window()
    win_mgr:setup_child_window(chat)
  end
end

--- 清理并关闭 chat
--- @param win_mgr table|nil 窗口管理器
--- @param chat table chat 实例
function M.cleanup_chat(win_mgr, chat)
  vim.schedule(function()
    if win_mgr then
      win_mgr:cleanup(chat)
    else
      chat:close()
    end
  end)
end

-- ============================================================================
-- Chat 历史记录相关函数
-- ============================================================================

--- 获取 chat 的 save_id（由 Maxa AI session history owner 生成）
--- @param chat table|nil Maxa AI Chat 实例
--- @return string|nil save_id 会话保存 ID，无效时返回 nil
function M.get_chat_save_id(chat)
  if not chat then
    return nil
  end
  if not chat.opts then
    return nil
  end
  local save_id = chat.opts.save_id
  if not save_id or save_id == "" then
    return nil
  end
  return save_id
end

-- ============================================================================
-- 消息清理函数（保留 literal @/# 文本，仅处理显式 context 行）
-- ============================================================================

--- 清理 LLM 生成消息中会被 helpers.strip_context() 处理的 `>` context 行。
--- Literal `@name` / `#path` mention 文本必须逐字保留。
---
--- @param messages table 消息数组 [{role: string, content: string}, ...]
--- @return table 清理后的消息数组
function M.sanitize_messages(messages)
  if not messages or #messages == 0 then
    return {}
  end

  local sanitized = {}

  for _, msg in ipairs(messages) do
    local cleaned_content = msg.content

    -- 移除以 > 开头的行（Context 标记）
    -- 防止被 helpers.strip_context() 移除
    -- 将 > 替换为缩进，保留内容
    cleaned_content = cleaned_content:gsub("\n>([^\n]*)", "\n  %1")
    cleaned_content = cleaned_content:gsub("^>([^\n]*)", "  %1")

    table.insert(sanitized, {
      role = msg.role,
      content = cleaned_content,
    })
  end

  return sanitized
end

return M
