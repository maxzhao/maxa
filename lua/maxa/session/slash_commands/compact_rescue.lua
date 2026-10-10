local Command = {}
Command.__index = Command
function Command.new(args)
  return setmetatable({ Chat = args.Chat, context = args.context }, Command)
end
function Command:execute()
  local chat = self.Chat
  local instructions = require("maxa.session.slash_commands.compact_utils")
    .extract_slash_command_instructions(chat, self.context, "compact_rescue")
  return require("maxa.session.handoff_compaction").start(chat, nil, nil, { interactive = true, instructions = instructions })
end
return Command
