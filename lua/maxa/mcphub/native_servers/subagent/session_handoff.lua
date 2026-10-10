-- run_agent handoff owns preparation; the ordinary tool-batch boundary commits it.
local M = {}
local identity = require("maxa.session.agent_identity")
local history_core = require("maxa.session.history_core")
local soft_stop = require("maxa.lifecycle.chat_soft_stop")
local injector = require("maxa.interactions.chat.tools.builtin.runtime.context_injector")

local function live(chat)
  return chat and not chat._closed and vim.api.nvim_buf_is_valid(chat.bufnr)
end

function M.is_child_eligible(chat)
  local execution = chat and chat._subagent_executor
  local parent = identity.parent(chat)
  return live(chat) and identity.is_subagent(chat)
    and not history_core.is_unsavable_save_id(identity.save_id(chat))
    and execution and execution.chat == chat and not execution.finished
    and execution.parent == parent and live(parent)
end

function M.validate(req, params)
  local parent = req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  if not live(parent) then return nil, "handoff requires an exact caller Chat" end
  if not identity.is_main(parent) and not M.is_child_eligible(parent) then
    return nil, "handoff requires a main Chat or an active persistent delegated child with its current parent"
  end
  if require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge").current()
    or (req.ui and req.ui._state and req.ui._state.batch_parent) then
    return nil, "handoff requires a standalone synchronous run, not multicall or async"
  end
  if not parent.current_tool then return nil, "handoff requires an active caller tool batch" end
  if parent._session_handoff then return nil, "a session handoff is already pending" end
  if history_core.is_unsavable_save_id(identity.save_id(parent)) then
    return nil, "handoff requires a history-backed Chat"
  end
  if params.max_turns ~= nil and params.max_turns ~= 0 then
    return nil, "max_turns is only supported for delegated sessions, not handoff"
  end
  return parent
end

-- Save/read-back both canonical transcript and index; autosave is not a commit.
local function save_verified(chat)
  local api = require("maxa.session.history_session").get_history_api()
  if not api or not api.save_chat or not api.load_chat or not api.get_chats then
    return false, "history API is unavailable"
  end
  injector.flush(chat)
  local ok, err = pcall(function()
    -- Canonical storage follows the active workspace; never save a handoff to
    -- another project's history merely because the caller is currently hidden.
    api.get_chats()
    local root = chat.opts.project_root
    if root and vim.fn.isdirectory(vim.fs.joinpath(root, ".maxa")) == 1 then
      assert(api.get_location and vim.fs.normalize(api.get_location()) == vim.fs.normalize(vim.fs.joinpath(root, ".maxa", "history")),
        "history workspace does not match the caller project")
    end
    api.save_chat(chat)
    local id = identity.save_id(chat)
    local data, index = api.load_chat(id), api.get_chats()[id]
    local messages = require("maxa.session.history_session").strip_runtime_control_messages(chat.messages)
    assert(data and index, "saved Chat or history index is unavailable")
    assert(vim.deep_equal(data.messages, messages), "saved transcript does not match the prepared Chat")
    assert(vim.deep_equal(data._meta.agent, identity.history(chat)), "saved Chat identity does not match")
    assert(vim.deep_equal(index.agent, identity.history(chat)), "history index identity does not match")
  end)
  return ok, ok and nil or tostring(err)
end

local function discard(parent, state)
  if parent._session_handoff == state then parent._session_handoff = nil end
  state.finished = true
  if live(state.target) then state.target:close() end
end

function M.prepare(parent, target, deferred, goal, res)
  local state = { target = target, phase = "preparing", child = M.is_child_eligible(parent) and true or false }
  parent._session_handoff = state
  local function fail(stage, err)
    if state.finished then return end
    discard(parent, state)
    res:error("run_agent: handoff " .. stage .. " failed: " .. tostring(err))
  end
  parent:add_callback("on_cancelled", function()
    if parent._session_handoff ~= state then return end
    if state.phase == "preparing" then fail("preparation", "caller cancelled")
    else state.cancelled = true end
  end)
  parent:add_callback("on_closed", function()
    if parent._session_handoff ~= state then return end
    if state.phase == "preparing" then fail("preparation", "caller Chat was closed")
    else discard(parent, state) end
  end)

  local function ready(err)
    if state.finished then return end
    if err then return fail("preload", err) end
    if not live(parent) or not live(target) then return fail("preparation", "Chat is unavailable") end
    if state.child and (not M.is_child_eligible(parent)
      or require("maxa.mcphub.native_servers.subagent.async_cancel").is_cancelled(parent)) then
      return fail("preparation", "delegated invocation is no longer active")
    end
    if deferred then
      require("maxa.mcphub.native_servers.subagent.utils").append_sub_agent_tail(target.messages, goal)
    end
    require("maxa.session.compaction_messages").mark_current_messages_as_protected_prefix(target)
    local saved, save_error = save_verified(target)
    if not saved then return fail("target history", save_error) end
    state.phase = "scheduled"
    soft_stop.request_at_boundary(parent, state)
    res:text(require("maxa.mcphub.native_servers.subagent.result_format").handoff({
      status = "handoff_scheduled", save_id = identity.save_id(target),
    }))
    res:send()
  end
  if deferred then
    require("maxa.mcphub.native_servers.subagent.background_calls").execute(target, deferred, ready, { strict_files = true })
  else ready() end
