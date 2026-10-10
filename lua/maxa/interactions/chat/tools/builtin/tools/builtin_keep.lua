-- keep 工具
-- 管理 TTL tool result 的生命周期。

local param_utils = require("maxa.mcphub.native_servers.shared.params")
local validation_utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local ttl_result = require("maxa.interactions.chat.tools.builtin.runtime.ttl_result")

local function handler(context, response)
  local params = param_utils.normalize(context.params)
  local tool_call_id = params.tool_call_id
  local action = params.action

  local valid_title, title_err = validation_utils.validate_required_string(params.title, "title")
  if not valid_title then
    return response:error("keep: " .. (title_err or "Invalid title"))
  end

  if not tool_call_id or tool_call_id == "" then
    return response:error("keep: tool_call_id is required")
  end
  if not action or action == "" then
    return response:error("keep: action is required")
  end

  local allowed = { discard = true, defer = true, keep = true, persist = true }
  if not allowed[action] then
    return response:error("keep: action must be one of discard, defer, keep, persist")
  end

  local ability_utils = require("maxa.interactions.chat.tools.builtin.runtime.ability_utils")
  local chat = ability_utils.get_chat_and_agent(context)
  if not chat then
    return response:error("keep: Cannot access chat session")
  end

  local ok, message = ttl_result.apply_action(chat, tool_call_id, action, params.ttl)
  if not ok then
    return response:error("keep: " .. tostring(message))
  end

  return response:text("✅ " .. tostring(message)):send()
end

return {
  name = "keep",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").title_detail("keep", args) }
  end,
  description = [[Manage a TTL-managed tool result by tool call id.

Use immediately after a TTL-managed result when default expiry is not acceptable. Actions: `discard` removes content now; `defer` keeps N more LLM rounds and requires `ttl`; `keep` keeps for this chat; `persist` keeps and protects during compression.]],
  inputSchema = {
    type = "object",
    properties = {
      title = {
        type = "string",
        description = "Short required title used for tool display.",
      },
      tool_call_id = {
        type = "string",
        description = "The tool call id shown in the TTL-managed tool result.",
      },
      action = {
        type = "string",
        enum = { "discard", "defer", "keep", "persist" },
        description = "Lifecycle action to apply: discard, defer, keep, or persist.",
      },
      ttl = {
        type = "integer",
        description = "Number of additional LLM response rounds to keep the result; required when action=defer.",
        minimum = 1,
      },
    },
    required = { "title", "tool_call_id", "action" },
  },
  run = handler,
}
