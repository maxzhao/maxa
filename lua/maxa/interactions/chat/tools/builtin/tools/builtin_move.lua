-- Move or rename a file/directory
-- 迁移自: mcphub.nvim/lua/maxa/mcphub/native/neovim/files/operations.lua

local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

return {
  name = "move",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").path_detail("move", args) }
  end,
  description = "Move or rename a file or directory.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Source path.",
      },
      new_path = {
        type = "string",
        description = "Destination path.",
      },
    },
    required = { "path", "new_path" },
  },
  run = function(context, response)
    local Path = require("plenary.path")
    local params = param_utils.normalize(context.params)
    local path, path_err = param_utils.required_string(params.path, "path")
    if not path then
      return response:error(path_err)
    end
    local new_path, new_path_err = param_utils.required_string(params.new_path, "new_path")
    if not new_path then
      return response:error(new_path_err)
    end

    local p = Path:new(path)
    if not p:exists() then
      return response:error("Source path not found: " .. path)
    end

    local new_p = Path:new(new_path)
    local parent = new_p:parent()
    if parent and not parent:exists() then
      local mkdir_ok, mkdir_err = pcall(function()
        parent:mkdir({ parents = true })
      end)
      if not mkdir_ok then
        return response:error(string.format("Failed to create destination parent directory `%s`: %s", tostring(parent), tostring(mkdir_err)))
      end
    end

    local src_abs = p:absolute()
    local dst_abs = new_p:absolute()
    local rename_ok, rename_err = vim.uv.fs_rename(src_abs, dst_abs)
    if not rename_ok then
      return response:error(string.format("Failed to move `%s` to `%s`: %s", path, new_path, tostring(rename_err)))
    end

    -- 重载源文件和目标文件的 buffer
    utils.reload_buffer_if_needed(path)
    utils.reload_buffer_if_needed(new_path)

    -- 触发 FileOperation 事件（移动 = 源删除 + 目标创建）
    utils.fire_file_event(context, "delete", path, "move")
    utils.fire_file_event(context, "create", new_path, "move")

    return response:text(string.format("Moved %s to %s", path, new_path)):send()
  end,
}
