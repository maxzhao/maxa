-- resume_agent 工具实现
-- 从 session 的 save_id 恢复历史会话，追加 messages 后作为子代理继续执行
local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local compaction_messages = require("maxa.session.compaction_messages")
local mcphub_config = require("maxa.mcphub.native_servers.config")
local utils = require("maxa.mcphub.native_servers.subagent.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local session_status = require("maxa.session.session_status")
local subagent_trace = require("maxa.mcphub.native_servers.subagent.session_trace")

local DEFAULT_MAX_TURNS = math.huge
local VALID_RESUME_MODES = { in_place = true, new_chat = true }

local M = {}

--- 验证 save_id
--- @param save_id any
--- @return boolean
--- @return string|nil
local function validate_save_id(save_id)
  if save_id == nil then
    return false, "'save_id' parameter is required"
  end
  if type(save_id) ~= "string" then
    return false, "'save_id' must be a string, got " .. type(save_id)
  end
  if save_id == "" or save_id:match("^%s*$") then
    return false, "'save_id' cannot be empty"
  end
  return true, nil
end

--- 验证 resume mode
--- @param resume_mode any
--- @return boolean
--- @return string|nil
local function validate_resume_mode(resume_mode)
  if resume_mode == nil then
    return true, nil
  end
  if type(resume_mode) ~= "string" then
    return false, "'resume_mode' must be a string, got " .. type(resume_mode)
  end
  if not VALID_RESUME_MODES[resume_mode] then
    return false, string.format("'resume_mode' must be one of: in_place, new_chat. Got '%s'", resume_mode)
  end
  return true, nil
end

--- 查找当前 Neovim 中已打开的同一历史会话 Chat
--- @param save_id string
--- @return table|nil chat
--- @return number|nil bufnr
local function find_open_chat_by_save_id(save_id)
  local ok, Chat = pcall(require, "maxa.interactions.chat")
  if not ok or type(Chat.buf_get_chat) ~= "function" then
    return nil, nil
  end

  local list_ok, opened_chats = pcall(Chat.buf_get_chat)
  if not list_ok or type(opened_chats) ~= "table" then
    return nil, nil
  end

  for _, entry in ipairs(opened_chats) do
    local chat = type(entry) == "table" and (entry.chat or entry) or nil
    local bufnr = type(entry) == "table" and (entry.bufnr or (chat and chat.bufnr)) or nil
    if chat and chat.opts and chat.opts.save_id == save_id then
      return chat, bufnr
    end
  end

  return nil, nil
end

--- 验证 adapter preset key
--- @param adapter_key any
--- @return boolean
--- @return string|nil
local function validate_adapter_key(adapter_key)
  return utils.validate_adapter_key(adapter_key)
end

--- 提取历史会话的 adapter 名称和 model
--- @param source table get_messages_source 返回值
--- @return string|nil adapter_name
--- @return string|nil model
local function extract_restored_adapter_info(source)
  if not source then
    return nil, nil
  end

  if source.chat and source.chat.adapter then
    local adapter = source.chat.adapter
    local adapter_name = adapter.name or adapter.formatted_name
    local model = adapter.schema and adapter.schema.model and adapter.schema.model.default or nil
    return adapter_name, model
  end

  local chat_data = source.chat_data or {}
  local adapter_name = chat_data.adapter
  local settings = chat_data.settings or {}
  local model = settings.model or chat_data.model
  return adapter_name, model
end

--- 解析 resume_agent 使用的 adapter
--- @param source table get_messages_source 返回值
--- @param adapter_key string|nil adapter preset override
--- @return table|nil adapter
--- @return string|nil error
local function resolve_resume_adapter(source, adapter_key)
  local adapters = require("maxa.adapters")

  if adapter_key then
    local preset, err = mcphub_config.get_adapter(adapter_key)
    if not preset then return nil, err end
    if preset.inherit then
      if source and source.chat and source.chat.adapter then
        return utils.resolve_adapter_by_key(adapter_key, source.chat), nil
      end
      local restored_name = extract_restored_adapter_info(source)
      if restored_name then preset.adapter = restored_name
      else preset = vim.tbl_deep_extend("keep", preset, mcphub_config.get_default("chat")) end
      if preset.adapter == "inherit" then preset.adapter = mcphub_config.get_default("chat").adapter end
    end
    local resolved = adapters.resolve(preset.adapter, { model = preset.model, temperature = preset.temperature })
    for key, value in pairs(mcphub_config.get_reasoning_effort_settings(resolved, preset.thinking_mode) or {}) do
      resolved.schema[key].default = value
    end
    return resolved, nil
  end

  if source and source.chat and source.chat.adapter then
    return vim.deepcopy(source.chat.adapter), nil
  end

  local adapter_name, restored_model = extract_restored_adapter_info(source)
  if adapter_name then
    local ok, adapter = pcall(adapters.resolve, adapter_name, {
      model = restored_model,
    })
    if ok and adapter then
      return adapter, nil
    end
  end

  local preset = mcphub_config.get_default("chat")
  if preset then
    local resolved = adapters.resolve(preset.adapter, { model = preset.model, temperature = preset.temperature })
    for key, value in pairs(mcphub_config.get_reasoning_effort_settings(resolved, preset.thinking_mode) or {}) do
      resolved.schema[key].default = value
    end
    return resolved, nil
  end

  return nil, "Failed to resolve adapter: restored session has no adapter and default preset is unavailable"
end

--- 构建 Chat 初始 messages
--- @param restored_messages table[]
--- @param input_messages table[]
--- @return table chat_messages
--- @return number restored_prefix_count
--- @return table context_items
local function build_resume_messages(restored_messages, input_messages, goal_prompt, project_root)
  local chat_messages = vim.deepcopy(restored_messages or {})
  local restored_prefix_count = #chat_messages

  local background, context_items, deferred_background = utils.prepare_background_messages(input_messages, project_root)
  vim.list_extend(chat_messages, background)
  if not deferred_background then utils.append_sub_agent_tail(chat_messages, goal_prompt) end

  return chat_messages, restored_prefix_count, context_items, deferred_background
end

local function copy_registry(schemas, in_use, target_chat)
  require("maxa.session.builtin_registry").apply(target_chat, schemas, in_use)
end

--- 从保存数据继承 tool registry
--- @param source table
--- @param target_chat table
--- @return boolean success
local function inherit_saved_tool_registry(source, target_chat)
  local chat_data = source and source.chat_data or nil
  if not chat_data or not target_chat or not target_chat.tool_registry then
    return false
  end

  local saved_schemas = vim.deepcopy(chat_data.schemas or {})
  local saved_in_use = vim.deepcopy(chat_data.in_use or {})
  local nested = chat_data.tool_registry
  if type(nested) == "table" then
    saved_schemas = vim.tbl_extend("force", saved_schemas, vim.deepcopy(nested.schemas or {}))
    saved_in_use = vim.tbl_extend("force", saved_in_use, vim.deepcopy(nested.in_use or {}))
  end
  if type(chat_data.schemas) ~= "table" and type(chat_data.in_use) ~= "table" and type(nested) ~= "table" then
    return false
  end
  copy_registry(saved_schemas, saved_in_use, target_chat)
  return true
end

--- 注册 messages 中 context items 到 Chat context registry
--- @param chat table
--- @param context_items table[]
local function register_context_items(chat, context_items)
  if not chat or not context_items or #context_items == 0 then
    return
  end

  for _, item in ipairs(context_items) do
    if item.type == "file" or item.type == "symbols" then
      local paths = type(item.path) == "table" and item.path or { item.path }
      for _, path in ipairs(paths) do
        local full_path = vim.fn.fnamemodify(path, ":p")
        local tag = item.type == "file" and "file" or "symbols"
        local id = "<" .. tag .. ">" .. full_path .. "</" .. tag .. ">"
        if chat.context and chat.context.add then
          chat.context:add({
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


--- 创建 resume 子代理 Chat，但不启动执行。供 resume_agent handler 复用。
--- @param opts table
--- @return table|nil chat
--- @return table|nil meta
--- @return string|nil error
local function create_resume_chat(opts)
  opts = opts or {}
  local valid, goal_error = utils.validate_required_string(opts.goal_prompt, "goal_prompt")
  if not valid then return nil, nil, goal_error end
  local save_id = opts.save_id
  local messages = opts.messages
  local adapter_key = opts.adapter
  local restrict_tools = opts.restrict_tools
  local req = opts.req
  local res = opts.res
  local parent_chat = opts.parent_chat
  local original_bufnr = opts.original_bufnr or vim.api.nvim_get_current_buf()
  local win_mgr = opts.win_mgr or utils.create_window_manager(parent_chat, original_bufnr)
  local title_override = opts.title
  local resume_mode = opts.resume_mode or "in_place"
  local in_place = resume_mode == "in_place"

  local open_chat, open_bufnr = find_open_chat_by_save_id(save_id)
  if in_place and open_chat then
    return nil,
      nil,
      string.format(
        "Cannot resume save_id '%s' in-place because it is already open in buffer %s. Close that chat or use resume_mode='new_chat'.",
        save_id,
        tostring(open_bufnr or open_chat.bufnr or "unknown")
      )
  end

  local source, source_err = history_session.get_messages_source(save_id, req and req.caller or nil)
  if not source then
    return nil, nil, string.format("Failed to restore save_id '%s': %s", save_id, source_err or "unknown error")
  end
  if not source.messages or #source.messages == 0 then
    return nil, nil, string.format("Restored save_id '%s' has no messages", save_id)
  end

  local resolved_adapter, adapter_err = resolve_resume_adapter(source, adapter_key)
  if not resolved_adapter then
    return nil, nil, adapter_err or "Failed to resolve adapter"
  end

  local buffer_context = utils.build_buffer_context(original_bufnr)
  local source_opts = source.chat and source.chat.opts or source.chat_data or {}
  buffer_context.cwd = source_opts.cwd or buffer_context.cwd
  buffer_context.project_root = source_opts.project_root or buffer_context.project_root
  local chat_messages, restored_prefix_count, context_items, deferred_background = build_resume_messages(
    source.messages, messages, opts.goal_prompt, buffer_context.project_root or buffer_context.cwd
  )
  local restored_title = (source.chat and source.chat.opts and source.chat.opts.title)
    or (source.chat and source.chat.title)
    or (source.chat_data and source.chat_data.title)
    or (source.chat_data and source.chat_data.opts and source.chat_data.opts.title)
    or ("Resume: " .. save_id:sub(1, 40))

  local callbacks = {
    on_created = function(c)
      register_context_items(c, context_items)
    end,
  }

  local tool_display = require("maxa.interactions.chat.tools.display")
  local render_messages = utils.build_sub_agent_render_messages(chat_messages)

  local target_save_id = in_place and save_id or history_core.generate_save_id({ prefix = "resume" })
  local non_interactive = utils.build_non_interactive_defaults({
    auto_submit = false,
    messages = render_messages,
    title = title_override or restored_title,
    save_id = target_save_id,
  })

  local restored_settings = source.chat and source.chat.settings or (source.chat_data and source.chat_data.settings) or nil
  local chat_opts = vim.tbl_extend("force", non_interactive, {
    adapter = resolved_adapter,
    buffer_context = buffer_context,
    cwd = (source.chat_data and source.chat_data.cwd) or buffer_context.cwd,
    project_root = (source.chat_data and source.chat_data.project_root) or buffer_context.project_root,
    messages = render_messages,
    settings = restored_settings and vim.deepcopy(restored_settings) or nil,
    callbacks = callbacks,
    _meta = (source.chat and source.chat._meta) or (source.chat_data and source.chat_data._meta),
    history_updated_at = in_place and source.chat_data and source.chat_data.updated_at or nil,
    agent_child = req ~= nil,
    agent_parent = parent_chat,
    agent_preserve_history = in_place,
    headless = true,
    ignore_system_prompt = utils.check_has_system_prompt_in_messages(chat_messages),
  })

  local chat, success
  if res then
    chat, success = utils.create_chat_with_error_handling(chat_opts, "resume_agent", res, win_mgr)
    if not success then
      return nil, nil, nil
    end
  else
    local Chat = require("maxa.interactions.chat")
    local ok, created = utils.with_subagent_chat_creation(Chat, function()
      return Chat.new(chat_opts)
    end, { hidden = true, restore_last_chat = true })
    if not ok or not created then
      return nil, nil, "Failed to create resume chat: " .. tostring(created)
    end
    chat = created
  end

  -- Chat.new 使用 render_messages 完成 UI 渲染；恢复原始 messages 供 LLM/API 使用。
  chat.messages = chat_messages
  utils.bind_sub_agent_render_messages(chat)
  if chat.tools then
    chat.tools.messages = chat.messages
  end
  tool_display.apply_render_postprocess(chat, render_messages)

  -- 恢复历史不应把整段 restored_messages 标成 compact protected prefix。
  -- protected prefix 只表示原会话真正不可压缩的初始基础消息，应继承来源会话已有值；
  -- 否则历史恢复 / restart-resume 后会把全部历史锁死，导致后续无法压缩。
  local source_protected_prefix_count = compaction_messages.get_protected_prefix_count(source)
  compaction_messages.set_protected_prefix_count(chat, source_protected_prefix_count)

  local tools_inherited = false
  if restrict_tools ~= nil then
    utils.apply_tools_override(chat, restrict_tools)
  else
    if source.chat then
      tools_inherited = require("maxa.session.builtin_registry").apply(
        chat,
        source.chat.tool_registry and source.chat.tool_registry.schemas,
        source.chat.tool_registry and source.chat.tool_registry.in_use
      )
      if tools_inherited and source.chat.tool_registry and source.chat.tool_registry.flags then
        chat.tool_registry.flags = vim.deepcopy(source.chat.tool_registry.flags)
      end
    else
      tools_inherited = inherit_saved_tool_registry(source, chat)
    end
    if not tools_inherited then
      utils.apply_tools_override(chat, nil)
    end
  end

  if source.chat then
    utils.inherit_context_items(source.chat, chat)
  elseif source.chat_data and source.chat_data.context_items then
    chat.context_items = vim.deepcopy(source.chat_data.context_items)
  end

  local trace_state = subagent_trace.start_resume("resume_agent", req, parent_chat, source, chat, {
    source_save_id = save_id,
    resume_mode = resume_mode,
    params = opts.params or {
      save_id = save_id,
      messages = messages,
      adapter = adapter_key,
      restrict_tools = restrict_tools,
      title = title_override,
      resume_mode = resume_mode,
    },
  })

  if source.chat and source.chat.cycle then
    chat.cycle = source.chat.cycle
  elseif source.chat_data and source.chat_data.cycle then
    chat.cycle = source.chat_data.cycle
  end

  if parent_chat then
    utils.set_child_recursion_depth(parent_chat, chat)
    require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").bind_child(parent_chat, chat, req.ui)
    local sh_ok, sh_registry = pcall(require, "maxa.abilities.hooks.registry")
    if sh_ok then
      sh_registry.register_parent_chain(parent_chat.id, chat.id)
    end
  end

  return chat, {
    source = source,
    win_mgr = win_mgr,
    restored_prefix_count = restored_prefix_count,
    deferred_background = deferred_background,
    tools_inherited = tools_inherited,
    resume_mode = resume_mode,
    trace_state = trace_state,
  }, nil
end

--- resume_agent 主处理函数
--- @param req table MCP 请求
--- @param res table MCP 响应
local function resume_agent(req, res)

  if not req then
    return res:error(utils.format_error("resume_agent", "Invalid request object - request is nil or missing"))
  end
  if not req.params then
    return res:error(utils.format_error("resume_agent", "Invalid request - missing params object"))
  end

  local accepted, retired_error = utils.reject_instructions(req.params)
  if not accepted then
    return res:error(utils.format_error("resume_agent", retired_error))
  end
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local goal_prompt = params.goal_prompt
  local messages = params.messages
  local adapter_key, preset_error = utils.preset_key(params)
  if preset_error then return res:error(utils.format_error("resume_agent", preset_error)) end
  local restrict_tools = params.restrict_tools
  local max_turns = utils.normalize_max_turns(params.max_turns, DEFAULT_MAX_TURNS)
  local title_override = params.title
  local resume_mode = params.resume_mode or "in_place"
  local valid, error_msg = validate_save_id(save_id)
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg))
  end

  valid, error_msg = utils.validate_required_string(goal_prompt, "goal_prompt")
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg))
  end
  valid, error_msg = utils.validate_messages(messages, { optional = true, require_user = false })
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg or "Invalid messages"))
  end

  valid, error_msg = validate_resume_mode(resume_mode)
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg))
  end

  valid, error_msg = validate_adapter_key(adapter_key)
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg))
  end

  valid, error_msg = utils.validate_optional_string(title_override, "title")
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg or "Invalid title"))
  end

  valid, error_msg = utils.validate_tools(restrict_tools)
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg or "Invalid restrict_tools"))
  end

  valid, error_msg = utils.validate_max_turns(max_turns)
  if not valid then
    return res:error(utils.format_error("resume_agent", error_msg or "Invalid max_turns"))
  end

  local cc_available, cc_error = utils.check_chat_available()
  if not cc_available then
    return res:error(utils.format_error("resume_agent", cc_error or "Maxa AI Chat not available"))
  end

  local original_bufnr = vim.api.nvim_get_current_buf()
  local parent_chat = utils.get_parent_chat(req, original_bufnr)

  local allowed, recursion_error = utils.check_execution_allowed("resume_agent", parent_chat)
  if not allowed then
    return res:error(utils.format_error("resume_agent", recursion_error))
  end

  local chat, resume_meta, create_err = create_resume_chat({
    save_id = save_id,
    messages = messages,
    goal_prompt = goal_prompt,
    adapter = adapter_key,
    restrict_tools = restrict_tools,
    req = req,
    res = res,
    parent_chat = parent_chat,
    original_bufnr = original_bufnr,
    title = title_override,
    resume_mode = resume_mode,
    params = params,
  })
  if create_err then
    return res:error(utils.format_error("resume_agent", create_err))
  end
  if not chat then
    return
  end

  local win_mgr = resume_meta.win_mgr
  local restored_prefix_count = resume_meta.restored_prefix_count
  local tools_inherited = resume_meta.tools_inherited
  local effective_resume_mode = resume_meta.resume_mode

  local function cleanup_resume_chat()
    if win_mgr then
      win_mgr:cleanup(chat)
    else
      chat:close()
    end
  end

  utils.setup_window_layout(win_mgr, chat)

  local agent_executor = require("maxa.mcphub.native_servers.subagent.tools.agent_executor")
  local agent_finished = false
  local function on_resume_cancel(c)
    if agent_finished then
      return
    end
    c:stop()
  end

  local window_manager = require("maxa.mcphub.native_servers.subagent.tools.window_manager")
  if win_mgr then
    window_manager.setup_subagent_keymaps(chat, on_resume_cancel)
  end

  require("maxa.mcphub.native_servers.subagent.async_cancel").register_chat("subagent__resume_agent", chat, {
    kind = "subagent_chat",
    title = title,
    save_id = effective_resume_mode == "in_place" and save_id or utils.get_chat_save_id(chat),
    current_chat = function() return chat end,
  })

  require("maxa.mcphub.native_servers.subagent.background_calls").before_agent(chat, resume_meta.deferred_background, goal_prompt, {
    ui = req.ui,
    chat = chat,
    prompt = nil,
    max_turns = max_turns,
    fork_start_index = restored_prefix_count,
    handoff_parent = parent_chat,
    on_replaced = function(target)
      chat = target
      resume_meta.trace_state = subagent_trace.start_child("resume_agent", req, parent_chat, target, {
        session_role = "resumed", mode = effective_resume_mode, params = params,
      })
    end,
    on_complete = function(result)
      agent_finished = true
      result.source_save_id = save_id
      result.adapter_overridden = adapter_key ~= nil
      result.tools_overridden = restrict_tools ~= nil
      result.tools_inherited = tools_inherited
      result.resume_mode = effective_resume_mode

      subagent_trace.record_subagent_completed("resume_agent", chat, result, {
        mode = effective_resume_mode,
        trace_state = resume_meta.trace_state,
      })

      res:text(require("maxa.mcphub.native_servers.subagent.result_format").answer(result))
      res:send()

      vim.schedule(cleanup_resume_chat)
    end,
    on_error = function(err)
      agent_finished = true

      -- Active token recovery is owned by Session before executor termination.
      vim.schedule(cleanup_resume_chat)
      local recovery = {
        save_id = utils.get_chat_save_id(chat),
        source_save_id = save_id,
        resume_mode = effective_resume_mode,
        context_status = session_status.to_llm(session_status.from_chat(chat)),
      }
      subagent_trace.record_subagent_error("resume_agent", chat, err, {
        mode = effective_resume_mode,
        recovery = recovery,
      })
      utils.send_recoverable_error(res, "resume_agent", err, recovery)
    end,
  }, agent_executor)
