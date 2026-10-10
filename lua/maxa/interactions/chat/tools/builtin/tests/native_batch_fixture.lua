-- Test-only driver for the actual model-batch validator, scheduler and history owner.
local M = {}
local serial = 0
function M.execute(chat, args, siblings, options)
  local inventory = require("maxa.interactions.chat.tools.builtin")
  local validator = require("maxa.interactions.chat.tools.validator")
  local responses = require("maxa.adapters.http.openai_responses")
  serial = serial + 1
  chat.bufnr = chat.bufnr or vim.api.nvim_create_buf(false, true)
  chat.messages = chat.messages or {}
  chat.tool_registry = { schemas = {}, in_use = {} }
  local names = { multicall = true, run = true }
  for _, sibling in ipairs(siblings or {}) do names[sibling.name] = true end
  for _, request in ipairs(args.runs or {}) do
    if request.scope == "tool" and inventory.configs[request.command] then names[request.command] = true end
  end
  for name in pairs(names) do
    local definition = inventory.resolve(name)
    if definition then
      chat.tool_registry.in_use[name] = true
      chat.tool_registry.schemas["<tool>" .. name .. "</tool>"] = { ["function"] = {
        name = name, parameters = definition.inputSchema,
      } }
    end
  end
  local function call(name, params, index)
    return { id = "fc_fixture_" .. serial .. "_" .. index, call_id = "call_fixture_" .. serial .. "_" .. index,
      type = "function", ["function"] = { name = name, arguments = vim.json.encode(params) } }
  end
  local calls = { call("multicall", args, 0) }
  for index, sibling in ipairs(siblings or {}) do calls[#calls + 1] = call(sibling.name, sibling.args, index) end
  local message = { role = "llm", content = "", tools = { calls = calls } }
  chat.messages[#chat.messages + 1] = message
  local holder = { members = {}, outputs = {}, validation = {}, message = message }
  function chat:add_tool_output(tool, text, _, metadata)
    local id = tool.function_call.call_id or tool.function_call.id
    local output = { ok = not (metadata and metadata.is_error), text = text, call_id = id }
    holder.outputs[#holder.outputs + 1] = output
    self.messages[#self.messages + 1] = { role = "tool", content = text, tools = { call_id = id } }
    if tool.name == "multicall" then
      holder.summary = {}
      for line in text:gmatch("[^\n]+") do
        local key, value = line:match("^([a-z_]+): (.+)$")
        assert(key, "Invalid multicall summary line: " .. line)
        holder.summary[key] = tonumber(value) or value
      end
    else
      for index, item in ipairs(message.tools.calls) do
        if (item.call_id or item.id) == id then holder.members[index - 1] = output; break end
      end
    end
  end
  function chat:add_validation_error_output(_, text)
    holder.validation[#holder.validation + 1] = text
    holder.error = text
  end
  local tools = { chat = chat, bufnr = chat.bufnr, adapter = responses, tools_config = inventory.configs,
    mark_error = function() holder.failed = true end,
    _flush_validation_corrections = function() holder.closed = true end,
  }
  local plan = validator.classify_batch(tools, chat, calls)
  require("maxa.interactions.chat.tools.native_batch").execute(tools, plan, "fixture-" .. serial,
    options or { model_batch = true })
  return holder
end
return M
