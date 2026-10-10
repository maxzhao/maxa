-- Ordered first-party Maxa Chat builtin inventory.
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")

local TOOLS = {
  { name = "analyze", module = "builtin_analyze" },
  { name = "ask", module = "builtin_ask" },
  { name = "multicall", module = "builtin_multicall" },
  { name = "kill", module = "builtin_kill" },
  { name = "delete", module = "builtin_delete" },
  { name = "edit", module = "builtin_edit" },
  { name = "run", module = "builtin_run" },
  { name = "fire", module = "builtin_fire" },
  { name = "wait", module = "builtin_wait" },
  { name = "keep", module = "builtin_keep" },
  { name = "load", module = "builtin_load" },
  { name = "move", module = "builtin_move" },
  { name = "read", module = "builtin_read" },
  { name = "write", module = "builtin_write" },
  { name = "search", module = "builtin_search" },
  { name = "glob", module = "builtin_glob" },
}

local NAMES = {}
local MODULES = {}
for _, tool in ipairs(TOOLS) do
  NAMES[#NAMES + 1] = tool.name
  MODULES[tool.name] = tool.module
end

local M = {
  names = NAMES,
  definitions = {},
  configs = {},
}

local KNOWN = {}
for _, name in ipairs(NAMES) do
  KNOWN[name] = true
end

function M.resolve(name)
  if not KNOWN[name] then
    return nil
  end
  if M.definitions[name] then
    return M.definitions[name]
  end
  local definition = require("maxa.interactions.chat.tools.builtin.tools." .. MODULES[name])
  assert(definition.name == name, string.format("builtin module %s declared name %s", name, tostring(definition.name)))
  assert(type(definition.inputSchema) == "table", "builtin " .. name .. " is missing inputSchema")
  assert(type(definition.run) == "function", "builtin " .. name .. " is missing Chat-owned run callback")
  M.definitions[name] = definition
  return definition
end

local function make_callback(name)
  local definition = M.resolve(name)
  return {
    name = name,
    cmds = {
      function(tools, args, _, output_handler)
        return adapter.execute(definition, tools, args, output_handler)
      end,
    },
    schema = {
      type = "function",
      ["function"] = {
        name = name,
        description = definition.description,
        parameters = definition.inputSchema,
        strict = false,
      },
    },
    output = {
      success = function(self, tools, _, stdout)
        local value = stdout and stdout[#stdout] or ""
        tools.chat:add_tool_output(self, tostring(value or ""))
      end,
      error = function(self, tools, _, stderr)
        local value = stderr and stderr[#stderr] or "An error occurred"
        tools.chat:add_tool_output(self, tostring(value or "An error occurred"))
      end,
    },
  }
end

for _, name in ipairs(NAMES) do
  M.configs[name] = {
    id = "maxa_builtin:" .. name,
    description = "Maxa Chat builtin: " .. name,
    hide_in_help_window = false,
    visible = false,
    callback = function()
      return make_callback(name)
    end,
  }
end

function M.apply(tools_config)
  tools_config = tools_config or {}
  for _, name in ipairs(NAMES) do
    tools_config[name] = M.configs[name]
  end
  return tools_config
end

return M
