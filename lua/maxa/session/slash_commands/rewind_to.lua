local fork_utils = require("maxa.session.slash_commands.chat_fork_utils")

---@class MaxaAI.SlashCommand.RewindTo: MaxaAI.SlashCommand
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
  fork_utils.open_rewind_to_picker(fork_utils.get_active_chat(self.Chat))
end

return SlashCommand
