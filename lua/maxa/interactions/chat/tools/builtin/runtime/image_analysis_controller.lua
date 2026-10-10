-- filepath: lua/maxa/interactions/chat/tools/builtin/runtime/image_analysis_controller.lua
-- Strict temporary image-analysis lifecycle over a Maxa AI Chat instance.

local M = {}
local MAX_DIAGNOSTIC_BYTES = 800
local EMPTY_RESPONSE_CORRECTION = [[Your previous response contained no tool calls and no usable text. Return the complete requested image-analysis result now as one nonempty final assistant text response. Do not call tools and do not add a separate closing message.]]
M.DEFAULT_TIMEOUT_SECONDS = 300

local function bounded(value)
  local text = vim.trim(tostring(value or ""):gsub("%s+", " "))
  return #text > MAX_DIAGNOSTIC_BYTES and (text:sub(1, MAX_DIAGNOSTIC_BYTES) .. "...") or text
end

local function has_tools(tools)
  return type(tools) == "table" and not vim.tbl_isempty(tools)
end

local function final_text(output)
  if type(output) ~= "table" or vim.tbl_isempty(output) then
    return nil
  end
  local ok, content = pcall(table.concat, output, "")
  if not ok then
    return nil
  end
  content = vim.trim(content)
  return content ~= "" and content or nil
end

