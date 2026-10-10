-- Delete multiple files or directories
-- 迁移自: mcphub.nvim/lua/maxa/mcphub/native/neovim/files/operations.lua

local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

return {
  name = "delete",
  display = function(args)
    local paths = args.paths
    if type(paths) ~= "table" or #paths == 0 then return { summary = "delete" } end
    local helpers = require("maxa.interactions.chat.tools.display_helpers")
    local function path(index)
      return helpers.format_path(type(paths[index]) == "string" and paths[index] or tostring(paths[index] or ""))
    end
    if #paths == 1 then return { summary = "delete " .. path(1) } end
    local lines = {}
    for index = 1, math.min(#paths, 10) do
      lines[#lines + 1] = string.format("%d. %s", index, path(index))
    end
    if #paths > 10 then lines[#lines + 1] = string.format("… and %d more items", #paths - 10) end
    local summary = "delete (" .. #paths .. " items)"
    return { summary = summary, blocks = { { kind = "fold", title = summary, content = table.concat(lines, "\n") } } }
  end,
  description = "Delete one or more files or directories.",
  inputSchema = {
    type = "object",
    properties = {
      paths = {
        type = "array",
        items = {
          type = "string",
        },
        description = "Paths to delete.",
      },
    },
    required = { "paths" },
  },
  run = function(context, response)
    local Path = require("plenary.path")
    local params = param_utils.normalize(context.params)
    local results = {}
    local errors = {}

    if not params.paths or not vim.islist(params.paths) then
      return response:error("paths must be an array of strings")
    end

    if #params.paths == 0 then
      return response:error("paths array cannot be empty")
    end

    for i, path in ipairs(params.paths) do
      local p = Path:new(path)

      if not p:exists() then
        table.insert(errors, string.format("Path %d not found: %s", i, path))
      else
        local success, err = pcall(function()
          if p:is_dir() then
            p:rm({ recursive = true })
          else
            p:rm()
          end
        end)

        if not success then
          table.insert(errors, string.format("Failed to delete path %d (%s): %s", i, path, err))
        elseif p:exists() then
          table.insert(
            errors,
            string.format(
              "Failed to delete path %d (%s): deletion returned without error but path still exists",
              i,
              path
            )
          )
        else
          -- 触发 FileOperation 事件
          utils.fire_file_event(context, "delete", path, "delete")
          table.insert(results, {
            path = path,
            index = i,
          })
        end
      end
    end

    if #errors == 0 then
      local summary = #results == 1 and ("Deleted " .. results[1].path)
        or string.format("Deleted %d items", #results)
      return response:text(summary):send()
    end

    -- Partial failures need the identity of completed items for safe retry.
    local response_parts = {}
    if #results > 0 then
      table.insert(response_parts, string.format("Deleted %d item(s):", #results))
      for _, result in ipairs(results) do
        table.insert(response_parts, string.format("  %d. %s", result.index, result.path))
      end
    end

    if #errors > 0 then
      if #results > 0 then
        table.insert(response_parts, "\nErrors encountered:")
      end
      for _, error in ipairs(errors) do
        table.insert(response_parts, "ERROR: " .. error)
      end
    end

    return response:error(table.concat(response_parts, "\n"))
  end,
}