end

M.save_verified = save_verified

-- Runtime-owned Session compaction reaches the same commit through safe stop,
-- rather than a public run_agent tool batch. Public validate() remains strict.
function M.schedule_compaction(parent, target)
  if not live(parent) or parent._session_handoff then return false, "source Chat is unavailable or already transferring" end
  if not identity.is_main(parent) and not M.is_child_eligible(parent) then
    return false, "compaction requires a main or active persistent delegated Chat"
  end
  local saved, err = save_verified(target)
  if not saved then return false, err end
  parent._session_handoff = { target = target, phase = "scheduled", child = M.is_child_eligible(parent) and true or false }
  return true
end

-- Called after canonical outputs and context have settled, before auto-submit.
function M.after_tools(parent, failed)
  local state = parent._session_handoff
  if not state or state.phase ~= "scheduled" then return false end
  local target = state.target
  local function blocked(err)
    discard(parent, state)
    soft_stop.latch(parent)
    local message = "run_agent: handoff was not committed: " .. tostring(err)
    parent:add_buf_message({ role = require("maxa.config").constants.LLM_ROLE, content = message })
    vim.notify(message, vim.log.levels.ERROR)
    return true, message
  end
  if failed or state.cancelled then return blocked("caller tool batch failed or was cancelled") end
  if not live(target) or soft_stop.is_busy(parent) or parent._tool_input then
    return blocked("Chat is unavailable or caller has not reached a safe boundary")
  end
  local saved, err = save_verified(parent)
  if not saved then return blocked("caller history: " .. tostring(err)) end

  if state.child then
    if not M.is_child_eligible(parent) then return blocked("delegated invocation is no longer active") end
    local execution = parent._subagent_executor
    local ancestor = identity.parent(parent)
    require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").bind_child(ancestor, target, execution.ui, parent)
    local hooks_ok, hooks = pcall(require, "maxa.abilities.hooks.registry")
    if hooks_ok then
      hooks.register_parent_chain(ancestor.id, target.id)
      hooks.inherit_session_hooks(parent.id, target.id, target)
    end
    local was_visible = parent.ui:is_visible()
    if was_visible then
      local opened, open_error = pcall(function()
        target.ui:open({ window_opts = identity.window_opts(target) })
        assert(target.ui:is_visible(), "target child window is unavailable")
      end)
      if not opened then return blocked("child window: " .. tostring(open_error)) end
    end
    local replaced, replace_error = execution.replace(target)
    if not replaced then return blocked(replace_error) end
    parent._session_handoff = nil
    state.finished = true
    parent:close()
    return true
  end

  -- Open the prepared target before destroying the caller, so window failure
  -- can restore the caller. No target model work starts until caller closure.
  local opened, open_error = pcall(function()
    if parent.ui:is_visible() then parent.ui:hide() end
    target.opts.preserve_main, target.opts.headless = nil, nil
    target.ui:open({ window_opts = { layout = "vertical", position = "right" } })
    assert(target.ui:is_visible(), "target main window is unavailable")
  end)
  if not opened then
    target.opts.preserve_main = true
    pcall(function() if target.ui:is_visible() then target.ui:hide() end end)
    local restored, restore_error = pcall(function()
      parent.ui:open({ window_opts = { layout = "vertical", position = "right" } })
      assert(parent.ui:is_visible(), "caller main window is unavailable")
    end)
    local detail = "main window: " .. tostring(open_error)
    if not restored then detail = detail .. "; caller window restore failed: " .. tostring(restore_error) end
    return blocked(detail)
  end
  parent._session_handoff = nil
  state.finished = true
  parent:close()
  target:submit({ auto_submit = true })
  return true
end

return M