end

M.name = "resume_agent"
M.description = "Restore save_id, append optional background messages, then goal_prompt as the final user message and continue as a child Agent."
M.inputSchema = {
  type = "object",
  properties = {
    save_id = {
      type = "string",
      description = "Required. The saved Maxa AI history session ID to restore and continue.",
    },
    messages = {
      type = "array",
      description = "Optional user/assistant/context background and tool_call entries after restored history; calls execute serially before goal_prompt and failures stop execution. Context supports file, symbols, url and image.",
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
    goal_prompt = {
      type = "string",
      description = "Required nonblank follow-up goal; appended as the final user message after restored history and background. Preserves restored Runtime/Soul.",
    },
    resume_mode = {
      type = "string",
      enum = { "in_place", "new_chat" },
      default = "in_place",
      description = "Resume target mode. Default 'in_place' continues with the original save_id and refuses to run if that save_id is already open. 'new_chat' creates a separate resumed history session.",
    },
    preset = {
      type = "string",
      description = "Optional named chat preset override; omission preserves restored adapter/model.",
    },
    restrict_tools = {
      type = "array",
      items = { type = "string" },
      description = "Optional tool restriction list. Omitted inherits restored tools when possible, else Chat builtins. [] removes all tools. Use registered bare first-party builtin names; Ability targets are dispatched through `run(scope=\"tool\")`.",
    },
    max_turns = {
      type = "number",
      description = "Maximum LLM response turns before forcing completion. Default/0: unlimited. Positive numbers set a hard safety limit.",
    },
    title = {
      type = "string",
      description = "Optional session title for history display, max 50 chars; omitted reuses restored title.",
    },
  },
  required = { "save_id", "goal_prompt" },
}
M.display = require("maxa.mcphub.native_servers.subagent.tools.presentation").answer("@subagent:resume_agent")
M.handler = resume_agent
M._private = {
  validate_save_id = validate_save_id,
  validate_adapter_key = validate_adapter_key,
  validate_resume_mode = validate_resume_mode,
  find_open_chat_by_save_id = find_open_chat_by_save_id,
  extract_restored_adapter_info = extract_restored_adapter_info,
  build_resume_messages = build_resume_messages,
  inherit_saved_tool_registry = inherit_saved_tool_registry,
  resolve_resume_adapter = resolve_resume_adapter,
  create_resume_chat = create_resume_chat,
}

return M
