-- Historical overwrite recovery is retired. Active token recovery belongs to
-- maxa.session.handoff_compaction before the delegated executor terminates.
local M = {}
function M.detect_token_error(err)
  local text = tostring(err):lower()
  for _, marker in ipairs({ "maximum context length", "token limit", "context_length_exceeded", "too many tokens", "context window", "input is too long", "prompt is too long" }) do
    if text:find(marker, 1, true) then return true end
  end
  return false
end
function M.is_unsavable_save_id(save_id)
  return require("maxa.session.history_core").is_unsavable_save_id(save_id)
end
return M
