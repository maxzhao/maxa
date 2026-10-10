-- SubAgent session trace integration helpers.
--
-- This module is intentionally observational: it only copies trace membership
-- onto child chats and appends session trace events when an existing tracked
-- parent/restored session has _meta.session_trace. Untracked SubAgent calls
-- keep their previous behavior.

local session_trace = require("maxa.session.session_trace")

local M = {}

local function now()
  return os.time()
end

local function active_membership(holder)
  local membership = session_trace.get_membership(holder)
  if type(membership) ~= "table" or membership.active == false or not membership.root_trace_id then
    return nil
  end
  return membership
end

local function deepcopy_plain(value)
  if type(value) ~= "table" then
    return value
  end
  local ok, copy = pcall(vim.deepcopy, value)
  if not ok then
    return tostring(value)
  end
  local ok_utils, history_utils = pcall(require, "maxa.session.history.utils")
  if ok_utils and history_utils and type(history_utils.remove_functions) == "function" then
    return history_utils.remove_functions(copy)
  end
  return copy
end

local function table_keys(list)
  if type(list) ~= "table" then
    return nil
  end
  local out = {}
  for key in pairs(list) do
    table.insert(out, tostring(key))
  end
  table.sort(out)
  return out
end

local function current_tool_call_id(req)
  local agent = req and req.caller and req.caller.maxa_ai
  if agent and agent.tool and agent.tool.function_call and agent.tool.function_call.id then
    return agent.tool.function_call.id
  end
  return nil
end

local function get_parent_chat(req)
  local agent = req and req.caller and req.caller.maxa_ai
  if agent and type(agent.chat) == "table" then
    return agent.chat
  end

  local ok_chat, Chat = pcall(require, "maxa.interactions.chat")
  if ok_chat and type(Chat.buf_get_chat) == "function" then
    local ok_current, chat = pcall(Chat.buf_get_chat, vim.api.nvim_get_current_buf())
    if ok_current and type(chat) == "table" then
      return chat
    end
  end
  return nil
end

local function persist_chat_membership(chat)
  if type(chat) ~= "table" or not chat.opts or not chat.opts.save_id then
    return false
  end
  local ok_core, history_core = pcall(require, "maxa.session.history_core")
  if ok_core and history_core.is_unsavable_save_id(chat.opts.save_id) then
    return false
  end
  local ok_history, history_api = pcall(require, "maxa.session.history")
  if ok_history and history_api and history_api.exports and type(history_api.exports.save_chat) == "function" then
    pcall(history_api.exports.save_chat, chat)
    return true
  end
  return false
end

local function append_event(root_trace_id, event, holder)
  local ok, result, err = pcall(session_trace.append_event, root_trace_id, event)
  if ok and result then
    return result, err
  end

  local message = ok and err or result
  if type(holder) == "table" then
    holder._session_trace_errors = holder._session_trace_errors or {}
    table.insert(holder._session_trace_errors, {
      kind = event and event.kind or "unknown",
      error = tostring(message or "unknown trace append error"),
      created_at = now(),
    })
  end
  return nil, tostring(message or "unknown trace append error")
end

local function parent_info(parent_chat, membership)
  if not parent_chat or not membership then
    return nil
  end
  return {
    save_id = parent_chat.opts and parent_chat.opts.save_id or nil,
    span_id = membership.span_id,
    session_role = membership.session_role,
  }
end

