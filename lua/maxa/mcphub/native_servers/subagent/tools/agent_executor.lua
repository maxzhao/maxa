-- agent_executor.lua
-- 可复用的 Agent 执行逻辑模块
-- 提供统一的 Agent 执行接口，供 fork_agent、run_agent 和 multi_agent 使用

local async_cancel = require("maxa.mcphub.native_servers.subagent.async_cancel")
local completion_guard = require("maxa.mcphub.native_servers.subagent.completion_guard")
local session_status = require("maxa.session.session_status")
local utils = require("maxa.mcphub.native_servers.subagent.utils")
local window_manager = require("maxa.mcphub.native_servers.subagent.tools.window_manager")

local M = {}

--- 默认 max_turns 限制（math.huge = 无限，除非明确指定）
local DEFAULT_MAX_TURNS = math.huge

--- 验证必需参数
--- @param opts table 执行选项
--- @return boolean valid 是否有效
--- @return string|nil error 错误消息
local function validate_opts(opts)
  if not opts then
    return false, "opts parameter is required"
  end

  if not opts.chat then
    return false, "chat parameter is required"
  end

  if type(opts.chat) ~= "table" then
    return false, "chat must be a table, got " .. type(opts.chat)
  end

  -- prompt 参数可选（run_agent 场景下 messages 已在 Chat.new 时传入）
  if opts.prompt ~= nil then
    if type(opts.prompt) ~= "string" then
      return false, "prompt must be a string, got " .. type(opts.prompt)
    end

    if opts.prompt == "" or opts.prompt:match("^%s*$") then
      return false, "prompt cannot be empty"
    end
  end

  -- 验证 max_turns
  if opts.max_turns ~= nil then
    if type(opts.max_turns) ~= "number" then
      return false, "max_turns must be a number, got " .. type(opts.max_turns)
    end
    if opts.max_turns < 0 then
      return false, "max_turns must be >= 0, got " .. tostring(opts.max_turns)
    end
  end

  -- 验证回调函数
  if opts.on_complete and type(opts.on_complete) ~= "function" then
    return false, "on_complete must be a function, got " .. type(opts.on_complete)
  end

  if opts.on_error and type(opts.on_error) ~= "function" then
    return false, "on_error must be a function, got " .. type(opts.on_error)
  end

  return true, nil
end

--- 构建执行结果
--- @param chat table Chat 实例
--- @param reason string 完成原因
--- @param current_turn number 当前轮次
--- @param max_turns number 最大轮次
--- @param fork_start_index number|nil fork 开始索引
--- @return table result 执行结果
local function build_result(chat, reason, current_turn, max_turns, fork_start_index)
  -- 提取最终响应
  local final_response = utils.extract_final_response(chat.messages, fork_start_index)

  local status = session_status.from_chat(chat)
  return {
    content = final_response or "",
    turns_used = current_turn,
    max_turns = max_turns == math.huge and -1 or max_turns,
    finish_reason = reason,
    message_count = #chat.messages,
    save_id = utils.get_chat_save_id(chat),
    context_status = session_status.to_llm(status),
  }
end

