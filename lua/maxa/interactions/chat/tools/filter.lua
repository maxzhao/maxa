local filter = require("maxa.interactions.chat.helpers.filter")

---@class MaxaAI.Tools.Filter
local Filter = filter.create_filter({
  skip_keys = { "opts", "groups" }, -- Ignore retired tool-group configuration.
  post_filter = function(filtered_config, opts)
    filtered_config.groups = nil
    -- Adapter specific tool
    if opts and opts.adapter and opts.adapter.available_tools then
      for tool_name, tool_config in pairs(opts.adapter.available_tools) do
        local should_show = true
        if tool_config.enabled then
          if type(tool_config.enabled) == "function" then
            should_show = tool_config.enabled(opts.adapter)
          else
            should_show = tool_config.enabled
          end
        end

        -- An adapter's tool will take precedence over built-in tools
        if should_show then
          filtered_config[tool_name] = vim.tbl_extend("force", tool_config, {
            _adapter_tool = true,
            _has_client_tool = tool_config.opts and tool_config.opts.client_tool and true or false,
          })
        end
      end
    end

    return filtered_config
  end,
})

-- Maintain backward compatibility with existing API
Filter.filter_enabled_tools = Filter.filter_enabled
Filter.is_tool_enabled = Filter.is_enabled

return Filter
