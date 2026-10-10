-- Buffer-local message spans. Source is a canonical message reference or a
-- tool-call locator; neither positions nor display metadata enter chat history.
local api = vim.api
local NS = api.nvim_create_namespace("MaxaAI-chat-message-origin")
local M = {}
M.__index = M

function M.new(chat, bufnr)
  return setmetatable({ chat = chat, bufnr = bufnr, marks = {} }, M)
end

function M:clear()
  if api.nvim_buf_is_valid(self.bufnr) then
    api.nvim_buf_clear_namespace(self.bufnr, NS, 0, -1)
  end
  self.marks = {}
end

function M:mark(first_row, first_col, last_row, last_col, source)
  if not source or (first_row == last_row and first_col == last_col) then
    return
  end
  local lines = api.nvim_buf_get_lines(self.bufnr, first_row, last_row + 1, false)
  for row = first_row, last_row do
    local first = row == first_row and first_col or 0
    local last = row == last_row and last_col or #(lines[row - first_row + 1] or "")
    if last > first then
      local id = api.nvim_buf_set_extmark(self.bufnr, NS, row, first, {
        end_row = row,
        end_col = last,
        invalidate = true,
        right_gravity = true,
        end_right_gravity = false,
      })
      self.marks[id] = source
    end
  end
end

-- Existing marks inside replaced text must not silently attach to new content.
function M:forget_replaced(start_row, end_row)
  if end_row <= start_row then
    return
  end
  for _, mark in ipairs(api.nvim_buf_get_extmarks(self.bufnr, NS, { start_row, 0 }, { end_row, 0 }, {})) do
    if mark[2] < end_row then
      self.marks[mark[1]] = nil
      api.nvim_buf_del_extmark(self.bufnr, NS, mark[1])
    end
  end
end

