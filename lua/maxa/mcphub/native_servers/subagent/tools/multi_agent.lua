-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent.lua
-- multi_agent MCP Tool: 多 Agent 协作讨论入口
-- 整合 Coordinator、AgentChat、DisplayAdapter、SummaryStore 等组件

local Coordinator = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.coordinator")
local SessionManager = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.session_manager")
local window_manager = require("maxa.mcphub.native_servers.subagent.tools.window_manager")
local utils = require("maxa.mcphub.native_servers.subagent.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local subagent_trace = require("maxa.mcphub.native_servers.subagent.session_trace")

---@class MultiAgentParams
---@field id? string 会话 ID（继续之前的会话）
---@field agents? table[] Agent 配置列表（首次调用必填）
---@field task? string 讨论任务（首次调用必填，继续时可选追加）
---@field termination? table 终止配置 {max_rounds?: number, max_messages?: number}
---@field routing? table 路由配置 {initial_agent?: string}
---@field display? table 显示配置 {enabled?: boolean, type?: string}

--- 验证 agents 参数
---@param agents any
---@return boolean valid
---@return string|nil error
local function validate_agents(agents)
  if not agents then
    return false, "agents parameter is required"
  end

  if type(agents) ~= "table" then
    return false, "agents must be an array of agent configurations"
  end

  if #agents == 0 then
    return false, "agents array cannot be empty, at least one agent is required"
  end

  for i, agent in ipairs(agents) do
    if type(agent) ~= "table" then
      return false, string.format("agent[%d] must be an object", i)
    end
    if not agent.name or type(agent.name) ~= "string" then
      return false, string.format("agent[%d].name is required and must be a string", i)
    end
    if not agent.role or type(agent.role) ~= "string" then
      return false, string.format("agent[%d].role is required and must be a string", i)
    end
    local soul_valid, soul_err = utils.validate_soul_params(agent)
    if not soul_valid then
      return false, string.format("agent[%d]: %s", i, soul_err)
    end
    local key, selection_err = utils.preset_key(agent)
    if selection_err then return false, string.format("agent[%d]: %s", i, selection_err) end
    agent.adapter = key
    local valid, err = utils.validate_adapter_key(key)
    if valid and agent.goal_prompt ~= nil then valid, err = utils.validate_required_string(agent.goal_prompt, "goal_prompt") end
    if not valid then return false, string.format("agent[%d]: %s", i, err) end
    -- 验证 restrict_tools（允许已注册的裸名 builtin、MCP 工具和工具组）
    if agent.restrict_tools then
      local valid, err = utils.validate_tools(agent.restrict_tools)
      if not valid then
        return false, string.format("agent[%d].restrict_tools: %s", i, err)
      end
    end
  end

  return true, nil
end

--- 验证 task 参数
---@param task any
---@return boolean valid
---@return string|nil error
local function validate_task(task)
  if not task then
    return false, "task parameter is required"
  end

  if type(task) ~= "string" then
    return false, "task must be a string"
  end

  if task == "" or task:match("^%s*$") then
    return false, "task cannot be empty"
  end

  return true, nil
end

--- 验证 Phase 2 参数
---@param params table 完整参数表
---@return boolean valid
---@return string|nil error
local function validate_phase2_params(params)
  local final_agent = params.final_agent
  local final_prompt = params.final_prompt
  local final_max_turns = params.final_max_turns
  local final_agent_config = params.final_agent_config

  -- 1. final_agent 必选，值必须是 "fork" 或 "run"
  if not final_agent then
    return false, "final_agent parameter is required"
  end
  if final_agent ~= "fork" and final_agent ~= "run" then
    return false, "final_agent must be 'fork' or 'run', got: " .. tostring(final_agent)
  end

  -- 2. final_prompt 必选，必须是非空字符串
  if not final_prompt then
    return false, "final_prompt parameter is required"
  end
  if type(final_prompt) ~= "string" then
    return false, "final_prompt must be a string"
  end
  if final_prompt == "" or final_prompt:match("^%s*$") then
    return false, "final_prompt cannot be empty"
  end

  -- 3. final_max_turns 可选；0 表示无限制，正整数表示硬限制
  if final_max_turns ~= nil then
    if type(final_max_turns) ~= "number" then
      return false, "final_max_turns must be a number"
    end
    if final_max_turns < 0 or math.floor(final_max_turns) ~= final_max_turns then
      return false, "final_max_turns must be 0 or a positive integer"
    end
  end

  -- 4. final_agent_config 仅在 final_agent="run" 时有效
  if final_agent_config ~= nil then
    if final_agent ~= "run" then
      return false, "final_agent_config is only valid when final_agent='run'"
    end
    if type(final_agent_config) ~= "table" then
      return false, "final_agent_config must be an object"
    end
    local soul_valid, soul_err = utils.validate_soul_params(final_agent_config, "final_prompt")
    if not soul_valid then
      return false, "final_agent_config: " .. soul_err
    end
    local key, selection_err = utils.preset_key(final_agent_config)
    if selection_err then return false, "final_agent_config: " .. selection_err end
    final_agent_config.adapter = key
    local adapter_valid, adapter_err = utils.validate_adapter_key(key)
    if not adapter_valid then return false, "final_agent_config: " .. adapter_err end
    -- inherit 互斥校验（复用 utils）
    local inherit_valid, inherit_err = utils.validate_inherit_exclusivity(final_agent_config)
    if not inherit_valid then
      return false, "final_agent_config: " .. inherit_err
    end
      -- 验证 restrict_tools（允许已注册的裸名 builtin、MCP 工具和工具组）
    if final_agent_config.restrict_tools ~= nil then
      local valid, err = utils.validate_tools(final_agent_config.restrict_tools)
      if not valid then
        return false, "final_agent_config.restrict_tools: " .. err
      end
    end
  end

  return true, nil
end

--- 构建 Display Chat 内容
---@param discussions table[] 讨论记录列表
---@return string content 格式化的内容
local function build_display_content(discussions)
  if not discussions or #discussions == 0 then
    return "(No discussion content)"
  end

  local parts = {}

  for _, entry in ipairs(discussions) do
    -- 添加 Agent 的消息
    table.insert(parts, string.format("## %s", entry.agent))
    table.insert(parts, entry.message)
    table.insert(parts, "")
  end

  return table.concat(parts, "\n")
end

--- multi_agent 工具处理函数
---@param req table MCP 请求对象
---@param res table MCP 响应对象
local function multi_agent_handler(req, res)
  -- 参数验证
  if not req or not req.params then
    return res:error("multi_agent: Invalid request - missing params object")
  end

  -- Check raw inputs so retired keys cannot disappear through null normalization.
  local sources = {}
  if type(req.params.agents) == "table" then
    for _, agent in ipairs(req.params.agents) do
      if type(agent) == "table" then
        sources[#sources + 1] = agent
      end
    end
  end
  if type(req.params.final_agent_config) == "table" then
    local valid, err = utils.validate_soul_params(req.params.final_agent_config, "final_prompt")
    if not valid then return res:error("multi_agent: " .. err) end
  end
  local accepted, retired_error = utils.reject_instructions(req.params, "task")
  if not accepted then return res:error("multi_agent: " .. retired_error) end
  for _, source in ipairs(sources) do
    local valid, err = utils.validate_soul_params(source)
    if not valid then
      return res:error("multi_agent: " .. err)
    end
  end
  local params = param_utils.normalize(req.params)
  local session_id = params.id
  local agents = params.agents
  local task = params.task
  local termination = params.termination
  local routing = params.routing
  local title = params.title
  local background_valid, background_error = utils.validate_messages(params.messages, { optional = true, require_user = false })
  if not background_valid then return res:error("multi_agent: " .. background_error) end

  local coordinator
  local is_resume = false
  local deferred_background

  local function get_current_save_id()
    return coordinator and coordinator.display_chat and utils.get_chat_save_id(coordinator.display_chat) or nil
  end

  -- 获取父 Chat（与 run_agent 统一：优先从 req.caller 获取精确实例）
  local original_bufnr = vim.api.nvim_get_current_buf()
  local parent_chat = utils.get_parent_chat(req, original_bufnr)
  local parent_bufnr = parent_chat and parent_chat.bufnr or original_bufnr
  local wm = window_manager.new(parent_chat, parent_bufnr)

  -- 检查递归深度（multi_agent 本身会创建一组子代理）
  local allowed, recursion_error = utils.check_execution_allowed("multi_agent", parent_chat)
  if not allowed then
    return res:error(utils.format_error("multi_agent", recursion_error))
  end

  local parent_depth = utils.get_chat_recursion_depth(parent_chat)
  local parent_opts = parent_chat and parent_chat.opts or {}
  local context_root = parent_opts.project_root or parent_opts.cwd or vim.fn.getcwd()

  -- 保存父 Chat 的 adapter（用于 AgentChat 继承和 Phase 2 Fork）
  local parent_adapter = parent_chat and parent_chat.adapter or nil

  -- 判断是继续会话还是新建会话
  if session_id then
    -- 继续之前的会话
    local restore_err
    coordinator, restore_err = Coordinator.restore(session_id)
    if not coordinator then
      return res:error("multi_agent: " .. tostring(restore_err))
    end
    is_resume = true
    if params.messages then
      local background, context_items
      background, context_items, deferred_background = utils.prepare_background_messages(params.messages, context_root)
      vim.list_extend(coordinator._shared_background, background)
      coordinator._session.config.shared_background = vim.deepcopy(coordinator._shared_background)
    end
  else
    -- 新建会话：验证必填参数
    -- 验证 title
    local valid, err = utils.validate_required_string(title, "title")
    if not valid then
      return res:error("multi_agent: " .. (err or "Invalid title"))
    end

    -- 验证 agents
    valid, err = validate_agents(agents)
    if not valid then
      return res:error("multi_agent: " .. err)
    end

    -- 验证 task
    valid, err = validate_task(task)
    if not valid then
      return res:error("multi_agent: " .. err)
    end

    -- 验证 Phase 2 参数
    valid, err = validate_phase2_params(params)
    if not valid then
      return res:error("multi_agent: " .. err)
    end

    -- 构建 Coordinator 配置
    -- 参数映射: max_rounds -> maxTurns, min_rounds -> minTurns
    local term_config = termination or {}
    term_config.maxTurns = term_config.maxTurns or term_config.max_rounds or 10
    term_config.minTurns = term_config.minTurns or term_config.min_rounds or 1

    local shared_background, context_items
    shared_background, context_items, deferred_background = utils.prepare_background_messages(params.messages, context_root)
    local coordinator_opts = {
      agents = agents,
      shared_background = shared_background,
      termination = term_config,
      routing = routing,
      -- Phase 2 配置
      final_agent = params.final_agent,
      final_prompt = params.final_prompt,
      final_max_turns = utils.normalize_max_turns(params.final_max_turns, math.huge),
      final_agent_config = params.final_agent_config,
      title = title,
    }

    -- 创建 Coordinator
    local ok, create_err = pcall(function()
      coordinator = Coordinator.new(coordinator_opts)
    end)

    if not ok then
      return res:error("multi_agent: Failed to create coordinator - " .. tostring(create_err))
    end
  end

  -- 保存 wm 到 coordinator，用于在 Agent 创建后恢复父窗口
  coordinator._parent_window_manager = wm
  -- 保存父 adapter 到 coordinator，用于 AgentChat 继承
  coordinator._parent_adapter = parent_adapter
  -- 保存父 chat 到 coordinator，用于 Phase 2 继承工具
  coordinator._parent_chat = parent_chat
  -- 保存当前 multi_agent 层级，用于其内部 AgentChat 继承深度
  coordinator._recursion_depth = parent_depth + 1

  -- 使用纯回调模式（不使用 vim.wait，避免阻塞事件循环）
  -- 参考通用子代理异步回调实现

  -- 设置完成回调
  coordinator.on_complete = function(result)
    -- 清理资源（cleanup 内部已有延迟，给异步任务留出时间）
    coordinator:cleanup()

    -- 任务 11.3: 只返回 Phase 2 的最终输出
    -- Phase 2 结果存储在 coordinator._phase2_result 中
    local phase2_result = coordinator._phase2_result

    if phase2_result then
      -- Phase 2 完成，返回最终输出
      local response_data = {
        success = true,
        data = {
          content = phase2_result.content,
          save_id = phase2_result.save_id,
          session_id = coordinator and coordinator.session_id or session_id,
        },
      }
      subagent_trace.record_tool_completed("multi_agent", req, params, response_data, {
        parent_chat = parent_chat,
        status = "completed",
      })
      res:text(require("maxa.mcphub.native_servers.subagent.result_format").answer(response_data))
      res:send()
    else
      -- Phase 2 未执行（理论上不应发生，因为 final_agent 是必选参数）
      local recovery = {
        save_id = get_current_save_id(),
        session_id = coordinator and coordinator.session_id or session_id,
      }
      subagent_trace.record_tool_completed("multi_agent", req, params, {}, {
        parent_chat = parent_chat,
        status = "error",
        error = "Phase 2 did not execute - no final result available",
        recovery = recovery,
      })
      utils.send_recoverable_error(res, "multi_agent", "Phase 2 did not execute - no final result available", recovery)
    end
  end

  -- 设置错误回调
  -- 任务 11.3: 错误也返回 JSON 格式；Display Chat 已创建后尽量携带 save_id
  coordinator.on_error = function(error_msg)
    local save_id = get_current_save_id()

    -- 清理资源（cleanup 内部已有延迟，给异步任务留出时间）
    coordinator:cleanup()

    local recovery = {
      save_id = save_id,
      session_id = coordinator and coordinator.session_id or session_id,
    }
    subagent_trace.record_tool_completed("multi_agent", req, params, {}, {
      parent_chat = parent_chat,
      status = "error",
      error = "Discussion failed - " .. tostring(error_msg),
      recovery = recovery,
    })
    utils.send_recoverable_error(res, "multi_agent", "Discussion failed - " .. tostring(error_msg), recovery)
  end

  -- Shared calls run once in the Display/final Chat, never once per participant.
  local function start_discussion()
  local start_ok, start_err = xpcall(function()
    if is_resume then
      coordinator:resume(task) -- task 可选，用于追加指令
    else
      coordinator:start(task)
    end
  end, debug.traceback)

  if not start_ok then
    local save_id = get_current_save_id()
    coordinator:cleanup()
    local action = is_resume and "resume" or "start"
    if save_id then
      local recovery = {
        save_id = save_id,
        session_id = coordinator and coordinator.session_id or session_id,
      }
      subagent_trace.record_tool_completed("multi_agent", req, params, {}, {
        parent_chat = parent_chat,
        status = "error",
        error = "Failed to " .. action .. " discussion - " .. tostring(start_err),
        recovery = recovery,
      })
      return utils.send_recoverable_error(res, "multi_agent", "Failed to " .. action .. " discussion - " .. tostring(start_err), recovery)
    end
    subagent_trace.record_tool_completed("multi_agent", req, params, {}, {
      parent_chat = parent_chat,
      status = "error",
      error = "Failed to " .. action .. " discussion - " .. tostring(start_err),
    })
    return res:error("multi_agent: Failed to " .. action .. " discussion - " .. tostring(start_err))
  end

  end

  if deferred_background then
    local created, create_error = pcall(function()
      if not coordinator.display_chat then coordinator:_create_display_chat() end
    end)
    if not created then return coordinator.on_error(create_error) end
    local chat = coordinator.display_chat
    if not utils.inherit_tool_registry(parent_chat, chat) then utils.apply_tools_override(chat, nil) end
    require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").bind_child(parent_chat, chat, req.ui)
    local background_start = #chat.messages
    require("maxa.mcphub.native_servers.subagent.background_calls").execute(chat, deferred_background, function(err)
      utils.apply_tools_override(chat, {})
      if err then return coordinator.on_error(err) end
      for index = background_start + 1, #chat.messages do
        coordinator._shared_background[#coordinator._shared_background + 1] = vim.deepcopy(chat.messages[index])
      end
      if coordinator._session then
        coordinator._session.config.shared_background = vim.deepcopy(coordinator._shared_background)
        SessionManager.save(coordinator._session)
      end
      start_discussion()
    end)
  else
    start_discussion()
  end
end

local shared_messages_schema = vim.deepcopy(require("maxa.mcphub.native_servers.subagent.tools.run_agent").inputSchema.properties.messages)
shared_messages_schema.description = "Optional shared user/assistant/context background and tool_call entries executed serially once in the Display/final Chat before discussion. Results and loaded context are copied to participants and persisted; failures stop execution. Supplied messages on resume append to stored background."

-- 工具定义
return {
  name = "multi_agent",
  description = "Run a role-based multi-agent discussion, then execute a final Phase 2 task via fork or run mode.",

  inputSchema = {
    type = "object",
    properties = {
      id = {
        type = "string",
        description = "Existing discussion session ID to continue; when set, agents and task are optional.",
      },
      agents = {
        type = "array",
        description = "Agent configurations for the discussion.",
        items = {
          type = "object",
          properties = {
            name = {
              type = "string",
              description = "Agent name used for display and handoff targeting.",
            },
            role = {
              type = "string",
              description = "Short role description, e.g. Technical Researcher or Critical Reviewer.",
            },
            soul = {
              type = "string",
              description = "Complete Soul source: exact `#ability[/path]` package file reference, explicit absolute/`~/`/`./`/`../` path, or inline text. Matched missing references/paths fail without fallback. Replaces only Soul, not Runtime.",
            },
            goal_prompt = {
              type = "string",
              description = "Optional participant goal; defaults to task. Appended as the final user message after shared background, round records and private notes on every turn.",
            },
            preset = {
              type = "string",
              description = "Optional named chat preset; omission inherits parent settings, then defaults.chat without a parent.",
            },
            icon = {
              type = "string",
              description = "Optional display icon; default 🤖.",
            },
            restrict_tools = {
              type = "array",
              items = { type = "string" },
              description = "Optional tool restriction list. Omitted gives all Chat builtins plus handoff. [] leaves handoff only.",
            },
          },
          required = { "name", "role" },
        },
      },
      messages = shared_messages_schema,
      task = {
        type = "string",
        description = "Discussion task or question.",
      },
      title = {
        type = "string",
        description = "Required display/history title, max 50 chars; when id is set, the stored title is retained.",
      },
      termination = {
        type = "object",
        description = "Discussion termination conditions.",
        properties = {
          max_rounds = {
            type = "number",
            description = "Maximum discussion rounds; default 10.",
          },
          min_rounds = {
            type = "number",
            description = "Minimum rounds before handoff to user is allowed; default 1.",
          },
          max_messages = {
            type = "number",
            description = "Maximum total messages across all agents.",
          },
        },
      },
      routing = {
        type = "object",
        description = "Initial discussion routing.",
        properties = {
          initial_agent = {
            type = "string",
            description = "Agent name that starts discussion; default first agent.",
          },
        },
      },
      -- Phase 2 参数
      final_agent = {
        type = "string",
        enum = { "fork", "run" },
        description = "Required Phase 2 execution type. `fork` inherits parent adapter/tools; `run` uses final_agent_config semantics.",
      },
      final_prompt = {
        type = "string",
        description = "Required Phase 2 user prompt appended to Display Chat messages.",
      },
      final_max_turns = {
        type = "number",
        description = "Optional max turns for Phase 2 execution; default/0 unlimited.",
      },
      final_agent_config = {
        type = "object",
        description = "Optional Phase 2 run-mode config; ignored when final_agent='fork'. Uses run_agent inherit/independent semantics.",
        properties = {
          inherit = {
            type = "boolean",
            description = "Inherit parent role/system prompt and tools. Incompatible with soul; goals do not affect inference or adapter/model. Shared messages and discussion records are retained in both modes.",
          },
          preset = {
            type = "string",
            description = "Optional named chat preset; omission inherits parent settings, then defaults.chat without a parent.",
          },
          soul = {
            type = "string",
            description = "Complete Soul source: exact `#ability[/path]` package file reference, explicit absolute/`~/`/`./`/`../` path, or inline text. Matched missing references/paths fail without fallback. Retains Runtime and triggers independent mode.",
          },
          restrict_tools = {
            type = "array",
            items = { type = "string" },
            description = "Restrict to specific tools. Does not affect adapter/model/role/context inheritance. If not set in independent mode, gets all Chat builtins. Set [] to remove all tools.",
          },
        },
      },
    },
    required = { "title", "final_agent", "final_prompt" },
  },

  display = require("maxa.mcphub.native_servers.subagent.tools.presentation").answer("@subagent:multi_agent"),
  handler = multi_agent_handler,
}
