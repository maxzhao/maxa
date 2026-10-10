-- 静默版 write - 不打开文件、不显示 UI
-- 直接写入文件内容

local utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

return {
  name = "write",
  display = function(args)
    return { summary = require("maxa.interactions.chat.tools.display_helpers").path_detail("write", args) }
  end,
  description = "Overwrite a file with the provided content, creating parent directories when needed.",
  inputSchema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Path to the file to write.",
      },
      content = {
        type = "string",
        description = "Complete file content to write.",
      },
    },
    required = { "path", "content" },
  },
  run = function(context, response)
    local params = param_utils.normalize(context.params)

    -- 参数验证
    local missing_path = not params.path or vim.trim(params.path) == ""
    local missing_content = not params.content

    -- 两个参数都缺失，可能是输出被截断
    if missing_path and missing_content then
      return response:error(
        "Both 'path' and 'content' parameters are missing. "
          .. "This usually happens when the content is too large and output gets truncated. "
          .. "Please use edit tool instead, which supports incremental writes with smaller SEARCH/REPLACE blocks."
      )
    end

    if missing_path then
      return response:error("Missing required parameter: path")
    end
    if missing_content then
      return response:error("Missing required parameter: content")
    end

    local file_path = params.path
    local content = params.content

    -- 确保父目录存在
    local p = require("plenary.path"):new(file_path)
    local parent = p:parent()
    if not parent:exists() then
      local mkdir_ok, mkdir_err = pcall(function()
        parent:mkdir({ parents = true })
      end)
      if not mkdir_ok then
        return response:error(string.format("Failed to create parent directory for `%s`: %s", file_path, tostring(mkdir_err)))
      end
    end

    -- 检查文件是否已存在（用于判定 create vs modify）
    local file_existed = p:exists()

    -- 写入文件
    local write_ok, write_err = pcall(function()
      p:write(content, "w")
    end)
    if not write_ok then
      return response:error(string.format("Failed to write `%s`: %s", file_path, tostring(write_err)))
    end

    -- 重载已打开且未修改的 buffer
    utils.reload_buffer_if_needed(file_path)

    -- 触发 FileOperation 事件
    utils.fire_file_event(context, file_existed and "modify" or "create", file_path, "write")

    return response:text(string.format("%s %s", file_existed and "Updated" or "Created", file_path)):send()
  end,
}
