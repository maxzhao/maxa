local upload = require("maxa.session.telegram_upload")

local SlashCommand = {}

function SlashCommand.new(args)
  return setmetatable({ Chat = args.Chat, config = args.config, context = args.context }, { __index = SlashCommand })
end

function SlashCommand:execute(_)
  upload.start(self.Chat, { context = self.context })
end

return SlashCommand
