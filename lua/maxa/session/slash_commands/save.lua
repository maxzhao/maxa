local fork_utils = require("maxa.session.slash_commands.chat_fork_utils")

---@class MaxaAI.SlashCommand.SaveScratch: MaxaAI.SlashCommand
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
  local result, err = fork_utils.save_scratch_chat(chat)
  if not result then
    vim.notify("[save] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("[save] Scratch saved to history: %s", result.save_id), vim.log.levels.INFO)
end

return SlashCommand
