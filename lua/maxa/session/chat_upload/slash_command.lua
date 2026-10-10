local upload = require("maxa.session.chat_upload")

---@class MaxaAI.SlashCommand.Upload: MaxaAI.SlashCommand
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
  upload.start(self.Chat, { context = self.context })
end

return SlashCommand
