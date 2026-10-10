---@class MaxaAI.Tools
---@field adapter MaxaAI.HTTPAdapter The adapter in use for the chat
---@field aug number The augroup for the tool
---@field bufnr number The buffer of the chat buffer
---@field constants table<string, string> The constants for the tool
---@field chat MaxaAI.Chat The chat buffer that initiated the tool
---@field extracted table The extracted tools from the LLM's response
---@field messages table The messages in the chat buffer
---@field status string The status of the tool
---@field stdout table The stdout of the tool
---@field stderr table The stderr of the tool
---@field tool MaxaAI.Tools.Tool The current tool that's being run
---@field tools_config table The available tools for the tool system
---@field tools_ns number The namespace for the virtual text that appears in the header

local Orchestrator = require("maxa.interactions.chat.tools.orchestrator")
local display = require("maxa.interactions.chat.tools.display")
local buffer_guard = require("maxa.interactions.chat.ui.buffer_guard")
local tool_filter = require("maxa.interactions.chat.tools.filter")

local config = require("maxa.config")
local log = require("maxa.utils.log")
local ui_utils = require("maxa.utils.ui")
local utils = require("maxa.utils")

local api = vim.api

local CONSTANTS = {
  NS_TOOLS = "MaxaAI-tools",
  AUTOCMD_GROUP = "maxa.ai.tools",

  STATUS_ERROR = "error",
  STATUS_SUCCESS = "success",
}

---@class MaxaAI.Tools
local Tools = {}

-- Private helper methods

---@param name string
---@return string
function Tools:_unavailable_tool_message(name)
  local available_tools_msg = ""
  if self.chat and self.chat.tool_registry and self.chat.tool_registry.in_use then
    local available_tools = vim.tbl_keys(self.chat.tool_registry.in_use)
    if next(available_tools) then
      available_tools_msg = "The available tools are: "
        .. table.concat(
          vim.tbl_map(function(t)
            return "`" .. t .. "`"
          end, available_tools),
          ", "
        )
    else
      available_tools_msg = "No tools available"
    end
  else
    available_tools_msg = "No tools available"
  end

  return string.format("Tool `%s` not found. %s", name, available_tools_msg)
end

---Handle missing or invalid tool errors
---@param tool table The tool that failed
---@param error_message string The error message
---@return nil
function Tools:_handle_tool_error(tool, error_message)
  local name = tool["function"].name
  local tool_call = vim.deepcopy(tool)
  tool_call.name = name
  tool_call.function_call = tool_call

  log:error(error_message)
  self:mark_error()
  self.chat:add_tool_output(tool_call, self:_unavailable_tool_message(name), "")
  return utils.fire("ToolsFinished", { bufnr = self.bufnr })
end

