local specs = require("maxa.project.specs")

---@class MaxaAI.SlashCommand.PickSpec: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommandArgs
function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
end

---@param chat table
---@param items table[]
local function open_picker(chat, context, items)
  local insertion = require("maxa.interactions.chat.slash_commands.insertion")
  local confirmed = false
  require("snacks.picker").pick({
    title = "Pick Spec",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      return { { specs.format_entry(item) } }
    end,
    transform = function(item)
      item.file = item.path
      item.text = item.text or item.rel_path
      return item
    end,
    preview = function(ctx)
      local item = ctx.item
      local buf_id = ctx.preview:scratch()
      vim.bo[buf_id].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, specs.preview_lines(item))
    end,
    on_close = function()
      if not confirmed then insertion.discard_anchor(chat, context) end
    end,
    confirm = function(picker, _)
      local selections = picker:selected({ fallback = true })
      if not selections or #selections == 0 then
        return
      end
      confirmed = true
      picker:close()
      insertion.add(chat, context, { content = selections[1].rel_path })
    end,
  })
end

---@param SlashCommands MaxaAI.SlashCommands
function SlashCommand:execute(SlashCommands)
  if type(self.Chat) ~= "table" or type(self.Chat.add_buf_message) ~= "function" then
    vim.notify("[pick_spec] Active chat is not available", vim.log.levels.ERROR)
    return
  end

  local project_root = specs.project_root(0)
  local specs_dir = specs.specs_dir(project_root)
  local stat = vim.uv.fs_stat(specs_dir)
  if not stat or stat.type ~= "directory" then
    vim.notify("[pick_spec] No .maxa/specs directory found", vim.log.levels.INFO)
    return
  end

  local items = specs.list_items({ project_root = project_root })
  if #items == 0 then
    vim.notify("[pick_spec] No spec files found under .maxa/specs", vim.log.levels.INFO)
    return
  end
  require("maxa.interactions.chat.slash_commands.insertion").track_context(self.Chat, self.context)
  open_picker(self.Chat, self.context, items)
end

return SlashCommand
