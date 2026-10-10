local drafts = require("maxa.project.drafts")

---@class MaxaAI.SlashCommand.LatestDraft: MaxaAI.SlashCommand
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
  local project_root = drafts.project_root(0)
  drafts.ensure_drafts_dir(project_root)
  local latest = drafts.latest_file({ project_root = project_root })
  if not latest then
    vim.notify("[latest_draft] No draft files found under .maxa/drafts", vim.log.levels.INFO)
    return
  end
  require("maxa.interactions.chat.slash_commands.insertion").add(
    self.Chat,
    self.context,
    { content = latest.rel_path }
  )
end

return SlashCommand
