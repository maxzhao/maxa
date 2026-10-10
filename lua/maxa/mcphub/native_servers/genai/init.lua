-- genai MCP Server
-- 生成类模型工具组：图片生成/编辑、文本转语音与视频生成。
-- 遵循 Lua MCP Servers 规范: https://ravitemer.github.io/mcphub.nvim/mcp/native/

local tools = {
  require("maxa.mcphub.native_servers.genai.tools.image_generate"),
  require("maxa.mcphub.native_servers.genai.tools.image_edit"),
  require("maxa.mcphub.native_servers.genai.tools.audio_speech"),
  require("maxa.mcphub.native_servers.genai.tools.video_generate"),
}

return {
  name = "genai",
  displayName = "Generative AI Tools",

  capabilities = {
    tools = tools,
    resources = {},
    resourceTemplates = {},
    prompts = {},
  },

  config = {
    version = "3.0.0",
    description = "Tools for generative media models such as image, video, and audio generation.",
  },
}
