-- streaming_llm: 共享的异步流式 LLM 请求模块
-- 从 compact_silent 中提取的通用模式，供所有调用点复用
-- 核心：stream=true + client:send + SSE chunk 累积 + adapter parse_chat 解析
--
-- 解决问题：
-- 1. 网关超时：stream=true 持续发送数据，避免 60s 超时（504）
-- 2. UI 阻塞：异步回调，不阻塞 Neovim 事件循环
-- 3. 代码重复：统一 adapter 初始化、错误处理、重试逻辑

local M = {}

local function prepare_streaming_adapter(resolved_adapter, source_name)
  local adapter = vim.deepcopy(resolved_adapter)
  if not adapter or adapter.type ~= "http" then
    return nil, "Failed to resolve HTTP adapter" .. (source_name and (": " .. source_name) or "")
  end
  adapter:map_schema_to_params(require("maxa.schema").get_default(adapter))

  -- 启用 streaming
  if adapter.opts then
    adapter.opts.stream = true
  else
    adapter.opts = { stream = true }
  end

  -- Patch setup handler：copilot 的 setup 检查 has_function_calling，
  -- 会错误地设置 opts.tools = false，导致 tools 不发送。
  -- 强制在 setup 后恢复 opts.tools = true
  local original_setup = adapter.handlers and adapter.handlers.setup
  if original_setup then
    adapter.handlers.setup = function(self)
      local result = original_setup(self)
      self.opts.tools = true
      return result
    end
  end

  return adapter, nil
end

local function resolve_chat_adapter_config(chat)
  if not chat or not chat.adapter then
    return nil, nil, nil, "parent chat adapter is required"
  end

  local adapter_name = chat.adapter.name
  if not adapter_name or adapter_name == "" then
    return nil, nil, nil, "parent chat adapter name is missing"
  end

  local model_name = chat.settings and chat.settings.model or nil
  if not model_name then
    model_name = chat.adapter.model and chat.adapter.model.name or nil
  end
  if not model_name then
    model_name = chat.adapter.parameters and chat.adapter.parameters.model or nil
  end

  local temperature = chat.settings and chat.settings.temperature or nil
  if temperature == nil then
    temperature = chat.adapter.parameters and chat.adapter.parameters.temperature or nil
  end

  return adapter_name, model_name, temperature, nil
end

--- 从父 chat 的 adapter/model/temperature 配置重新 resolve 干净的 streaming adapter
--- 避免直接复用父 chat 运行态 adapter 对象导致 handler/schema/状态污染或同步 model 解析阻塞。
---@param chat table 父 chat
---@return table|nil adapter 初始化好的 adapter
---@return string|nil error 错误信息
function M.create_streaming_adapter_from_chat(chat)
  local adapter_name, model_name, temperature, err = resolve_chat_adapter_config(chat)
  if not adapter_name then
    return nil, err
  end

  return M.create_streaming_adapter(adapter_name, model_name, temperature)
end

--- 从已解析的 Maxa AI adapter 创建启用 streaming 的 adapter
--- 保留兼容入口；优先用于没有父 chat 配置可继承的场景。
---@param resolved_adapter table 已解析的 adapter 对象
---@return table|nil adapter 初始化好的 adapter
---@return string|nil error 错误信息
function M.create_streaming_adapter_from_resolved(resolved_adapter)
  if not resolved_adapter then
    return nil, "resolved adapter is required"
  end
  return prepare_streaming_adapter(resolved_adapter, resolved_adapter.name)
end

--- 创建启用 streaming 的 adapter
--- 统一处理：adapter schema 初始化、stream=true、setup handler patch
---@param adapter_name string adapter 名称（如 "copilot"）
---@param model_name string|nil 模型名称（可选，用于覆盖默认模型）
---@param temperature number|nil 温度（可选，用于覆盖默认温度）
---@return table|nil adapter 初始化好的 adapter
---@return string|nil error 错误信息
function M.create_streaming_adapter(adapter_name, model_name, temperature, thinking_mode)
  local adapters = require("maxa.adapters")
  local resolve_opts = {}
  if model_name then
    resolve_opts.model = model_name
  end
  if temperature ~= nil then
    resolve_opts.temperature = temperature
  end
  local resolved_adapter = adapters.resolve(adapter_name, resolve_opts)
  if thinking_mode ~= nil then
    local settings = require("maxa.mcphub.native_servers.config").get_reasoning_effort_settings(resolved_adapter, thinking_mode)
    for key, value in pairs(settings or {}) do
      if resolved_adapter.schema and resolved_adapter.schema[key] then
        resolved_adapter.schema[key].default = value
      end
    end
  end
  return prepare_streaming_adapter(resolved_adapter, adapter_name)
