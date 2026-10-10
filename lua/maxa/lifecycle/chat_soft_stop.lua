-- chat_soft_stop: graceful Maxa AI chat stop after current operation.
--
-- Soft stop is intentionally different from Chat:stop(): it never cancels the
-- active request/tool. It drains the current LLM response and any tool-call
-- batch, then suppresses the next auto-submit continuation.

local M = {}

local REQUESTED_KEY = "_maxa_soft_stop_requested"
local COMPLETED_KEY = "_maxa_soft_stop_completed"
local OWNER_KEY = "_maxa_soft_stop_owner"
local FINALIZING_KEY = "_maxa_soft_stop_finalizing"
local READY_CALLBACK_KEY = "_maxa_soft_stop_ready_callback_installed"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function tools_active(chat)
  if type(chat) ~= "table" then
    return false
  end
  if chat.current_tool ~= nil then
    return true
  end
  if type(chat.tools) == "table" and chat.tools.tool ~= nil then
    return true
  end
  return false
end

function M.is_busy(chat)
  if type(chat) ~= "table" then
    return false
  end
  return chat.current_request ~= nil or tools_active(chat)
end

function M.is_requested(chat)
  return type(chat) == "table" and chat[REQUESTED_KEY] == true
end

function M.is_latched(chat)
  return type(chat) == "table" and (chat[REQUESTED_KEY] == true or chat[COMPLETED_KEY] == true)
end

function M.clear(chat, reason)
  if type(chat) ~= "table" then
    return false
  end
  local was_requested = chat[REQUESTED_KEY] == true
  chat[REQUESTED_KEY] = nil
  chat[FINALIZING_KEY] = nil
  if reason ~= "completed" then
    chat[COMPLETED_KEY] = nil
    chat[OWNER_KEY] = nil
  end
  return was_requested
end

-- Trusted runtime orchestration API. Release a completed/requested soft-stop
-- before another runtime-owned operation (for example silent compression).
function M.release(chat)
  if type(chat) ~= "table" then
    return false
  end
  local was_latched = M.is_latched(chat)
  chat[REQUESTED_KEY] = nil
  chat[COMPLETED_KEY] = nil
  chat[FINALIZING_KEY] = nil
  chat[OWNER_KEY] = nil
  return was_latched
end

-- Re-establish a manual-resumable stop after an orchestration failure. Unlike
-- request(), this is valid when no provider/tool operation is currently busy.
function M.latch(chat)
  if type(chat) ~= "table" then
    return false
  end
  chat[REQUESTED_KEY] = nil
  chat[FINALIZING_KEY] = nil
  chat[COMPLETED_KEY] = true
  chat[OWNER_KEY] = nil
  return true
end

function M.is_owned_by(chat, owner)
  return type(chat) == "table" and owner ~= nil and chat[OWNER_KEY] == owner and M.is_latched(chat)
end

local function fire_soft_stopped(chat, reason)
  if not chat.bufnr then
    return
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "MaxaAIChatSoftStopped",
    data = {
      bufnr = chat.bufnr,
      id = chat.id,
      reason = reason,
    },
  })
end

