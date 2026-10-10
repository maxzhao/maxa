-- Coordinate SubAgent terminal callbacks with runtime-owned token decisions.
--
-- A threshold can be detected after the next child request is already queued.
-- That request may then emit on_completed while Telegram is still waiting. The
-- decision state machine, not the SubAgent controller, owns that completion.
local M = {}

---@param chat table|nil Maxa AI Chat
---@param callback function Terminal callback to retry after the decision releases
---@return boolean deferred
function M.defer_for_token_decision(chat, callback)
  local decision = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
  if not decision or type(decision.defer_completion) ~= "function" then
    return false
  end
  return decision.defer_completion(chat, callback)
end

---@param chat table|nil
---@return string|nil action
function M.token_decision_action(chat)
  return type(chat) == "table" and chat._maxa_token_decision_last_action or nil
end

---@param chat table|nil
---@return boolean
function M.is_token_terminal(chat)
  local action = M.token_decision_action(chat)
  return action == "finish" or action == "interrupt"
end

return M