end

--- 将流式 reasoning chunks 合并为可回传给 thinking 模型的消息结构。
---@param adapter table
---@param chunks table[]
---@return table|string|nil reasoning
function M.build_stream_reasoning(adapter, chunks)
  if type(chunks) ~= "table" or #chunks == 0 then
    return nil
  end
  return require("maxa.adapters").call_handler(adapter, "build_reasoning", chunks)
end

--- 发起异步流式 LLM 请求
--- 累积 SSE chunks，完成后回调返回完整内容
---@param adapter table 已初始化的 adapter（来自 create_streaming_adapter）
---@param messages table[] 消息数组（已 map_roles）
---@param opts table|nil 选项 { tools = table|nil, timeout = number|nil, on_chunk_text = function|nil, on_tool_calls = function|nil }
---@param callback function 完成回调 function(content: string|nil, err: string|nil)
function M.streaming_request(adapter, messages, opts, callback)
  opts = opts or {}
  local http = require("maxa.http")
  local adapters = require("maxa.adapters")
  local error_handler = require("maxa.session.llm_error_handler")

  local client = http.new({ adapter = adapter })

  local payload = {
    messages = adapter:map_roles(vim.deepcopy(messages)),
  }

  if opts.tools then
    payload.tools = opts.tools
  end

  local stream_output = {} -- 累积 content delta chunks
  local stream_reasoning = {} -- 累积 reasoning delta / terminal metadata
  local stream_tools = {} -- 累积 tool_calls（parse_chat 在 completed 事件中填充）
  local had_error = false

  -- 重试状态
  local retry_counts = { network_issue = 0, rate_limited = 0 }
  local caller_chat = opts.caller_chat -- 用于 token_limit 共享计数器

  local active_job = nil
  local finished = false
  local timeout_timer = nil

  local function stop_active_job()
    if active_job then
      if active_job.cancel then
        pcall(function()
          active_job.cancel()
        end)
      elseif active_job.shutdown then
        pcall(function()
          active_job:shutdown()
        end)
      end
    end
  end

  local function stop_timeout_timer()
    if timeout_timer then
      pcall(vim.fn.timer_stop, timeout_timer)
      timeout_timer = nil
    end
  end

  local function finish(content, err)
    if finished then
      return
    end
    finished = true
    stop_timeout_timer()
    callback(content, err)
  end

  local function finish_tool_calls(tool_calls, content, reasoning)
    if finished then
      return
    end
    finished = true
    stop_timeout_timer()
    opts.on_tool_calls(tool_calls, content, reasoning)
  end

  local timeout_ms = tonumber(opts.timeout)
  if timeout_ms and timeout_ms > 0 then
    timeout_timer = vim.fn.timer_start(timeout_ms, function()
      if finished then
        return
      end
      stop_active_job()
      finish(nil, string.format("LLM request timed out after %dms", timeout_ms))
    end)
  end

  local function do_request()
    if finished then
      return
    end
    had_error = false
    stream_output = {}
    stream_reasoning = {}
    stream_tools = {}

    active_job = client:send(payload, {
      on_chunk = function(data)
        if not data or data == "" then
          return
        end
        local result = adapters.call_handler(adapter, "parse_chat", data, stream_tools)
        if result and result.status == "success" and result.output then
          if result.output.content and result.output.content ~= "" then
            table.insert(stream_output, result.output.content)
            if opts.on_chunk_text then
              opts.on_chunk_text(result.output.content)
            end
          end
          if result.output.reasoning then
            table.insert(stream_reasoning, result.output.reasoning)
          end
        end
      end,

      on_done = function()
        if had_error or finished then
          return
        end

        local content = #stream_output > 0 and vim.trim(table.concat(stream_output, "")) or nil
        if content == "" then
          content = nil
        end

        -- 返回 tool_calls 信息（如果有）
        if #stream_tools > 0 then
          -- 转换为统一格式
          local tool_calls = {}
          for _, tc in ipairs(stream_tools) do
            local args = tc["function"] and tc["function"].arguments or ""
            if type(args) == "string" and args ~= "" then
              local ok_args, parsed = pcall(vim.json.decode, args)
              args = ok_args and parsed or {}
            elseif type(args) ~= "table" then
              args = {}
            end
            table.insert(tool_calls, {
              id = tc.call_id or tc.id,
              name = tc["function"] and tc["function"].name or tc.name,
              input = args,
            })
          end
          -- 通过 opts.on_tool_calls 回调传递（如果提供）。第三个参数
          -- reasoning 保持向后兼容，旧回调会自然忽略额外参数。
          if opts.on_tool_calls then
            finish_tool_calls(tool_calls, content, M.build_stream_reasoning(adapter, stream_reasoning))
            return
          end
        end

        finish(content, nil)
      end,

      on_error = function(err)
        if had_error or finished then
          return
        end
        had_error = true

        local error_body = error_handler.extract_error_string(err)
        local error_type = error_handler.classify_http_error(error_body, adapter)

        -- token_limit: 使用 caller_chat 级共享计数器
        if error_type == error_handler.TYPES.TOKEN_LIMIT then
          local count = caller_chat and (caller_chat._compact_token_limit_retries or 0) or 0
          local delay = error_handler.get_retry_delay(error_handler.TYPES.TOKEN_LIMIT, count)
          if caller_chat and delay then
            error_handler.consume_token_limit_retry(caller_chat)
            local config = error_handler.RETRY_CONFIGS.token_limit
            vim.notify(
              string.format("[streaming_llm] token 超限，%ds 后重试 (%d/%d)", delay, count + 1, config.max_retries),
              vim.log.levels.WARN
            )
            vim.defer_fn(function()
              if not finished then
                do_request()
              end
            end, delay * 1000)
            return
          end
        end

        -- 其他可重试错误
        if error_type and error_handler.is_retryable(error_type) then
          local count = retry_counts[error_type] or 0
          local delay = error_handler.get_retry_delay(error_type, count)
          if delay then
            retry_counts[error_type] = count + 1
            local config = error_handler.RETRY_CONFIGS[error_type]
            vim.notify(
              string.format(
                "[streaming_llm] %s，%ds 后重试 (%d/%d)",
                error_type == error_handler.TYPES.RATE_LIMITED and "限流" or "网络问题",
                delay,
                count + 1,
                config and config.max_retries or 0
              ),
              vim.log.levels.WARN
            )
            vim.defer_fn(function()
              if not finished then
                do_request()
              end
            end, delay * 1000)
            return
          end
        end

        -- 不可重试或重试耗尽
        finish(nil, "LLM request failed: " .. (error_body or "unknown"))
      end,

      silent = true,
    })
  end

  do_request()

  return {
    cancel = function(reason)
      if finished then
        return
      end
      stop_active_job()
      finish(nil, tostring(reason or "LLM request cancelled"))
    end,
  }
