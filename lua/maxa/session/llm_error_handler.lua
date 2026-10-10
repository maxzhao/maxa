-- llm_error_handler.lua: LLM API 错误分类与重试配置
-- 共享错误分类/重试模块，供 Chat recovery 与独立 streaming/压缩工具使用
--
-- 职责:
-- 1. 错误模式匹配表（统一维护）
-- 2. HTTP 错误分类（纯函数，无副作用）
-- 3. 重试配置常量
-- 4. 错误字符串提取（从各种错误对象格式）

local M = {}

-- ═══════════════════════════════════════════════════════════
-- 错误类型
-- ═══════════════════════════════════════════════════════════

---@alias LLMErrorType
---| "token_limit"        # Token 超限（模型上下文窗口不足）
---| "network_issue"      # 网络/临时错误（连接超时、token 过期等）
---| "rate_limited"       # 所有账户被限流（需长等待重试）
---| "invalid_signature"  # Thinking 签名无效（账户切换导致）
---| "permanent"          # 永久性错误（不可重试）

M.TYPES = {
  TOKEN_LIMIT = "token_limit",
  NETWORK = "network_issue",
  RATE_LIMITED = "rate_limited",
  INVALID_SIGNATURE = "invalid_signature",
  PERMANENT = "permanent",
}

-- ═══════════════════════════════════════════════════════════
-- 重试配置
-- ═══════════════════════════════════════════════════════════

---@class LLMRetryConfig
---@field max_retries number 最大重试次数
---@field delays number[]|nil 递增延迟序列（秒）
---@field delay number|nil 固定延迟（秒，兼容旧配置）

M.RETRY_CONFIGS = setmetatable({}, {
  __index = function(_, key)
    return require("maxa.config").runtime().recovery[key]
  end,
})

-- ═══════════════════════════════════════════════════════════
-- 错误模式匹配表
-- 新增错误模式时只需在此处添加，所有消费方自动生效
-- ═══════════════════════════════════════════════════════════

-- Protocol-level context-window failures shared by active OpenAI-compatible adapters.
local TOKEN_LIMIT_PATTERNS = {
  "model_max_prompt_tokens_exceeded",
  "exceeds the limit",
  "prompt token count.*exceeds",
  "context_length_exceeded",
  "maximum context length",
}

-- 可重试的网络/临时错误（连接超时、token 过期等）
local RETRYABLE_PATTERNS = {
  "Chat communication timed out", -- request watchdog idle deadline
  "Connection timed out", -- curl timeout
  "curl: %(28%)", -- curl error 28 (timeout)
  "curl: %(18%)", -- curl error 18 (SSL certificate / transfer errors from upstream)
  "curl: %(92%)", -- curl error 92 (SSL verify fail during token refresh)
  "unable to get local issuer certificate", -- OpenSSL issuer chain validation error
  "SSL certificate", -- generic SSL certificate validation error
  "token expired", -- OAuth token 刷新中
  "unauthorized", -- 401 状态
  "user_request_timeout", -- OpenAI-compatible 408: upstream timed out reading request body
  "Timed out reading request body", -- OpenAI-compatible 408 message body
  "5%d%d error:", -- 5xx 服务端错误（502/503/504/524 等 CDN/网关超时，CC 格式化消息）
  "Internal Server Error", -- HTTP 500 原始 body（hook 捕获 err.body 不含 status code 前缀）
}

-- newapi 后端专有的可重试错误。
-- 某些分组权限错误是上游临时路由/账号态问题，实际可通过延迟重试恢复。
-- 仅在显式声明 backend/quota.provider="newapi" 的 OpenAI Responses adapter 生效。
local NEWAPI_RETRYABLE_PATTERNS = {
  "无权访问 .- 分组",
}

-- 协议级 OpenAI Responses 网关超时错误。
-- 这类 Cloudflare/body 文本是 OpenAI Responses 中转的通用临时故障，适用于显式声明 openai_responses 协议的后端。
local OPENAI_RESPONSES_RETRYABLE_PATTERNS = {
  "error code:%s*504", -- Cloudflare gateway timeout
  "error code:%s*524", -- Cloudflare origin timeout
  '"code"%s*:%s*"upstream_service_error"', -- upstream node/backend transient failure reported with HTTP 400
  "Concurrency limit exceeded for .-, please retry later", -- OpenAI Responses account/user concurrency throttle; retry later
  "usage_limit_reached", -- OpenAI Responses usage throttle surfaced as response.failed
  "The usage limit has been reached", -- OpenAI Responses usage throttle message from MaxaAI notify.inspect output
  "server_is_overloaded", -- OpenAI Responses temporary server overload surfaced as response.failed
  "servers are currently overloaded", -- OpenAI Responses overload message; retry later
  "upstream_error", -- OpenAI Responses upstream transient failure surfaced as response.failed
  "Upstream request failed", -- OpenAI Responses upstream transient failure message; retry later
  "server_error", -- server error
}

