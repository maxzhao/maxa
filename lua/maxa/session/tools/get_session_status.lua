-- get_session_status: 获取会话上下文状态
local history_core = require("maxa.session.history_core")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local session_status = require("maxa.session.session_status")

return {
  name = "get_session_status",
  description = "Return context_status for a saved chat: token usage/limit/percent, messages JSON bytes, and message count.",

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Required saved chat ID.",
      },
    },
    required = { "save_id" },
  },

  handler = function(req, res)
    local params = param_utils.normalize(req.params)
    local save_id = params.save_id
    if not save_id or save_id == "" then
      return res:error("Missing required parameter: save_id")
    end

    local chat_data, err = history_core.read_chat(save_id)
    if not chat_data then
      return res:error("Failed to load chat: " .. (err or "unknown error"))
    end

    local status = session_status.to_llm(session_status.from_chat_data(chat_data, save_id))
    return res:text(vim.json.encode(history_core.create_response({
      save_id = chat_data.save_id or save_id,
      context_status = status,
    })))
  end,
}