end

--- 流式请求 + vim.wait 等待结果（同步语义，但 HTTP 层仍是流式）
--- 用于必须同步返回的场景（如 compact_range 的顺序路径）
--- HTTP 层流式避免网关超时，Lua 层 vim.wait 阻塞等待
---@param adapter table 已初始化的 adapter
---@param messages table[] 消息数组
---@param opts table|nil 选项 { tools = table|nil, timeout = number|nil, caller_chat = table|nil }
---@return string|nil content 响应内容
---@return string|nil error 错误信息
function M.streaming_request_sync(adapter, messages, opts, callback_override)
  opts = opts or {}
  local timeout_ms = opts.timeout or 120000 -- 默认 2 分钟
  local wait_timeout = timeout_ms + 30000 -- vim.wait 超时 = HTTP timeout + 30s buffer

  local result_content = nil
  local result_error = nil
  local done = false

  -- 如果提供了 callback_override，使用异步模式
  if callback_override then
    M.streaming_request(adapter, messages, opts, function(content, err)
      callback_override(content, err)
    end)
    return
  end

  M.streaming_request(adapter, messages, opts, function(content, err)
    result_content = content
    result_error = err
    done = true
  end)

  local completed = vim.wait(wait_timeout, function()
    return done
  end, 50)

  if not completed then
    return nil, string.format("Streaming request timed out after %ds", wait_timeout / 1000)
  end

  return result_content, result_error
end

return M
