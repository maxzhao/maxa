-- agent_executor 单元测试
-- 测试 agent_executor 模块的核心功能

describe("agent_executor", function()
  local agent_executor
  local mock_chat
  local mock_utils

  before_each(function()
    -- 重置模块缓存
    package.loaded["maxa.mcphub.native_servers.subagent.tools.agent_executor"] = nil
    package.loaded["maxa.mcphub.native_servers.subagent.utils"] = nil
    package.loaded["maxa.mcphub.native_servers.subagent.tools.window_manager"] = nil
    package.loaded["maxa.config"] = nil

    -- Mock utils 模块
    mock_utils = {
      extract_final_response = function(messages, start_index)
        -- 模拟从 messages 提取响应
        for i = #messages, (start_index or 1), -1 do
          local msg = messages[i]
          if (msg.role == "assistant" or msg.role == "llm") and msg.content then
            return msg.content
          end
        end
        return nil
      end,
      create_response = function(data)
        return {
          success = true,
          data = data,
          timestamp = "2026-02-06T01:53:44",
        }
      end,
      get_chat_save_id = function()
        return "save-id-1"
      end,
      normalize_max_turns = function(max_turns, default_value)
        if max_turns == nil or max_turns == 0 then
          return default_value or math.huge
        end
        return max_turns
      end,
    }
    package.loaded["maxa.mcphub.native_servers.subagent.utils"] = mock_utils

    -- Mock window_manager 模块
    local mock_window_manager = {
      is_interrupted = function(chat)
        return chat._interrupted or false
      end,
      reset_interrupted = function(chat)
        chat._interrupted = false
      end,
    }
    package.loaded["maxa.mcphub.native_servers.subagent.tools.window_manager"] = mock_window_manager
    package.loaded["maxa.config"] = {
      constants = {
        USER_ROLE = "user",
        SYSTEM_ROLE = "system",
      },
    }

    -- 加载被测试模块
    agent_executor = require("maxa.mcphub.native_servers.subagent.tools.agent_executor")

    -- 创建 mock chat 对象
    mock_chat = {
      messages = {},
      adapter = { name = "test_adapter" },
      tools = { pending = {} },
      tool_registry = {
        in_use = {},
        schemas = {},
      },
      callbacks = {},
      submit = function(self, opts)
        -- 模拟提交，触发 callbacks
        self._submitted = true
        return true
      end,
      stop = function(self)
        self._stopped = true
        if self.callbacks and self.callbacks.on_cancelled then
          self.callbacks.on_cancelled(self)
        end
      end,
    }
  end)

  describe("execute()", function()
    it("应该验证必需参数", function()
      local result, err = pcall(agent_executor.execute, {})
      assert.is_false(result)
      assert.is_not_nil(err)
      assert.matches("chat.*required", err:lower())
    end)

    it("应该允许 prompt 缺省", function()
      local result = pcall(agent_executor.execute, {
        chat = mock_chat,
        on_complete = function() end,
      })
      assert.is_true(result)
    end)

    it("默认 max_turns 应该不限制轮数", function()
      local completed = false

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        on_complete = function(result)
          completed = true
        end,
      })

      -- 验证 callbacks 已设置
      assert.is_not_nil(mock_chat.callbacks)
      assert.is_not_nil(mock_chat.callbacks.on_completed)

      -- 默认 max_turns 是无限制；即使多次完成回调带有 tool_calls，
      -- 也不应该因为达到旧的固定 10 轮阈值而结束。
      for i = 1, 10 do
        table.insert(mock_chat.messages, {
          role = "assistant",
          content = "",
          tool_calls = { { id = "call_" .. i, name = "test_tool" } },
        })
        mock_chat.callbacks.on_completed[1](mock_chat)
      end

      -- 验证没有触发 max_turns 完成
      assert.is_false(completed)
    end)

    it("应该检测无 tool_calls 的完成条件", function()
      local completed = false
      local result_data = nil

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        max_turns = 5,
        on_complete = function(result)
          completed = true
          result_data = result
        end,
      })

      -- 添加一条没有 tool_calls 的响应
      table.insert(mock_chat.messages, {
        role = "assistant",
        content = "final answer",
      })

      -- 触发 on_completed
      mock_chat.callbacks.on_completed[1](mock_chat)

      -- 等待异步完成（使用 vim.wait）
      vim.wait(1500, function()
        return completed
      end)

      -- 验证完成回调被触发
      assert.is_true(completed)
      assert.is_not_nil(result_data)
      assert.equals("completed", result_data.finish_reason)
      assert.equals("final answer", result_data.content)
    end)

    it("应该把 max_turns=0 视为不限制轮数", function()
      local completed = false
      local result_data = nil

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        max_turns = 0,
        on_complete = function(result)
          completed = true
          result_data = result
        end,
      })

      table.insert(mock_chat.messages, {
        role = "assistant",
        content = "unlimited response",
      })

      mock_chat.callbacks.on_completed[1](mock_chat)

      vim.wait(1500, function()
        return completed
      end)

      assert.is_true(completed)
      assert.is_not_nil(result_data)
      assert.equals("completed", result_data.finish_reason)
      assert.equals("unlimited response", result_data.content)
      assert.equals(-1, result_data.max_turns)
    end)

    it("应该继续执行当有 tool_calls 时", function()
      local completed = false

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        max_turns = 5,
        on_complete = function(result)
          completed = true
        end,
      })

      -- 添加一条有 tool_calls 的响应
      table.insert(mock_chat.messages, {
        role = "assistant",
        content = "",
        tool_calls = { { id = "call_1", name = "test_tool" } },
      })

      -- 触发 on_completed
      mock_chat.callbacks.on_completed[1](mock_chat)

      -- 等待一小段时间
      vim.wait(300, function()
        return completed
      end)

      -- 验证未完成（因为有 tool_calls）
      assert.is_false(completed)
    end)

    it("应该处理错误回调", function()
      local error_triggered = false
      local error_message = nil

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        on_error = function(err)
          error_triggered = true
          error_message = err
        end,
      })

      -- 触发错误
      mock_chat.callbacks.on_error[1](mock_chat, "test error")

      -- 验证错误回调被触发
      assert.is_true(error_triggered)
      assert.equals("Agent execution failed: test error", error_message)
    end)

    it("应该处理取消回调", function()
      local error_triggered = false

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        on_error = function(err)
          error_triggered = true
        end,
      })

      -- 触发取消（非打断）
      mock_chat._interrupted = false
      mock_chat.callbacks.on_cancelled[1](mock_chat)

      -- 验证错误回调被触发
      assert.is_true(error_triggered)
    end)

    it("应该忽略打断状态", function()
      local completed = false
      local error_triggered = false

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        on_complete = function(result)
          completed = true
        end,
        on_error = function(err)
          error_triggered = true
        end,
      })

      -- 设置打断状态
      mock_chat._interrupted = true

      -- 触发 on_completed（打断状态）
      mock_chat.callbacks.on_completed[1](mock_chat)

      -- 等待一小段时间
      vim.wait(600, function()
        return completed or error_triggered
      end)

      -- 验证未触发完成或错误
      assert.is_false(completed)
      assert.is_false(error_triggered)

      -- 验证打断标志被重置
      assert.is_false(mock_chat._interrupted)
    end)

    it("应该添加 prompt 到 messages", function()
      local initial_count = #mock_chat.messages

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        on_complete = function() end,
      })

      -- 验证 prompt 被添加
      assert.equals(initial_count + 1, #mock_chat.messages)
      assert.equals("test prompt", mock_chat.messages[#mock_chat.messages].content)
    end)

    it("应该调用 chat:submit()", function()
      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        on_complete = function() end,
      })

      -- 等待异步提交
      vim.wait(100, function()
        return mock_chat._submitted
      end)

      -- 验证 submit 被调用
      assert.is_true(mock_chat._submitted)
    end)
  end)

  describe("响应提取", function()
    it("应该从 messages 提取最终响应", function()
      local result_data = nil

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        on_complete = function(result)
          result_data = result
        end,
      })

      -- 添加多条消息
      table.insert(mock_chat.messages, {
        role = "assistant",
        content = "first response",
      })
      table.insert(mock_chat.messages, {
        role = "user",
        content = "user message",
      })
      table.insert(mock_chat.messages, {
        role = "assistant",
        content = "final response",
      })

      -- 触发完成
      mock_chat.callbacks.on_completed[1](mock_chat)

      -- 等待异步完成
      vim.wait(1500, function()
        return result_data ~= nil
      end)

      -- 验证提取了最后一条 assistant 消息
      assert.is_not_nil(result_data)
      assert.equals("final response", result_data.content)
    end)

    it("应该支持 fork_start_index 参数", function()
      local result_data = nil

      -- 添加一些历史消息
      table.insert(mock_chat.messages, {
        role = "assistant",
        content = "old response",
      })
      local fork_start = #mock_chat.messages

      agent_executor.execute({
        chat = mock_chat,
        prompt = "test prompt",
        fork_start_index = fork_start,
        on_complete = function(result)
          result_data = result
        end,
      })

      -- 添加新消息
      table.insert(mock_chat.messages, {
        role = "assistant",
        content = "new response",
      })

      -- 触发完成
      mock_chat.callbacks.on_completed[1](mock_chat)

      -- 等待异步完成
      vim.wait(1500, function()
        return result_data ~= nil
      end)

      -- 验证只提取 fork 后的响应
      assert.is_not_nil(result_data)
      assert.equals("new response", result_data.content)
    end)
  end)
end)
