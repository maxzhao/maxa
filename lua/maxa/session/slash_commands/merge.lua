local fork_utils = require("maxa.session.slash_commands.chat_fork_utils")

---@class MaxaAI.SlashCommand.Merge: MaxaAI.SlashCommand
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
  local chat = fork_utils.get_active_scratch_chat(self.Chat)
  local ok, err = fork_utils.merge_scratch(chat)
  if not ok then
    vim.notify("[merge] " .. tostring(err), vim.log.levels.ERROR)
  end
end

return SlashCommand
