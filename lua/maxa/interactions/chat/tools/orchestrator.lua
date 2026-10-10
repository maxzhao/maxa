local Queue = require("maxa.interactions.chat.tools.runtime.queue")
local Runner = require("maxa.interactions.chat.tools.runtime.runner")
local log = require("maxa.utils.log")
local os_utils = require("maxa.utils.os")
local utils = require("maxa.utils")

local fmt = string.format

---Strip any ANSI color codes which don't render in the chat buffer
---@param tbl table
---@return table
local function strip_ansi(tbl)
  for i, v in ipairs(tbl) do
    tbl[i] = v:gsub("\027%[[0-9;]*%a", "")
  end
  return tbl
end

---Add a response to the chat buffer regarding a tool's execution
---@param exec MaxaAI.Tools.Orchestrator
---@param llm_message string
---@param user_message? string
local send_response_to_chat = function(exec, llm_message, user_message)
  exec.tools.chat:add_tool_output(exec.tool, llm_message, user_message)
end

---Execute a shell command with platform-specific handling
---@param cmd table
---@param callback function
local function execute_shell_command(cmd, callback)
  if vim.fn.has("win32") == 1 then
    -- See PR #2186
    local shell_cmd = table.concat(cmd, " ") .. "\r\nEXIT %ERRORLEVEL%\r\n"
    vim.system({ "cmd.exe", "/Q", "/K" }, {
      stdin = shell_cmd,
      env = { PROMPT = "\r\n" },
    }, callback)
  else
    vim.system(os_utils.build_shell_command(cmd), {}, callback)
  end
end

---Converts a cmd-based tool to a function-based tool.
---@param tool MaxaAI.Tools.Tool
---@return MaxaAI.Tools.Tool
local function cmd_to_func_tool(tool)
  tool.cmds = vim
    .iter(tool.cmds)
    :map(function(cmd)
      if type(cmd) == "function" then
        return cmd
      end

      local flag = cmd.flag
      cmd = cmd.cmd or cmd
      if type(cmd) == "string" then
        cmd = vim.split(cmd, " ", { trimempty = true })
      end

      ---@param tools MaxaAI.Tools
      return function(tools, _, _, cb)
        cb = vim.schedule_wrap(cb)
        execute_shell_command(cmd, function(out)
          if flag then
            tools.chat.tool_registry.flags = tools.chat.tool_registry.flags or {}
            tools.chat.tool_registry.flags[flag] = (out.code == 0)
          end

          local eol_pattern = vim.fn.has("win32") == 1 and "\r?\n" or "\n"

          if out.code == 0 then
            cb({
              status = "success",
              data = strip_ansi(vim.split(out.stdout, eol_pattern, { trimempty = true })),
            })
          else
            local combined = {}
            if out.stderr and out.stderr ~= "" then
              vim.list_extend(combined, strip_ansi(vim.split(out.stderr, eol_pattern, { trimempty = true })))
            end
            if out.stdout and out.stdout ~= "" then
              vim.list_extend(combined, strip_ansi(vim.split(out.stdout, eol_pattern, { trimempty = true })))
            end
            cb({ status = "error", data = combined })
          end
        end)
      end
    end)
    :totable()

  return tool
end

---@class MaxaAI.Tools.Orchestrator
---@field id number The id of the tools coordinator
---@field index number The index of the current command
---@field handlers table<string, function>
---@field output table<string, function>
---@field queue MaxaAI.Tools.Orchestrator.Queue
---@field status string The status of the tool execution "success" | "error"
---@field tool MaxaAI.Tools.Tool The current tool being executed
---@field tool_output table? The output collected from the tool
---@field tools MaxaAI.Tools
local Orchestrator = {}

---@param tools MaxaAI.Tools
---@param id number
function Orchestrator.new(tools, id)
  local self = setmetatable({
    id = id,
    queue = Queue.new(),
    tools = tools,
    cancelled = false,
  }, { __index = Orchestrator })
  self.cancel_handle = {
    cancel = function(reason)
      return self:cancel(reason)
    end,
  }

  return self
end

function Orchestrator:cancel(reason)
  if self.cancelled then
    return false
  end
  self.cancelled = true
  self.cancel_reason = reason or "tool batch cancelled"
  -- Input completion clears its transient view and returns the normal error
  -- result. Latch cancellation first so that callback cannot run the queue.
  local chat = self.tools and self.tools.chat
  if chat and chat._tool_input then
    require("maxa.interactions.chat.tools.input").cancel(chat, self.cancel_reason)
  end
  -- A wait/ordinary async callback may not return when stopped; settle its
  -- canonical call now. The runner's completion latch rejects any late output.
  if self.cancel_current then self.cancel_current(self.cancel_reason) end
  return true
end

---Add the tool's handlers to the executor
---@return nil
function Orchestrator:_setup_handlers()
  self.handlers = {
    setup = function()
      if not self.tool then
        return
      end
      if self.tool.handlers and self.tool.handlers.setup then
        return self.tool.handlers.setup(self.tool, self.tools)
      end
    end,
    on_exit = function()
      if not self.tool then
        return
      end

      if self.tool.handlers and self.tool.handlers.on_exit then
        return self.tool.handlers.on_exit(self.tool, self.tools)
      end
    end,
  }

  self.output = {
    error = function(cmd)
      if not self.tool then
        return
      end

      if self.tool.output and self.tool.output.error then
        self.tool.output.error(self.tool, self.tools, cmd, self.tools.stderr)
      else
        send_response_to_chat(self, fmt("Error calling `%s`", self.tool.name))
      end
    end,
    cancelled = function(cmd)
      if not self.tool then
        return
      end

      if self.tool.output and self.tool.output.cancelled then
        self.tool.output.cancelled(self.tool, self.tools, cmd)
      else
        send_response_to_chat(
          self,
          fmt("The user cancelled the execution of the %s tool", self.tool.name),
          fmt("Cancelled `%s`", self.tool.name)
        )
      end
    end,
    success = function(cmd)
      if not self.tool then
        return
      end

      if self.tool.output and self.tool.output.success then
        self.tool.output.success(self.tool, self.tools, cmd, self.tool_output or {})
      else
        send_response_to_chat(self, fmt("Executed `%s`", self.tool.name))
      end
    end,
  }
