---@class MaxaAI.Chat.ContextItem
---@field bufnr? number Buffer attached as a message, if any
---@field id string ID linking internal metadata to a message or registered tool
---@field source string Origin of the attachment
---@field opts? table

---@class MaxaAI.Chat.Context
---@field Chat MaxaAI.Chat
local Context = {}

function Context.new(args)
  return setmetatable({ Chat = args.chat }, { __index = Context })
end

---Record attachment metadata independently of the editable Chat input.
---@param item MaxaAI.Chat.ContextItem
function Context:add(item)
  if item then
    table.insert(self.Chat.context_items, item)
  end
  return self
end

return Context
