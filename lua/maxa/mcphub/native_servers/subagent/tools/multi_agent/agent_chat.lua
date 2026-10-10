-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/agent_chat.lua
-- AgentChat: 封装隐藏的 Maxa AI Chat，支持连续性历史和 Handoff 检测
-- 用于 Multi-Agent 协作系统中各 Agent 的独立会话管理

local compaction_messages = require("maxa.session.compaction_messages")
local completion_guard = require("maxa.mcphub.native_servers.subagent.completion_guard")
local handoff_tool = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.handoff_tool")
local log = require("maxa.utils.log")
local mcp_handoff = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.mcp_handoff")

---@class AgentChatConfig
---@field name string Agent 名称
---@field role string 角色描述
---@field soul? string Ability 引用、显式文件路径或内联 Soul
---@field soul_prompt? string 兼容旧字段
---@field soul_file? string 兼容旧字段
---@field goal_prompt? string 当前代理的用户目标
---@field shared_background? table[] 已加载的共享背景快照
---@field adapter? string 已配置的 LLM adapter 预设名，nil 表示继承父代理
---@field parent_adapter? table 父代理的 adapter（用于继承模式）
---@field icon? string 显示图标
---@field coordinator? table MultiAgentCoordinator 实例（用于 Handoff Tool）
---@field agent_names? string[] 所有 Agent 名称列表（用于 Handoff Tool）
---@field min_rounds? number 最小讨论轮数（用于系统提示词）
---@field restrict_tools? string[] 限定工具列表（除 handoff 外的工具），nil 表示全部 Chat builtins

---@class AgentChat
---@field name string Agent 名称
---@field role string 角色描述
---@field icon string 显示图标
---@field chat table|nil Maxa AI Chat 实例
---@field is_busy boolean 是否正在处理请求
---@field _on_response function|nil 响应回调
---@field _coordinator table|nil Coordinator 引用
---@field _current_round number 当前轮次
---@field _restrict_tools string[]|nil 限定工具列表
local AgentChat = {}
AgentChat.__index = AgentChat

--- 创建新的 AgentChat 实例
---@param config AgentChatConfig
---@return AgentChat
function AgentChat.new(config)
  assert(config.name, "AgentChat requires 'name'")
  assert(config.role, "AgentChat requires 'role'")

  local self = setmetatable({
    name = config.name,
    role = config.role,
    icon = config.icon or "🤖",
    chat = nil,
    is_busy = false,
    _on_response = nil,
    _coordinator = config.coordinator,
    _agent_names = config.agent_names or {},
    _current_round = 0,
    _config = config, -- 保存配置用于延迟创建 Chat
    _response_handled = false, -- 防重复完成标志
    _waiting_for_handoff = false, -- 等待 handoff 完成标志（阻塞式设计）
    _min_rounds = config.min_rounds or 1, -- 最小讨论轮数
    _restrict_tools = config.restrict_tools, -- 限定工具列表（除 handoff 外）
    _recursion_depth = config.recursion_depth, -- multi_agent 内部 AgentChat 的子代理深度
  }, AgentChat)

  return self
end

--- 构建系统提示词
---@param config AgentChatConfig
---@return string
function AgentChat:_build_system_prompt(config)
  local utils = require("maxa.mcphub.native_servers.subagent.utils")
  local valid, err = utils.validate_soul_params(config)
  if not valid then return nil, err end
  return utils.build_soul_system_prompt(config, config.buffer_context)
end

