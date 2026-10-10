-- collapse_tail: 塌陷式压缩当前保存会话的尾部连续区间
-- 只做 N..last -> summary + preserved messages，不做 compact_range 的多段处理/过滤/清理

local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local compaction_messages = require("maxa.session.compaction_messages")
local session_trace = require("maxa.session.session_trace")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

local M = {}

local function make_error(message, extra)
  local payload = vim.tbl_extend("force", {
    status = "error",
    error_type = "collapse_tail_validation_error",
    message = message,
    retryable = true,
  }, extra or {})
  return vim.json.encode(payload)
end

local function normalize_index(value)
  local n = tonumber(value)
  if not n then
    return nil
  end
  return math.floor(n)
end

local function normalize_preserve_indices(value)
  if value == nil or value == vim.NIL then
    return {}
  end
  if type(value) ~= "table" then
    return nil, "preserve_indices must be an array"
  end
  local result = {}
  for _, raw in ipairs(value) do
    local n = normalize_index(raw)
    if not n then
      return nil, "preserve_indices must contain only numeric indices"
    end
    table.insert(result, n)
  end
  return result, nil
end

--- Validate collapse params and build collapsed message list.
---@param messages table[] original messages
---@param params table {collapse_start_index, preserve_indices, summary_text}
---@return table[]|nil collapsed_messages
---@return table|nil info
---@return string|nil err
function M.build_collapsed_messages(messages, params)
  if type(messages) ~= "table" or #messages == 0 then
    return nil, nil, "messages must be a non-empty array"
  end
  params = params or {}

  local total_count = #messages
  local collapse_start_index = normalize_index(params.collapse_start_index)
  if not collapse_start_index then
    return nil, nil, "collapse_start_index is required and must be a number"
  end
  if collapse_start_index < 1 or collapse_start_index >= total_count then
    return nil,
      nil,
      string.format(
        "collapse_start_index must be >= 1 and < last message index (%d); got %d",
        total_count,
        collapse_start_index
      )
  end

  local summary_text = params.summary_text
  if type(summary_text) ~= "string" or summary_text == "" then
    return nil, nil, "summary_text is required and must be a non-empty string"
  end

  local preserve_indices, preserve_err = normalize_preserve_indices(params.preserve_indices)
  if not preserve_indices then
    return nil, nil, preserve_err
  end

  local seen = {}
  for i, idx in ipairs(preserve_indices) do
    if idx < collapse_start_index or idx > total_count then
      return nil,
        nil,
        string.format(
          "preserve_indices[%d]=%d is out of collapse range [%d, %d]",
          i,
          idx,
          collapse_start_index,
          total_count
        )
    end
    if seen[idx] then
      return nil, nil, string.format("preserve_indices contains duplicate index %d", idx)
    end
    if i > 1 and idx <= preserve_indices[i - 1] then
      return nil, nil, "preserve_indices must be strictly increasing and in original message order"
    end
    seen[idx] = true
  end

  local collapsed = {}
  for i = 1, collapse_start_index - 1 do
    table.insert(collapsed, vim.deepcopy(messages[i]))
  end

  local summary_message = {
    role = "assistant",
    content = summary_text,
    _meta = {
      tag = "collapse_summary",
      collapsed_range = {
        start_index = collapse_start_index,
        end_index = total_count,
      },
      preserved_indices = vim.deepcopy(preserve_indices),
    },
  }
  table.insert(collapsed, summary_message)

  for _, idx in ipairs(preserve_indices) do
    table.insert(collapsed, vim.deepcopy(messages[idx]))
  end

  -- 与 compact_range 保持一致：force_reload 可能产生同 context.id 的重复加载，
  -- collapse 路径也只保留最后一次成功加载的 context 及其 tool pair。
  collapsed = compaction_messages.dedup_context_messages(collapsed)

  return collapsed,
    {
      collapse_start_index = collapse_start_index,
      collapse_end_index = total_count,
      preserve_indices = preserve_indices,
      total_before = total_count,
      total_after = #collapsed,
    },
    nil
end