local function safe_params(params, tool_name)
  params = deepcopy_plain(params or {}) or {}
  local out = {}

  if tool_name == "run_agent" then
    out = {
      title = params.title,
      messages = params.messages,
      inherit = params.inherit,
      adapter = params.adapter,
      soul = params.soul and "[provided]" or nil,
      soul_prompt = params.soul_prompt and "[legacy provided]" or nil,
      soul_file = params.soul_file and "[legacy provided]" or nil,
      goal_prompt = params.goal_prompt,
      restrict_tools = params.restrict_tools,
      max_turns = params.max_turns,
      warmup = params.warmup,
      run_mode = params.run_mode,
    }
  elseif tool_name == "fork_agent" then
    out = {
      title = params.title,
      goal_prompt = params.goal_prompt,
      max_turns = params.max_turns,
      fork_mode = params.fork_mode,
    }
  elseif tool_name == "resume_agent" then
    out = {
      save_id = params.save_id,
      title = params.title,
      messages = params.messages,
      goal_prompt = params.goal_prompt,
      resume_mode = params.resume_mode,
      adapter = params.adapter,
      restrict_tools = params.restrict_tools,
      max_turns = params.max_turns,
    }
  elseif tool_name == "ask_llm" then
    out = {
      messages = params.messages,
      adapter = params.adapter,
      timeout = params.timeout,
    }
  elseif tool_name == "multi_agent" then
    out = {
      id = params.id,
      title = params.title,
      task = params.task,
      messages = params.messages,
      agents = params.agents,
      termination = params.termination,
      routing = params.routing,
      final_agent = params.final_agent,
      final_prompt = params.final_prompt,
      final_max_turns = params.final_max_turns,
      final_agent_config = params.final_agent_config,
    }
  else
    out = params
  end

  return out
end

local function make_started_event(tool_name, req, parent_chat, parent_membership, child_chat, child_membership, opts)
  opts = opts or {}
  local tool_call_id = opts.tool_call_id or current_tool_call_id(req)
  return {
    schema_version = session_trace.SCHEMA_VERSION,
    event_id = opts.event_id,
    root_trace_id = child_membership.root_trace_id,
    kind = "subagent.started",
    span_id = child_membership.span_id,
    parent_span_id = child_membership.parent_span_id,
    session = session_trace.session_info(child_chat, child_membership),
    parent = parent_info(parent_chat, parent_membership),
    tool = {
      name = tool_name,
      mode = opts.mode,
      tool_call_id = tool_call_id,
    },
    params = safe_params(opts.params, tool_name),
    dedupe_key = table.concat({
      "subagent.started",
      tostring(child_membership.root_trace_id),
      tostring(parent_membership and parent_membership.span_id or "restored"),
      tostring(tool_call_id or child_membership.span_id),
      tostring(tool_name),
      tostring(opts.mode or ""),
    }, ":"),
  }
end

function M.start_child(tool_name, req, parent_chat, child_chat, opts)
  opts = opts or {}
  local parent_membership = active_membership(parent_chat)
  if not parent_membership then
    return nil
  end

  local event_id = session_trace.new_event_id("evt")
  local child_membership, membership_err = session_trace.copy_membership(parent_chat, child_chat, {
    new_span = true,
    session_role = opts.session_role or "subagent",
    source_event_id = event_id,
  })
  if not child_membership then
    return nil, membership_err
  end

  local event = make_started_event(tool_name, req, parent_chat, parent_membership, child_chat, child_membership, {
    event_id = event_id,
    tool_call_id = opts.tool_call_id,
    mode = opts.mode,
    params = opts.params,
  })
  persist_chat_membership(child_chat)

  local append_result, append_err = append_event(child_membership.root_trace_id, event, child_chat)
  if append_result and append_result.event_id and append_result.event_id ~= event_id then
    child_membership.source_event_id = append_result.event_id
    session_trace.set_membership(child_chat, child_membership)
    persist_chat_membership(child_chat)
  end

  return {
    membership = child_membership,
    parent_membership = parent_membership,
    started_event_id = append_result and append_result.event_id or event_id,
    append_error = append_err,
  }
end

local function source_holder(source)
  if not source then
    return nil
  end
  return source.chat or source.chat_data
end

