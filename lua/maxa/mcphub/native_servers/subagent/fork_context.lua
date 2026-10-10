-- filepath: lua/maxa/mcphub/native_servers/subagent/fork_context.lua
-- Shared, side-effect-free extraction of the clean parent prefix for forked work.

local M = {}

local function find_tool_call_message(messages, tool_call_id)
  if not tool_call_id then
    return nil, 0
  end
  for index = #messages, 1, -1 do
    local message = messages[index]
    if message.role == "llm" or message.role == "assistant" then
      local calls = (message.tools and message.tools.calls) or message.tool_calls
      if calls and #calls > 0 then
        for _, call in ipairs(calls) do
          if call.id == tool_call_id then
            return index, #calls
          end
        end
      end
    end
  end
  return nil, 0
end

local function strip_pending_tool_calls(messages)
  if #messages == 0 then
    return
  end
  local last = messages[#messages]
  if last.role ~= "llm" and last.role ~= "assistant" then
    return
  end
  local had_tools = false
  if last.tools and last.tools.calls and #last.tools.calls > 0 then
    last.tools = nil
    had_tools = true
  end
  if last.tool_calls and #last.tool_calls > 0 then
    last.tool_calls = nil
    had_tools = true
  end
  if had_tools and (not last.content or last.content == "") then
    table.remove(messages)
    strip_pending_tool_calls(messages)
  end
end

---Copy the parent prefix before the assistant message that issued this tool call.
---@param parent_messages table
---@param tool_call_id string|nil
---@return table messages
---@return boolean is_batch
function M.build_clean_messages(parent_messages, tool_call_id)
  local tool_index, call_count = find_tool_call_message(parent_messages or {}, tool_call_id)
  if tool_index then
    local clean = {}
    for index = 1, tool_index - 1 do
      clean[#clean + 1] = vim.deepcopy(parent_messages[index])
    end
    return clean, call_count > 1
  end

  local clean = vim.deepcopy(parent_messages or {})
  strip_pending_tool_calls(clean)
  return clean, false
end

---Resolve the exact calling chat; never falls back to last_chat().
---@param caller table|nil
---@return table|nil chat
---@return string|nil tool_call_id
---@return string|nil error
function M.resolve_caller(caller)
  local agent = caller and caller.maxa_ai
  local chat = agent and agent.chat
  if type(chat) ~= "table" then
    return nil, nil, "caller Maxa AI chat is required"
  end
  if type(chat.messages) ~= "table" or type(chat.adapter) ~= "table" then
    return nil, nil, "caller Maxa AI chat is invalid"
  end
  local tool_call_id = agent.tool and agent.tool.function_call and agent.tool.function_call.id or nil
  return chat, tool_call_id, nil
end

M._test = { find_tool_call_message = find_tool_call_message }

return M
