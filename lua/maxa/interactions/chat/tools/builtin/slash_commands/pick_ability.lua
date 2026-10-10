local ability_utils = require("maxa.interactions.chat.tools.builtin.runtime.ability_utils")

local SlashCommand = {}

function SlashCommand.new(args)
  return setmetatable({ Chat = args.Chat, config = args.config, context = args.context }, { __index = SlashCommand })
end

local function preview_lines(ability)
  if not ability.dir then
    return { "MCP-only Ability", "", ability.description or ability.name }
  end
  local file = io.open(ability.dir .. "/SKILL.md", "r")
  if not file then
    return { "SKILL.md not found" }
  end
  local content = file:read("*a") or ""
  file:close()
  local frontmatter, body = ability_utils.parse_frontmatter(content)
  local lines = { "---", "name: " .. tostring(frontmatter and frontmatter.name or ability.name) }
  if frontmatter and frontmatter.description then
    lines[#lines + 1] = "description: " .. frontmatter.description
  end
  vim.list_extend(lines, { "---", "" })
  vim.list_extend(lines, vim.split(body or "", "\n", { plain = true }))
  return lines
end

local function open_picker(chat, context, abilities)
  local insertion = require("maxa.interactions.chat.slash_commands.insertion")
  local confirmed = false
  require("snacks.picker").pick({
    title = "Pick Ability",
    items = abilities,
    main = { file = false, float = true },
    format = function(item)
      local badge = item.source == "project" and "📁" or (item.source == "mcp" and "🔌" or "🌐")
      local description = item.description or ""
      if #description > 60 then
        description = description:sub(1, 57) .. "..."
      end
      return { { string.format("%s %s  %s", badge, item.name, description) } }
    end,
    transform = function(item)
      item.file = item.name
      item.text = item.name .. " " .. (item.description or "")
      return item
    end,
    preview = function(ctx)
      local buffer = ctx.preview:scratch()
      vim.bo[buffer].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, preview_lines(ctx.item))
    end,
    on_close = function()
      if not confirmed then
        insertion.discard_anchor(chat, context)
      end
    end,
    confirm = function(picker)
      local selections = picker:selected({ fallback = true })
      if not selections or #selections == 0 then
        return
      end
      confirmed = true
      picker:close()
      insertion.add(chat, context, { content = selections[1].name })
    end,
  })
end

function SlashCommand:execute()
  local root = vim.fs.root(0, { ".maxa" }) or vim.uv.cwd() or vim.fn.getcwd(-1, -1)
  local visible = {}
  for _, ability in ipairs(require("maxa.abilities.catalog").scan_abilities(root) or {}) do
    if ability.visibility ~= "hidden" then
      visible[#visible + 1] = ability
    end
  end
  if #visible == 0 then
    vim.notify("[ability] No Abilities found", vim.log.levels.INFO)
    return
  end
  require("maxa.interactions.chat.slash_commands.insertion").track_context(self.Chat, self.context)
  open_picker(self.Chat, self.context, visible)
end

return SlashCommand
