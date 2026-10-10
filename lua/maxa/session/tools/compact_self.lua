local param_utils = require("maxa.mcphub.native_servers.shared.params")
local history_core = require("maxa.session.history_core")
-- compact_self.lua: LLM 主动请求压缩当前会话
-- 工具本身只设标记，由 llm_error_recovery 的 done() hook 检测后触发实际压缩
--
-- 流程:
-- 1. LLM 调用 compact_self(instructions="...")
-- 2. handler 设置 chat._self_compact_requested = true + chat._self_compact_instructions
-- 3. 立即返回确认消息（工具不做任何压缩）
-- 4. LLM 完成当前回合 → done() hook 触发
-- 5. llm_error_recovery 检测到标记 → 触发 handoff_compaction.start

return {
  name = "compact_self",
  description = table.concat({
    "Request current-chat compaction after this response completes.",
    "Uses the shared handoff compaction workflow and configured retention profile.",
    "Requires current-conversation compression authorization. Instructions identify recoverable task state and preservation needs.",
  }, " "),
  inputSchema = {
    type = "object",
    properties = {
      instructions = {
        type = "string",
        description = table.concat({
          "Describe the recoverable task state that must survive compression:",
          "the latest user request and goal, completed and unfinished work, ordered next steps,",
          "constraints and loaded rules, changed files, validation status, current errors or blockers, and key decisions.",
          "Also identify history that must remain verbatim and history whose originals may be summarized or deleted from the successor while useful facts survive in handoff.",
          "Use concrete session facts rather than generic instructions.",
        }, " "),
      },
    },
    required = { "instructions" },
  },
  handler = function(req, res)
    -- 获取 chat 实例（req.caller 是 MCPHub caller wrapper，不是 chat 对象）
    local caller = req.caller
    local chat = caller and caller.maxa_ai and caller.maxa_ai.chat
    if not chat then
      return res:error("compact_self can only be called from a chat session"):send()
    end

    local save_id = chat.opts and chat.opts.save_id or nil
    if history_core.is_unsavable_save_id(save_id) then
      return res:error("compact_self is not available for temporary/unsavable chat sessions"):send()
    end

    -- 检查 adapter 是否支持 token 计数
    local adapter = chat.adapter
    if not adapter or not (adapter.features and adapter.features.tokens) then
      return res
        :error(
          "Current adapter does not support token counting. "
            .. "Cannot determine compression need. Use /compact_silent slash command instead."
        )
        :send()
    end

    local params = param_utils.normalize(req.params)
    local instructions = param_utils.default(params.instructions, "")

    -- 设置标记供 done() hook 检测
    chat._self_compact_requested = true
    chat._self_compact_instructions = instructions

    return res
      :text(
        "✅ Compression request accepted. Instructions recorded: "
          .. instructions
          .. "\n\nCompression will start automatically after the current response completes. "
            .. "End this response with recoverable task state; the successor will continue after handoff."
      )
      :send()
  end,
}
