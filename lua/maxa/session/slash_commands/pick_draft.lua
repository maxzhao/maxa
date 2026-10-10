local drafts = require("maxa.project.drafts")

---@class MaxaAI.SlashCommand.PickDraft: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommandArgs
function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
end

local function format_relative_time(timestamp)
  local diff = os.time() - timestamp
  if diff < 0 then
    diff = 0
  end
  if diff < 60 then
    return diff .. "s"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h"
  else
    return math.floor(diff / 86400) .. "d"
  end
end

local function format_size(bytes)
  if bytes < 1024 then
    return bytes .. "B"
  elseif bytes < 1024 * 1024 then
    return string.format("%.1fK", bytes / 1024)
  end
  return string.format("%.1fM", bytes / 1024 / 1024)
end

local function format_entry(item)
  return string.format("%s  %s  %s", item.rel_path, format_size(item.size or 0), format_relative_time(item.mtime or 0))
end

---@param path string
---@return string[]
local function preview_lines(path)
  local file = io.open(path, "r")
  if not file then
    return { "Draft file not readable" }
  end
  local content = file:read(20000) or ""
  file:close()

  local lines = vim.split(content, "\n", { plain = true })
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    return { "(empty draft)" }
  end
  if #content >= 20000 then
    table.insert(lines, "")
    table.insert(lines, "... preview truncated ...")
  end
  return lines
end

---@param chat table
---@param items table[]
local function open_picker(chat, context, items)
  local insertion = require("maxa.interactions.chat.slash_commands.insertion")
  local confirmed = false
  require("snacks.picker").pick({
    title = "Pick Draft",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      return { { format_entry(item) } }
    end,
    transform = function(item)
      item.file = item.path
      item.text = item.rel_path
      return item
    end,
    preview = function(ctx)
      local item = ctx.item
      local buf_id = ctx.preview:scratch()
      vim.bo[buf_id].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, preview_lines(item.path))
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
  local project_root = drafts.project_root(0)
  drafts.ensure_drafts_dir(project_root)
  local items = drafts.list_files({ project_root = project_root })
  if #items == 0 then
    vim.notify("[pick_draft] No draft files found under .maxa/drafts", vim.log.levels.INFO)
    return
  end
  require("maxa.interactions.chat.slash_commands.insertion").track_context(self.Chat, self.context)
  open_picker(self.Chat, self.context, items)
end

return SlashCommand