-- Permanent OpenAI-compatible request errors: retrying cannot make the selected
-- model/backend support the requested protocol or parameters.
local PERMANENT_PATTERNS = {
  '"code"%s*:%s*"model_not_supported"',
  '"code"%s*:%s*"unsupported_api_for_model"',
  "model_not_supported",
  "unsupported_api_for_model",
  "unsupported_parameter",
}

-- Active local gateway account-pool exhaustion is temporary: all configured
-- accounts are expired or throttled, so use the existing delayed retry path.
local LOCAL_RATE_LIMITED_PATTERNS = {
  "No available accounts%. All accounts are expired or rate%-limited%.",
}

-- Thinking-signature errors can occur after an active gateway rotates accounts.
local INVALID_SIGNATURE_PATTERNS = {
  "Invalid.*signature.*thinking", -- Invalid `signature` in `thinking` block
  "invalid_request_body.*signature", -- {"error":{"message":"...signature...","code":"invalid_request_body"}}
  "Bad Request", -- generic 400 from upstream (no specific reason, likely transient)
}

-- ═══════════════════════════════════════════════════════════
-- 内部工具函数
-- ═══════════════════════════════════════════════════════════

--- 检查字符串是否匹配任一模式
---@param s string 待检查字符串
---@param patterns string[] Lua 模式列表
---@return boolean
local function match_any(s, patterns)
  for _, pattern in ipairs(patterns) do
    if s:match(pattern) then
      return true
    end
  end
  return false
end

--- 获取 adapter 声明的中转后端 provider。
---@param context table|string|nil adapter 上下文或旧 adapter 名称
---@return string|nil
local function get_backend_provider(context)
  if type(context) == "table" then
    if context.backend and context.backend.provider then
      return context.backend.provider
    end
    if context.quota and context.quota.provider then
      return context.quota.provider
    end
  end
  return nil
end

---@param context table|string|nil adapter 上下文或旧 adapter 名称
---@return string|nil
local function get_backend_protocol(context)
  if type(context) == "table" then
    if context.backend and context.backend.protocol then
      return context.backend.protocol
    end
    if context.protocol then
      return context.protocol
    end
  end
  return nil
end

---@param context table|string|nil adapter 上下文或旧 adapter 名称
---@return boolean
local function is_openai_responses_backend(context)
  return get_backend_protocol(context) == "openai_responses"
end

---@param error_body string 错误信息字符串
---@param context table|string|nil adapter 上下文或旧 adapter 名称
---@return LLMErrorType|nil
local function classify_backend_specific_error(error_body, context)
  local provider = get_backend_provider(context)
  if provider == "local"
    and is_openai_responses_backend(context)
    and match_any(error_body, LOCAL_RATE_LIMITED_PATTERNS)
  then
    return M.TYPES.RATE_LIMITED
  end

  if is_openai_responses_backend(context) and match_any(error_body, OPENAI_RESPONSES_RETRYABLE_PATTERNS) then
    return M.TYPES.NETWORK
  end

  if provider == "newapi" and match_any(error_body, NEWAPI_RETRYABLE_PATTERNS) then
    return M.TYPES.NETWORK
  end
  return nil
end

-- ═══════════════════════════════════════════════════════════
-- 公共 API
-- ═══════════════════════════════════════════════════════════

