-- Scheduling is local to one completed model response. Optional runs become
-- flat runtime-authored call/result records only after the batch closes.
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local inventory = require("maxa.interactions.chat.tools.builtin")
local display = require("maxa.interactions.chat.tools.display")
local core = require("maxa.interactions.chat.tools.builtin.runtime.tool_call_core")
local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
local utils = require("maxa.utils")
local M = {}

function M.execute(tools, plan, id, opts)
  local chat = tools.chat
  local expansion_error
  if plan.native_batch.runs and not plan.native_batch.error and opts and opts.model_batch then
    local calls, raw_runs, execution_params = require("maxa.interactions.chat.tools.builtin.runtime.multicall_history").expand(
      plan.entries[1].call, plan.native_batch.runs, chat)
    if calls then
      local expanded = require("maxa.interactions.chat.tools.validator").classify_batch(tools, chat, calls,
        { expanded_runs = true, execution_params = execution_params })
      -- Only the model-input runs/sibling mixing guard is bypassed; generated
      -- members retain normal validation and correlation checks.
      expanded.native_batch.expansion = { raw_runs = raw_runs, original_entries = plan.entries }
      plan = expanded
    else expansion_error = raw_runs end
  end
  local declaration_index = plan.native_batch.declaration_index
  local members, completed, running, next_index = {}, 0, 0, 1
  local terminal, cancelled, pumping, preflighting = false, false, false, true
  local declaration, settings, parent_ui, first_failed
  local cancel_handle

  local function close()
    if terminal then return end
    terminal = true
    tools.tool = nil
    if plan.native_batch.expansion and not preflighting then
      require("maxa.interactions.chat.tools.builtin.runtime.multicall_history").commit(chat, plan)
    end
    if chat.current_tool == cancel_handle then chat.current_tool = nil end
    tools:_flush_validation_corrections()
    utils.fire("ToolsFinished", { id = id, bufnr = tools.bufnr, cancelled = cancelled })
  end
  local function tool_for(entry)
    local fn = type(entry.call) == "table" and entry.call["function"] or nil
    local ok, args = pcall(vim.json.decode, fn and fn.arguments ~= "" and fn.arguments or "{}")
    return { name = entry.tool_name, function_call = entry.call, args = ok and args or {} }
  end
  local function reject(reason)
    if terminal then return end
    tools:mark_error()
    for _, entry in ipairs(plan.native_batch.expansion and plan.native_batch.expansion.original_entries or plan.entries) do
      if entry.kind ~= "rejected_unreplayable" then
        chat:add_validation_error_output(tool_for(entry), entry.kind == "rejected_replayable" and entry.feedback
          or "MULTICALL_PREFLIGHT_ERROR\n" .. reason .. "\nNo member was executed.")
      end
    end
    close()
  end
  local function summary()
    local succeeded, failed, skipped = 0, 0, 0
    for _, member in ipairs(members) do
      if member.status == "success" then succeeded = succeeded + 1
      elseif member.status == "error" or member.started and member.status == "cancelled" then failed = failed + 1
      else skipped = skipped + 1 end
    end
    local facts = { status = cancelled and "cancelled" or failed > 0 and "failed" or "completed",
      mode = settings.mode, on_error = settings.on_error, members = #members,
      succeeded = succeeded, failed = failed, not_executed = skipped,
      first_failed_index = settings.mode == "sequence" and settings.on_error == "stop" and first_failed or nil }
    local lines = {}
    for _, key in ipairs({ "status", "mode", "on_error", "members", "succeeded", "failed", "not_executed", "first_failed_index" }) do
      if facts[key] ~= nil then lines[#lines + 1] = key .. ": " .. tostring(facts[key]) end
    end
    local text = table.concat(lines, "\n")
    if failed > 0 or cancelled then tools:mark_error() end
    display.complete_ui(parent_ui, { ok = failed == 0 and not cancelled, text = text, status = facts.status })
    chat:add_tool_output(declaration, text, nil, { is_error = failed > 0 or cancelled })
    utils.fire("ToolFinished", { id = id, name = "multicall", bufnr = tools.bufnr })
    close()
  end
  local function settle(member, result, status)
    if member.done or terminal then return end
    member.done = true
    if member.started then running = running - 1 end
    member.handles = nil -- submitted async work is never batch-owned
    member.status = status or (result.ok and "success" or "error")
    completed = completed + 1
    local text = result.ok and adapter.content_to_result(result.content) or tostring(result.error or "Unknown tool error")
    display.complete_ui(member.context.ui, { ok = result.ok == true, text = text, status = member.status })
    chat:add_tool_output(member.tool, text, nil, { is_error = result.ok ~= true })
    if member.status == "error" then
      tools:mark_error()
      first_failed = first_failed or member.index
    end
  end
  local function cancel(reason)
    if terminal or cancelled then return false end
    cancelled = true
    reason = reason or "tool batch cancelled"
    if preflighting then reject(reason); return true end
    -- Latch first; cancellation callbacks may synchronously return results.
    for _, member in ipairs(members) do
      if not member.done then
        for _, handle in ipairs(member.handles or {}) do pcall(handle.cancel, reason) end
        if not member.done then
          settle(member, { ok = false, error = "TOOL_CANCELLED\n" .. reason }, "cancelled")
          if member.started then utils.fire("ToolFinished", { id = id, name = member.tool.name, bufnr = tools.bufnr }) end
        end
      end
    end
    summary()
    return true
  end
  cancel_handle = { cancel = cancel }
  chat.current_tool = cancel_handle
  utils.fire("ToolsStarted", { id = id, bufnr = tools.bufnr })
  local decision = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
  if decision and decision.should_cancel_tool_batch and decision.should_cancel_tool_batch(chat) then
    return cancel("token finish budget exhausted")
  end
  if not (opts and opts.model_batch) then return reject("multicall requires a complete model-generated tool batch.") end
  if plan.native_batch.error or expansion_error then return reject(plan.native_batch.error or expansion_error) end
  if chat._maxa_hidden_image_analysis then return reject("Hidden image-analysis child cannot use multicall.") end
  for _, entry in ipairs(plan.entries) do
    if entry.kind ~= "valid" then return reject("Invalid call at batch index " .. entry.index .. ": " .. tostring(entry.reason)) end
    local definition = inventory.resolve(entry.tool_name)
    local registry = chat.tool_registry
    if not definition or not tools.tools_config[entry.tool_name]
      or not (registry and registry.in_use and registry.in_use[entry.tool_name]) then
      return reject("Unavailable native first-party builtin at batch index " .. entry.index .. ": " .. entry.tool_name)
    end
    if entry.index ~= declaration_index and (definition.interactive or entry.tool_name == "multicall") then
      return reject("Interactive or nested batch member is prohibited: " .. entry.tool_name)
    end
    local tool = tool_for(entry)
    local local_tools = { chat = chat, tool = tool }
    local expansion = plan.native_batch.expansion
    local raw = expansion and expansion.raw_runs[entry.index - 1]
    local context, err = adapter.invocation_from_tools(local_tools, tool.args, definition)
    if not context then return reject(err) end
    if entry.execution_params then context.params = vim.deepcopy(entry.execution_params) end
    if raw then
      context.ui._state.args = vim.deepcopy(raw)
      context.ui._state.name = "run"
      context.ui._state.bound = nil
      context.ui._state.bound_args = nil
      if definition.name ~= "run" then context.display_args = vim.json.decode(raw.args or "{}")
      else context.display_args = vim.deepcopy(raw) end
    end
    context.native_batch_declaration = entry.index == declaration_index
    context.batch_parent = not context.native_batch_declaration
    if entry.tool_name == "run" and tool.args.scope == "tool" then context.active_wrappers.run = true end
    context, err = adapter.prepare(definition, context)
    if not context then return reject("Batch index " .. entry.index .. ": " .. tostring(err)) end
    local ok, extension, extension_err = pcall(require("maxa.interactions.chat.tools.builtin.runtime.extensions").select, definition.name, context)
    if not ok or extension_err then return reject(tostring(extension_err or extension)) end
    if definition.name == "run" and context.params.scope ~= "shell" and context.params.scope ~= "win"
      and context.params.scope ~= "tool" and not extension then
      return reject("Unsupported run scope: " .. context.params.scope)
    end
    if context.native_batch_declaration then
      declaration, settings, parent_ui = tool, context.params, context.ui
    else
      members[#members + 1] = { index = #members + 1, tool = tool, definition = definition,
        context = context, display_run = raw, handles = {} }
    end
  end

  local pump
  pump = function()
    if terminal or cancelled or pumping then return end
    pumping = true
    local limit = settings.mode == "sequence" and 1
      or (settings.max_concurrency == 0 and #members or settings.max_concurrency)
    while not terminal and not cancelled and running < limit and next_index <= #members do
      local member = members[next_index]
      next_index = next_index + 1
      if settings.mode == "sequence" and settings.on_error == "stop" and first_failed then
        local failed = members[first_failed]
        settle(member, { ok = false, error = string.format(
          "NOT_EXECUTED_SEQUENCE_STOP\nEarlier member %d (%s) failed; on_error=stop. This handler was not executed.",
          first_failed, failed.tool.name) }, "not-executed")
      else
        member.started, running = true, running + 1
        display.start_member(member.context.ui)
        utils.fire("ToolStarted", { id = id, tool = member.tool.name, bufnr = tools.bufnr })
        local function done(result)
          if member.done or terminal then return end
          if cancelled then result = { ok = false, error = "TOOL_CANCELLED" } end
          settle(member, result, cancelled and "cancelled" or nil)
          utils.fire("ToolFinished", { id = id, name = member.tool.name, bufnr = tools.bufnr })
          if completed == #members and not pumping and not cancelled then return summary() end
          pump()
        end
        member.context.cancel_context = { register = function(handle)
          if member.done or terminal then return false end
          member.handles[#member.handles + 1] = handle
          if cancelled then pcall(handle.cancel, "tool batch cancelled") end
          return true
        end }
        local ok, err = pcall(bridge.with_context, member.context.cancel_context,
          function() return adapter.invoke(member.definition, member.context, done, true) end)
        if not ok then done({ ok = false, error = tostring(err) }) end
      end
    end
    pumping = false
    if completed == #members and not terminal and not cancelled then summary() end
  end
  local function start()
    if terminal or cancelled then return end
    if plan.native_batch.expansion then
      local staged, err = require("maxa.interactions.chat.tools.builtin.runtime.multicall_history").stage(chat, plan)
      if not staged then return reject(err) end
    end
    preflighting = false
    local views = {}
    for index, member in ipairs(members) do
      views[index] = { name = member.display_run and "run" or member.tool.name, args = member.display_run or member.tool.args,
        call_id = member.context.tool_call_id, definition = not member.display_run and member.definition or nil }
    end
    display.begin_native_batch(parent_ui, views)
    for _, member in ipairs(members) do
      if member.display_run and member.tool.name ~= "run" then
        display.bind_target(member.context.ui, member.definition, member.context.display_args)
      end
    end
    display.push_pending_tool(tools.bufnr, "multicall", declaration.args, #chat.messages, parent_ui._state.id)
    utils.fire("ToolStarted", { id = id, tool = "multicall", bufnr = tools.bufnr })
    display.on_terminal(parent_ui, function() if not terminal and completed ~= #members then cancel("Chat closed") end end)
    pump()
  end
  local index = 0
  local function preflight_next()
    if terminal or cancelled then return end
    index = index + 1
    local member = members[index]
    if not member then return start() end
    local check = member.definition.preflight
    local checked = false
    local function ready(err)
      if checked or terminal or cancelled then return end
      checked = true
      if err then return reject("Member " .. member.index .. " (" .. member.tool.name .. "): " .. tostring(err)) end
      preflight_next()
    end
    if check then
      local ok, err = pcall(check, member.context, ready)
      if not ok then ready(err) end
    else ready() end
  end
  preflight_next()
end
return M
