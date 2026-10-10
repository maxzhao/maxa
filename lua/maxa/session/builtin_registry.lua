-- Reconcile persisted tool registries with the current builtin public contract.
local M = {}

local RETIRED = {
  call = true,
  analyze_image = true,
  call_tool = true,
  call_tools_parallel = true,
  cancel_async_task = true,
  cancel = true,
  delete_items = true,
  edit_file = true,
  execute_command = true,
  execute_lua = true,
  lua = true,
  fire_event = true,
  get_async_result = true,
  invalid_call = true,
  keep_tool_result = true,
  load_context = true,
  load_server = true,
  load_skill = true,
  move_item = true,
  read_file = true,
  write_file = true,
  winrun = true,
  report = true,
  search_skill = true,
}

local function schema_name(schema)
  if type(schema) ~= "table" then
    return nil
  end
  local fn = schema["function"]
  if type(fn) == "table" and type(fn.name) == "string" then
    return fn.name
  end
  if type(schema.name) == "string" then
    return schema.name
  end
  return nil
end

function M.current()
  local config = require("maxa.config").interactions.chat.tools
  local schemas, in_use = {}, {}
  if type(config) ~= "table" then
    return schemas, in_use
  end
  for _, name in ipairs(require("maxa.interactions.chat.tools.builtin").names) do
    local tool_config = config[name]
    if tool_config and type(tool_config.callback) == "function" then
      local tool = tool_config.callback()
      if tool and type(tool.schema) == "table" then
        schemas["<tool>" .. name .. "</tool>"] = tool.schema
        in_use[name] = true
      end
    end
  end
  return schemas, in_use
end

function M.is_retired_schema(id, schema)
  local name = type(id) == "string" and id:match("^<tool>(.-)</tool>$") or nil
  name = name or schema_name(schema)
  if name == "multicall" then
    local fn = type(schema) == "table" and schema["function"] or nil
    local parameters = fn and fn.parameters or type(schema) == "table" and (schema.parameters or schema.inputSchema)
    local properties = parameters and parameters.properties or {}
    return properties.title == nil or properties.calls ~= nil or properties.async ~= nil
  end
  return type(name) == "string" and RETIRED[name] == true
end
function M.reconcile(_, _)
  -- Hard-cut restore installs the exact current first-party inventory. Persisted
  -- loader or MCP schemas remain historical transcript data, never registry aliases.
  return M.current()
end

function M.apply(chat, schemas, in_use)
  if not chat or not chat.tool_registry then
    return false
  end
  chat.tool_registry.schemas, chat.tool_registry.in_use = M.reconcile(schemas, in_use)
  return true
end
return M
