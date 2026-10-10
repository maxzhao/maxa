-- fork_agent 工具实现
-- Fork 当前 Chat 会话创建子代理，继承完整状态
-- 策略：Clone State + 使用 Chat.new() 的 auto_submit
local compaction_messages = require("maxa.session.compaction_messages")
local fork_context = require("maxa.mcphub.native_servers.subagent.fork_context")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local session_status = require("maxa.session.session_status")
local subagent_trace = require("maxa.mcphub.native_servers.subagent.session_trace")
local utils = require("maxa.mcphub.native_servers.subagent.utils")

--- 默认 max_turns 限制（math.huge = 无限，除非明确指定）
local DEFAULT_MAX_TURNS = math.huge
local VALID_FORK_MODES = { temporary = true, new_chat = true }

--- 验证 fork_mode
--- @param fork_mode any
--- @return boolean valid
--- @return string|nil error
local function validate_fork_mode(fork_mode)
  if fork_mode == nil then
    return true, nil
  end
  if type(fork_mode) ~= "string" then
    return false, "'fork_mode' must be a string, got " .. type(fork_mode)
  end
  if not VALID_FORK_MODES[fork_mode] then
    return false, string.format("'fork_mode' must be one of: temporary, new_chat. Got '%s'", fork_mode)
  end
  return true, nil
end

--- 从 req.caller 中提取父 Chat 对象和当前 tool_call_id
--- MCPHub 通过 caller.maxa_ai (agent) 传递上下文，agent.chat 是 Chat 实例
--- @param caller table|nil req.caller 对象
--- @return table|nil chat Chat 实例
--- @return string|nil error_or_tool_call_id 错误消息或 tool_call_id
--- @return string|nil tool_call_id 当 chat 有效时返回 tool_call_id
local function get_parent_chat_and_tool_id(caller)
  if not caller then
    return nil, "fork_agent requires caller context. This tool must be called from within a Chat session."
  end

  -- MCPHub MaxaAI 扩展传递 caller.maxa_ai (agent 对象)
  local agent = caller.maxa_ai
  if not agent then
    return nil, "fork_agent requires MaxaAI agent context. This tool must be called from within a Chat session."
  end

  -- agent.chat 是 Chat 实例
  local chat = agent.chat
  if not chat then
    return nil, "fork_agent requires parent Chat. No Chat session found in agent context."
  end

  -- 验证 chat 对象的基本结构
  if type(chat) ~= "table" then
    return nil, "Invalid parent Chat object: expected table, got " .. type(chat)
  end

  if not chat.messages then
    return nil, "Invalid parent Chat object: missing 'messages' field"
  end

  if not chat.adapter then
    return nil, "Invalid parent Chat object: missing 'adapter' field"
  end

  -- 尝试获取当前 tool_call_id
  -- agent.tool.function_call.id 包含当前正在执行的 tool call 的 ID
  local tool_call_id = nil
  if agent.tool and agent.tool.function_call and agent.tool.function_call.id then
    tool_call_id = agent.tool.function_call.id
  end

  return chat, nil, tool_call_id
end

--- 构建 forked goal prompt
--- @param goal_prompt string 用户提供的目标
--- @return string 完整的 forked task prompt
local function build_forked_prompt(goal_prompt)
  -- 如果用户已经提供了完整的 [FORKED TASK] 格式，直接使用
  if goal_prompt:match("^%[FORKED TASK%]") then
    return goal_prompt
  end

  return "[FORKED TASK]\n\n" .. goal_prompt
end

