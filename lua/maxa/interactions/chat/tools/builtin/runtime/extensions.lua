-- Ability-owned dynamic interceptors for canonical Chat builtin invocations.
local M = {}

function M.select(tool_name, context)
  -- Batch declarations belong to the native scheduler, not Ability handlers.
  if tool_name == "multicall" then
    return nil
  end
  local chat = context and context.chat
  if not chat or not chat.messages or #chat.messages == 0 or context.ability_script
    or (tool_name == "run" and context.params.scope == "tool") then
    return nil
  end
  local state, state_err = require("maxa.session.abilities").catalog(chat, context.cwd)
  if not state then
    return nil, state_err
  end
  local catalog = require("maxa.abilities.catalog")
  for _, name in ipairs(state.order) do
    -- MCP-only loads have no package code. Installed Skill sources remain mutable.
    if #state.abilities[name].revision.roots > 0 then
      local prefix = string.format("Ability '%s' builtin '%s': ", name, tool_name)
      local ability, ability_err = catalog.resolve(name, context.cwd)
      if not ability then
        -- Failed live metadata cannot create a new interceptor. Only a known
        -- loaded declaration for this builtin may block it; unrelated malformed
        -- or retired packages must not disable ordinary recovery tools.
        local declared = state.abilities[name].revision.builtin_extensions or {}
        if not vim.tbl_contains(declared, tool_name) then goto continue end
        return nil, prefix .. tostring(ability_err)
      end
      local entry, entry_err = catalog.resolve_builtin_extension(ability, tool_name)
      if entry_err then
        return nil, prefix .. entry_err
      end
      if entry then
        local chunk, load_err = loadfile(entry.path)
        if not chunk then
          return nil, prefix .. tostring(load_err)
        end
        local ok, extension = pcall(chunk)
        if not ok then
          return nil, prefix .. tostring(extension)
        end
        if type(extension) ~= "table" or type(extension.match) ~= "function" or type(extension.run) ~= "function" then
          return nil, prefix .. "extension must return a table with match(context) and run(context, response)"
        end
        local matched, match = pcall(extension.match, context)
        if not matched then
          return nil, prefix .. tostring(match)
        end
        if type(match) ~= "boolean" then
          return nil, prefix .. "match(context) must return a boolean"
        end
        if match then
          return { run = extension.run, key = name .. ":" .. tool_name, prefix = prefix }
        end
      end
    end
    ::continue::
  end
end

return M
