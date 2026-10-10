local param_utils = require("maxa.mcphub.native_servers.shared.params")
local history_core = require("maxa.session.history_core")
local transfer = require("maxa.session.history.transfer")

local M = {
  name = "transfer_chat",
  description = "Copy or move one current-project saved Chat to another Maxa project's .maxa/history with a fresh target save_id; move deletes the source only after target write/index success and the result contains transfer metadata only.",
  inputSchema = {
    type = "object",
    properties = {
      mode = {
        type = "string",
        enum = { "copy", "move" },
        description = "Transfer operation.",
      },
      save_id = {
        type = "string",
        description = "Current-project saved Chat ID to transfer.",
      },
      target_project_root = {
        type = "string",
        description = "Target Maxa project root; must contain .maxa; missing .maxa/history is created.",
      },
    },
    required = { "mode", "save_id", "target_project_root" },
  },
}

function M.handler(req, res)
  local params = param_utils.normalize(req.params)
  local mode = params.mode
  local save_id = params.save_id
  local target_project_root = params.target_project_root

  if mode ~= "copy" and mode ~= "move" then
    return res:error("transfer_chat: mode must be copy or move")
  end
  if type(save_id) ~= "string" or save_id == "" then
    return res:error("transfer_chat: save_id is required")
  end
  if type(target_project_root) ~= "string" or vim.trim(target_project_root) == "" then
    return res:error("transfer_chat: target_project_root is required")
  end

  local result, err = transfer.transfer_chat({
    mode = mode,
    source_history_dir = history_core.get_history_dir(),
    source_save_id = save_id,
    target_project_root = target_project_root,
  })
  if not result then
    return res:error("transfer_chat: " .. (err or "unknown error"))
  end

  return res:text(vim.json.encode(history_core.create_response(result))):send()
end

return M