function M:lines(start_row, end_row, lines, source)
  local count = api.nvim_buf_line_count(self.bufnr)
  local first_row = start_row < 0 and count + start_row + 1 or start_row
  local last_row = end_row < 0 and count + end_row + 1 or end_row
  if first_row == 0 and last_row == count then
    self:clear()
  else
    self:forget_replaced(first_row, last_row)
  end
  api.nvim_buf_set_lines(self.bufnr, start_row, end_row, false, lines)
  if source and #lines > 0 then
    self:mark(first_row, 0, first_row + #lines - 1, #lines[#lines], source)
  end
  return first_row, first_row + #lines
end

function M:text(start_row, start_col, end_row, end_col, lines, source)
  if start_row ~= end_row or start_col ~= end_col then
    self:forget_replaced(start_row, end_row + 1)
  end
  api.nvim_buf_set_text(self.bufnr, start_row, start_col, end_row, end_col, lines)
  if source and #lines > 0 then
    self:mark(start_row, start_col, start_row + #lines - 1,
      #lines == 1 and start_col + #lines[1] or #lines[#lines], source)
  end
  return start_row, start_row + #lines - 1
end

function M:rebind_messages(previous, current, index_map)
  local indices = {}
  for i, message in ipairs(previous or {}) do
    indices[message] = i
  end
  for id, source in pairs(self.marks) do
    local old_index = indices[source]
    if old_index then
      local new_index = index_map and index_map[old_index] or old_index
      self.marks[id] = new_index and current[new_index] or nil
      if not self.marks[id] and api.nvim_buf_is_valid(self.bufnr) then
        api.nvim_buf_del_extmark(self.bufnr, NS, id)
      end
    end
  end
end

-- Invalidate displayed fragments of messages removed or replaced by debug editing.
function M:forget_indices(first, last)
  for id, source in pairs(self.marks) do
    local _, index = self:resolve(source)
    if index and index >= first and index <= last then
      self.marks[id] = nil
      if api.nvim_buf_is_valid(self.bufnr) then
        api.nvim_buf_del_extmark(self.bufnr, NS, id)
      end
    end
  end
end

function M:bind_render_indices(messages)
  for id, source in pairs(self.marks) do
    if type(source) == "table" and source.render_index then
      self.marks[id] = messages[source.render_index]
    end
  end
end

-- Return the nearest displayed user message's first marked row (zero-based).
-- Marks follow buffer edits; canonical message identity keeps consecutive user
-- messages distinct even when they share a rendered header.
function M:user_message_row(current_row, direction)
  if not api.nvim_buf_is_valid(self.bufnr) then
    return nil
  end
  local seen = {}
  local previous
  for _, mark in ipairs(api.nvim_buf_get_extmarks(self.bufnr, NS, 0, -1, { details = true })) do
    local id, row, _, details = unpack(mark)
    if not details.invalid and self.marks[id] then
      local message, index = self:resolve(self.marks[id])
      if index and not seen[index] and message.role == "user"
        and not (message.opts and message.opts.visible == false)
        and not (message.tools and message.tools.call_id)
        and not (message._meta and message._meta.tag == "tool_output") then
        seen[index] = true
        if direction > 0 and row > current_row then
          return row
        end
        if direction < 0 and row < current_row then
          previous = row
        end
      end
    end
  end
  return previous
end

-- Logical render fragments locate restored folds without text-equality searches.
function M:rows(source)
  local first, last
  if not api.nvim_buf_is_valid(self.bufnr) then return nil end
  for _, mark in ipairs(api.nvim_buf_get_extmarks(self.bufnr, NS, 0, -1, { details = true })) do
    local origin = self.marks[mark[1]]
    if origin and origin.call_id == source.call_id and origin.phase == source.phase
      and (source.all_fragments or origin.fragment == source.fragment) and not mark[4].invalid then
      first = math.min(first or mark[2], mark[2])
      last = math.max(last or mark[2], mark[2])
    end
  end
  return first, last
end

-- Exact canonical-message span for display-only destination replacements.
function M:message_range(source)
  local first, last
  if not api.nvim_buf_is_valid(self.bufnr) then return nil end
  for _, mark in ipairs(api.nvim_buf_get_extmarks(self.bufnr, NS, 0, -1, { details = true })) do
    if self.marks[mark[1]] == source and not mark[4].invalid then
      local start = { mark[2], mark[3] }
      local finish = { mark[4].end_row, mark[4].end_col }
      if not first or start[1] < first[1] or (start[1] == first[1] and start[2] < first[2]) then first = start end
      if not last or finish[1] > last[1] or (finish[1] == last[1] and finish[2] > last[2]) then last = finish end
    end
  end
  if first and last then return { first[1], first[2], last[1], last[2] } end
end

function M:remove_call(call_id, phase)
  local rows = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(self.bufnr, NS, 0, -1, { details = true })) do
    local origin = self.marks[mark[1]]
    if origin and origin.call_id == call_id and origin.phase == phase and not mark[4].invalid then rows[mark[2]] = true end
  end
  local ordered = vim.tbl_keys(rows)
  table.sort(ordered, function(a, b) return a > b end)
  for _, row in ipairs(ordered) do self:lines(row, row + 1, {}) end
end

function M:resolve(source)
  local messages = self.chat and self.chat.messages or {}
  if type(source) == "table" and source.call_id then
    for i, msg in ipairs(messages) do
      if source.phase == "result" and (msg.role == "tool" or msg.role == "user")
        and msg.tools and msg.tools.call_id == source.call_id then
        return msg, i
      end
      if source.phase == "request" and (msg.role == "llm" or msg.role == "assistant") then
        for _, call in ipairs(msg.tools and msg.tools.calls or {}) do
          if (call.call_id or call.id) == source.call_id then
            return msg, i
          end
        end
      end
    end
    return nil
  end
  for i, msg in ipairs(messages) do
    if msg == source then
      return msg, i
    end
  end
  return nil
end

-- row/col are zero-based buffer coordinates, col is a byte offset.
function M:at(row, col)
  if not api.nvim_buf_is_valid(self.bufnr) then
    return nil
  end
  local line = api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
  if not line or col >= #line then
    return nil
  end
  local marks = api.nvim_buf_get_extmarks(self.bufnr, NS, { row, 0 }, { row, #line }, { details = true })
  for i = #marks, 1, -1 do
    local mark = marks[i]
    local id, first_row, first_col, details = unpack(mark)
    local last_row, last_col = details.end_row, details.end_col
    if self.marks[id] and not details.invalid
      and (row > first_row or (row == first_row and col >= first_col))
      and (row < last_row or (row == last_row and col < last_col)) then
      local message, index = self:resolve(self.marks[id])
      return message, index, self.marks[id]
    end
  end
  return nil
end

-- Half-open buffer byte range; blockwise selection uses the same columns on each row.
-- Return the contiguous canonical interval, including invisible messages between hits.
function M:indices_in_range(start_row, start_col, end_row, end_col, blockwise)
  if not api.nvim_buf_is_valid(self.bufnr) then
    return nil
  end
  local first, last
  for row = start_row, end_row do
    local line = api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
    if line then
      local left = (row == start_row or blockwise) and start_col or 0
      local right = (row == end_row or blockwise) and end_col or #line
      -- Keep the selection bounds byte-based, like UI:message_at().
      left = math.min(left, #line)
      right = math.min(right, #line)
      if right > left then
        local marks = api.nvim_buf_get_extmarks(self.bufnr, NS, { row, 0 }, { row, #line }, { details = true })
        for _, mark in ipairs(marks) do
          local id, _, col, details = unpack(mark)
          if self.marks[id] and not details.invalid and col < right and details.end_col > left then
            local _, index = self:resolve(self.marks[id])
            if index then
              first = math.min(first or index, index)
              last = math.max(last or index, index)
            end
          end
        end
      end
    end
  end
  return first, last
end

return M
