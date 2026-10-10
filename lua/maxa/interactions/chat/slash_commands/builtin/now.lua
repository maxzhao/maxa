---@class MaxaAI.SlashCommand.Now: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommand
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

---Execute the slash command
---@return nil
function SlashCommand:execute()
  require("maxa.interactions.chat.slash_commands.insertion").add(
    self.Chat,
    self.context,
    { content = os.date("%a, %d %b %Y %H:%M:%S %z") }
  )
end

return SlashCommand
