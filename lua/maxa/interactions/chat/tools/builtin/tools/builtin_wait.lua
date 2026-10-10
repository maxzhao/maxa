-- Retrieve builtin async task results.

local param_utils = require("maxa.mcphub.native_servers.shared.params")
local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local registry = require("maxa.interactions.chat.tools.builtin.runtime.async_registry")

local DEFAULT_WAIT_TIMEOUT = 300

local function is_terminal(status)
  return registry.is_terminal(status)
end

local function response_payload(task, opts)
  if task and task.status == "succeeded" then return task.result or "" end
  return require("maxa.interactions.chat.tools.builtin.runtime.async_result").state(task, opts)
end

local function maybe_consume(task, consume)
  if consume and task and is_terminal(task.status) then
    registry.consume(task.id)
  end
end

local function send_task(context, response, task, opts)
  local payload = response_payload(task, opts)
  if context.ui and task and task.status == "succeeded" then
    require("maxa.interactions.chat.tools.display").retain_wait_result(context.ui, task._presentation)
  end
  maybe_consume(task, opts and opts.consume)
  return response:text(payload):send()
end

return {
  name = "wait",
  display = function(args, result)
    local title = require("maxa.interactions.chat.tools.display_helpers").title_detail("wait", args)
    local view = { summary = title, blocks = {} }
    if result and type(result.text) == "string" and result.text ~= "" then
      view.blocks[1] = { kind = "fold", title = title, content = result.text }
    end
    return view
  end,
  description = "Get a builtin async task result. `mode='try'` returns immediately; `mode='wait'` blocks until completion or wait timeout. Succeeded tasks return their original result verbatim; other states return minimal task status and diagnostics. Wait timeout does not cancel or time out the task.",
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
      mode = {
        type = "string",
        enum = { "try", "wait" },
        default = "try",
        description = "`try` is non-blocking; `wait` blocks until completion or timeout.",
      },
      timeout = {
        type = "number",
        minimum = 0,
        default = DEFAULT_WAIT_TIMEOUT,
        description = "Maximum seconds to wait when `mode='wait'`; set to `0` to wait indefinitely until the task reaches a terminal state. This only limits the wait call and does not change the async task's own timeout.",
      },
      consume = {
        type = "boolean",
        default = false,
        description = "When true, remove a terminal result from the registry after returning it.",
      },
    },
    required = { "title", "async_id" },
  },
  run = function(context, response)
    local params = param_utils.normalize(context and context.params or {})
    local valid_title, title_err = utils.validate_required_string(params.title, "title")
    if not valid_title then
      return response:error("wait: " .. title_err)
    end

    local async_id = params.async_id
    if not async_id or async_id == "" then
      return response:error("wait: async_id is required")
    end

    local mode = param_utils.default(params.mode, "try")
    if mode ~= "try" and mode ~= "wait" then
      return response:error("wait: mode must be 'try' or 'wait'")
    end

    local consume = param_utils.boolean(params.consume, false)

    if mode == "try" then
      return send_task(context, response, registry.get(async_id), { async_id = async_id, consume = consume })
    end

    local timeout = tonumber(param_utils.default(params.timeout, DEFAULT_WAIT_TIMEOUT)) or DEFAULT_WAIT_TIMEOUT
    if timeout < 0 then
      return response:error("wait: timeout must be >= 0")
    end

    -- Only active blocking wait mounts the live display; return removes it.
    local task = registry.get(async_id)
    local sink = task and task._presentation
    local display = context.ui and require("maxa.interactions.chat.tools.display")
    local detach_display = display and sink and display.attach_wait(context.ui, sink) or function() end
    local detach_input = require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").attach_wait(context.chat, async_id)
    local function detach()
      detach_input()
      detach_display()
    end
    local closed = false
    local cancel_waiter
    if display then
      display.on_terminal(context.ui, function()
        closed = true
        detach()
        if cancel_waiter then cancel_waiter() end
      end)
    end
    cancel_waiter = registry.wait(async_id, timeout * 1000, function(completed, wait_timed_out)
      if closed then return end
      detach()
      return send_task(context, response, completed, {
        async_id = async_id,
        consume = consume,
        wait_timed_out = wait_timed_out,
      })
    end)
  end,
}