--- 主处理函数
--- @param req table MCP 请求对象
--- @param res table MCP 响应对象
local function fork_agent(req, res)
  -- 验证请求对象
  if not req then
    return res:error(utils.format_error("fork_agent", "Invalid request object - request is nil or missing"))
  end

  if not req.params then
    return res:error(utils.format_error("fork_agent", "Invalid request - missing params object"))
  end

  local accepted, retired_error = utils.reject_instructions(req.params)
  if not accepted then
    return res:error(utils.format_error("fork_agent", retired_error))
  end
  local params = param_utils.normalize(req.params)
  local goal_prompt = params.goal_prompt
  local max_turns = utils.normalize_max_turns(params.max_turns, DEFAULT_MAX_TURNS)
  if params.restrict_tools ~= nil then
    return res:error(
      utils.format_error(
        "fork_agent",
        "'restrict_tools' is no longer supported by fork_agent; forked agents always inherit parent tools"
      )
    )
  end

  if params.temperature ~= nil then
    return res:error(
      utils.format_error(
        "fork_agent",
        "'temperature' is no longer supported by fork_agent; forked agents always inherit parent adapter/model settings"
      )
    )
  end

  local fork_mode = params.fork_mode or "new_chat"
  local title_override = params.title
  -- 验证 title（必需）
  local valid, error_msg = utils.validate_required_string(title_override, "title")
  if not valid then
    return res:error(utils.format_error("fork_agent", error_msg or "Invalid title"))
  end

  -- 验证 goal_prompt（必需）
  valid, error_msg = utils.validate_required_string(goal_prompt, "goal_prompt")
  if not valid then
    return res:error(utils.format_error("fork_agent", error_msg or "Invalid goal_prompt"))
  end

  -- 验证 max_turns
  valid, error_msg = utils.validate_max_turns(max_turns)
  if not valid then
    return res:error(utils.format_error("fork_agent", error_msg or "Invalid max_turns"))
  end

  -- 验证 fork_mode
  valid, error_msg = validate_fork_mode(fork_mode)
  if not valid then
    return res:error(utils.format_error("fork_agent", error_msg or "Invalid fork_mode"))
  end

  -- 检查 Maxa AI Chat 是否可用
  local cc_available, cc_error = utils.check_chat_available()
  if not cc_available then
    return res:error(utils.format_error("fork_agent", cc_error or "Maxa AI Chat not available"))
  end

  -- 获取父 Chat 实例和当前 tool_call_id
  local parent_chat, chat_error, tool_call_id = get_parent_chat_and_tool_id(req.caller)
  if not parent_chat then
    return res:error(utils.format_error("fork_agent", chat_error or "Failed to get parent chat"))
  end

  -- 检查递归深度（基于父 Chat 元数据，避免异步计数泄漏）
  local allowed, recursion_error = utils.check_execution_allowed("fork_agent", parent_chat)
  if not allowed then
    return res:error(utils.format_error("fork_agent", recursion_error))
  end

  local Chat = require("maxa.interactions.chat")
  local cc_config = require("maxa.config")

  -- 保存父 chat 的窗口和 buffer 信息
  local parent_bufnr = parent_chat.bufnr
  local parent_winnr = (parent_chat.ui and parent_chat.ui.winnr) or vim.fn.bufwinid(parent_bufnr)
  if parent_winnr == -1 then
    parent_winnr = vim.api.nvim_get_current_win()
  end

  -- =========================================================================
  -- 子代理窗口管理（使用 window_manager 模块）
  -- =========================================================================
  local keymap_manager = require("maxa.mcphub.native_servers.subagent.tools.window_manager")
  local win_mgr = utils.create_window_manager(parent_chat, parent_bufnr)

  -- =========================================================================
  -- 构建 forked messages
  -- 策略：根据 tool_call_id 找到包含当前 tool_calls 的 LLM 消息，
  --       然后回滚到该消息之前。这样所有批量调用的子代理都看到相同的历史。
  --
  -- 优点：
  -- 1. 不需要复杂的快照缓存机制
  -- 2. 自动处理批量调用 vs 单独调用
  -- 3. 每个子代理看到干净的历史，不包含其他子代理的结果
  -- =========================================================================
  local forked_messages, is_batch = fork_context.build_clean_messages(parent_chat.messages, tool_call_id)

  -- 记录 fork 开始时的消息索引（用于提取子代理响应）
  local fork_start_index = #forked_messages

  -- =========================================================================
  -- 添加 user-role 历史边界和任务尾部，确保子代理从明确任务上下文开始。
  -- =========================================================================
  local forked_prompt = build_forked_prompt(goal_prompt)

  -- 1. FORK BOUNDARY 作为 user 消息，避免改变 Responses 顶层 instructions。
  local fork_boundary = table.concat({
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    "[FORK BOUNDARY]",
    "",
    "上方所有内容是从父代理继承的上下文。",
    "你看到的任何工具调用都是父代理执行的，不是你的。",
    "你尚未进行任何工具调用——这是你的第一轮。",
    "你的任务定义在此边界的下方。",
    "可以合理使用可用的 SubAgent 工具，但不得把边界下方任务原样或近似原样转包给下一层子代理。",
    "如需创建下一层子代理，必须拆成明确子问题，并说明职责边界、停止条件和结果回传方式。",
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
  }, "\n")

  table.insert(forked_messages, {
    role = cc_config.constants.USER_ROLE,
    content = fork_boundary,
    _meta = { tag = "agent_boundary" },
    opts = { visible = false },
  })

  -- 2. 追加 fork 任务。
  utils.append_sub_agent_tail(forked_messages, forked_prompt)

  -- =========================================================================
  -- 准备 adapter（完全继承父 chat，不允许 fork 调用方覆盖 temperature/model）
  -- =========================================================================
  local forked_adapter = parent_chat.adapter

  -- =========================================================================
  -- 准备 buffer context
  -- =========================================================================
  local buffer_context = parent_chat.buffer_context
    or require("maxa.utils.context").get(parent_bufnr)

  -- =========================================================================
  -- 创建 forked Chat 实例
  -- 关键：禁用 auto_submit，手动控制 submit 时机
  -- 原因：Chat.new() 内部会在返回前调用 submit()（当 auto_submit = true）
  --       我们需要在 Chat.new() 返回后修复被 ui:render() 删除的 fork prompt
  -- =========================================================================

  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = utils.build_sub_agent_render_messages(forked_messages)

  local non_interactive = utils.build_non_interactive_defaults({
    auto_submit = false, -- 禁用自动提交，我们手动控制
  })
  local fork_save_id = nil
  if fork_mode == "temporary" then
    local history_core = require("maxa.session.history_core")
    fork_save_id = history_core.make_unsavable_save_id("fork_agent")
  end

  local chat_opts = vim.tbl_extend("force", non_interactive, {
    adapter = forked_adapter,
    buffer_context = buffer_context,
    cwd = parent_chat.opts and parent_chat.opts.cwd or buffer_context.cwd,
    project_root = parent_chat.opts and parent_chat.opts.project_root or buffer_context.project_root,
    messages = render_messages,
    -- 继承父会话的设置
    settings = parent_chat.settings and vim.deepcopy(parent_chat.settings) or nil,
    -- title: 优先使用 LLM 提供的，否则从 goal_prompt 提取
    title = title_override,
    save_id = fork_save_id,
    agent_child = true,
    agent_parent = parent_chat,
    headless = true,
    -- 父 chat 的 system prompt 已在 forked_messages 中，
    -- 不让 Chat.new 再注入默认 system prompt（避免重复）
    ignore_system_prompt = true,
  })

  -- =========================================================================
  -- 创建 Chat 实例（auto_submit = false，不会自动调用 submit）
  -- ui:render() 会删除最后一条消息，我们在 submit 前重新添加
  -- 注意：Chat.new() 会调用 close_last_chat()，隐藏父 chat 的窗口
  -- =========================================================================
  local ok, forked_chat = utils.with_subagent_chat_creation(Chat, function()
    return Chat.new(chat_opts)
  end, { hidden = true, restore_last_chat = true })

  if not ok then
    local err_msg = type(forked_chat) == "string" and forked_chat or "Unknown error during Chat creation"
    -- 恢复父 chat 窗口
    win_mgr:restore_parent_window()
    return res:error(utils.format_error("fork_agent", "Failed to create forked Chat: " .. err_msg))
  end

  if not forked_chat then
    -- 恢复父 chat 窗口
    win_mgr:restore_parent_window()
    return res:error(utils.format_error("fork_agent", "Failed to create forked Chat instance"))
  end

  -- Chat.new 使用 render_messages 完成 UI 渲染；恢复原始 messages 供 LLM/API 使用。
  forked_chat.messages = forked_messages
  utils.bind_sub_agent_render_messages(forked_chat)
  if forked_chat.tools then
    forked_chat.tools.messages = forked_chat.messages
  end
  tool_display.apply_render_postprocess(forked_chat, render_messages)

  compaction_messages.mark_current_messages_as_protected_prefix(forked_chat)
  utils.set_child_recursion_depth(parent_chat, forked_chat)
  require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").bind_child(parent_chat, forked_chat, req.ui)

  local trace_state = subagent_trace.start_child("fork_agent", req, parent_chat, forked_chat, {
    session_role = "subagent",
    mode = fork_mode,
    params = params,
    tool_call_id = tool_call_id,
  })

  -- =========================================================================
  -- 恢复父 chat 窗口（被 Chat.new() 中的 close_last_chat() 隐藏了）
  -- =========================================================================
  win_mgr:restore_parent_window()

  -- =========================================================================
  -- 将子代理窗口移动到父窗口下方
  -- =========================================================================
  win_mgr:setup_child_window(forked_chat)

  -- =========================================================================
  -- 定义取消回调（用于 q 键）
  -- =========================================================================
  local function on_fork_cancel(forked_chat)
    -- 调用 stop() 触发正常的取消流程
    forked_chat:stop()
  end

  -- =========================================================================
  -- 设置子代理键位
  -- Ctrl+C: 打断（停止当前请求，保持会话）
  -- q: 取消（终止子代理，返回错误给父代理）
  -- =========================================================================
  keymap_manager.setup_subagent_keymaps(forked_chat, on_fork_cancel)

  -- =========================================================================
  -- 继承父会话的额外状态
  -- =========================================================================

  -- 继承父会话工具；fork_agent 不允许调用方限制或覆盖工具
  utils.inherit_tool_registry(parent_chat, forked_chat)

  -- 继承父会话的 context_items
  utils.inherit_context_items(parent_chat, forked_chat)

  -- [AbilityHook] 注册 cascade parent_chain + 继承 session hooks
  -- fork_agent 创建的子代理行为应与父代理完全一致
  local sh_ok, sh_registry = pcall(require, "maxa.abilities.hooks.registry")
  if sh_ok then
    sh_registry.register_parent_chain(parent_chat.id, forked_chat.id)
    sh_registry.inherit_session_hooks(parent_chat.id, forked_chat.id, forked_chat)
  end

  -- 继承 cycle 计数（用于 prompt caching 优化）
  forked_chat.cycle = parent_chat.cycle or 1

  -- =========================================================================
  -- 使用 agent_executor 执行 forked chat
  -- =========================================================================
  local agent_executor = require("maxa.mcphub.native_servers.subagent.tools.agent_executor")

  require("maxa.mcphub.native_servers.subagent.async_cancel").register_chat("subagent__fork_agent", forked_chat, {
    kind = "subagent_chat",
    title = title,
    save_id = fork_mode == "temporary" and nil or utils.get_chat_save_id(forked_chat),
    current_chat = function() return forked_chat end,
  })

  agent_executor.execute({
    ui = req.ui,
    chat = forked_chat,
    prompt = nil, -- 任务已在 messages 的 tool result 中
    max_turns = max_turns,
    fork_start_index = fork_start_index,
    handoff_parent = parent_chat,
    on_replaced = function(target)
      forked_chat = target
      trace_state = subagent_trace.start_child("fork_agent", req, parent_chat, target, {
        session_role = "subagent", mode = fork_mode, params = params,
      })
    end,
    on_complete = function(result)
      -- 构建响应数据（添加 goal 字段）
      local response_data = vim.tbl_extend("force", result, {
        goal = goal_prompt,
        fork_mode = fork_mode,
      })
      if fork_mode == "temporary" then
        response_data.save_id = nil
        if response_data.context_status then
          response_data.context_status.save_id = nil
        end
      end

      subagent_trace.record_subagent_completed("fork_agent", forked_chat, response_data, {
        mode = fork_mode,
        trace_state = trace_state,
      })

      -- Project only model-facing facts; retain the full internal trace result.
      res:text(require("maxa.mcphub.native_servers.subagent.result_format").answer(response_data))
      res:send()

      -- 清理 forked chat 并关闭子代理窗口
      vim.schedule(function()
        win_mgr:cleanup(forked_chat)
      end)
    end,
    on_error = function(err)
      -- Completed invocations report recoverable IDs without modifying history.
      vim.schedule(function()
        win_mgr:cleanup(forked_chat)
      end)

      local session_status = require("maxa.session.session_status")
      local error_context_status = session_status.to_llm(session_status.from_chat(forked_chat))
      if fork_mode == "temporary" and error_context_status then
        error_context_status.save_id = nil
      end
      local recovery = {
        save_id = fork_mode == "temporary" and nil or utils.get_chat_save_id(forked_chat),
        parent_save_id = parent_chat and parent_chat.opts and parent_chat.opts.save_id or nil,
        fork_mode = fork_mode,
        context_status = error_context_status,
      }
      subagent_trace.record_subagent_error("fork_agent", forked_chat, err, {
        mode = fork_mode,
        recovery = recovery,
      })
      utils.send_recoverable_error(res, "fork_agent", err, recovery)
    end,
  })
end

-- 工具定义
return {
  name = "fork_agent",
  description = "Fork a child Agent with full parent conversation history and config. Provide only the child goal; context is inherited.",
  inputSchema = {
    type = "object",
    properties = {
      goal_prompt = {
        type = "string",
        description = [[Goal for the forked Agent. Describe what to do, not a tool command such as "use fork_agent". Do not repeat inherited context or file contents. Nested SubAgent use is allowed only for smaller scoped subproblems, not pass-through copies of this goal.]],
      },
      max_turns = {
        type = "number",
        description = "Maximum LLM response turns before forced completion. Default/0: unlimited; positive numbers are hard safety limits. Auto-compact handles token limits.",
      },
      fork_mode = {
        type = "string",
        enum = { "temporary", "new_chat" },
        default = "new_chat",
        description = "Fork persistence mode. Default new_chat creates recoverable history; temporary records no chat history and returns no resumable save_id.",
      },
      title = {
        type = "string",
        description = "Required concise session title for history display, max 50 chars.",
      },
    },
    required = { "goal_prompt", "title" },
  },
  display = require("maxa.mcphub.native_servers.subagent.tools.presentation").answer("@subagent:fork_agent"),
  handler = fork_agent,
}
