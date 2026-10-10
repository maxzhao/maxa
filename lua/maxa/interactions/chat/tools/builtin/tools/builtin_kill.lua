-- Force-cancel a builtin async task by async_id.

local param_utils = require("maxa.mcphub.native_servers.shared.params")
local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")

local result = require("maxa.interactions.chat.tools.builtin.runtime.async_result")

return {
  name = "kill",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").title_detail("kill", args) }
  end,
  description = "Force-cancel a running builtin async task that should not be waited on with `wait`. Returns outer task state and whether cancellation was requested; cooperative inner work may still drain.",
  inputSchema = {
    type = "object",
    properties = {
      title = {
        type = "string",
        description = "Short required title used for tool display.",
      },
      async_id = {
        type = "string",
        description = "Async task id returned by a builtin tool called with async=true.",
      },
    },
    required = { "title", "async_id" },
  },
  run = function(context, response)
    local params = param_utils.normalize(context and context.params or {})
    local valid_title, title_err = utils.validate_required_string(params.title, "title")
    if not valid_title then
      return response:error("kill: " .. title_err)
    end

    local async_id = params.async_id
    if not async_id or async_id == "" then
      return response:error("cancel: async_id is required")
    end

    local task = registry.get(async_id)
    if not task then
      return response:text(result.state(nil, { async_id = async_id, cancellation = "not_performed" })):send()
    end

    if registry.is_terminal(task.status) then
      return response:text(result.state(task, { cancellation = "not_performed_already_terminal" })):send()
    end

    local ok, cancelled_task_or_error = registry.cancel(async_id, "Async task cancelled by cancel.")
    if not ok then
      return response:text(result.state(registry.get(async_id), {
        async_id = async_id, cancellation = "not_performed",
        reason = "Async task could not be cancelled: " .. tostring(cancelled_task_or_error),
      })):send()
    end

    return response:text(result.state(cancelled_task_or_error, { cancellation = "requested" })):send()
  end,
}
