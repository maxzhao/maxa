-- SubAgent cooperative cancellation helpers for builtin async wrappers.

local M = {}

local CANCELLED_KEY = "_maxa_subagent_async_cancel_requested"
local CANCEL_REASON_KEY = "_maxa_subagent_async_cancel_reason"

local function soft_stop_module()
  local ok, soft_stop = pcall(require, "maxa.lifecycle.chat_soft_stop")
  if ok then
    return soft_stop
  end
  return nil
end

function M.is_cancelled(chat)
  return type(chat) == "table" and chat[CANCELLED_KEY] == true
end

function M.reason(chat)
  if type(chat) ~= "table" then
    return nil
  end
  return chat[CANCEL_REASON_KEY]
end

function M.mark_cancelled(chat, reason)
  if type(chat) ~= "table" then
    return false
  end
  chat[CANCELLED_KEY] = true
  chat[CANCEL_REASON_KEY] = reason or "SubAgent was cancelled by outer async task."
  return true
end

function M.request_chat_cancel(chat, reason)
  if type(chat) ~= "table" then
    return false
  end
  M.mark_cancelled(chat, reason)
  if chat._handoff_compaction then
    require("maxa.session.handoff_compaction").cancel(chat, M.reason(chat))
    return true
  end

  local soft_stop = soft_stop_module()
  if soft_stop and type(soft_stop.is_busy) == "function" and soft_stop.is_busy(chat) then
    if type(soft_stop.request) == "function" and not soft_stop.is_requested(chat) then
      pcall(soft_stop.request, chat)
    end
  end

  return true
end

function M.register_chat(tool_name, chat, opts)
  opts = opts or {}
  local ok, bridge = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
  if not ok or not bridge or type(bridge.register_handle) ~= "function" then
    return nil
  end

  local handle = {
    kind = opts.kind or "subagent_chat",
    tool_name = tool_name,
    chat_id = chat and chat.id or nil,
    save_id = opts.save_id,
    title = opts.title,
    cancel = function(reason)
      M.request_chat_cancel(opts.current_chat and opts.current_chat() or chat, reason)
      if type(opts.on_cancel_requested) == "function" then
        opts.on_cancel_requested(reason)
      end
    end,
  }

  if bridge.register_handle(handle) then
    return handle
  end
  return nil
end

function M.register_handle(handle)
  local ok, bridge = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
  if not ok or not bridge or type(bridge.register_handle) ~= "function" then
    return false
  end
  return bridge.register_handle(handle)
end

function M._keys()
  return {
    cancelled = CANCELLED_KEY,
    reason = CANCEL_REASON_KEY,
  }
end

return M
