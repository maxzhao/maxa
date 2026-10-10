-- get_loaded_items: list committed Abilities and ordinary context files
local history_core = require("maxa.session.history_core")
local loaded_items = require("maxa.session.loaded_items")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

--- 处理函数
---@param req table 请求对象
---@param res table 响应对象
local function get_loaded_items(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id

  -- 获取消息
  local messages
  if not save_id or save_id == "" then
    if not req.caller or not req.caller.maxa_ai then
      return res:error("get_loaded_items: No current session found (must be called from a Maxa AI chat or provide save_id)")
    end
    local chat = req.caller.maxa_ai.chat
    if not chat or not chat.messages then
      return res:error("get_loaded_items: Current session has no messages")
    end
    messages = chat.messages
    save_id = chat.opts and chat.opts.save_id or nil
  else
    local chat_data, err = history_core.read_chat(save_id)
    if not chat_data then
      return res:error("get_loaded_items: Failed to read chat - " .. (err or "unknown error"))
    end
    messages = chat_data.messages or {}
  end

  -- 提取已加载项目（复用 utils 公共函数）
  local items = loaded_items.extract_loaded_items(messages)

  local result = history_core.create_response({
    save_id = save_id,
    abilities = items.abilities,
    contexts = items.contexts,
    total = #items.abilities + #items.contexts,
  })

  return res:text(vim.json.encode(result)):send()
end

return {
  name = "get_loaded_items",
  description = "List committed Abilities and loaded context files for the current or a saved chat; returns identifiers/paths, not content.",

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Saved chat ID; omitted reads current chat.",
      },
    },
    required = {},
  },

  handler = get_loaded_items,
}
