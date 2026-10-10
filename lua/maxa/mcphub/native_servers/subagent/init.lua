-- MaxaAI MCP Server
-- 提供基于 MaxaAI 的 LLM 调用能力
-- 遵循 Lua MCP Servers 规范: https://ravitemer.github.io/mcphub.nvim/mcp/native/

-- 加载 MCP handoff 模块
local mcp_handoff = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.mcp_handoff")

-- 加载所有工具模块
local tools = {
  require("maxa.mcphub.native_servers.subagent.tools.run_agent"),
  require("maxa.mcphub.native_servers.subagent.tools.fork_agent"),
  require("maxa.mcphub.native_servers.subagent.tools.resume_agent"),
  require("maxa.mcphub.native_servers.subagent.tools.multi_agent"),
  mcp_handoff.create_tool(), -- handoff 工具（用于 multi-agent 协作）
}

return {
  name = "subagent",

  displayName = "SubAgent LLM Tools",

  -- Required: Server capabilities
  capabilities = {
    tools = tools,
    resources = {},
    resourceTemplates = {},
    prompts = {},
  },

  -- Optional: Server-specific configuration
  config = {
    version = "1.1.0",
    description = "MCP Server providing LLM capabilities through MaxaAI's Background and Chat modules",
  },
}
