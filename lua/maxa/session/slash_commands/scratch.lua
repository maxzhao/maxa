local fork_utils = require("maxa.session.slash_commands.chat_fork_utils")

---@class MaxaAI.SlashCommand.Scratch: MaxaAI.SlashCommand
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
  local chat = fork_utils.get_active_chat(self.Chat)
  local child, err = fork_utils.fork_current_chat(chat, { scratch = true })
  if not child then
    vim.notify("[scratch] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("[scratch] Created temporary chat (history disabled)", vim.log.levels.INFO)
end

return SlashCommand