end

---When the tools coordinator is finished, finalize it via an autocmd
---@param self MaxaAI.Tools.Orchestrator
---@return nil
function Orchestrator:_finalize_tools()
  if self.tools and self.tools._flush_validation_corrections then
    self.tools:_flush_validation_corrections()
  end
  self.tools.tool = nil
  local chat = self.tools and self.tools.chat
  if chat and chat.current_tool == self.cancel_handle then
    chat.current_tool = nil
  end
  return utils.fire("ToolsFinished", { id = self.id, bufnr = self.tools.bufnr, cancelled = self.cancelled })
end

---Setup the tool to be executed
---@param input? any
---@return nil
function Orchestrator:setup_next_tool(input)
  local chat = self.tools and self.tools.chat
  if self.cancelled then
    if self.tool then
      self:finalize_tool()
    end
    self:cancel_pending_tools()
    return self:_finalize_tools()
  end
  if chat and chat._maxa_image_analysis_terminal then
    if self.tool then
      self:finalize_tool()
    end
    self:cancel_pending_tools()
    return self:_finalize_tools()
  end
  if self.queue:is_empty() then
    return self:_finalize_tools()
  end

  -- Get the next tool to run
  self.tool = self.queue:pop()
  self.tool_output = {}

  local rejection = self.tool
    and (self.tool._maxa_validation_rejection or self.tool._maxa_tool_resolution_error)
  if rejection then
    self.tools:mark_error()
    self.tools.chat:add_validation_error_output(self.tool, rejection.feedback)
    self.tool = nil
    return self:setup_next_tool()
  end

  self:_setup_handlers()
  self.handlers.setup() -- Call this early as execute needs to setup its cmds dynamically

  -- Transform cmd-based tools to func-based
  self.tool = cmd_to_func_tool(self.tool)

  -- Get the first command to run
  local cmd = self.tool.cmds[1]
  log:debug("[Orchestrator::setup_next_tool] `%s` tool", self.tool.name)

  return self:execute_tool({ cmd = cmd, input = input })
end

---Cancel all pending tools in the queue
---@return nil
function Orchestrator:cancel_pending_tools()
  local current_tool = self.tool
  while not self.queue:is_empty() do
    local pending_tool = self.queue:pop()
    self.tool = pending_tool

    local rejection = pending_tool
      and (pending_tool._maxa_validation_rejection or pending_tool._maxa_tool_resolution_error)
    if rejection then
      self.tools:mark_error()
      self.tools.chat:add_validation_error_output(pending_tool, rejection.feedback)
    else
      -- Prepare handlers/output first
      self:_setup_handlers()
      local first_cmd = pending_tool.cmds and pending_tool.cmds[1] or nil

      local ok, err = pcall(function()
        self.output.cancelled(first_cmd)
      end)
      if not ok then
        self.tool = current_tool
        return log:error("Failed to run cancelled handler for tool %s: %s", tostring(pending_tool.name), err)
      end
    end
  end
  self.tool = current_tool
end

---Execute the tool command
---@param args { cmd: function, input?: any }
---@return nil
function Orchestrator:execute_tool(args)
  utils.fire("ToolStarted", { id = self.id, tool = self.tool.name, bufnr = self.tools.bufnr })

  return Runner.new({ index = 1, orchestrator = self, cmd = args.cmd }):setup(args.input)
end

---Handle an error from a tool
---@param args { action: table, error?: any }
---@return nil
function Orchestrator:error(args)
  self.tools.status = self.tools.constants.STATUS_ERROR
  if args.error then
    table.insert(self.tools.stderr, args.error)
  end

  local ok, err = pcall(function()
    self.output.error(args.action)
  end)
  if not ok then
    if self.tool and self.tool.function_call then
      self.tools.chat:add_tool_output(
        self.tool,
        string.format("Internal error with `%s` tool: %s", self.tool.name, err)
      )
    end
  end

  self:finalize_tool()
  self:setup_next_tool()
end

---Handle a successful completion of a tool
---@param args { action: table, output?: any }
---@return nil
function Orchestrator:success(args)
  if self.tools.status ~= self.tools.constants.STATUS_ERROR then
    self.tools.status = self.tools.constants.STATUS_SUCCESS
  end

  if args.output then
    table.insert(self.tools.stdout, args.output)
    if not self.tool_output then
      self.tool_output = {}
    end
    table.insert(self.tool_output, args.output)
  end
  local ok, err = pcall(function()
    self.output.success(args.action)
  end)

  if not ok then
    log:error("Internal error with the %s success handler: %s", self.tool.name, err)
    if self.tool and self.tool.function_call then
      self.tools.chat:add_tool_output(self.tool, string.format("Internal error with `%s` tool", self.tool.name))
    end
  end
end

---Finalize the execution of the tool
---@return nil
function Orchestrator:finalize_tool()
  if self.tool then
    local tool = self.tool
    require("maxa.lifecycle.current_tool").clear(tool)
    pcall(function()
      self.handlers.on_exit()
    end)
    utils.fire("ToolFinished", { id = self.id, name = tool.name, bufnr = self.tools.bufnr })
    self.tool = nil
  end
end

return Orchestrator
