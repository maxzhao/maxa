-- list_chats: 列出所有会话历史
local history_core = require("maxa.session.history_core")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

--- 列出会话历史的处理函数
---@param req table 请求对象
---@param res table 响应对象
local function list_chats(req, res)
  local params = param_utils.normalize(req.params)
  local limit = param_utils.default(params.limit, 10)
  local offset = param_utils.default(params.offset, 0)

  -- 参数验证
  if type(limit) ~= "number" or limit < 1 then
    return res:error("list_chats: limit must be a positive number")
  end
  if type(offset) ~= "number" or offset < 0 then
    return res:error("list_chats: offset must be a non-negative number")
  end

  -- 限制最大返回数量
  if limit > 100 then
    limit = 100
  end

  -- 读取索引文件
  local index_data, err = history_core.read_index()
  if not index_data then
    return res:error("list_chats: Failed to read history index - " .. (err or "unknown error"))
  end

  -- 将索引对象转换为数组并排序
  local chats = {}
  for save_id, chat_info in pairs(index_data) do
    table.insert(chats, {
      save_id = save_id,
      title = chat_info.title or "Untitled",
      updated_at = chat_info.updated_at or 0,
      updated_at_formatted = chat_info.updated_at and os.date("%Y-%m-%d %H:%M", chat_info.updated_at) or "",
      message_count = chat_info.message_count or 0,
      token_estimate = chat_info.token_estimate or 0,
      model = chat_info.model or "",
      adapter = chat_info.adapter or "",
      cwd = chat_info.cwd or "",
      project_root = chat_info.project_root or "",
    })
  end

  -- 按 updated_at 降序排序（最新的在前）
  table.sort(chats, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)

  -- 计算总数
  local total = #chats

  -- 应用分页
  local paginated = {}
  for i = offset + 1, math.min(offset + limit, total) do
    table.insert(paginated, chats[i])
  end

  -- 构建响应
  local result = history_core.create_response({
    chats = paginated,
    total = total,
    limit = limit,
    offset = offset,
    has_more = (offset + limit) < total,
  })

  return res:text(vim.json.encode(result)):send()
end

return {
  name = "list_chats",
  description = "List historical chats sorted by updated_at descending, with pagination.",

  inputSchema = {
    type = "object",
    properties = {
      limit = {
        type = "number",
        description = "Maximum sessions to return; default 10, max 100.",
      },
      offset = {
        type = "number",
        description = "Sessions to skip for pagination; default 0.",
      },
    },
  },

  handler = list_chats,
}