---Resolve and prepare a tool for execution
---@param tool table The tool call from the LLM
---@param id number The execution ID for event firing
---@return table|nil The resolved tool or nil if failed
---@return string|nil Error message if resolution failed
---@return boolean|nil Whether this is a JSON parsing error that needs special handling
function Tools:_resolve_and_prepare_tool(tool, id)
  local name = tool["function"].name
  local tool_config = self.tools_config[name]

  -- Allow for hybrid tools that use an adapter's tool alongside a MaxaAI tool
  if tool_config and tool_config._adapter_tool == true and tool_config._has_client_tool then
    tool_config = utils.resolve_nested_value(config, tool_config.opts.client_tool)
  end

  if not tool_config then
    return nil, string.format("Couldn't find the tool `%s`", name), false
  end

  local ok, resolved_tool = pcall(function()
    return Tools.resolve(tool_config)
  end)

  if not ok or not resolved_tool then
    log:debug("Tool resolution failed for `%s`: %s", name, resolved_tool)
    return nil, string.format("Couldn't resolve the tool `%s`", name), false
  end

  -- NOTE: We deepcopy here to avoid mutating the original tool definition which
  -- has disastrous side effects.
  local prepared_tool = vim.deepcopy(resolved_tool)
  prepared_tool.name = name
  prepared_tool.function_call = tool

  -- Parse and set arguments - handle JSON errors specially like the original code
  if tool["function"].arguments then
    local args = tool["function"].arguments
    -- For some adapter's that aren't streaming, the args are strings rather than tables
    if type(args) == "string" then
      if args == "" then
        args = "{}"
      end
      local ok, decoded = pcall(vim.json.decode, args)
      if not ok then
        log:error("Couldn't decode the tool arguments: %s", args)
        self.chat:add_tool_output(
          prepared_tool,
          string.format('You made an error in calling the %s tool: "%s"', name, decoded),
          ""
        )
        self.status = CONSTANTS.STATUS_ERROR
        utils.fire("ToolsFinished", { id = id, bufnr = self.bufnr })
        return nil, "JSON parsing failed", true -- Special flag to indicate this was handled
      end

      args = decoded
    end
    prepared_tool.args = args
  end

  -- Merge options
  prepared_tool.opts = vim.tbl_extend("force", prepared_tool.opts or {}, tool_config.opts or {})

  -- Handle environment variables
  if prepared_tool.env then
    local env = type(prepared_tool.env) == "function" and prepared_tool.env(vim.deepcopy(prepared_tool)) or {}
    utils.replace_placeholders(prepared_tool.cmds, env)
  end

  if self.bufnr then
    local message_count = self.chat and #self.chat.messages or nil
    local call = prepared_tool.function_call
    display.push_pending_tool(self.bufnr, prepared_tool.name, prepared_tool.args or {}, message_count,
      call and (call.call_id or call.id))
    if call and (call.call_id or call.id) and self.chat then
      display.create_ui(self.chat, call.call_id or call.id, prepared_tool.name, prepared_tool.args, prepared_tool)
    end
  end
  return prepared_tool, nil, false
end

-- Public interface methods

---@param args table
function Tools.new(args)
  local self = setmetatable({
    adapter = args.adapter,
    aug = api.nvim_create_augroup(CONSTANTS.AUTOCMD_GROUP .. ":" .. args.bufnr, { clear = true }),
    bufnr = args.bufnr,
    chat = {},
    constants = CONSTANTS,
    extracted = {},
    messages = args.messages,
    stdout = {},
    stderr = {},
    tool = nil,
    tools_config = tool_filter.filter_enabled_tools(config.interactions.chat.tools, { adapter = args.adapter }),
    tools_ns = api.nvim_create_namespace(CONSTANTS.NS_TOOLS),
  }, { __index = Tools })

  -- Listen for any adapter and model changes on the chat buffer and update the available tools
  api.nvim_create_autocmd("User", {
    group = api.nvim_create_augroup(CONSTANTS.AUTOCMD_GROUP .. ".list:" .. args.bufnr, { clear = true }),
    pattern = "MaxaAIChatModel",
    callback = function(autocmd_args)
      if autocmd_args.data.bufnr ~= self.bufnr then
        return
      end
      self.tools_config =
        tool_filter.filter_enabled_tools(config.interactions.chat.tools, { adapter = autocmd_args.data.adapter })
    end,
  })

  return self
end

---Refresh the tools configuration to pick up any dynamically added tools
---@param opts? table Options for refreshing the tools
---@return MaxaAI.Tools
function Tools:refresh(opts)
  opts = opts or {}
  self.tools_config = tool_filter.filter_enabled_tools(config.interactions.chat.tools, opts)
  return self
end

