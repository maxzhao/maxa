local catalog = require("maxa.abilities.catalog")
local util = require("maxa.prompts.runtime")

local Souls = {}
Souls.__index = Souls

function Souls.new(args)
  return setmetatable({ Chat = args.Chat }, Souls)
end

local function fail(message)
  vim.notify("/souls: " .. message, vim.log.levels.ERROR)
  return false
end

function Souls:execute()
  local chat = self.Chat
  if not chat or not chat.replace_soul then
    return fail("No active Chat")
  end
  if chat.current_request then
    return fail("Cannot change Soul while a Chat request is in progress")
  end
  local root = chat.opts and chat.opts.project_root or vim.fn.getcwd()
  local ability, err = catalog.resolve("agency-nexus", root)
  if not ability then
    return fail("Cannot resolve agency-nexus: " .. tostring(err))
  end

  local choices = {}
  local seen = {}
  for _, entries in ipairs({ ability.files or {}, ability.hidden_references or {} }) do
    for target in pairs(entries) do
      if target:match("^/agents/[^/]+/[^/]+%.md$") and not seen[target] then
        seen[target] = true
        choices[#choices + 1] = { target = target, reference = catalog.format_reference("agency-nexus", target) }
      end
    end
  end
  table.sort(choices, function(a, b) return a.target < b.target end)
  if #choices == 0 then
    return fail("No Agency role Markdown files are available")
  end

  vim.ui.select(choices, {
    prompt = "Select an Agency Soul",
    format_item = function(item) return item.target:sub(#"/agents/" + 1) end,
  }, function(selected)
    if not selected then return end
    if not seen[selected.target] then
      return fail("Invalid Agency Soul selection")
    end
    local entry, file_err = catalog.resolve_file(ability, selected.target)
    if not entry then
      return fail(tostring(file_err))
    end
    local ok, content = pcall(util.ResolveSoul, {
      project_root = root,
      cwd = chat.opts and chat.opts.cwd,
    }, { soul = selected.reference })
    if not ok then
      return fail(tostring(content))
    end
    local replaced, reason = chat:replace_soul(content)
    if not replaced then
      return fail(reason)
    end
    vim.notify("Soul selected: " .. selected.reference, vim.log.levels.INFO)
  end)
end

return Souls
