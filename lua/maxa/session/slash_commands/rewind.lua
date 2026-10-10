local fork_utils = require("maxa.session.slash_commands.chat_fork_utils")

---@class MaxaAI.SlashCommand.Rewind: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommandArgs
function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
end

local function notify(msg, level)
  vim.notify("[session] " .. msg, level or vim.log.levels.INFO)
end

---@param SlashCommands MaxaAI.SlashCommands
function SlashCommand:execute(SlashCommands)
  local ok, result = fork_utils.rewind_current_chat(fork_utils.get_active_chat(self.Chat))
  if not ok then
    notify("rewind failed: " .. tostring(result), vim.log.levels.ERROR)
    return
  end
  notify(string.format("rewound %d message(s); restored user input from [%d]", result.removed_count or 0, result.index or 0))
end

return SlashCommand
