-- Current-Neovim Lua execution through the prepared run extension.
local api = vim.api
local param_utils = require("maxa.mcphub.native_servers.shared.params")

return {
  match = function(context)
    return context.params.scope == "@neovim:lua"
  end,
  run = function(context, response)
    local params = context.params
    for _, key in ipairs({ "args", "timeout" }) do
      if not param_utils.is_absent(params[key]) then
        return response:error("@neovim:lua does not accept " .. key .. ".")
      end
    end
    if params.cwd ~= vim.fs.normalize(context.cwd) then
      return response:error("@neovim:lua does not support a different cwd.")
    end
    for key, value in pairs(params.opts or {}) do
      if key ~= "async" then
        return response:error("Unsupported @neovim:lua option: " .. tostring(key))
      end
      if not param_utils.is_absent(value) and value ~= false then
        return response:error("@neovim:lua does not support opts.async=true.")
      end
    end

    local code = params.command

    -- Construct Lua heredoc
    local src = string.format(
      [[
lua << EOF
%s
EOF]],
      code
    )

    -- Execute with output capture
    local ok, result = pcall(api.nvim_exec2, src, { output = true })

    if not ok then
      return response:error("Lua execution error:\n" .. tostring(result))
    end

    local output = result.output or ""
    if output == "" then
      return response:text("Code executed successfully. (No output)"):send()
    end

    local builtin_utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
    local MAX_OUTPUT_CHARS = builtin_utils.MAX_OUTPUT_CHARS

    if #output > MAX_OUTPUT_CHARS then
      local log_file = builtin_utils.make_temp_log("mcpx_lua")
      local Path = require("plenary.path")
      local write_ok, write_err = pcall(function()
        Path:new(log_file):write(output, "w")
      end)
      if not write_ok then
        return response:error("Failed to write Lua output log: " .. tostring(write_err))
      end

      local preview = vim.fn.strcharpart(output, 0, 240):gsub("\r", "\\r"):gsub("\n", "\\n")
      return response:text(string.format("Preview: %s…\nFull output: %s\nSize: %d chars", preview, log_file, #output)):send()
    end

    return response:text(output):send()
  end,
}