--- 执行 Agent
--- @param opts AgentExecutorOpts 执行选项
---   - chat: table - Chat 实例（必需）
---   - prompt: string|nil - 用户提示（可选，nil 时直接提交 chat）
---   - max_turns: number - 最大轮次（默认无限制）
---   - on_complete: function(result) - 完成回调
---   - on_error: function(error) - 错误回调
---   - fork_start_index: number - fork 开始索引（可选）
function M.execute(opts)
  -- 验证参数
  local valid, error_msg = validate_opts(opts)
  if not valid then
    error(error_msg)
  end

  local chat = opts.chat
  local prompt = opts.prompt
  local max_turns = utils.normalize_max_turns(opts.max_turns, DEFAULT_MAX_TURNS)
  local on_complete = opts.on_complete or function() end
  local on_error = opts.on_error or function() end
  local fork_start_index = opts.fork_start_index

  -- One delegated invocation can own successive sibling Chats. Each Chat's
  -- callbacks remain local; replacement retires them without completing it.
  local execution = opts.execution or {
    chat = chat, parent = opts.handoff_parent, ui = opts.ui, turns_used = 0, finished = false,
  }
  execution.chat = chat
  if not opts.execution and execution.parent and execution.parent.add_callback then
    local function cancel_current()
      if not execution.finished then
        async_cancel.request_chat_cancel(execution.chat, "Parent delegated invocation was cancelled or closed")
      end
    end
    execution.parent:add_callback("on_cancelled", cancel_current)
    execution.parent:add_callback("on_closed", cancel_current)
  end
  chat._subagent_executor = execution
  local close_view = require("maxa.mcphub.native_servers.subagent.tools.presentation").bind(chat, opts.ui)
  local cancel_boundary
  local function close_progress()
    close_view()
    if cancel_boundary then
      pcall(vim.api.nvim_del_autocmd, cancel_boundary)
      cancel_boundary = nil
    end
  end

  -- 状态跟踪
  local finished = false
  local current_turn = execution.turns_used
  local collected_output = nil -- Hook done() 捕获的输出

  -- =========================================================================
  -- 定义完成回调
  -- =========================================================================
  local function on_agent_complete(reason)
    if finished then
      return
    end
    finished = true
    execution.finished = true
    close_progress()

    -- 尝试多种方式提取响应
    local final_response = collected_output

    -- 方式 1: 从 messages 提取
    if not final_response or final_response == "" then
      final_response = utils.extract_final_response(chat.messages, fork_start_index)
    end

    -- 方式 2: 从 buffer 读取（如果 buffer 仍然有效）
    if (not final_response or final_response == "") and chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
      local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
      if #lines > 0 then
        -- 查找最后一个 LLM 响应块
        local in_llm_block = false
        local llm_content = {}
        local llm_role_pattern = "^## 🤖" -- MaxaAI 的 LLM 角色标记

        for _, line in ipairs(lines) do
          if line:match(llm_role_pattern) then
            in_llm_block = true
            llm_content = {} -- 重置，只保留最后一个块
          elseif line:match("^## 👤") or line:match("^## 🧑") then
            in_llm_block = false
          elseif in_llm_block then
            table.insert(llm_content, line)
          end
        end

        if #llm_content > 0 then
          final_response = vim.trim(table.concat(llm_content, "\n"))
        end
      end
    end

    -- 构建响应数据
    local result = build_result(chat, reason, current_turn, max_turns, fork_start_index)
    result.content = final_response or "(No response captured)"

    -- 调用完成回调
    on_complete(result)
  end

  -- =========================================================================
  -- 定义错误回调
  -- =========================================================================
  local function on_agent_error(err)
    if finished then
      return
    end
    finished = true
    execution.finished = true
    close_progress()

    local error_message = "Agent execution failed"
    if err then
      if type(err) == "string" then
        error_message = error_message .. ": " .. err
      elseif type(err) == "table" and err.message then
        error_message = error_message .. ": " .. err.message
      end
    end

    -- 调用错误回调
    on_error(error_message)
  end

  local function on_agent_cancelled(reason)
    on_agent_error(reason or async_cancel.reason(chat) or "Agent was cancelled")
  end

  -- =========================================================================
  -- 构建 callbacks
  -- =========================================================================
  -- Predeclare so deferred completion callbacks can safely re-enter this
  -- executor after the token-decision state releases the completion boundary.
  local callbacks
  callbacks = {
    on_closed = function() on_agent_error("Agent Chat was closed") end,
    on_cancelled = function(c)
      -- 检查是否是"打断"而非"取消"
      -- 打断时不触发错误，让用户可以继续输入
      if window_manager.is_interrupted(c) then
        return
      end
      -- 真正的取消：返回错误
      on_agent_error("Agent was cancelled")
    end,
    on_error = function(c, err)
      on_agent_error(err)
    end,
    on_ready = function(c)
      if async_cancel.is_cancelled(c) then
        on_agent_cancelled(async_cancel.reason(c))
      end
    end,
    on_completed = function(c)
      if finished then return end
      if completion_guard.defer_for_token_decision(c, function()
        callbacks.on_completed(c)
      end) then
        return
      end

      -- 检查是否是"打断"状态
      -- 打断时不触发完成，让用户可以继续输入
      if window_manager.is_interrupted(c) then
        return
      end

      if async_cancel.is_cancelled(c) then
        on_agent_cancelled(async_cancel.reason(c))
        return
      end

      current_turn = current_turn + 1
      execution.turns_used = current_turn

      -- 检查 max_turns 限制
      if current_turn >= max_turns then
        vim.defer_fn(function()
          on_agent_complete("max_turns_reached")
        end, 200)
        return
      end

      -- 检查最后一条消息是否有 tool_calls
      local last_msg = c.messages[#c.messages]
      local has_tool_calls = false

      if last_msg and last_msg.tool_calls and #last_msg.tool_calls > 0 then
        has_tool_calls = true
      end

      -- 也检查 chat 的 tools 状态
      if c.tools and c.tools.pending and #c.tools.pending > 0 then
        has_tool_calls = true
      end

      if not has_tool_calls then
        -- 无 tool_calls = 最终答案
        -- 延迟等待响应完全写入 messages（流式响应可能需要时间）
        vim.defer_fn(function()
          -- 再次检查是否有 collected_output
          if collected_output and collected_output ~= "" then
            on_agent_complete("completed")
          else
            -- 如果还没有捕获到输出，等待更长时间（最多 15 秒）
            local wait_count = 0
            local max_wait = 15 -- 最多等待 15 秒
            local function wait_for_response()
              if finished then return end
              wait_count = wait_count + 1
              -- 再次尝试从 messages 提取
              local start_idx = fork_start_index and (fork_start_index + 1) or 1
              for i = #c.messages, start_idx, -1 do
                local msg = c.messages[i]
                if (msg.role == "assistant" or msg.role == "llm") and msg.content and msg.content ~= "" then
                  collected_output = msg.content
                  break
                end
              end

              if collected_output and collected_output ~= "" then
                on_agent_complete("completed")
              elseif wait_count < max_wait then
                vim.defer_fn(wait_for_response, 1000) -- 每秒检查一次
              else
                on_agent_complete("completed")
              end
            end
            wait_for_response()
          end
        end, 1000) -- 初始等待 1 秒
      end
      -- 如果有 tool_calls，MaxaAI 会自动处理并继续
    end,
  }

  -- =========================================================================
  -- 合并 callbacks（不覆盖原有的 callbacks）
  -- =========================================================================
  -- MaxaAI 的 callbacks 结构: { event_name = { callback1, callback2, ... } }
  -- 我们需要将新的 callbacks 添加到对应的事件数组中
  for event, callback in pairs(callbacks) do
    if not chat.callbacks[event] then
      chat.callbacks[event] = {}
    end
    table.insert(chat.callbacks[event], callback)
  end

  -- tools_done can already be in user-input role and omit on_ready. The
  -- existing soft-stop event still owns that cooperative cancellation boundary.
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    cancel_boundary = vim.api.nvim_create_autocmd("User", {
      pattern = "MaxaAIChatSoftStopped",
      callback = function(event)
        if not finished and event.data and event.data.bufnr == chat.bufnr and async_cancel.is_cancelled(chat) then
          on_agent_cancelled(async_cancel.reason(chat))
        end
      end,
    })
  end

  -- Hook done() 捕获输出。
  if not chat._original_done then
    chat._original_done = chat.done
    chat.done = function(self, output, reasoning, tools, meta, opts)
      if output and #output > 0 then
        local content = vim.trim(table.concat(output, ""))
        if content ~= "" then
          collected_output = content
        end
      end

      -- 调用原始 done 方法（使用 : 调用，不需要传 self）
      local result = self:_original_done(output, reasoning, tools, meta, opts)

      -- 在原始 done 完成后，再次检查 messages（作为备用）
      vim.schedule(function()
        if finished then return end
        if not collected_output or collected_output == "" then
          -- 从 messages 中提取最后一条 LLM 响应
          local start_idx = fork_start_index and (fork_start_index + 1) or 1
          for i = #self.messages, start_idx, -1 do
            local msg = self.messages[i]
            if (msg.role == "assistant" or msg.role == "llm") and msg.content and msg.content ~= "" then
              collected_output = msg.content
              break
            end
          end
        end
      end)

      return result
    end
  end

  function execution.replace(target)
    if finished or execution.finished or async_cancel.is_cancelled(chat) then
      return false, "delegated invocation is no longer active"
    end
    if current_turn >= max_turns then return false, "delegated turn budget is exhausted" end
    finished = true
    close_progress()
    for event, callback in pairs(callbacks) do
      local registered = chat.callbacks[event] or {}
      for i = #registered, 1, -1 do
        if registered[i] == callback then table.remove(registered, i) end
      end
    end
    if chat._original_done then
      chat.done, chat._original_done = chat._original_done, nil
    end
    execution.chat = target
    if opts.on_replaced then opts.on_replaced(target) end
    local next_opts = vim.tbl_extend("force", opts, {
      chat = target, execution = execution, prompt = nil,
    })
    next_opts.fork_start_index = nil
    M.execute(next_opts)
    return true
  end

  -- =========================================================================
  -- 添加 prompt 到 messages（如果提供）
  -- =========================================================================
  if prompt then
    local ok, cc_config = pcall(require, "maxa.config")
    if not ok then
      error("Failed to load Maxa AI config")
    end

    table.insert(chat.messages, {
      role = cc_config.constants.USER_ROLE,
      content = prompt,
    })
  end

  -- =========================================================================
  -- 提交 chat
  -- =========================================================================
  vim.schedule(function()
    if finished then return end
    if async_cancel.is_cancelled(chat) then
      on_agent_cancelled(async_cancel.reason(chat))
      return
    end
    chat:submit({ auto_submit = true })
  end)
end

return M
