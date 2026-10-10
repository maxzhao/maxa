local fork_utils = require("maxa.session.slash_commands.chat_fork_utils")

---@class MaxaAI.SlashCommand.Fork: MaxaAI.SlashCommand
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
  local child, err = fork_utils.fork_current_chat(chat, { scratch = false })
  if not child then
    vim.notify("[fork] " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("[fork] Created chat fork: %s", child.opts and child.opts.save_id or "(no save_id)"), vim.log.levels.INFO)
end

return SlashCommand