---Set the autocmds for the tool
---@return nil
function Tools:set_autocmds()
  api.nvim_create_autocmd("User", {
    desc = "Handle responses from the Tool system",
    group = self.aug,
    pattern = "MaxaAITools*",
    callback = function(request)
      if request.data.bufnr ~= self.bufnr then
        return
      end

      if request.match == "MaxaAIToolsStarted" then
        log:info("[Tool System] Initiated")
        -- Call-scoped presentation owns progress (including tools that suppress
        -- it for input). Never add a second batch overlay beneath the draft.
        ui_utils.clear_notification(self.bufnr, { namespace = CONSTANTS.NS_TOOLS .. "_" .. tostring(self.bufnr) })
      elseif request.match == "MaxaAIToolsFinished" then
        local cancelled = request.data and request.data.cancelled == true
        local execution_complete = self._execution_complete
        self._execution_complete = nil
        return vim.schedule(function()
          if self.chat._closed then
            return
          end
          if not buffer_guard.valid(self.bufnr) then
            buffer_guard.abort(self.chat, "Tool continuation buffer is unavailable")
            return
          end
          if self.chat._session_handoff and self.chat._session_handoff.phase == "scheduled" then
            local failed = self.status == CONSTANTS.STATUS_ERROR or cancelled
            require("maxa.interactions.chat.tools.builtin.runtime.context_injector").flush(self.chat)
            self:reset({ auto_submit = false })
            require("maxa.mcphub.native_servers.subagent.session_handoff").after_tools(self.chat, failed)
            return
          end
          if self.chat._handoff_compaction_runner then
            require("maxa.interactions.chat.tools.builtin.runtime.context_injector").flush(self.chat)
            local failed = self.status == CONSTANTS.STATUS_ERROR or cancelled
            if require("maxa.session.handoff_compaction").after_tools(self.chat, failed) then
              self:reset({ auto_submit = false })
              return
            end
          end
          if execution_complete then
            local failed = self.status == CONSTANTS.STATUS_ERROR or cancelled
            require("maxa.interactions.chat.tools.builtin.runtime.context_injector").flush(self.chat)
            self:reset({ auto_submit = false })
            return execution_complete(not failed, cancelled and "tool execution cancelled" or nil)
          end
          local auto_submit = function()
            return self.chat:submit({
              auto_submit = true,
              callback = function()
                self:reset({ auto_submit = true })
              end,
            })
          end

          if cancelled then
            local decision = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
            if
              decision
              and type(decision.should_resume_cancelled_tool_batch) == "function"
              and decision.should_resume_cancelled_tool_batch(self.chat)
            then
              return auto_submit()
            end
            return self:reset({ auto_submit = false })
          end
          if self.status == CONSTANTS.STATUS_ERROR and self.tools_config.opts.auto_submit_errors then
            return auto_submit()
          end
          if self.status == CONSTANTS.STATUS_SUCCESS and self.tools_config.opts.auto_submit_success then
            return auto_submit()
          end

          self:reset({ auto_submit = false })
          utils.fire("ChatDone", { bufnr = self.bufnr, id = self.chat.id })
        end)
      end
    end,
  })
end

function Tools:mark_error()
  self.status = CONSTANTS.STATUS_ERROR
end

function Tools:_flush_validation_corrections()
  local corrections = self._validation_corrections or {}
  self._validation_corrections = nil
  for _, entry in ipairs(corrections) do
    self.chat:add_message({
      role = config.constants.USER_ROLE,
      content = entry.feedback,
    }, { visible = false })
  end
end