function M.start_resume(tool_name, req, parent_chat, source, child_chat, opts)
  opts = opts or {}
  local holder = source_holder(source)
  local source_membership = active_membership(holder)
  local parent_membership = active_membership(parent_chat)
  local basis = source_membership and holder or parent_membership and parent_chat or nil
  local basis_membership = source_membership or parent_membership
  if not basis or not basis_membership then
    return nil
  end

  local event_id = session_trace.new_event_id("evt")
  local child_membership
  local membership_err
  if source_membership and opts.resume_mode ~= "new_chat" then
    child_membership, membership_err = session_trace.set_membership(child_chat, source_membership)
  else
    child_membership, membership_err = session_trace.copy_membership(basis, child_chat, {
      new_span = true,
      session_role = "resumed",
      parent_span_id = source_membership and source_membership.span_id or basis_membership.span_id,
      source_event_id = event_id,
    })
  end
  if not child_membership then
    return nil, membership_err
  end

  local event = make_started_event(tool_name, req, parent_chat, parent_membership, child_chat, child_membership, {
    event_id = event_id,
    mode = opts.resume_mode,
    params = opts.params,
  })
  event.source = {
    save_id = opts.source_save_id,
    span_id = source_membership and source_membership.span_id or nil,
    session_role = source_membership and source_membership.session_role or nil,
  }
  event.dedupe_key = table.concat({
    "subagent.started",
    tostring(child_membership.root_trace_id),
    tostring(opts.source_save_id or "unknown_source"),
    tostring(current_tool_call_id(req) or event_id),
    tostring(child_membership.span_id),
    tostring(tool_name),
    tostring(opts.resume_mode or "in_place"),
  }, ":")

  persist_chat_membership(child_chat)

  local append_result, append_err = append_event(child_membership.root_trace_id, event, child_chat)
  if opts.resume_mode == "new_chat" and append_result and append_result.event_id and append_result.event_id ~= event_id then
    child_membership.source_event_id = append_result.event_id
    session_trace.set_membership(child_chat, child_membership)
    persist_chat_membership(child_chat)
  end

  return {
    membership = child_membership,
    parent_membership = parent_membership,
    source_membership = source_membership,
    started_event_id = append_result and append_result.event_id or event_id,
    append_error = append_err,
  }
end

local function final_turn_ref(chat, content)
  local last = type(chat) == "table" and chat._session_trace_last_turn_event or nil
  if type(last) ~= "table" then
    return nil
  end
  if last.kind ~= "main_turn.agent_reply" and last.kind ~= "main_turn.agent_error" then
    return nil
  end
  local normalized = content == nil and "" or tostring(content)
  if last.content_hash and last.content_hash ~= session_trace.hash(normalized) then
    return nil
  end
  return {
    event_id = last.event_id,
    kind = last.kind,
    message_index = last.message_index,
    duplicate = last.duplicate == true or nil,
  }
end

local function result_payload(chat, result, opts)
  opts = opts or {}
  result = deepcopy_plain(result or {}) or {}
  local content = result.content
  local ref = final_turn_ref(chat, content)
  local payload = {
    status = opts.status or result.status or "completed",
    finish_reason = result.finish_reason,
    save_id = result.save_id,
    source_save_id = result.source_save_id,
    parent_save_id = result.parent_save_id,
    context_status = result.context_status,
    turns_used = result.turns_used,
    max_turns = result.max_turns,
    message_count = result.message_count,
    adapter = result.adapter,
    adapter_overridden = result.adapter_overridden,
    tools_overridden = result.tools_overridden,
    tools_inherited = result.tools_inherited,
    inherit = result.inherit,
    run_mode = result.run_mode,
    fork_mode = result.fork_mode,
    resume_mode = result.resume_mode,
    compact_stats = result.compact_stats,
    recovery_available = result.recovery_available,
    suggestion = result.suggestion,
    original_error = result.original_error,
  }

  if ref then
    payload.final_turn_event_ref = ref
    payload.content_hash = session_trace.hash(content or "")
    payload.content_length = #(tostring(content or ""))
  elseif content ~= nil then
    payload.content = content
  end

  return payload
end

