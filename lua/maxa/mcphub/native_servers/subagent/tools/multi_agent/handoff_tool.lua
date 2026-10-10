-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/handoff_tool.lua
-- Handoff Tool: 异步事件驱动的 Agent 切换工具
-- 用于 Multi-Agent 协作系统中 Agent 之间的控制权转移

local log = require("maxa.utils.log")

local M = {}

---@class HandoffToolResult
---@field status "handoff_initiated" 状态
---@field target string 目标 Agent 名称或 "user"
---@field message string 传递的内容

---@class HandoffEvent
---@field from string 来源 Agent 名称
---@field to string 目标 Agent 名称或 "user"
---@field message string 传递的内容

-- Handoff Tool 调用结果的标识
local HANDOFF_RESULT_MARKER = '"status":"handoff_initiated"'

--- 从 MCP 工具输出中提取 JSON 内容
--- MCP 工具输出格式: **`tool_name` Tool**: Returned the following:\n\n````\n{json}\n````
---@param content string 消息内容
---@return string|nil json_content 提取的 JSON 内容
local function extract_json_from_mcp_output(content)
  -- 尝试匹配 MCP 工具输出格式中的 JSON
  -- 格式: ````\n{...}\n````
  local json = content:match("````%s*\n(.-)%s*\n````")
  if json then
    return json
  end

  -- 如果没有 markdown 包装，检查是否直接是 JSON
  if content:match("^%s*{") then
    return content
  end

  return nil
end

--- 检测消息是否为 Handoff Tool 的调用结果
--- 用于在 on_completed 回调中判断是否触发了 Handoff
--- 支持两种格式：
--- 1. 直接 JSON 格式（MaxaAI 内置工具）
--- 2. MCP 工具输出格式（被 markdown 包装）
---@param msg table MaxaAI 消息对象
---@return boolean is_handoff 是否为 Handoff 结果
---@return HandoffToolResult|nil result 解析后的结果 (如果是 Handoff)
function M.is_handoff_tool_result(msg)
  -- 检查消息角色是否为 tool (工具调用结果)
  if not msg or msg.role ~= "tool" then
    return false, nil
  end

  -- 检查内容是否包含 handoff 结果标识
  local content = msg.content
  if type(content) ~= "string" then
    return false, nil
  end

  -- 快速检查：内容是否包含 handoff 标识
  if not content:find(HANDOFF_RESULT_MARKER, 1, true) then
    return false, nil
  end

  -- 提取 JSON 内容（支持 MCP 工具的 markdown 包装格式）
  local json_content = extract_json_from_mcp_output(content)
  if not json_content then
    return false, nil
  end

  -- 尝试解析 JSON
  local ok, result = pcall(vim.json.decode, json_content)
  if not ok or type(result) ~= "table" then
    return false, nil
  end

  -- 验证必要字段
  if result.status == "handoff_initiated" and result.target then
    return true, result
  end

  return false, nil
end

--- 从消息列表中查找最后一条 Handoff Tool 结果
--- 用于在 on_completed 中检测是否有 Handoff 调用
---@param messages table[] MaxaAI 消息列表
---@return boolean found 是否找到 Handoff 结果
---@return HandoffToolResult|nil result 解析后的结果
---@return number|nil index 消息索引
function M.find_last_handoff_result(messages)
  if not messages or #messages == 0 then
    return false, nil, nil
  end

  -- 从后向前查找
  for i = #messages, 1, -1 do
    local msg = messages[i]
    local is_handoff, result = M.is_handoff_tool_result(msg)
    if is_handoff then
      return true, result, i
    end
    -- 如果遇到 assistant 消息，停止查找（只查找最近一轮的工具调用）
    if msg.role == "assistant" then
      break
    end
  end

  return false, nil, nil
end

-- MCP 工具名称（格式：server__tool）
local MCP_TOOL_NAME = "subagent__handoff"

--- 创建 Handoff Tool 的 schema 定义 (OpenAI 格式)
--- 用于注册到 MaxaAI 的工具系统
---@param agent_names string[] 可用的 Agent 名称列表
---@return table schema Tool schema 定义 (OpenAI 格式)
function M.create_schema(agent_names)
  -- 构建 target 的 enum 值：所有 Agent 名称 + "user"
  local target_enum = vim.list_extend(vim.deepcopy(agent_names), { "user" })

  return {
    type = "function",
    ["function"] = {
      name = MCP_TOOL_NAME,
      description = [[Transfer discussion control to another Agent or finish by targeting `user`. Before calling, output your public analysis as plain text; `message` is private to the target.]],
      parameters = {
        type = "object",
        properties = {
          target = {
            type = "string",
            enum = target_enum,
            description = "Next Agent name, or `user` to end discussion and return to the user.",
          },
          message = {
            type = "string",
            description = "Private message visible only to target; keep it concise.",
          },
        },
        required = { "target", "message" },
      },
    },
  }
end

