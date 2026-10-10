-- Private invocation/result helpers for first-party Maxa Chat builtins.
local M = {}

local function encode_resource(resource)
  local ok, encoded = pcall(vim.json.encode, resource)
  return ok and encoded or vim.inspect(resource)
end

function M.content_to_result(content)
  local parts = {}
  for _, item in ipairs(content or {}) do
    if item.type == "text" then
      table.insert(parts, tostring(item.text or ""))
    elseif item.type == "resource" then
      table.insert(parts, "MCP resource: " .. encode_resource(item.resource))
    end
  end
  return table.concat(parts, "\n")
end

local Result = {}
Result.__index = Result

function Result.new(done)
  return setmetatable({ done = done, content = {}, sent = false }, Result)
end

function Result:text(text)
  if type(text) ~= "string" then
    text = vim.inspect(text)
  end
  table.insert(self.content, { type = "text", text = text })
  return self
end

function Result:resource(resource)
  table.insert(self.content, { type = "resource", resource = resource })
  return self
end

function Result:send()
  if self.sent then
    return nil
  end
  self.sent = true
  return self.done({ ok = true, content = self.content })
end

function Result:error(message, details)
  if self.sent then
    return nil
  end
  self.sent = true
  if type(message) ~= "string" then
    message = vim.inspect(message)
  end
  if details ~= nil then
    message = message .. "\nDetails: " .. vim.inspect(details)
  end
  return self.done({ ok = false, error = message })
end

local function invocation_from_tools(tools, args, definition)
  local chat = tools and tools.chat or nil
  local tool = tools and tools.tool or nil
  local function_call = tool and tool.function_call or nil
  if type(chat) ~= "table" or type(tool) ~= "table" or type(function_call) ~= "table" then
    return nil, "exact Chat invocation/tool-call context is unavailable"
  end
  local cwd = chat.opts and chat.opts.cwd or nil
  if type(cwd) ~= "string" or cwd == "" then
    return nil, "exact Chat project working directory is unavailable"
  end
  local agent = { chat = chat, tool = tool, bufnr = chat.bufnr }
  return {
    params = args or {},
    display_args = vim.deepcopy(args or {}),
    ui = require("maxa.interactions.chat.tools.display").create_ui(
      chat, function_call.call_id or function_call.id, tool.name, args, definition),
    chat = chat,
    bufnr = chat.bufnr,
    cwd = cwd,
    project_root = chat.opts and chat.opts.project_root or nil,
    save_id = (chat.opts and chat.opts.save_id) or chat.save_id,
    tool = tool,
    tool_name = tool.name,
    tool_call_id = function_call.call_id or function_call.id,
    active_wrappers = {},
    caller = {
      type = "maxa_ai",
      maxa_ai = agent,
      context = { bufnr = chat.bufnr },
    },
  }
end

function M.child_context(parent, tool_name, params)
  local child = vim.tbl_extend("force", {}, parent or {})
  child.params = params or {}
  child.display_args = vim.deepcopy(params or {})
  child.tool_name = tool_name
  child.active_wrappers = vim.deepcopy((parent and parent.active_wrappers) or {})
  child.active_extensions = vim.deepcopy((parent and parent.active_extensions) or {})
  if tool_name == "run" and child.params.scope == "tool" then
    child.active_wrappers[tool_name] = true
  end
  return child
end

function M.prepare(definition, context)
  if definition.inputSchema and not context.ability_script then
    local schema = definition.inputSchema
    if definition.name == "run" and context.run_member then
      schema = vim.deepcopy(schema)
      schema.required = vim.tbl_filter(function(key) return key ~= "title" end, schema.required or {})
      schema.properties.title.type = { "string", "null" }
    end
    local validator = require("maxa.interactions.chat.tools.schema_validation")
    local valid, err = validator.validate(schema, context.params, { object_root = true })
    if not valid then return nil, validator.format_error(err) end
  end
  if definition.prepare ~= nil then
    if type(definition.prepare) ~= "function" then
      return nil, definition.name .. ": prepare must be a function"
    end
    local ok, params, err = pcall(definition.prepare, context)
    if not ok then
      return nil, definition.name .. ": preparation failed: " .. tostring(params)
    end
    if err ~= nil then
      return nil, definition.name .. ": " .. tostring(err)
    end
    if type(params) ~= "table" then
      return nil, definition.name .. ": prepare must return a parameter table"
    end
    context = vim.tbl_extend("force", {}, context)
    context.params = params
  end
  return context
end

function M.invoke(definition, context, done, prepared)
  local result = Result.new(done)
  if not prepared then
    local ready, err = M.prepare(definition, context)
    if not ready then return result:error(err) end
    context = ready
  end
  local selected, extension, extension_err = pcall(
    require("maxa.interactions.chat.tools.builtin.runtime.extensions").select,
    definition.name,
    context
  )
  if not selected then
    return result:error(extension)
  end
  if extension_err then
    return result:error(extension_err)
  end
  local run = definition.run
  if extension then
    if context.active_extensions and context.active_extensions[extension.key] then
      return result:error(extension.prefix .. "recursive extension dispatch is not allowed")
    end
    context = vim.tbl_extend("force", {}, context)
    context.active_extensions = vim.deepcopy(context.active_extensions or {})
    context.active_extensions[extension.key] = true
    run = extension.run
    result.done = function(output)
      local core = require("maxa.interactions.chat.tools.builtin.runtime.tool_call_core")
      if output.ok then
        if definition.name == "read" and #M.content_to_result(output.content) > 20000 then
          return done({ ok = false, error = extension.prefix .. "read extension exceeded the 20,000-byte result limit" })
        end
        for _, item in ipairs(output.content or {}) do
          if item.type == "text" and definition.name ~= "read" then
            item.text = core.handle_output_limit(item.text, definition.name)
          end
        end
      else
        output.error = core.handle_error_output_limit(extension.prefix .. output.error, definition.name)
      end
      return done(output)
    end
  end
  local ok, returned = pcall(run, context, result)
  if not ok then
    return result:error(returned)
  end
  if returned ~= nil and not result.sent then
    return result:text(returned):send()
  end
  return returned
end

function M.execute(definition, tools, args, output_handler)
  local context, context_err = invocation_from_tools(tools, args, definition)
  if not context then
    return { status = "error", data = context_err }
  end
  if definition.name == "run" and args and args.scope == "tool" then
    context.active_wrappers[definition.name] = true
  end

  local completed = false
  local synchronous = true
  local sync_output = nil
  local function finish(result)
    if completed then
      return nil
    end
    completed = true
    local message = result.ok
        and { status = "success", data = M.content_to_result(result.content) }
      or { status = "error", data = tostring(result.error or "An error occurred") }
    if synchronous then
      sync_output = message
      return message
    end
    return output_handler(message)
  end

  M.invoke(definition, context, finish)
  synchronous = false
  return sync_output
end

M.Result = Result
M.invocation_from_tools = invocation_from_tools

return M
