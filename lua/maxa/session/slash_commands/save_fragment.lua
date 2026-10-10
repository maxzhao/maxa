local fragments = require("maxa.session.chat_fragments")

---@class MaxaAI.SlashCommand.SaveFragment: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommandArgs
function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
end

---@param SlashCommands MaxaAI.SlashCommands
function SlashCommand:execute(SlashCommands)
  fragments.open_save_picker(fragments.get_active_chat(self.Chat))
end

return SlashCommand
