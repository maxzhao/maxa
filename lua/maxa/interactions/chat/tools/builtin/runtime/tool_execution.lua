-- Tool scope keeps target authorization/results separate from process execution.
local core = require("maxa.interactions.chat.tools.builtin.runtime.tool_call_core")
local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")
local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
local params = require("maxa.mcphub.native_servers.shared.params")
local M = {}

function M.run(context, response)
  local p = context.params
  local task = params.boolean((p.opts or {}).async, false)
    and registry.create({ tool = "run", label = p.title, context = context }) or nil
  local meta = { outer_tool_name = "run" }
  if task then
    meta.async_id = task.id
    registry.set_canceller(task.id, function(reason)
      bridge.cancel(task.id, reason or "Async run cancelled.")
    end)
  end
  local execution = context
  if task and task._presentation then
    execution = vim.tbl_extend("force", {}, context, { ui = task._presentation })
  end
  core.execute(execution, { tool = p.command, params = p.args or {} }, function(result)
    if task then
      bridge.clear(task.id)
      if result.ok then registry.succeed(task.id, core.content_to_result(result.content))
      else registry.fail(task.id, result.error or "Unknown tool error") end
      return
    end
    if not result.ok then return response:error(result.error or "Unknown tool error") end
    for _, item in ipairs(result.content or {}) do
      if item.type == "text" then response:text(item.text or "")
      elseif item.type == "resource" then response:resource(item.resource) end
    end
    return response:send()
  end, meta)
  if task then
    return response:text(require("maxa.interactions.chat.tools.builtin.runtime.async_result").state(task, { submitted = true })):send()
  end
end

return M
