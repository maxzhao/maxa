-- MaxaAI MCP SubAgent 配置模块
-- 委托给上层统一配置 util.mcphub.config
-- 保持向后兼容的 API 接口
local M = {}

--- Maximum nested sub-agent creation depth.
--- Depth counts sub-agent tools that create child agents.
setmetatable(M, { __index = function(_, key)
  if key == "MAX_RECURSION_DEPTH" then return require("maxa.config").runtime().subagent.max_recursion_depth end
end })

local mcp_config = require("maxa.mcphub.native_servers.config")

-- ============================================================================
-- 向后兼容：直接暴露上层 config 的表
-- ============================================================================

--- Adapter 预设表（向后兼容，实际数据来自 mcp_config.adapters）
M.adapters_preset = mcp_config.adapters

-- ============================================================================
-- 向后兼容 API
-- ============================================================================

--- 解析 Adapter 预设（向后兼容，委托给 mcp_config.get_adapter）
--- @param preset_key string|nil 预设 key
--- @return table|nil config 解析后的配置，失败返回 nil
--- @return string|nil error 错误消息，成功返回 nil
function M.resolve_adapter(preset_key)
  return mcp_config.get_adapter(preset_key)
end

return M
