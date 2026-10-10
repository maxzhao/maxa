-- run_agent 工具实现
-- 创建自主 Agent，支持工具调用和自主决策
-- 支持 inherit 模式（继承父 chat 配置）和独立模式（自定义角色/工具）
-- 可通过 soul 引用 Ability 文档、文件路径或内联角色定义
local compaction_messages = require("maxa.session.compaction_messages")
local mcphub_config = require("maxa.mcphub.native_servers.config")
local utils = require("maxa.mcphub.native_servers.subagent.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local session_status = require("maxa.session.session_status")
local history_core = require("maxa.session.history_core")
local subagent_trace = require("maxa.mcphub.native_servers.subagent.session_trace")

--- 默认 max_turns 限制（math.huge = 无限，除非明确指定）
local DEFAULT_MAX_TURNS = math.huge
local VALID_RUN_MODES = { temporary = true, new_chat = true, handoff = true }

local function validate_run_mode(run_mode)
  if run_mode == nil then
    return true, nil
  end
  if type(run_mode) ~= "string" then
    return false, "'run_mode' must be a string, got " .. type(run_mode)
  end
  if not VALID_RUN_MODES[run_mode] then
    return false, string.format("'run_mode' must be one of: temporary, new_chat, handoff. Got '%s'", run_mode)
  end
  return true, nil
end

local function strip_temporary_save_id(result)
  if result then
    result.save_id = nil
    if result.context_status then
      result.context_status.save_id = nil
    end
  end
end

--- 主处理函数
--- @param req table MCP 请求对象
--- @param res table MCP 响应对象
local function run_agent(req, res)

  -- 验证请求对象
  if not req then
    return res:error(utils.format_error("run_agent", "Invalid request object - request is nil or missing"))
  end

  if not req.params then
    return res:error(utils.format_error("run_agent", "Invalid request - missing params object"))
  end

  local soul_valid, soul_error = utils.validate_soul_params(req.params)
  if not soul_valid then
    return res:error(utils.format_error("run_agent", soul_error))
  end
  local params = param_utils.normalize(req.params)
  local messages = params.messages
  local goal_prompt = params.goal_prompt
  local adapter_key, preset_error = utils.preset_key(params)
  if preset_error then return res:error(utils.format_error("run_agent", preset_error)) end
  local soul_config = {
    soul = params.soul,
    soul_prompt = params.soul_prompt,
    soul_file = params.soul_file,
  }
  local restrict_tools = params.restrict_tools
  local max_turns = utils.normalize_max_turns(params.max_turns, DEFAULT_MAX_TURNS)
  local title_override = params.title
  local run_mode = params.run_mode or "new_chat"
  local warmup_mode, warmup_error = utils.normalize_warmup_mode(params.warmup)
  if warmup_error then
    return res:error(utils.format_error("run_agent", warmup_error))
  end

  -- ========================================================================
  -- 参数验证
  -- ========================================================================

  -- 验证 title
  local valid, error_msg = utils.validate_required_string(title_override, "title")
  if not valid then
    return res:error(utils.format_error("run_agent", error_msg or "Invalid title"))
  end

  valid, error_msg = utils.validate_required_string(goal_prompt, "goal_prompt")
  if not valid then
    return res:error(utils.format_error("run_agent", error_msg))
  end

  -- Optional background need not contain a task user message.
  valid, error_msg = utils.validate_messages(messages, { optional = true, require_user = false })
  if not valid then
    return res:error(utils.format_error("run_agent", error_msg or "Invalid messages"))
  end

  -- 验证 restrict_tools
  if restrict_tools ~= nil then
    valid, error_msg = utils.validate_tools(restrict_tools)
    if not valid then
      return res:error(utils.format_error("run_agent", error_msg or "Invalid restrict_tools"))
    end
  end

  valid, error_msg = utils.validate_adapter_key(adapter_key)
  if not valid then return res:error(utils.format_error("run_agent", error_msg)) end

  -- 验证 max_turns
  valid, error_msg = utils.validate_max_turns(max_turns)
  if not valid then
    return res:error(utils.format_error("run_agent", error_msg or "Invalid max_turns"))
  end

  -- 验证 run_mode
  valid, error_msg = validate_run_mode(run_mode)
  if not valid then
    return res:error(utils.format_error("run_agent", error_msg or "Invalid run_mode"))
  end

  -- 检查 Maxa AI Chat 是否可用
  local cc_available, cc_error = utils.check_chat_available()
  if not cc_available then
    return res:error(utils.format_error("run_agent", cc_error or "Maxa AI Chat not available"))
  end

  -- ========================================================================
  -- 获取父 chat & 推断 inherit 模式
  -- ========================================================================

  local original_bufnr = vim.api.nvim_get_current_buf()
  local is_handoff = run_mode == "handoff"
  local parent_chat
  if is_handoff then
    parent_chat, error_msg = require("maxa.mcphub.native_servers.subagent.session_handoff").validate(req, params)
    if not parent_chat then return res:error(utils.format_error("run_agent", error_msg)) end
  else
    parent_chat = utils.get_parent_chat(req, original_bufnr)
  end
  local handoff_parent = is_handoff and require("maxa.session.agent_identity").parent(parent_chat) or nil
  local child_handoff = is_handoff and handoff_parent ~= nil
  local has_parent_chat = parent_chat ~= nil

  -- 检查递归深度（基于父 Chat 元数据，避免异步计数泄漏）
  local allowed, recursion_error = utils.check_execution_allowed("run_agent", child_handoff and handoff_parent or parent_chat)
  if not allowed then
    return res:error(utils.format_error("run_agent", recursion_error))
  end

  -- 推断 inherit 模式
  local use_inherit = utils.infer_inherit_mode(params, has_parent_chat)

  -- 验证 inherit 互斥性
  valid, error_msg = utils.validate_inherit_exclusivity(params, use_inherit)
  if not valid then
    return res:error(utils.format_error("run_agent", error_msg))
  end

  -- ========================================================================
  -- 构建 chat messages
  -- ========================================================================

  local cc_config = require("maxa.config")
  local chat_messages = {}
  local buffer_context = utils.build_buffer_context(original_bufnr)
  if parent_chat then
    local parent_ctx = parent_chat.opts or {}
    buffer_context.cwd = parent_ctx.cwd or buffer_context.cwd
    buffer_context.project_root = parent_ctx.project_root or buffer_context.project_root
  end
  local background_messages, context_items, deferred_background, background_error = utils.prepare_background_messages(
    messages, buffer_context.project_root or buffer_context.cwd, { strict_files = is_handoff })
  if not background_messages then return res:error(utils.format_error("run_agent", background_error)) end

  -- Inheritance preserves the complete base; independent children compose Runtime + Soul.
  local system_prompt = use_inherit and utils.inherit_system_prompt_from_parent(parent_chat) or nil
  if not system_prompt or system_prompt == "" then
    local sp_error
    system_prompt, sp_error = utils.build_soul_system_prompt(soul_config, buffer_context)
    if sp_error then
      return res:error(utils.format_error("run_agent", sp_error))
    end
  end
  table.insert(chat_messages, {
    role = cc_config.constants.SYSTEM_ROLE,
    content = system_prompt,
    opts = { visible = false },
    _meta = { tag = "system_prompt_from_config" },
  })

  -- 2. 继承模式：预加载继承的 context 数据
  local inherited_context_data = nil
  if use_inherit and parent_chat and not is_handoff then
    inherited_context_data = utils.extract_context_data(parent_chat)
    if inherited_context_data and #inherited_context_data > 0 then
      utils.preload_inherited_context_to_messages(chat_messages, inherited_context_data)
    end
  end

  if is_handoff and buffer_context.project_root then
    local rules_path = vim.fs.joinpath(buffer_context.project_root, ".maxa", "AGENTS.md")
    if vim.uv.fs_lstat(rules_path) then
      local rules, _, _, rules_error = utils.prepare_background_messages({
        { role = "context", type = "file", path = rules_path },
      }, buffer_context.project_root, { strict_files = true })
      if not rules then return res:error(utils.format_error("run_agent", rules_error)) end
      for _, rule in ipairs(rules) do
        rule.role = cc_config.constants.SYSTEM_ROLE
        rule._meta.tag = "rules"
        table.insert(chat_messages, rule)
      end
    end
  end
  local warmup_prefix_count = #chat_messages
  vim.list_extend(chat_messages, background_messages)
  if not deferred_background then utils.append_sub_agent_tail(chat_messages, goal_prompt) end

  -- ========================================================================
  -- 解析 adapter
  -- ========================================================================

  local resolved_adapter = utils.resolve_adapter_by_key(adapter_key, parent_chat, use_inherit)

  -- ========================================================================
  -- 创建窗口管理器和 buffer context
  -- ========================================================================

  local win_mgr = utils.create_window_manager(parent_chat, original_bufnr)

  -- ========================================================================
  -- 构建 callbacks（on_created：工具注入 + context 注册）
  -- ========================================================================

  -- 确定工具集
  local tools_for_callback
  if restrict_tools ~= nil then
    -- 工具限制不影响 inherit：可在继承父 adapter/model/role/context 的同时限制工具
    tools_for_callback = restrict_tools
  elseif use_inherit then
    -- 继承模式且未限制工具：工具在 Chat 创建后通过 inherit_tool_registry 处理
    tools_for_callback = nil
  else
    -- 独立模式 + 默认 Chat builtins
    tools_for_callback = vim.deepcopy(require("maxa.interactions.chat.tools.builtin").names)
  end

  local callbacks = {
    on_created = function(c)
      -- 工具注入（非继承模式或有限定工具集时）
      if tools_for_callback then
        utils.apply_tools_override(c, tools_for_callback)
      end

      -- 注册继承的 context_items 元数据
      if inherited_context_data and #inherited_context_data > 0 then
        for _, ctx_data in ipairs(inherited_context_data) do
          local context_opts = vim.deepcopy(ctx_data.opts or {})
          if c.context and c.context.add then
            c.context:add({
              source = ctx_data.source,
              id = ctx_data.id,
              path = ctx_data.path,
              opts = context_opts,
            })
          end
        end
      end

      -- 注册 messages 中提取的 context items
      if #context_items > 0 then
        for _, item in ipairs(context_items) do
          if item.type == "file" or item.type == "symbols" then
            local paths = type(item.path) == "table" and item.path or { item.path }
            for _, path in ipairs(paths) do
              local full_path = vim.fn.fnamemodify(path, ":p")
              local tag = item.type == "file" and "file" or "symbols"
              local id = "<" .. tag .. ">" .. full_path .. "</" .. tag .. ">"
              if c.context and c.context.add then
                c.context:add({
                  source = "maxa.interactions.chat.slash_commands." .. tag,
                  id = id,
                  path = full_path,
                  opts = { visible = true },
                })
              end
            end
          end
        end
      end
    end,
  }

  -- ========================================================================
  -- 创建 Chat 实例
  -- ========================================================================

  local non_interactive = utils.build_non_interactive_defaults({
    auto_submit = false,
    messages = chat_messages,
    title = title_override,
  })

  local run_save_id = nil
  if run_mode == "temporary" then
    run_save_id = history_core.make_unsavable_save_id("run_agent")
  end

  local render_messages = utils.build_sub_agent_render_messages(chat_messages)
  local chat_opts = vim.tbl_extend("force", non_interactive, {
    adapter = resolved_adapter,
    buffer_context = buffer_context,
    cwd = buffer_context.cwd,
    project_root = buffer_context.project_root,
    messages = render_messages,
    callbacks = callbacks,
    save_id = run_save_id,
    agent_child = not is_handoff or child_handoff,
    agent_parent = child_handoff and handoff_parent or (not is_handoff and parent_chat or nil),
    preserve_main = is_handoff and not child_handoff or nil,
    headless = true,
  })

  -- 处理 ignore_system_prompt（如果有自定义 system prompt，跳过默认的）
  local has_system_prompt = utils.check_has_system_prompt_in_messages(chat_messages)
  if has_system_prompt then
    chat_opts.ignore_system_prompt = true
  end

  -- 创建 chat 实例
  local chat, success = utils.create_chat_with_error_handling(chat_opts, "run_agent", res, win_mgr)
  if not success then
    return
  end

  chat.messages = chat_messages
  utils.bind_sub_agent_render_messages(chat)
  if chat.tools then
    chat.tools.messages = chat_messages
  end

  compaction_messages.mark_current_messages_as_protected_prefix(chat)
  if not is_handoff then
    utils.set_child_recursion_depth(parent_chat, chat)
    require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").bind_child(parent_chat, chat, req.ui)
  end

  -- 继承模式下：未显式限制工具时继承父 chat 的 tool_registry；显式 restrict_tools 已在 on_created 中应用
  if use_inherit and parent_chat and restrict_tools == nil then
    utils.inherit_tool_registry(parent_chat, chat)
  end

  utils.configure_chat_warmup(chat, warmup_mode, warmup_prefix_count, "subagent.run_agent")

  if is_handoff then
    return require("maxa.mcphub.native_servers.subagent.session_handoff").prepare(
      parent_chat, chat, deferred_background, goal_prompt, res)
  end

  local trace_state = subagent_trace.start_child("run_agent", req, parent_chat, chat, {
    session_role = "subagent",
    mode = run_mode,
    params = params,
  })

  -- [AbilityHook] 注册 cascade parent_chain（子代理继承父 hook 链）
  if parent_chat then
    local sh_ok, sh_registry = pcall(require, "maxa.abilities.hooks.registry")
    if sh_ok then
      sh_registry.register_parent_chain(parent_chat.id, chat.id)
    end
  end

  -- 设置窗口布局
  utils.setup_window_layout(win_mgr, chat)

  -- ========================================================================
  -- 执行 Agent
  -- ========================================================================

  local agent_executor = require("maxa.mcphub.native_servers.subagent.tools.agent_executor")

  local agent_finished = false
  local function on_agent_cancel(c)
    if agent_finished then
      return
    end
    c:stop()
  end

  -- 设置子代理键位
  local window_manager = require("maxa.mcphub.native_servers.subagent.tools.window_manager")
  if win_mgr then
    window_manager.setup_subagent_keymaps(chat, on_agent_cancel)
  end

  require("maxa.mcphub.native_servers.subagent.async_cancel").register_chat("subagent__run_agent", chat, {
    kind = "subagent_chat",
    title = title,
    save_id = run_mode == "temporary" and nil or utils.get_chat_save_id(chat),
    current_chat = function() return chat end,
  })

  require("maxa.mcphub.native_servers.subagent.background_calls").before_agent(chat, deferred_background, goal_prompt, {
    ui = req.ui,
    chat = chat,
    prompt = nil,
    max_turns = max_turns,
    handoff_parent = parent_chat,
    on_replaced = function(target)
      chat = target
      trace_state = subagent_trace.start_child("run_agent", req, parent_chat, target, {
        session_role = "subagent", mode = run_mode, params = params,
      })
    end,
    on_complete = function(result)
      agent_finished = true

      -- 构建响应数据
      result.inherit = use_inherit
      result.run_mode = run_mode
      if run_mode == "temporary" then
        strip_temporary_save_id(result)
      end
      if adapter_key then
        result.adapter = adapter_key
      end

      subagent_trace.record_subagent_completed("run_agent", chat, result, {
        mode = run_mode,
        trace_state = trace_state,
      })

      res:text(require("maxa.mcphub.native_servers.subagent.result_format").answer(result))
      res:send()

      vim.schedule(function()
        if win_mgr then
          win_mgr:cleanup(chat)
        else
          chat:close()
        end
      end)
    end,
    on_error = function(err)
      agent_finished = true

      -- Recovery must occur while the executor is active; preserve history on failure.
      vim.schedule(function()
        if win_mgr then
          win_mgr:cleanup(chat)
        else
          chat:close()
        end
      end)

      local session_status = require("maxa.session.session_status")
      local error_context_status = session_status.to_llm(session_status.from_chat(chat))
      if run_mode == "temporary" and error_context_status then
        error_context_status.save_id = nil
      end
      local recovery = {
        save_id = run_mode == "temporary" and nil or utils.get_chat_save_id(chat),
        context_status = error_context_status,
        run_mode = run_mode,
      }
      subagent_trace.record_subagent_error("run_agent", chat, err, {
        mode = run_mode,
        recovery = recovery,
      })
      utils.send_recoverable_error(res, "run_agent", err, recovery)
    end,
  }, agent_executor)
end

-- 工具定义
return {
  name = "run_agent",
  description = [[Run a fresh session with goal_prompt last after optional background. Default modes delegate a child and wait for its result. handoff replaces the exact caller at its safe tool-batch boundary: an explicitly user-requested main transfers to a new main; an active persistent delegated child, instructed by its main Agent or user, transfers to a sibling under the same current parent while its parent's original tool keeps waiting. Returns handoff_scheduled and the prepared save_id, not task completion. Preparation failure preserves the caller. restrict_tools only limits tools.]],
  inputSchema = {
    type = "object",
    properties = {
      messages = {
        type = "array",
        description = [[Optional user/assistant/context background and tool_call entries executed serially before goal_prompt; failures stop execution. Context supports file, symbols, url and image. Literal @name/#path text does not attach context.]],
        items = {
          type = "object",
          properties = {
            role = {
              type = "string",
              enum = { "user", "assistant", "context", "tool_call" },
              description = "Message role; context preloads content, tool_call executes a real registered tool before the goal.",
            },
            content = {
              type = "string",
              description = "Text content; required for user/assistant roles.",
            },
            name = {
              type = "string",
              description = "Registered bare tool name; required for tool_call, subject to the target Chat's tools and authorization.",
            },
            args = {
              type = "object",
              description = "Tool parameter object; required for tool_call and validated against that tool's schema at execution.",
              additionalProperties = true,
            },
            type = {
              type = "string",
              enum = { "file", "symbols", "url", "image" },
              description = "Context type; required when role='context'.",
            },
            path = {
              oneOf = {
                { type = "string" },
                { type = "array", items = { type = "string" } },
              },
              description = "Path or paths for file, symbols, or image context.",
            },
            url = {
              type = "string",
              description = "URL for url context.",
            },
          },
          required = { "role" },
        },
      },
      inherit = {
        type = "boolean",
        description = [[Inherit parent role/system prompt and tools, not conversation history. Delegated modes also inherit loaded context; handoff never copies old loaded context. Auto-inferred false with soul, true with parent otherwise, false without parent. Incompatible with soul; goals/tools do not affect inference or adapter selection.]],
      },
      preset = {
        type = "string",
        description = "Optional named chat preset; omission inherits parent settings, then defaults.chat without a parent.",
      },
      soul = {
        type = "string",
        description = "Complete Soul source. Resolves an exact `#ability[/path]` package file reference first, then an explicit absolute/`~/`/`./`/`../` path, otherwise inline text. A matched missing reference or path fails without fallback. Replaces only Soul; the common Runtime remains. Incompatible with effective inherit=true.",
      },
      goal_prompt = {
        type = "string",
        description = "Required nonblank execution goal, scope, constraints and deliverable; appended after all background as the final user message. Does not change Runtime/Soul or inherit mode.",
      },
      restrict_tools = {
        type = "array",
        items = { type = "string" },
        description = "Restrict to these tools only. Does not affect adapter/model/role/context inheritance. Omitted means all Chat builtins in independent mode or inherited tools in inherit mode. [] removes all tools.",
      },
      max_turns = {
        type = "number",
        description = "Delegated modes only: maximum LLM response turns before forcing completion. Default/0: unlimited. Positive numbers set a hard safety limit; handoff rejects nonzero values.",
      },
      warmup = utils.warmup_schema_property(),
      run_mode = {
        type = "string",
        enum = { "temporary", "new_chat", "handoff" },
        default = "new_chat",
        description = "Default new_chat delegates a saved child; temporary delegates without resumable history. handoff saves a fresh type-preserving successor and returns handoff_scheduled/save_id before switching at the caller tool boundary. Main needs explicit user request; active persistent child needs a main-Agent/user message and remains under the same current parent, whose delegated call waits for the successor. Use one standalone synchronous call in the source, not multicall or async. Child replacement retains its original delegated turn budget.",
      },
      title = {
        type = "string",
        description = "Required. Session title (max 50 chars). Used for history display.",
      },
    },
    required = { "goal_prompt", "title" },
  },
  display = require("maxa.mcphub.native_servers.subagent.tools.presentation").answer("@subagent:run_agent"),
  handler = run_agent,
}