local function cancel_error_recovery(chat)
  local ok, recovery = pcall(require, "maxa.session.llm_error_recovery")
  if ok and recovery and type(recovery.cancel_pending_retry) == "function" then
    local cancelled_ok, err = pcall(recovery.cancel_pending_retry, chat, "soft_stop")
    if not cancelled_ok then
      notify("[soft-stop] Error recovery cleanup failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

local function deactivate_repeat(chat)
  if type(chat) ~= "table" or rawget(chat, "_repeat_state") == nil then
    return false
  end
  local ok, repeat_command = pcall(require, "maxa.interactions.chat.tools.builtin.slash_commands.repeat")
  if ok and repeat_command and type(repeat_command.deactivate) == "function" then
    local deactivated_ok, err = pcall(repeat_command.deactivate, chat, "soft stop")
    if not deactivated_ok then
      notify("[soft-stop] Repeat cleanup failed: " .. tostring(err), vim.log.levels.WARN)
      return false
    end
    return true
  end
  return false
end

function M.finish(chat, reason)
  if type(chat) ~= "table" then
    return false
  end
  if chat[FINALIZING_KEY] == true then
    return false
  end
  if chat[REQUESTED_KEY] ~= true then
    return false
  end

  chat[FINALIZING_KEY] = true
  chat[REQUESTED_KEY] = nil
  chat[COMPLETED_KEY] = true

  cancel_error_recovery(chat)
  local repeat_deactivated = deactivate_repeat(chat)
  fire_soft_stopped(chat, reason)

  chat[FINALIZING_KEY] = nil

  if repeat_deactivated then
    notify("Soft stop: current operation completed; Repeat stopped.")
  else
    notify("Soft stop: current operation completed; auto-continuation stopped.")
  end
  return true
end

local function ensure_ready_callback(chat)
  if type(chat) ~= "table" or chat[READY_CALLBACK_KEY] == true then
    return
  end
  if type(chat.add_callback) ~= "function" then
    return
  end

  chat[READY_CALLBACK_KEY] = true
  chat:add_callback("on_ready", function(self_chat)
    -- Some MaxaAI ready paths dispatch on_ready before they
    -- clear current_request and the remaining runtime state. Checking inline
    -- leaves the soft stop armed forever because there may be no later
    -- on_ready event. Re-check after the current ready transition completes.
    vim.schedule(function()
      if M.is_requested(self_chat) and not M.is_busy(self_chat) then
        M.finish(self_chat, "ready")
      end
    end)
  end)
  chat:add_callback("on_closed", function(self_chat)
    M.clear(self_chat, "closed")
  end)
  chat:add_callback("on_cancelled", function(self_chat)
    M.clear(self_chat, "cancelled")
  end)
end

-- Runtime-owned completion/dispatch boundaries can have no current_request or
-- tools.tool even though continuation has not run yet. Unlike the user toggle,
-- this is idempotent and never disarms an already requested stop.
function M.request_at_boundary(chat, owner)
  if type(chat) ~= "table" then
    return false
  end
  ensure_ready_callback(chat)
  if M.is_latched(chat) then
    return true
  end
  chat[REQUESTED_KEY] = true
  chat[COMPLETED_KEY] = nil
  chat[OWNER_KEY] = owner
  return true
end

function M.request(chat)
  if type(chat) ~= "table" then
    notify("[soft-stop] No Maxa AI chat is available", vim.log.levels.WARN)
    return false
  end

  if chat[REQUESTED_KEY] == true then
    M.clear(chat, "toggle")
    notify("Soft stop cancelled; auto-continuation may continue.")
    return false
  end

  if not M.is_busy(chat) then
    notify("No active request/tool to soft-stop.", vim.log.levels.INFO)
    return false
  end

  ensure_ready_callback(chat)
  chat[REQUESTED_KEY] = true
  chat[COMPLETED_KEY] = nil
  chat[OWNER_KEY] = nil

  -- A recovery backoff uses a synthetic current_request only to keep Ctrl+C
  -- available; no provider/tool operation is actually running. Stop that wait
  -- immediately instead of waiting for its timer to attempt one more submit.
  if chat._network_retry_timer ~= nil then
    M.finish(chat, "retry_wait")
    return true
  end

  notify("Soft stop requested: current response/tools will finish, then auto-continuation will stop.")
  return true
end

function M.should_block_auto_submit(chat, opts)
  if type(chat) ~= "table" or type(opts) ~= "table" or opts.auto_submit ~= true then
    return false
  end
  -- COMPLETED_KEY is a latch, not merely a historical marker. Delayed timers,
  -- watchdog repair, Repeat, or an already-queued auto-submit continuation may
  -- arrive after finish() clears REQUESTED_KEY. Keep rejecting those automatic
  -- submits until an explicit non-auto submit releases the latch.
  return M.is_requested(chat) or chat[COMPLETED_KEY] == true
end

function M.call_callback(opts)
  if type(opts) ~= "table" or type(opts.callback) ~= "function" then
    return true
  end
  local ok, err = pcall(opts.callback)
  if not ok then
    notify("[soft-stop] auto-submit callback failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

function M.before_submit(chat, opts)
  opts = opts or {}
  if M.should_block_auto_submit(chat, opts) then
    local had_callback = type(opts.callback) == "function"
    M.call_callback(opts)
    if not had_callback and M.is_requested(chat) then
      M.finish(chat, "auto_submit_blocked")
    end
    return false
  end
  if opts.auto_submit ~= true and chat[COMPLETED_KEY] == true and not M.is_busy(chat) then
    chat[COMPLETED_KEY] = nil
    chat[OWNER_KEY] = nil
  end
  return true
end

function M.before_tools_done(chat, opts)
  opts = opts or {}
  if opts.auto_submit == true and (M.is_requested(chat) or chat[COMPLETED_KEY] == true) then
    local converted = vim.deepcopy(opts)
    converted.auto_submit = false
    return converted, true
  end
  return opts, false
end

function M.after_tools_done(chat, converted)
  if converted and M.is_requested(chat) then
    M.finish(chat, "tools_done")
  end
end

function M.setup()
end

function M._test_reset_patch()
end

function M._test_keys()
  return {
    requested = REQUESTED_KEY,
    completed = COMPLETED_KEY,
    finalizing = FINALIZING_KEY,
    ready_callback = READY_CALLBACK_KEY,
  }
end

return M