---Execute the tool in the chat buffer based on the LLM's response
---@param chat MaxaAI.Chat
---@param validation_plan table Validation plan or a raw call list for legacy callers
---@param opts? table { on_complete?: fun(success: boolean, error?: string) } suppresses model auto-submit
---@return nil
function Tools:execute(chat, validation_plan, opts)
  local id = math.random(10000000)
  self.chat = chat
  self._execution_complete = opts and opts.on_complete or nil
  -- Each batch starts successful; validation/member failures latch errors below.
  self.status = CONSTANTS.STATUS_SUCCESS

  local validator = require("maxa.interactions.chat.tools.validator")
  if type(validation_plan) ~= "table" or type(validation_plan.entries) ~= "table" then
    validation_plan = validator.classify_batch(self, chat, type(validation_plan) == "table" and validation_plan or {})
  end
  self._validation_corrections = validation_plan.corrections or {}
  if #self._validation_corrections > 0 then
    self:mark_error()
  end

  local ok_batch, batch = pcall(require, "maxa.lifecycle.tool_calls_completed_event")
  if ok_batch and batch and batch.start_batch then
    batch.start_batch(chat, validation_plan)
  end
  validator.fire_errors(validation_plan, chat and chat.bufnr or nil)

  local orchestrator
  local function safe_execute()
    -- NOTE: Set autocmds early so that errors can be handled properly
    self:set_autocmds()

    if validation_plan.native_batch then
      return require("maxa.interactions.chat.tools.native_batch").execute(self, validation_plan, id, opts)
    end

    orchestrator = Orchestrator.new(self, id)

    for _, entry in ipairs(validation_plan.entries) do
      if entry.kind == "valid" then
        local resolved_tool, error_msg, is_json_error = self:_resolve_and_prepare_tool(entry.call, id)

        if not resolved_tool then
          local name = entry.tool_name or ""
          local message = is_json_error and (error_msg or "Tool arguments could not be decoded")
            or self:_unavailable_tool_message(name)
          orchestrator.queue:push({
            _maxa_tool_resolution_error = { feedback = message },
            name = name,
            function_call = entry.call,
          })
        else
          self.tool = resolved_tool --[[@as MaxaAI.Tools.Tool]]
          orchestrator.queue:push(resolved_tool)
        end
      elseif entry.kind == "rejected_replayable" then
        orchestrator.queue:push({
          _maxa_validation_rejection = entry,
          name = entry.tool_name,
          function_call = entry.call,
          validation_snapshot = entry.snapshot,
        })
      end
    end

    chat.current_tool = orchestrator.cancel_handle
    local decision = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
    if
      decision
      and type(decision.should_cancel_tool_batch) == "function"
      and decision.should_cancel_tool_batch(chat)
    then
      orchestrator:cancel("token finish budget exhausted")
    end
    utils.fire("ToolsStarted", { id = id, bufnr = self.bufnr })
    orchestrator:setup_next_tool()
  end

  local ok, err = pcall(safe_execute)
  if not ok then
    log:error("chat::tools::init::execute - Execution error %s", err)
    self.status = CONSTANTS.STATUS_ERROR
    if orchestrator and chat.current_tool == orchestrator.cancel_handle then
      chat.current_tool = nil
    end
    self:_flush_validation_corrections()
    vim.schedule(function()
      utils.fire("ToolsFinished", { id = id, bufnr = self.bufnr })
    end)
  end
end

---Reset the Tools class
---@param opts? table
---@return nil
function Tools:reset(opts)
  opts = opts or {}

  ui_utils.clear_notification(self.bufnr, { namespace = CONSTANTS.NS_TOOLS .. "_" .. tostring(self.bufnr) })

  api.nvim_clear_autocmds({ group = self.aug })

  self.extracted = {}
  self.tool = nil
  self._validation_corrections = nil
  self.status = CONSTANTS.STATUS_SUCCESS
  self.stderr = {}
  self.stdout = {}

  self.chat:tools_done(opts)
  log:info("[Tools] Completed")
end

---Add an error message to the chat buffer
---@param error string
---@return MaxaAI.Tools
function Tools:add_error_to_chat(error)
  self.chat:add_message({
    role = config.constants.USER_ROLE,
    content = error,
  }, { visible = false })

  --- Alert the user that the error message has been shared
  self.chat:add_buf_message({
    role = config.constants.USER_ROLE,
    content = "Please correct for the error message I've shared",
  })

  if self.tools_config.opts and self.tools_config.opts.auto_submit_errors then
    self.chat:submit()
  end

  return self
end

---Resolve a tool from the config
---@param tool table The tool from the config
---@return MaxaAI.Tools.Tool|nil
function Tools.resolve(tool)
  local callback = tool.callback

  if type(callback) == "table" then
    return callback --[[@as MaxaAI.Tools.Tool]]
  end

  if type(callback) == "function" then
    return callback() --[[@as MaxaAI.Tools.Tool]]
  end

  local ok, module = pcall(require, "maxa." .. callback)
  if ok then
    log:debug("[Tools] %s identified", callback)
    return module
  end

  -- Try loading the tool from the user's config using a module path
  ok, module = pcall(require, callback)
  if ok then
    log:debug("[Tools] %s identified", callback)
    return module
  end

  -- Try loading the tool from the user's config using a file path
  local err
  module, err = loadfile(vim.fs.normalize(callback))
  if err then
    return log:error("[Tools] Failed to load tool from %s: %s", callback, err)
  end

  if module then
    log:debug("[Tools] %s identified", callback)
    return module()
  end

  return nil
end

return Tools
