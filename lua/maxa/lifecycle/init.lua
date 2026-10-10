-- Hooks 统一入口
-- 提供 setup() 调用所有位置无关的钩子
local M = {}
local setup_complete = false

--- 设置所有位置无关的钩子
--- 应在 maxa.config 开头调用
---@param opts table 配置选项
---@param opts.default_adapter string 默认适配器名称
---@param opts.default_model string 默认模型名称
function M.setup(opts)
  if setup_complete then
    return
  end
  opts = opts or {}

  -- Cross-capability lifecycle listeners only. Adapter, Chat, Tools, UI, and
  -- completion behavior is implemented directly by their canonical owners.
  require("maxa.interactions.chat.tools.display").setup()

  -- Chat/add_message Responses boundary must precede any on_created rules callback.
  require("maxa.lifecycle.chat_submitted_event").setup()

  -- Project schema check: first chat per project compares project schema with runtime-supported schema.
  require("maxa.project.schema_check").setup()

  -- 工具完成 AbilityHook 事件：本轮 tool results 写入后、auto-submit 边界触发
  require("maxa.lifecycle.tool_calls_completed_event").setup()

  -- 响应开始事件：HTTP 请求收到首个服务器 chunk 时触发 MaxaAIChatResponseStarted
  require("maxa.lifecycle.chat_response_started_event").setup()

  -- Chat HTTP 请求 watchdog：按有效输出监控阶段空闲；错误恢复由 session owner 协调
  require("maxa.lifecycle.chat_request_watchdog").setup(require("maxa.config").runtime().lifecycle.watchdog)

  -- Chat soft stop：当前请求/工具批次自然完成后阻止下一次 auto-submit 续跑
  require("maxa.lifecycle.chat_soft_stop").setup()

  -- Chat context limit stop：上下文占比达到阈值后复用 soft-stop 安全边界停止续跑
  require("maxa.lifecycle.chat_context_limit_stop").setup()

  -- Token threshold decision：95% 时安全停止，Telegram 收尾（5 分钟默认）/中断/压缩
  require("maxa.lifecycle.chat_token_threshold_decision").setup()

  -- session trace：仅对已启用 _meta.session_trace 的会话记录自然轮 opt-in lineage。
  require("maxa.lifecycle.session_trace_lifecycle").setup()

  -- AbilityHook 系统：注册 startup hooks，并在 `load`/历史恢复时管理 session hooks
  require("maxa.abilities.hooks")

  -- builtin async task 生命周期：chat close / Neovim exit 时取消仍在运行的异步任务
  require("maxa.lifecycle.builtin_async_tasks").setup()

  setup_complete = true
end

function M.reset_setup()
  setup_complete = false
end

return M
