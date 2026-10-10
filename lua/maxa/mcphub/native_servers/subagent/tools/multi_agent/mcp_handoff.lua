-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/mcp_handoff.lua
-- MCP Handoff Tool: 作为 MCP 工具的 handoff 实现
-- 用于 Multi-Agent 协作系统中 Agent 之间的控制权转移

local param_utils = require("maxa.mcphub.native_servers.shared.params")

local M = {}

-- 全局状态：当前活跃的 coordinator 和 agent 信息
-- 由 AgentChat 在 submit 前设置
M._active_context = nil

--- 设置当前活跃的上下文
---@param context table { coordinator: table, agent_name: string, agent_names: string[] }
function M.set_active_context(context)
  M._active_context = context
end

--- 清除当前活跃的上下文
function M.clear_active_context()
  M._active_context = nil
end

--- 获取当前活跃的上下文
---@return table|nil
function M.get_active_context()
  return M._active_context
end

--- 从 Agent 的消息历史中提取最后一轮的纯文本输出
--- LLM 在调用 handoff 之前可能输出了分析文本
--- 该文本作为 Agent 的公开发言（所有 Agent 和用户可见）
---@param messages table[] Chat 消息列表
---@return string|nil text_output 纯文本输出，nil 表示没有
function M._extract_text_output(messages)
  if not messages or #messages == 0 then
    return nil
  end

  -- 从后向前查找最后一条包含 handoff tool_calls 的 assistant/llm 消息
  -- 然后检查该消息的 content 字段（LLM 可能在同一条消息中同时输出文本和 tool_calls）
  -- 以及该消息之前的纯文本 assistant/llm 消息
  local text_parts = {}
  local found_tool_call = false

  for i = #messages, 1, -1 do
    local msg = messages[i]
    local role = msg.role

    if role == "assistant" or role == "llm" then
      local has_tool_calls = msg.tools and msg.tools.calls and #msg.tools.calls > 0

      if has_tool_calls and not found_tool_call then
        found_tool_call = true
        -- 检查这条消息是否也有文本 content
        -- 注意：CC 可能在 content 中注入 tool_display 摘要（如 "⚡ handoff -> X"）
        -- 这些不算纯文本输出
        if msg.content and msg.content ~= "" then
          local content = msg.content
          -- 跳过 tool_display 注入的摘要行
          local clean = content:gsub("⚡[^\n]*\n?", ""):gsub("⠀\n?", "")
          clean = vim.trim(clean)
          if clean ~= "" then
            table.insert(text_parts, 1, clean)
          end
        end
      elseif found_tool_call and not has_tool_calls then
        -- 在 tool_calls 消息之前的纯文本消息
        if msg.content and msg.content ~= "" then
          local content = msg.content
          -- 跳过 tool_display 注入的摘要行
          local clean = content:gsub("⚡[^\n]*\n?", ""):gsub("⠀\n?", "")
          clean = vim.trim(clean)
          if clean ~= "" then
            table.insert(text_parts, 1, clean)
          end
        else
          -- 遇到空内容的消息，停止
          break
        end
      elseif not found_tool_call then
        -- 还没找到 tool_calls，继续
      else
        -- 已经过了纯文本区域，停止
        break
      end
    elseif found_tool_call and (role == "tool" or role == "user") then
      -- 遇到 tool result 或 user 消息（上一轮的边界），停止
      break
    end
  end

  if #text_parts == 0 then
    return nil
  end

  return table.concat(text_parts, "\n\n")
end

--- 创建 MCP handoff 工具定义
---@return table MCP tool definition
function M.create_tool()
  return {
    name = "handoff",
    display = require("maxa.mcphub.native_servers.subagent.tools.presentation").handoff,
    description = "Transfer discussion control to another Agent or finish with `user`. First output public analysis as plain text; `message` is private to the target. The current public contribution counts toward the minimum before ending.",

    inputSchema = {
      type = "object",
      properties = {
        target = {
          type = "string",
          description = "Next Agent name, or `user` to end discussion and return to the user.",
        },
        message = {
          type = "string",
          description = "Short private message for target, such as advice or reminder; do not repeat public analysis.",
        },
      },
      required = { "target", "message" },
    },

    handler = function(req, res)
      local params = param_utils.normalize(req.params)
      local target = params.target
      local message = params.message -- 重命名: summary -> message

      -- 验证参数
      if not target or target == "" then
        return res:error("handoff: Missing required parameter 'target'")
      end

      if not message or message == "" then
        return res:error("handoff: Missing required parameter 'message'")
      end

      -- Only the exact invoking participant can route this discussion.
      local chat = req.chat or (req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat)
      local context = chat and chat._multi_agent_context
      if not context or not context.coordinator or not context.agent or context.agent.chat ~= chat then
        return res:error(
          "handoff: No active multi-agent context. This tool can only be used within a multi-agent discussion."
        )
      end

      local coordinator = context.coordinator
      local from_agent = context.agent_name
      local valid_targets = vim.list_extend(vim.deepcopy(context.agent_names or {}), { "user" })

      -- ⭐ 检查会话是否已结束，如果已结束则直接返回成功（不再处理）
      if coordinator.is_finished then
        return res:text(require("maxa.mcphub.native_servers.subagent.result_format").handoff({
          status = "session_ended",
        })):send()
      end

      -- 验证 target 是否有效
      if not vim.tbl_contains(valid_targets, target) then
        return res:error(
          string.format(
            "handoff: Invalid target '%s'. Valid targets are: %s",
            target,
            table.concat(valid_targets, ", ")
          )
        )
      end

      -- Validate this contribution before counting it toward the minimum.
      local public_speech = M._extract_text_output(chat.messages)
      if not public_speech or public_speech == "" then
        return res:error(
          "handoff: output your public analysis as plain text before calling handoff. "
            .. "Plain text is visible to other Agents and the user; "
            .. "handoff.message is private to the target. "
            .. "Provide the full analysis first, then call handoff."
        )
      end

      if target == "user" then
        local current_turns = (coordinator._sequence or 0) + 1
        local min_turns = coordinator.termination and coordinator.termination.minTurns or 1

        if current_turns < min_turns then
          -- 未达到最小发言次数，拒绝 handoff 到 user
          local other_agents = {}
          for _, name in ipairs(context.agent_names or {}) do
            if name ~= from_agent then
              table.insert(other_agents, name)
            end
          end
          local suggestion = #other_agents > 0 and other_agents[1] or from_agent

          return res:error(
            string.format(
              "handoff: Cannot end discussion yet. Current turns: %d, minimum: %d. "
                .. "Continue discussing (handoff to '%s') before concluding.",
              current_turns,
              min_turns,
              suggestion
            )
          )
        end
      end

      -- ⭐ 阻塞式设计 - 不立即返回，将回调加入等待队列
      coordinator:add_pending_handoff(from_agent, res, message)

      -- 设置 AgentChat 的等待标志
      if context.agent then
        context.agent._waiting_for_handoff = true
      end

      -- 直接通知 Coordinator 继续执行下一个 Agent
      vim.schedule(function()
        coordinator:_on_handoff({
          from = from_agent,
          to = target,
          message = message, -- 私信（仅 target 可见）
          public_speech = public_speech, -- 公开发言（所有 Agent 可见）
        })
      end)

      -- ⭐ 注意: 这里不调用 res:send()，让 MCP 请求保持等待状态
    end,
  }
end

return M