--- 从各种错误对象格式中提取错误信息字符串
--- 处理 MaxaAI HTTP 模块返回的多种错误结构
---@param err any 错误对象（string / table / other）
---@return string 错误信息字符串（空字符串表示无错误信息）
function M.extract_error_string(err)
  if not err then
    return ""
  end

  if type(err) == "string" then
    return err
  end

  if type(err) == "table" then
    -- 优先使用 body（HTTP 响应体，非空时）
    if err.body and err.body ~= "" then
      return tostring(err.body)
    end
    -- 其次检查 stderr.body（streaming 模式下 HTTP 400 错误的结构）
    -- http.lua 构造的错误对象: {message="400 error: ", stderr={status=400, body="...", ...}}
    if type(err.stderr) == "table" and err.stderr.body and err.stderr.body ~= "" then
      return tostring(err.stderr.body)
    end
    -- 再次使用 message（含 status code 信息，如 "524 error: "）
    if err.message and err.message ~= "" then
      return tostring(err.message)
    end
    -- 再次使用 stderr（字符串形式）
    if type(err.stderr) == "string" then
      return err.stderr
    end
    -- 最后序列化整个 table
    return vim.inspect(err)
  end

  return tostring(err)
end

--- 分类 HTTP 错误信息
--- 按优先级依次匹配：permanent → token_limit → backend_specific → invalid_signature → retryable
--- 优先级说明：
---   - token_limit 优先于 invalid_signature：两者都可能是 HTTP 400，
---     但 token_limit 有明确的错误码，避免被 "Bad Request" 误判为签名问题
-- backend_specific：仅在显式声明 provider/protocol 的后端下启用的专有重试规则
---   - retryable 最后：兜底匹配网络/临时错误
---@param error_body string 错误信息字符串
---@param context table|string|nil adapter 上下文（用于 provider 专有规则）；旧字符串仅保留给无 provider 的通用调用
---@return LLMErrorType|nil 错误类型，nil 表示未识别（不可重试）
function M.classify_http_error(error_body, context)
  if not error_body or error_body == "" then
    return nil
  end

  -- Permanent protocol/model errors must never fall through to network retries.
  if match_any(error_body, PERMANENT_PATTERNS) then
    return M.TYPES.PERMANENT
  end

  -- Token 超限（明确的 400 原因，优先于签名检测）
  if match_any(error_body, TOKEN_LIMIT_PATTERNS) then
    return M.TYPES.TOKEN_LIMIT
  end

  -- backend/provider 专有可重试错误
  local backend_specific = classify_backend_specific_error(error_body, context)
  if backend_specific then
    return backend_specific
  end

  -- Thinking 签名无效（账户切换导致）
  if match_any(error_body, INVALID_SIGNATURE_PATTERNS) then
    return M.TYPES.INVALID_SIGNATURE
  end

  -- 可重试的网络/临时错误
  if match_any(error_body, RETRYABLE_PATTERNS) then
    return M.TYPES.NETWORK
  end

  -- 未识别错误 → 不可重试
  return nil
end

--- 检查错误类型是否可重试
---@param error_type LLMErrorType|nil 错误类型
---@return boolean
function M.is_retryable(error_type)
  return error_type ~= nil and M.RETRY_CONFIGS[error_type] ~= nil
end

--- 检查 token_limit 重试是否在预算内（整个压缩会话共享计数）
--- 计数器挂在 chat 对象上，由活动恢复与独立压缩工具共享
---@param chat table|nil chat 实例（计数器载体）
---@return boolean 是否可重试
function M.can_retry_token_limit(chat)
  if not chat then
    return false
  end
  local count = chat._compact_token_limit_retries or 0
  return count < (M.RETRY_CONFIGS.token_limit and M.RETRY_CONFIGS.token_limit.max_retries or 2)
end

--- 消费一次 token_limit 重试配额
---@param chat table chat 实例
function M.consume_token_limit_retry(chat)
  if not chat then
    return
  end
  chat._compact_token_limit_retries = (chat._compact_token_limit_retries or 0) + 1
end

--- 获取指定错误类型和重试次数的延迟时间
---@param error_type LLMErrorType 错误类型
---@param current_count number 当前已重试次数（0-based）
---@return number|nil 延迟秒数，nil 表示重试次数已耗尽或无重试配置
function M.is_supported_openai_responses_backend(context)
  return is_openai_responses_backend(context)
end

function M.get_backend_provider(context)
  return get_backend_provider(context)
end

function M.get_backend_protocol(context)
  return get_backend_protocol(context)
end

function M.get_retry_delay(error_type, current_count)
  local config = M.RETRY_CONFIGS[error_type]
  if not config then
    return nil
  end
  if current_count >= config.max_retries then
    return nil
  end
  -- 递增延迟序列（network_issue）
  if config.delays then
    local index = math.min(current_count + 1, #config.delays)
    return config.delays[index]
  end
  -- 固定延迟（rate_limited）
  return config.delay
end

return M
