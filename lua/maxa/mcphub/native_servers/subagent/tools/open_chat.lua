-- Cursor-local SubAgent navigation uses logical provenance, never summary text.
local M = {}
local targets = {
  ["@subagent:run_agent"] = true,
  ["@subagent:fork_agent"] = true,
  ["@subagent:resume_agent"] = true,
  subagent__run_agent = true,
  subagent__fork_agent = true,
  subagent__resume_agent = true,
}

local function object(value)
  if type(value) == "table" then return value end
  if type(value) ~= "string" then return nil end
  local ok, decoded = pcall(vim.json.decode, value)
  return ok and type(decoded) == "table" and decoded or nil
end

local function target(name, args)
  return targets[name] or name == "run" and args and args.scope == "tool" and targets[args.command]
end

local function returned_id(value)
  local data = object(value)
  if not data then return nil end
  return data.save_id or data.context_status and data.context_status.save_id or returned_id(data.result)
end

local function notify(message)
  vim.notify("[Chat] " .. message, vim.log.levels.INFO)
end

local float = { layout = "float", relative = "editor", width = 0.8, height = 0.8 }

function M.open_live(child)
  if not child or child._closed or not vim.api.nvim_buf_is_valid(child.bufnr) then return end
  if require("maxa.session.agent_identity").is_main(child) then
    child.opts.preserve_main = true
    if child.ui:is_visible() and child.ui.winnr and vim.api.nvim_win_get_config(child.ui.winnr).relative == "" then child.ui:hide() end
  end
  child.ui:open({ window_opts = float })
  if child.ui.winnr and vim.api.nvim_win_is_valid(child.ui.winnr) then vim.api.nvim_set_current_win(child.ui.winnr) end
  return child
end

function M.open(chat, message, origin)
  if not message or not origin then return notify("Place the cursor on a SubAgent tool display.") end
  local call_id = origin.call_id or message.tools and message.tools.call_id
  if not call_id then return notify("Place the cursor on a SubAgent tool display.") end
  local call
  for _, msg in ipairs(chat.messages or {}) do
    for _, candidate in ipairs(msg.tools and msg.tools.calls or {}) do
      if (candidate.call_id or candidate.id) == call_id then call = candidate; break end
    end
    if call then break end
  end
  if not call or not call["function"] then return notify("No tool invocation at the cursor.") end
  local fn = call["function"]
  local args = object(fn.arguments) or {}
  local supported = target(fn.name, args)
  -- During wait the source invocation is not the wait's canonical call.
  local id = origin.related_chat_id
  if not supported and not (fn.name == "wait" and id) then
    return notify("Opening a tool window currently supports SubAgents only.")
  end
  local async_id
  for _, msg in ipairs(chat.messages or {}) do
    if msg.tools and msg.tools.call_id == call_id and msg.role == "tool" then
      id = id or msg._meta and msg._meta.presentation and msg._meta.presentation.related_chat_id
        or returned_id(msg.content)
      local result = object(msg.content)
      if result and result.async_id then
        local task = require("maxa.interactions.chat.tools.builtin.runtime.async_registry").get(result.async_id)
        async_id = result.async_id
        local sink = task and task._presentation
        local item = sink and sink._snapshot and sink:_snapshot()
        id = id or item and item.related_chat_id or returned_id(task and task.result)
      end
      break
    end
  end
  local Chat = require("maxa.interactions.chat")
  for _, entry in ipairs(Chat.buf_get_chat()) do
    local child = entry.chat
    local owner = child._tool_display_owner
    if id and child.opts.save_id == id
      or owner and owner.chat == chat and (owner.call_id == call_id or owner.call_id == async_id) and owner.member == origin.member then
      return M.open_live(child)
    end
  end
  for _, msg in ipairs(chat.messages or {}) do
    if msg.tools and msg.tools.call_id == call_id and msg.role == "tool" then
      id = id or msg._meta and msg._meta.presentation and msg._meta.presentation.related_chat_id
        or returned_id(msg.content, origin.member)
      break
    end
  end
  if not id and async_id then
    for _, msg in ipairs(chat.messages or {}) do
      if msg.role == "tool" then
        local result = object(msg.content)
        if result and result.async_id == async_id then id = returned_id(result, origin.member) or id end
      end
    end
  end
  if type(id) ~= "string" or id == "" or id:find("[/\\]") then
    return notify("This SubAgent has no live Chat or recoverable history.")
  end
  local history = require("maxa.session.history").exports
  local data = history.load_chat(id)
  if not data then return notify("SubAgent history is unavailable: " .. id) end
  -- Opening through a SubAgent invocation always floats, even if in-place resume
  -- preserved a historical main identity. Neither saved ancestry nor execution changes.
  local restored = history.create_chat(data, { window_opts = float, preserve_main = true })
  if not restored then return notify("Could not restore SubAgent history.") end
  return restored
end

return M