local function collapse_tail(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  if not save_id or save_id == "" then
    return res:error(make_error("collapse_tail: save_id is required", { suggested_action = "provide_save_id" })):send()
  end

  -- 压缩会话 save_id 校验
  local caller_chat = req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  if caller_chat and caller_chat._compact_target_save_id then
    local expected = caller_chat._compact_target_save_id
    if save_id ~= expected then
      return res
        :error(
          make_error(
            string.format("collapse_tail: Invalid save_id '%s'. Expected: '%s'", save_id, expected),
            { expected_save_id = expected, actual_save_id = save_id, suggested_action = "use_expected_save_id" }
          )
        )
        :send()
    end
  end

  local source, source_err = history_session.get_messages_source(save_id, req.caller)
  if not source then
    return res:error(make_error("collapse_tail: " .. source_err, { suggested_action = "fix_session_source" })):send()
  end

  local messages = source.messages or {}
  local protected_prefix_count = compaction_messages.get_protected_prefix_count(source)
  local collapse_start_index_for_guard = normalize_index(params.collapse_start_index)
  local protected_err = compaction_messages.validate_collapse_against_protected_prefix(
    collapse_start_index_for_guard,
    protected_prefix_count,
    "collapse_tail"
  )
  if protected_err then
    return res:error(vim.json.encode(protected_err)):send()
  end

  local collapsed_messages, info, build_err = M.build_collapsed_messages(messages, params)
  if build_err then
    return res:error(make_error("collapse_tail: " .. build_err, { suggested_action = "reprobe_or_fix_indices" })):send()
  end

  local actual_save_id = source.save_id or save_id
  local new_save_id = history_core.generate_save_id({ prefix = "collapse" })

  local archive_result, archive_err = session_trace.archive_compression_ranges(source, {
    {
      start_index = info.collapse_start_index,
      end_index = info.collapse_end_index,
      action = "collapse",
    },
  }, {
    tool_name = "collapse_tail",
    mode = "new",
  })
  if not archive_result then
    return res
      :error(
        make_error(
          "collapse_tail: failed to archive trace compression range - " .. tostring(archive_err),
          { retryable = false, suggested_action = "inspect_trace_archive_failure" }
        )
      )
      :send()
  end

  local adapter_name = nil
  if source.chat and source.chat.adapter then
    adapter_name = source.chat.adapter.name
  elseif source.chat_data then
    adapter_name = source.chat_data.adapter
  end

  local ok, save_err = history_session.save_messages_to_history(collapsed_messages, new_save_id, source.chat_data, adapter_name)
  if not ok then
    return res:error(make_error("collapse_tail: failed to save collapsed chat - " .. tostring(save_err), { retryable = false })):send()
  end

  local applied_result, applied_err = session_trace.append_compression_applied(source, {
    tool_name = "collapse_tail",
    mode = "new",
    action = "collapse_tail",
    new_save_id = new_save_id,
    original_save_id = actual_save_id,
    archives = archive_result.archives,
    stats = {
      total_before = info.total_before,
      total_after = info.total_after,
      collapse_start_index = info.collapse_start_index,
      collapse_end_index = info.collapse_end_index,
      preserved_count = #info.preserve_indices,
    },
  })
  if not applied_result then
    return res
      :error(
        make_error(
          "collapse_tail: collapsed chat saved but failed to append trace event - " .. tostring(applied_err),
          { retryable = false, suggested_action = "inspect_trace_event_failure" }
        )
      )
      :send()
  end

  if caller_chat and caller_chat._compact_target_save_id then
    caller_chat._compact_result_save_id = new_save_id
    caller_chat._collapse_tail_succeeded = true
  end

  local response = history_core.create_response({
    source = source.source_type,
    save_id = actual_save_id,
    new_save_id = new_save_id,
    action = "collapse_tail",
    stats = {
      total_before = info.total_before,
      total_after = info.total_after,
      collapse_start_index = info.collapse_start_index,
      collapse_end_index = info.collapse_end_index,
      preserved_count = #info.preserve_indices,
    },
    preserved_indices = info.preserve_indices,
  })

  return res:text(vim.json.encode(response)):send()
end

M.name = "collapse_tail"
M.description = "Cache-friendly compaction for a saved chat tail: replace messages N..last with one assistant summary plus selected preserved messages; no compact_range cleanup, multi-range processing, context deletion, or orphan-tool filtering."
M.inputSchema = {
  type = "object",
  properties = {
    save_id = {
      type = "string",
      description = "Saved Chat session ID whose explicit tail range is collapsed.",
    },
    collapse_start_index = {
      type = "number",
      description = "1-based tail start index; must be >= 1 and < last message index.",
    },
    preserve_indices = {
      type = "array",
      items = { type = "number" },
      description = "Strictly increasing indices inside collapse_start_index..last to keep verbatim after the summary; may be empty.",
    },
    summary_text = {
      type = "string",
      description = "Assistant summary replacing the collapsed tail range.",
    },
  },
  required = { "save_id", "collapse_start_index", "preserve_indices", "summary_text" },
}
M.handler = collapse_tail

return M