function M.record_subagent_completed(tool_name, chat, result, opts)
  opts = opts or {}
  local membership = active_membership(chat)
  if not membership then
    return nil
  end
  local payload = result_payload(chat, result, opts)
  local event = {
    schema_version = session_trace.SCHEMA_VERSION,
    root_trace_id = membership.root_trace_id,
    kind = "subagent.completed",
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = session_trace.session_info(chat, membership),
    tool = {
      name = tool_name,
      mode = opts.mode or payload.run_mode or payload.fork_mode or payload.resume_mode,
    },
    result = payload,
    dedupe_key = table.concat({
      "subagent.completed",
      tostring(membership.root_trace_id),
      tostring(membership.span_id),
      tostring(tool_name),
      tostring(payload.status or "completed"),
      tostring(payload.finish_reason or ""),
      session_trace.hash(payload.content or payload.content_hash or payload.original_error or ""),
    }, ":"),
  }
  return append_event(membership.root_trace_id, event, chat)
end

function M.record_subagent_error(tool_name, chat, err, opts)
  opts = opts or {}
  local membership = active_membership(chat)
  if not membership then
    return nil
  end
  local message = tostring(err or "Unknown error")
  local event = {
    schema_version = session_trace.SCHEMA_VERSION,
    root_trace_id = membership.root_trace_id,
    kind = "subagent.error",
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = session_trace.session_info(chat, membership),
    tool = {
      name = tool_name,
      mode = opts.mode,
    },
    error = {
      message = message,
      status = opts.status or "error",
      recovery = deepcopy_plain(opts.recovery),
    },
    dedupe_key = table.concat({
      "subagent.error",
      tostring(membership.root_trace_id),
      tostring(membership.span_id),
      tostring(tool_name),
      session_trace.hash(message),
    }, ":"),
  }
  return append_event(membership.root_trace_id, event, chat)
end

local function tool_result_payload(result, opts)
  result = deepcopy_plain(result or {}) or {}
  opts = opts or {}
  local data = type(result.data) == "table" and result.data or nil
  local content = result.content or (data and data.content) or nil
  return {
    status = opts.status or result.status or (opts.error and "error" or "completed"),
    content = content,
    error = opts.error and tostring(opts.error) or result.error,
    adapter = result.adapter,
    adapter_name = result.adapter_name,
    model = result.model,
    success = result.success,
    save_id = result.save_id or (data and data.save_id) or nil,
    session_id = result.session_id or (data and data.session_id) or nil,
    data_keys = data and table_keys(data) or nil,
    recovery = deepcopy_plain(opts.recovery),
  }
end

function M.record_tool_completed(tool_name, req, params, result, opts)
  opts = opts or {}
  local parent_chat = opts.parent_chat or get_parent_chat(req)
  local membership = active_membership(parent_chat)
  if not membership then
    return nil
  end
  local tool_call_id = opts.tool_call_id or current_tool_call_id(req)
  local payload = tool_result_payload(result, opts)
  local event = {
    schema_version = session_trace.SCHEMA_VERSION,
    root_trace_id = membership.root_trace_id,
    kind = tool_name .. ".completed",
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = session_trace.session_info(parent_chat, membership),
    tool = {
      name = tool_name,
      tool_call_id = tool_call_id,
    },
    params = safe_params(params, tool_name),
    result = payload,
    dedupe_key = table.concat({
      "tool.completed",
      tostring(membership.root_trace_id),
      tostring(membership.span_id),
      tostring(tool_call_id or "no_call_id"),
      tostring(tool_name),
      tostring(payload.status or "completed"),
      session_trace.hash(payload.content or payload.error or payload.data or ""),
    }, ":"),
  }
  return append_event(membership.root_trace_id, event, parent_chat)
end

M._test = {
  active_membership = active_membership,
  current_tool_call_id = current_tool_call_id,
  final_turn_ref = final_turn_ref,
  result_payload = result_payload,
  safe_params = safe_params,
  persist_chat_membership = persist_chat_membership,
  table_keys = table_keys,
}

return M