--- 创建 Handoff Tool 的 Anthropic 原生格式 schema
--- 用于直接传递给 Anthropic API，跳过 MaxaAI 的转换
---@param agent_names string[] 可用的 Agent 名称列表
---@return table schema Anthropic 原生格式的 Tool schema
function M.create_anthropic_schema(agent_names)
  -- 构建 target 的 enum 值：所有 Agent 名称 + "user"
  local target_enum = vim.list_extend(vim.deepcopy(agent_names), { "user" })

  return {
    name = MCP_TOOL_NAME,
    description = [[Transfer discussion control to another Agent or finish by targeting `user`. Before calling, output your public analysis as plain text; `message` is private to the target.]],
    input_schema = {
      type = "object",
      properties = {
        target = {
          type = "string",
          enum = target_enum,
          description = "Next Agent name, or `user` to end discussion and return to the user.",
        },
        message = {
          type = "string",
          description = "Private message visible only to target; keep it concise.",
        },
      },
      required = { "target", "message" },
    },
  }
end

--- 创建 Handoff Tool 定义
--- 返回完整的 MaxaAI Tool 定义，包含 schema 和 handlers
---@param opts table 配置选项
---@param opts.agent_names string[] 可用的 Agent 名称列表
---@param opts.coordinator table MultiAgentCoordinator 实例 (用于发送事件)
---@param opts.current_agent_fn function 获取当前 Agent 名称的函数
---@return table tool MaxaAI Tool 定义
function M.create_tool(opts)
  local agent_names = opts.agent_names or {}
  local native = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.mcp_handoff").create_tool()
  local definition = {
    name = MCP_TOOL_NAME,
    inputSchema = native.inputSchema,
    display = native.display,
    run = native.handler,
  }

  return {
    name = MCP_TOOL_NAME,
    display = require("maxa.mcphub.native_servers.subagent.tools.presentation").handoff,
    cmds = {
      ---Execute the handoff command
      ---@param self table Tool instance
      ---@param args table The arguments from the LLM's tool call
      ---@return { status: "success"|"error", data: string }
      function(tools, args, _, output_handler)
        return require("maxa.interactions.chat.tools.builtin.runtime.adapter")
          .execute(definition, tools, args, output_handler)
      end,
    },
    schema = M.create_schema(agent_names),
    handlers = {
      ---@param tools MaxaAI.Tools The tool object
      on_exit = function(tools)
        log:trace("[Handoff Tool] on_exit handler executed")
      end,
    },
    output = {
      ---Returns the command description for display
      ---@param self table Tool instance
      ---@return string
      cmd_string = function(self)
        local target = self.args and self.args.target or "unknown"
        return string.format("handoff -> %s", target)
      end,

      ---The message which is shared with the user when asking for approval
      ---@param self table Tool instance
      ---@param tools MaxaAI.Tools
      ---@return nil|string
      prompt = function(self, tools)
        local target = self.args and self.args.target or "unknown"
        if target == "user" then
          return "End discussion and return to user?"
        end
        return string.format("Hand off to %s?", target)
      end,

      ---@param self table Tool instance
      ---@param tools MaxaAI.Tools
      ---@param cmd table The command that was executed
      ---@param stdout table The output from the command
      success = function(self, tools, cmd, stdout)
        local chat = tools.chat
        local output = vim.iter(stdout):flatten():join("\n")
        local target = self.args and self.args.target or "unknown"

        local display_msg
        if target == "user" then
          display_msg = "Discussion ended, returning to user"
        else
          display_msg = string.format("Handed off to %s", target)
        end

        chat:add_tool_output(self, output, display_msg)
      end,

      ---@param self table Tool instance
      ---@param tools MaxaAI.Tools
      ---@param cmd table
      ---@param stderr table The error output from the command
      error = function(self, tools, cmd, stderr)
        local chat = tools.chat
        local errors = vim.iter(stderr):flatten():join("\n")
        local context = chat._multi_agent_context
        if context and context.coordinator._is_finishing and errors == "tool input cancelled" then
          return
        end
        log:error("[Handoff Tool] Error: %s", errors)
        chat:add_tool_output(self, "**Error:**\n" .. errors)
      end,
    },
  }
end

--- 创建用于检测 Handoff 的 on_completed 回调包装器
--- 用于在 AgentChat 的 on_completed 中检测 Handoff Tool 调用
---@param original_callback function|nil 原始的 on_completed 回调
---@param on_handoff function 检测到 Handoff 时的回调 (result: HandoffToolResult)
---@return function wrapped_callback 包装后的回调
function M.wrap_on_completed(original_callback, on_handoff)
  return function(chat)
    -- 检测是否有 Handoff Tool 调用结果
    local found, result = M.find_last_handoff_result(chat.messages)

    if found and result then
      log:debug("[Handoff Tool] Detected handoff in on_completed: target=%s", result.target)
      -- 调用 Handoff 处理回调
      if on_handoff then
        on_handoff(result)
      end
      -- Handoff 已触发，不执行原始回调的后续逻辑
      return
    end

    -- 没有 Handoff，执行原始回调
    if original_callback then
      original_callback(chat)
    end
  end
end

return M