--- Host discussion protocol is user background, not a system supplement.
function AgentChat:_build_discussion_prompt(config)
  -- 构建 Agent 名称列表（用于 Handoff 说明）
  local agent_list = table.concat(self._agent_names, ", ")
  if #self._agent_names == 0 then
    agent_list = "(no other agents)"
  end

  -- 获取 min_rounds 配置（如果有）
  local min_rounds = self._min_rounds or 1
  local min_rounds_hint = ""
  if min_rounds > 1 then
    min_rounds_hint = string.format(
      '\n\n⚠️ **重要**: 本次讨论要求至少进行 %d 轮。在达到最小轮数之前，请勿使用 target="user" 结束讨论，而应继续与其他 Agent 交流。',
      min_rounds
    )
  end

  local mode_prompt = string.format(
    [[Discussion participant: %s. Assigned responsibility: %s

## Core Discussion Rules

You are participating in a multi-agent discussion. The host registers `subagent__handoff` for this mode; other tools follow the common Runtime and actual registry.

### Visibility

- Your plain-text reply is public and automatically shared with all Agents and the user.
- `handoff.message` is private to the target only.
- Do not repeat your public analysis in `handoff.message`.

### Required Reply Flow

Every turn must follow this sequence:

1. First output your complete public analysis/conclusion as plain text.
2. Then call `subagent__handoff` to transfer control; calls before public analysis are rejected.
   - `target`: next Agent name, or "user" to end discussion.
   - `message`: concise private note for target, e.g. advice/question/reminder.

Do not call historical/internal system tools shown in prior messages.

Available targets:
- Other Agents: %s
- "user": end discussion and return to user.

Use target="user" only when all Agents have contributed enough, the problem is sufficiently analyzed, or you are explicitly asked to summarize/end.%s]],
    config.name,
    config.role,
    agent_list,
    min_rounds_hint
  )
  return mode_prompt
end

