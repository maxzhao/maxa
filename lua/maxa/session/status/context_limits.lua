local token_usage = require("maxa.session.token_usage")

local M = {}

function M.get_for_chat(chat, chat_state)
  return token_usage.get_context_window(chat, chat_state)
end

function M.set_static_limit(model, limit)
  if type(model) ~= "string" or model == "" then
    return false
  end
  local escaped = model:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("([^%w])", "%%%1")
  return token_usage.set_model_context_window("^" .. escaped .. "$", limit)
end

return M