---Install strict dispatch/final-response/lifecycle guards before the first child submit.
---@param opts table
---@return table controller
function M.install(opts)
  local chat = assert(opts.chat, "chat is required")
  local max_steps = assert(opts.max_steps, "max_steps is required")
  local timeout = opts.timeout or M.DEFAULT_TIMEOUT_SECONDS
  assert(type(timeout) == "number" and timeout > 0, "timeout must be a positive number")
  local original_submit = assert(chat.submit, "chat.submit is required")
  local original_submit_http = chat._submit_http
  local original_submit_acp = chat._submit_acp
  local original_done = assert(chat.done, "chat.done is required")
  local original_tools_done = assert(chat.tools_done, "chat.tools_done is required")
  local original_stop = chat.stop
  local original_close = assert(chat.close, "chat.close is required")
  local state = {
    chat = chat,
    max_steps = max_steps,
    steps_used = 0,
    regular_steps_used = 0,
    empty_retry_used = false,
    correction_dispatch_pending = false,
    active_request_is_correction = false,
    terminal = nil,
    terminal_value = nil,
    final_batch_pending = false,
    final_batch_error = nil,
    active_request = false,
    active_tools = false,
    cleaned = false,
    terminal_notified = false,
  }

  local timeout_timer
  local function stop_timeout_timer()
    if timeout_timer and not timeout_timer:is_closing() then
      timeout_timer:stop()
      timeout_timer:close()
    end
    timeout_timer = nil
  end

  local function terminal_submit()
    return nil
  end
  local function terminal_done()
    return nil
  end
  local function terminal_tools_done()
    return nil
  end
  local function terminal_close()
    return nil
  end

  local function cleanup()
    if state.cleaned then
      return
    end
    state.cleaned = true
    stop_timeout_timer()
    -- Terminal methods stay installed permanently so stale scheduled callbacks
    -- cannot dispatch against a disposed child.
    chat.submit = terminal_submit
    chat.done = terminal_done
    chat.tools_done = terminal_tools_done
    chat.close = terminal_close
    if original_submit_http then
      chat._submit_http = terminal_submit
    end
    if original_submit_acp then
      chat._submit_acp = terminal_submit
    end
    if type(opts.on_cleanup) == "function" then
      pcall(opts.on_cleanup, chat)
    end
    for _, message in ipairs(chat.messages or {}) do
      if message._meta and message._meta.image_analysis then
        message.content = nil
        if message.context then
          message.context.path = nil
          message.context.mimetype = nil
          message.context.detail = nil
        end
      end
    end
    chat.messages = {}
    chat.context_items = {}
    if chat.tools then
      chat.tools.messages = chat.messages
    end
    if chat.tool_registry then
      chat.tool_registry.schemas = {}
      chat.tool_registry.in_use = {}
    end
    pcall(original_close, chat)
  end

  local function notify_and_cleanup()
    if state.terminal_notified or not state.terminal or state.active_request or state.active_tools then
      return
    end
    state.terminal_notified = true
    if type(opts.on_terminal) == "function" then
      opts.on_terminal(state.terminal, state.terminal_value, state.steps_used, max_steps)
    end
    cleanup()
  end

  local function finish(kind, value)
    if state.terminal then
      return false
    end
    stop_timeout_timer()
    state.terminal = kind
    state.terminal_value = value
    chat._maxa_image_analysis_terminal = kind
    vim.schedule(notify_and_cleanup)
    return true
  end

  local function reserve_dispatch()
    if state.terminal then
      return false
    end
    local is_correction = state.correction_dispatch_pending
    if not is_correction and state.regular_steps_used >= max_steps then
      finish("failed", "STEP_LIMIT_EXCEEDED")
      return false
    end
    state.correction_dispatch_pending = false
    state.active_request_is_correction = is_correction
    if not is_correction then
      state.regular_steps_used = state.regular_steps_used + 1
    end
    state.steps_used = state.steps_used + 1
    state.active_request = true
    return true
  end
  -- submit itself may return before dispatch (busy/no-message/no-op). Count only
  -- when MaxaAI crosses the adapter-specific dispatch boundary.
  chat.submit = function(self, submit_opts)
    if state.terminal then
      -- ToolsFinished schedules submit(callback=Tools:reset). Reset owns the
      -- tools_done boundary; suppressing it leaves active_tools latched forever.
      if not state.cleaned and submit_opts and type(submit_opts.callback) == "function" then
        local ok, err = pcall(submit_opts.callback)
        if not ok then
          state.active_tools = false
          vim.schedule(notify_and_cleanup)
        end
      end
      return nil
    end
    local ok, result = pcall(original_submit, self, submit_opts)
    if not ok then
      finish("failed", "MODEL_REQUEST_FAILED: " .. bounded(result))
      return nil
    end
    return result
  end

  if original_submit_http then
    chat._submit_http = function(self, payload)
      if not reserve_dispatch() then
        return nil
      end
      local ok, result = pcall(original_submit_http, self, payload)
      if not ok then
        state.active_request = false
        finish("failed", "MODEL_REQUEST_FAILED: " .. bounded(result))
        vim.schedule(notify_and_cleanup)
        return nil
      end
      return result
    end
  end
  if original_submit_acp then
    chat._submit_acp = function(self, payload)
      if not reserve_dispatch() then
        return nil
      end
      local ok, result = pcall(original_submit_acp, self, payload)
      if not ok then
        state.active_request = false
        finish("failed", "MODEL_REQUEST_FAILED: " .. bounded(result))
        vim.schedule(notify_and_cleanup)
        return nil
      end
      return result
    end
  end

  chat.done = function(self, output, reasoning, tools, meta, done_opts)
    state.active_request = false
    local request_was_correction = state.active_request_is_correction
    state.active_request_is_correction = false
    if state.terminal then
      -- The terminal response must still let an already-issued tool batch run;
      -- queued siblings are stopped by the scoped Orchestrator guard.
      if has_tools(tools) then
        state.active_tools = true
        local result = original_done(self, output, reasoning, tools, meta, done_opts)
        vim.schedule(notify_and_cleanup)
        return result
      end
      vim.schedule(notify_and_cleanup)
      return nil
    end

    local request_failed = self.status == "error"
    local request_stopped = done_opts and done_opts.status == "stopped"
    local issued_tools = has_tools(tools)
    if issued_tools then
      state.active_tools = true
    end
    local ok, result = pcall(original_done, self, output, reasoning, tools, meta, done_opts)
    if not ok then
      state.active_tools = false
      finish("failed", "MODEL_REQUEST_FAILED: " .. bounded(result))
      vim.schedule(notify_and_cleanup)
      return nil
    end
    if request_stopped then
      finish("cancelled", "CANCELLED")
    elseif request_failed then
      finish(
        "failed",
        "MODEL_REQUEST_FAILED: " .. bounded(self._last_http_error or self._last_error or "model request failed")
      )
    elseif issued_tools and request_was_correction then
      state.final_batch_pending = true
      state.final_batch_error = "STEP_LIMIT_EXCEEDED"
    elseif issued_tools and state.regular_steps_used >= max_steps then
      state.final_batch_pending = true
      state.final_batch_error = "STEP_LIMIT_EXCEEDED"
    elseif not issued_tools then
      local content = final_text(output)
      if content then
        finish("completed", content)
      elseif state.empty_retry_used then
        finish("failed", "FINAL_RESPONSE_REQUIRED")
      else
        state.empty_retry_used = true
        state.correction_dispatch_pending = true
        chat.messages[#chat.messages + 1] = {
          role = "user",
          content = EMPTY_RESPONSE_CORRECTION,
          _meta = { tag = "image_analysis_empty_response_correction" },
          opts = { visible = false },
        }
        local submit_ok = pcall(chat.submit, chat, { auto_submit = true })
        if not submit_ok or state.correction_dispatch_pending then
          state.correction_dispatch_pending = false
          finish("failed", "MODEL_REQUEST_FAILED: empty-response correction did not dispatch")
        end
      end
    end
    vim.schedule(notify_and_cleanup)
    return result
  end

  chat.tools_done = function(self, tools_opts)
    state.active_tools = false
    if state.terminal then
      notify_and_cleanup()
      return nil
    end
    if state.final_batch_pending then
      finish("failed", state.final_batch_error or "STEP_LIMIT_EXCEEDED")
      vim.schedule(notify_and_cleanup)
      return nil
    end
    local ok, result = pcall(original_tools_done, self, tools_opts)
    if not ok then
      finish("failed", "MODEL_REQUEST_FAILED: " .. bounded(result))
      vim.schedule(notify_and_cleanup)
      return nil
    end
    return result
  end

  chat.close = function()
    if not state.terminal then
      finish("cancelled", "CANCELLED")
    end
    return nil
  end

  function state.cancel(reason)
    finish("cancelled", "CANCELLED: " .. bounded(reason or "cancelled"))
  end

  function state.abort(reason)
    state.active_request = false
    state.active_tools = false
    finish("failed", "MODEL_REQUEST_FAILED: " .. bounded(reason))
    notify_and_cleanup()
  end

  function state.cleanup()
    state.active_request = false
    state.active_tools = false
    if not state.terminal then
      state.terminal = "failed"
      state.terminal_value = "MODEL_REQUEST_FAILED: controller cleanup"
    end
    notify_and_cleanup()
  end

  local uv = vim.uv or vim.loop
  timeout_timer = assert(uv.new_timer(), "failed to create timeout timer")
  timeout_timer:start(math.floor(timeout * 1000), 0, function()
    vim.schedule(function()
      if not finish("timed_out", string.format("image analysis exceeded %s seconds", timeout)) then
        return
      end
      if type(original_stop) == "function" then
        pcall(original_stop, chat)
      end
      state.active_request = false
      state.active_tools = false
      notify_and_cleanup()
    end)
  end)

  return state
end

return M