--- 注册工具到 Chat 的 tool_registry
--- 先清空默认工具，再应用用户指定的工具，最后强制添加 handoff（确保 handoff 始终可用）
---@param chat table Chat 实例
---@param cc_config table MaxaAI 配置
---@param utils table utils 模块
function AgentChat:_register_tools(chat, cc_config, utils)
  local tools_config = cc_config.interactions.chat.tools

  -- ⭐ 始终清空默认工具（无论用户是否指定工具）
  -- 这确保 Agent 只使用 multi_agent 入参指定的工具，不继承系统默认值
  chat.tool_registry:clear()

  -- 清空 context_items 中 source 为 "tool" 的项
  if chat.context_items then
    chat.context_items = vim.tbl_filter(function(item)
      return item.source ~= "tool"
    end, chat.context_items)
  end

  -- 确定要注册的工具列表
  -- 如果用户未通过 restrict_tools 限定，默认注入全部 Chat builtins
  local tools_to_register = self._restrict_tools
  local is_default = false
  if not tools_to_register then
    tools_to_register = vim.deepcopy(require("maxa.interactions.chat.tools.builtin").names)
    is_default = true
  end

  -- 注册指定的工具
  local Tools = require("maxa.interactions.chat.tools")
  for _, tool_name in ipairs(tools_to_register) do
    local tool_config = tool_name ~= "groups" and tool_name ~= "opts" and tools_config[tool_name]
    if tool_config then
      local resolved_tool = Tools.resolve(tool_config)
      if resolved_tool and resolved_tool.schema then
        local id = "<tool>" .. tool_name .. "</tool>"
        chat.tool_registry.schemas[id] = resolved_tool.schema
        chat.tool_registry.in_use[tool_name] = true
        -- ⚠️ 不在这里添加 context，避免触发 format_role 错误
        -- context 已通过 preload_context_to_messages 预加载到 messages 中
      end
    else
      log:warn("[AgentChat:%s] Tool not found: %s", self.name, tool_name)
    end
  end

  if is_default then
    log:debug("[AgentChat:%s] Registered default Chat builtin tools", self.name)
  else
    log:debug("[AgentChat:%s] Registered %d user-specified tools", self.name, #tools_to_register)
  end

  -- ⭐ 强制添加 handoff 工具（无论用户是否指定其他工具）
  -- ⚠️ 使用直接注册方式，不调用 tool_registry:add()
  -- 因为 add() 会调用 context:add() → ts_parse_buffer → format_role(nil)
  -- 当 AgentChat buffer 没有 role header 时会崩溃
  local tool = handoff_tool.create_tool({ agent_names = self._agent_names })
  chat.tools.tools_config[tool.name] = { callback = tool }
  chat.tool_registry.schemas["<tool>" .. tool.name .. "</tool>"] = tool.schema
  chat.tool_registry.in_use[tool.name] = true
end

--- 创建隐藏的 Maxa AI Chat
---@return table|nil chat Chat 实例
---@return string|nil error 错误信息
function AgentChat:_create_hidden_chat()
  local Chat = require("maxa.interactions.chat")
  local utils = require("maxa.mcphub.native_servers.subagent.utils")
  local config = self._config

  -- Explicit unknown presets must fail instead of silently changing provider.
  local adapter = utils.resolve_adapter_by_key(config.adapter, config.parent_chat)
  if not adapter then
    return nil, "Failed to resolve adapter"
  end

  local system_prompt, sp_err = self:_build_system_prompt(config)
  if not system_prompt then
    return nil, sp_err
  end

  -- 构建初始 messages
  -- 注意：system 消息必须设置 opts.visible = false，否则 MaxaAI UI 会尝试渲染它
  -- 但 roles 配置中没有 "system" 键，会导致 format_role 报错
  local chat_messages = {
    { role = "system", content = system_prompt, opts = { visible = false }, _meta = { tag = "system_prompt_from_config" } },
  }
  vim.list_extend(chat_messages, vim.deepcopy(config.shared_background or {}))
  table.insert(chat_messages, {
    role = "user", content = self:_build_discussion_prompt(config), opts = { visible = false },
  })

  -- 非交互配置（复用 fork_agent 的模式）
  local chat_opts = {
    adapter = adapter,
    messages = utils.build_sub_agent_render_messages(chat_messages),
    buffer_context = config.buffer_context,
    cwd = config.buffer_context and config.buffer_context.cwd,
    project_root = config.buffer_context and config.buffer_context.project_root,

    -- 注意：MaxaAI 的 Chat.new 不会自动处理 tools 参数
    -- 需要在创建后手动注册工具到 tool_registry

    -- The shared composer supplied Runtime + Soul; discussion rules are user background.
    ignore_system_prompt = true,
    headless = true,
    agent_child = true,
    agent_parent = config.parent_chat,

    -- 非交互配置
    auto_submit = false,
    auto_submit_success = true,
    auto_submit_errors = true,
    stop_context_insertion = true,
    -- 禁用 intro message (hints)
    intro_message = "",

    -- 标题设置：阻止标题生成器触发 premium 请求
    title = "Agent: " .. (self.name or "unknown"),
    title_refresh_count = 999,

    -- 回调
    callbacks = {
      on_completed = function(chat)
        self:_on_chat_completed(chat)
      end,
      on_error = function(chat, err)
        self:_on_chat_error(chat, err)
      end,
      on_cancelled = function(chat)
        self:_on_chat_cancelled(chat)
      end,
    },
  }

  -- 创建 Chat 实例
  local ok, chat = pcall(Chat.new, chat_opts)
  if not ok or not chat then
    local err_msg = type(chat) == "string" and chat or "Chat.new returned nil"
    return nil, "Failed to create Chat: " .. err_msg
  end

  chat.messages = chat_messages
  if chat.tools then chat.tools.messages = chat_messages end
  utils.bind_sub_agent_render_messages(chat)
  require("maxa.session.abilities").rehydrate(chat)
  require("maxa.abilities.hooks").restore_hooks_from_messages(chat)

  chat._multi_agent_context = {
    coordinator = self._coordinator,
    agent_name = self.name,
    agent_names = self._agent_names,
    agent = self,
  }
  compaction_messages.mark_current_messages_as_protected_prefix(chat)

  if self._recursion_depth then
    chat[utils.RECURSION_DEPTH_KEY] = self._recursion_depth
    chat._subagent_recursion_depth = self._recursion_depth
  end

  -- ⭐ self_ref 用于后续所有 Hook 闭包中引用 AgentChat 实例
  local self_ref = self

  -- ⭐ 注册工具：先应用用户指定的工具，再强制添加 handoff
  local cc_config = require("maxa.config")
  self:_register_tools(chat, cc_config, utils)

  -- Hook tools:refresh 方法，在 refresh 之后自动重新添加 handoff 工具到 tool_registry
  local original_refresh = chat.tools.refresh
  chat.tools.refresh = function(tools_self, refresh_opts)
    -- 调用原始 refresh
    local result = original_refresh(tools_self, refresh_opts)
    -- 重新注册所有工具（包括用户指定的工具和 handoff）
    self_ref:_register_tools(chat, cc_config, utils)
    log:debug("[AgentChat:%s] Re-registered tools after refresh", self_ref.name)
    return result
  end

  -- ⭐ 保护 buffer：标记为 multi-agent 使用中，防止被意外删除
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.b[chat.bufnr]._multi_agent_protected = true
  end

  -- ⭐ Hook Chat 的 close 方法，防止意外删除 buffer
  local original_close = chat.close
  chat._original_close = original_close -- 保存原始方法供后续使用
  chat.close = function(self_chat)
    -- 如果被保护，只隐藏窗口，不删除 buffer
    if
      self_chat.bufnr
      and vim.api.nvim_buf_is_valid(self_chat.bufnr)
      and vim.b[self_chat.bufnr]._multi_agent_protected
    then
      log:debug("[AgentChat] Buffer %d is protected, hiding window instead of closing", self_chat.bufnr)
      if self_chat.ui and self_chat.ui.winnr and vim.api.nvim_win_is_valid(self_chat.ui.winnr) then
        pcall(vim.api.nvim_win_hide, self_chat.ui.winnr)
      end
      return
    end
    -- 否则调用原始 close
    return original_close(self_chat)
  end

  -- ⭐ Hook add_buf_message 方法，在 coordinator 结束时跳过写入
  local original_add_buf_message = chat.add_buf_message
  chat.add_buf_message = function(self_chat, ...)
    -- 检查 coordinator 是否正在结束
    if self_ref._coordinator and self_ref._coordinator._is_finishing then
      log:debug("[AgentChat:%s] Coordinator is finishing, skip add_buf_message", self_ref.name)
      return
    end
    -- 检查 buffer 是否有效
    if not self_chat.bufnr or not vim.api.nvim_buf_is_valid(self_chat.bufnr) then
      log:debug("[AgentChat:%s] Buffer invalid, skip add_buf_message", self_ref.name)
      return
    end
    -- 调用原始方法
    return original_add_buf_message(self_chat, ...)
  end

  -- ⭐ Hook add_tool_output 方法，在 coordinator 结束时或 buffer 无效时跳过
  -- 这是关键！add_tool_output 会调用 ui:unlock_buf()，如果 buffer 已删除会报错
  local original_add_tool_output = chat.add_tool_output
  chat.add_tool_output = function(self_chat, ...)
    -- 检查 coordinator 是否正在结束
    if self_ref._coordinator and self_ref._coordinator._is_finishing then
      log:debug("[AgentChat:%s] Coordinator is finishing, skip add_tool_output", self_ref.name)
      return
    end
    -- 检查 buffer 是否有效
    if not self_chat.bufnr or not vim.api.nvim_buf_is_valid(self_chat.bufnr) then
      log:debug("[AgentChat:%s] Buffer invalid, skip add_tool_output", self_ref.name)
      return
    end
    -- 调用原始方法
    return original_add_tool_output(self_chat, ...)
  end

  -- 隐藏 AgentChat 的窗口（它不需要显示）
  self:_hide_window(chat)

  -- ⭐ 清理 buffer 中 render 产生的 "## Me" header 和 Context
  -- Chat.new 完成后 buffer 中有 header，AgentChat 不需要
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    if chat.ui then
      chat.ui:unlock_buf()
    end
    local total = vim.api.nvim_buf_line_count(chat.bufnr)
    local me_header_line = nil
    for i = 1, math.min(total, 5) do
      local line = vim.api.nvim_buf_get_lines(chat.bufnr, i - 1, i, false)[1]
      if line and line:match("^## Me") then
        me_header_line = i
        break
      end
    end
    if me_header_line then
      local header_end = me_header_line
      for i = me_header_line + 1, total do
        local line = vim.api.nvim_buf_get_lines(chat.bufnr, i - 1, i, false)[1]
        if line and (line == "" or line:match("^>%s") or line:match("^> Context")) then
          header_end = i
        else
          break
        end
      end
      vim.api.nvim_buf_set_lines(chat.bufnr, me_header_line - 1, header_end, false, {})
      local ns_header = vim.api.nvim_create_namespace("MaxaAI-headers")
      vim.api.nvim_buf_clear_namespace(chat.bufnr, ns_header, 0, -1)
    end
    if chat.ui then
      chat.ui:lock_buf()
    end
  end

  return chat, nil
end

--- 隐藏 Chat 窗口
---@param chat table Chat 实例
function AgentChat:_hide_window(chat)
  if chat and chat.ui and chat.ui.winnr then
    pcall(vim.api.nvim_win_hide, chat.ui.winnr)
  end
end

--- 确保 Chat 已创建（延迟初始化）
---@return boolean success
---@return string|nil error
---@return boolean created 是否是新创建的
function AgentChat:_ensure_chat()
  if self.chat then
    return true, nil, false
  end

  local chat, err = self:_create_hidden_chat()
  if not chat then
    return false, err, false
  end

  self.chat = chat
  return true, nil, true
end

--- 发送消息并等待响应
---@param message string 用户消息内容
---@param callback function 回调函数 (response: string|nil, error: string|nil, handoff_result: table|nil)
function AgentChat:submit(message, callback, goal_prompt)
  if self.is_busy then
    callback(nil, "Agent is busy", nil)
    return
  end

  -- 确保 Chat 已创建
  local ok, err, just_created = self:_ensure_chat()
  if not ok then
    callback(nil, err, nil)
    return
  end

  -- Chat.new() 会调用 close_last_chat()，可能隐藏了其他窗口
  if just_created and self._coordinator then
    if self._coordinator._tab_info then
      -- 在 Multi-Agent Tab 中：恢复 Tab 布局（close_last_chat 可能关闭了 AGENT 窗口）
      self._coordinator:_restore_tab_layout()
    elseif self._coordinator._parent_window_manager then
      -- 不在 Tab 中：恢复父窗口
      self._coordinator._parent_window_manager:restore_parent_window()
    end
  end

  self.is_busy = true
  self._on_response = callback
  self._current_round = self._current_round + 1
  self._response_handled = false -- 重置防重复标志
  self._waiting_for_handoff = false -- 重置等待标志（新一轮 submit）

  -- Handoff context belongs to this participant, not a process-global active Chat.

  -- 注入本轮讨论消息。隐藏消息避免污染展示缓冲区；auto_submit 会直接发送 messages。
  local cc_config = require("maxa.config")
  table.insert(self.chat.messages, {
    role = cc_config.constants.USER_ROLE,
    content = message,
    opts = { visible = false },
  })

  if goal_prompt then
    require("maxa.mcphub.native_servers.subagent.utils").append_sub_agent_tail(self.chat.messages, goal_prompt)
  end

  log:debug("[AgentChat:%s] Submitting message for round %d", self.name, self._current_round)

  -- 提交请求（auto_submit = true：跳过 buffer 解析，直接发送 messages）
  -- 因为 tool_result 是 visible = false，buffer 中没有可见的用户消息
  self.chat:submit({ auto_submit = true })
end

-- 注意：handoff 工具现在通过 tool_registry:add 在 _create_hidden_chat 中注册
-- 不再需要单独的 _register_handoff_tool 方法

--- Chat 完成回调
---@param chat table Chat 实例
function AgentChat:_on_chat_completed(chat)
  if completion_guard.defer_for_token_decision(chat, function()
    self:_on_chat_completed(chat)
  end) then
    return
  end
  local token_terminal = completion_guard.is_token_terminal(chat)

  -- ⭐ 检查 coordinator 是否正在结束，如果是则跳过后续操作
  -- 这可以防止在 buffer 被删除后尝试访问它
  if self._coordinator and self._coordinator._is_finishing and not token_terminal then
    log:debug("[AgentChat:%s] Coordinator is finishing, skip on_completed to avoid buffer access", self.name)
    self.is_busy = false
    self._waiting_for_handoff = false
    -- 清理 MCP handoff 上下文
    mcp_handoff.clear_active_context()
    return
  end

  -- 调试日志
  log:debug(
    "[AgentChat:%s] _on_chat_completed called, _waiting_for_handoff=%s, _on_session_finished=%s, round=%d, messages=%d",
    self.name,
    tostring(self._waiting_for_handoff),
    tostring(self._on_session_finished ~= nil),
    self._current_round or 0,
    chat and chat.messages and #chat.messages or 0
  )

  -- 检查是否被打断
  if chat._subagent_interrupted then
    -- 被打断时，延迟重置标志，不触发回调
    vim.defer_fn(function()
      chat._subagent_interrupted = false
    end, 500)
    return
  end

  -- ⭐ 检查是否设置了完成监听器（表示会话已结束，这是最终响应）
  -- 注意：不再依赖 _waiting_for_handoff，因为它可能在中间 handoff 返回时被重置
  if self._on_session_finished then
    vim.notify(
      string.format("[AgentChat:%s] Session finished, triggering completion listener", self.name),
      vim.log.levels.INFO
    )
    self.is_busy = false
    self._waiting_for_handoff = false
    local cb = self._on_session_finished
    self._on_session_finished = nil
    vim.defer_fn(function()
      pcall(cb)
    end, 100)
    return
  end

  -- 如果正在等待 handoff 完成，不触发回调
  if self._waiting_for_handoff then
    vim.notify(
      string.format("[AgentChat:%s] Waiting for handoff to complete, skipping on_completed", self.name),
      vim.log.levels.DEBUG
    )
    self.is_busy = false
    return
  end

  -- 防重复完成
  if self._response_handled then
    return
  end
  self._response_handled = true

  self.is_busy = false

  -- 清理 MCP handoff 上下文
  mcp_handoff.clear_active_context()

  -- 检测是否有 Handoff Tool 调用
  local found, handoff_result = handoff_tool.find_last_handoff_result(chat.messages)

  -- 提取最后一条 LLM 响应
  local response = self:_extract_response(chat.messages)

  log:debug(
    "[AgentChat:%s] Completed - response=%s, handoff=%s",
    self.name,
    response and "yes" or "no",
    found and handoff_result.target or "none"
  )

  -- 延迟调用回调，给 MCP 工具的 UI 回调足够时间完成
  -- 参考通用子代理异步回调实现
  if self._on_response then
    local cb = self._on_response
    self._on_response = nil
    vim.defer_fn(function()
      cb(response, nil, token_terminal and {
        target = "user",
        token_threshold_action = completion_guard.token_decision_action(chat),
      } or found and handoff_result or nil)
    end, 200)
  end
end

--- Chat 错误回调
---@param chat table Chat 实例
---@param err any 错误信息
function AgentChat:_on_chat_error(chat, err)
  -- 防重复完成
  if self._response_handled then
    return
  end
  self._response_handled = true

  -- 重置所有状态标志（防止状态残留）
  self.is_busy = false
  self._waiting_for_handoff = false

  -- 清理 MCP handoff 上下文
  mcp_handoff.clear_active_context()

  local error_msg = "Chat error"
  if type(err) == "string" then
    error_msg = err
  elseif type(err) == "table" and err.message then
    error_msg = err.message
  end

  log:error("[AgentChat:%s] Error: %s", self.name, error_msg)

  -- 延迟调用回调
  if self._on_response then
    local cb = self._on_response
    self._on_response = nil
    vim.defer_fn(function()
      cb(nil, error_msg, nil)
    end, 200)
  end
end

--- Chat 取消回调
---@param chat table Chat 实例
function AgentChat:_on_chat_cancelled(chat)
  -- 检查是否被打断
  if chat._subagent_interrupted then
    -- 被打断时，延迟重置标志，不触发回调
    vim.defer_fn(function()
      chat._subagent_interrupted = false
    end, 500)
    return
  end

  -- 防重复完成
  if self._response_handled then
    return
  end
  self._response_handled = true

  -- 重置所有状态标志（防止状态残留）
  self.is_busy = false
  self._waiting_for_handoff = false

  -- 清理 MCP handoff 上下文
  mcp_handoff.clear_active_context()

  log:debug("[AgentChat:%s] Cancelled", self.name)

  -- 延迟调用回调
  if self._on_response then
    local cb = self._on_response
    self._on_response = nil
    vim.defer_fn(function()
      cb(nil, "Cancelled", nil)
    end, 200)
  end
end

--- 从消息列表中提取最后一条 LLM 响应
---@param messages table[] 消息列表
---@return string|nil response 响应内容
function AgentChat:_extract_response(messages)
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if (msg.role == "assistant" or msg.role == "llm") and msg.content and msg.content ~= "" then
      return msg.content
    end
  end
  return nil
end

--- 获取当前轮次
---@return number
function AgentChat:get_current_round()
  return self._current_round
end

--- 获取所有消息历史
---@return table[] messages
function AgentChat:get_messages()
  if not self.chat then
    return {}
  end
  return self.chat.messages or {}
end

--- 获取 save_id（用于持久化）
---@return string|nil save_id
function AgentChat:get_save_id()
  if not self.chat then
    return nil
  end

  -- 尝试从 chat 获取 save_id
  if self.chat.save_id then
    return self.chat.save_id
  end

  -- 尝试从 opts 获取
  if self.chat.opts and self.chat.opts.save_id then
    return self.chat.opts.save_id
  end

  return nil
end

--- 从保存的消息恢复 AgentChat
---@param config AgentChatConfig 配置
---@param messages table[] 保存的消息
---@return AgentChat
function AgentChat.restore(config, messages)
  local self = AgentChat.new(config)

  -- 创建 Chat
  local ok, err = self:_ensure_chat()
  if not ok then
    log:error("[AgentChat:%s] Failed to restore: %s", config.name, err)
    return self
  end

  -- 恢复消息（跳过第一条 system prompt，因为已经在创建时添加）
  for i = 2, #messages do
    table.insert(self.chat.messages, messages[i])
  end

  -- 计算当前轮次（统计 user 消息数量）
  local round = 0
  for _, msg in ipairs(messages) do
    if msg.role == "user" then
      round = round + 1
    end
  end
  self._current_round = round

  log:debug("[AgentChat:%s] Restored with %d messages, round=%d", config.name, #messages, round)

  return self
end

--- 停止当前请求
function AgentChat:stop()
  if self.chat and self.is_busy then
    self.chat:stop()
  end
end

--- 关闭 Chat
function AgentChat:close()
  if self.chat then
    local original_bufnr = self.chat.bufnr

    -- 移除 buffer 保护标记
    if original_bufnr and vim.api.nvim_buf_is_valid(original_bufnr) then
      vim.b[original_bufnr]._multi_agent_protected = nil
    end

    -- 关闭 UI 窗口（但不删除 Buffer）
    if self.chat.ui and self.chat.ui.winnr and vim.api.nvim_win_is_valid(self.chat.ui.winnr) then
      pcall(vim.api.nvim_win_close, self.chat.ui.winnr, true)
    end

    -- ⭐ 不调用 _original_close，因为它会：
    -- 1. 从 chatmap 中移除映射，导致 buf_get_chat 失败
    -- 2. 立即删除 Buffer，导致异步回调失败
    -- 我们只需要延迟删除 Buffer，让异步回调有时间完成

    -- 延迟删除 Buffer，给 MaxaAI 的异步回调足够时间完成
    if original_bufnr and vim.api.nvim_buf_is_valid(original_bufnr) then
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(original_bufnr) then
          pcall(vim.api.nvim_buf_delete, original_bufnr, { force = true })
        end
      end, 3000) -- 3 秒延迟
    end

    self.chat = nil
  end
  self.is_busy = false
  self._on_response = nil
  self._on_session_finished = nil
end

return AgentChat
