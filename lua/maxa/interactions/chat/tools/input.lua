-- One Chat-local input lease. Tools validate values and own completion.
local api = vim.api
local M = {}
local NS = api.nvim_create_namespace("Maxa-tool_input")
local RESTORE_KEY = "_maxa_tool_restore_draft"

local function valid(chat)
  return chat and chat.bufnr and api.nvim_buf_is_valid(chat.bufnr) and api.nvim_buf_is_loaded(chat.bufnr)
end
M.valid = valid

local function lock(chat, locked)
  if not valid(chat) then return end
  if chat.ui and chat.ui[locked and "lock_buf" or "unlock_buf"] then
    chat.ui[locked and "lock_buf" or "unlock_buf"](chat.ui)
  else vim.bo[chat.bufnr].modifiable = not locked end
end

function M.preserve_draft(state)
  local chat = state.chat
  if not valid(chat) or chat._last_role ~= require("maxa.config").constants.USER_ROLE then return end
  local first = math.max((tonumber(chat.header_line) or 1) - 1, 0)
  state.saved_draft = { lines = api.nvim_buf_get_lines(chat.bufnr, first, -1, false) }
  lock(chat, false)
  if chat.ui and chat.ui.write_lines then chat.ui:write_lines(first, -1, {})
  else api.nvim_buf_set_lines(chat.bufnr, first, -1, false, {}) end
  if not chat._tool_draft_callback and chat.add_callback then
    chat._tool_draft_callback = true
    chat:add_callback("on_ready", function(self)
      local draft = self[RESTORE_KEY]
      if not draft or not valid(self) then return end
      self[RESTORE_KEY] = nil
      local row = math.max((tonumber(self.header_line) or 1) - 1, 0)
      local modifiable = vim.bo[self.bufnr].modifiable
      lock(self, false)
      if self.ui and self.ui.write_lines then self.ui:write_lines(row, -1, draft.lines)
      else api.nvim_buf_set_lines(self.bufnr, row, -1, false, draft.lines) end
      vim.bo[self.bufnr].modifiable = modifiable
    end)
    chat:add_callback("on_closed", function(self) self[RESTORE_KEY] = nil end)
  end
end

function M.restore_draft(state)
  if state.saved_draft then state.chat[RESTORE_KEY] = state.saved_draft end
end

function M.open(chat, options, on_submit)
  if not valid(chat) then return nil, "exact caller Chat is unavailable" end
  if chat._tool_input then return nil, "this Chat already has an active input" end
  if type(options) ~= "table" or (options.mode ~= "input" and options.mode ~= "choice")
    or type(on_submit) ~= "function" then return nil, "invalid input lease options" end
  local lease = { chat = chat, options = options, callback = on_submit, keys = {} }
  chat._tool_input = lease
  if not options.transient then M.preserve_draft(lease) end
  lease.saved = { last_role = chat._last_role, builder = chat.builder and vim.deepcopy(chat.builder.state),
    ui_last_role = chat.ui and chat.ui.last_role, header_line = chat.header_line,
    modifiable = vim.bo[chat.bufnr].modifiable }
  lease.first = api.nvim_buf_line_count(chat.bufnr)
  if options.transient then
    lease.views = {}
    for _, win in ipairs(vim.fn.win_findbuf(chat.bufnr)) do
      lease.views[win] = api.nvim_win_call(win, function() return vim.fn.winsaveview() end)
    end
    lock(chat, false)
    local lines = { "" }
    if chat.ui and chat.ui.set_header then
      chat.ui:set_header(lines, require("maxa.config").interactions.chat.roles[require("maxa.config").constants.LLM_ROLE])
    end
    vim.list_extend(lines, vim.split(options.prompt or "", "\n", { plain = true }))
    if chat.ui and chat.ui.write_lines then chat.ui:write_lines(lease.first, lease.first, lines)
    else api.nvim_buf_set_lines(chat.bufnr, lease.first, lease.first, false, lines) end
    local last = api.nvim_buf_line_count(chat.bufnr) - 1
    local tail = api.nvim_buf_get_lines(chat.bufnr, last, last + 1, false)[1] or ""
    chat:add_buf_message({ role = require("maxa.config").constants.USER_ROLE, content = "" },
      { force_role = true, insert_at = { row = last, col = #tail } })
  else
    -- Append on a new row so Builder cannot extend the tool's EOF anchor.
    lock(chat, false)
    if chat.ui and chat.ui.write_lines then chat.ui:write_lines(lease.first, lease.first, { "" })
    else api.nvim_buf_set_lines(chat.bufnr, lease.first, lease.first, false, { "" }) end
    chat:add_buf_message({ role = require("maxa.config").constants.USER_ROLE, content = "" },
      { force_role = true, insert_at = { row = lease.first, col = 0 } })
  end
  lease.first_mark = api.nvim_buf_set_extmark(chat.bufnr, NS, lease.first, 0, { right_gravity = true })
  lease.input_row = math.max(api.nvim_buf_line_count(chat.bufnr) - 1, 0)
  -- Anchor the separator, not the editable first line: replacing/deleting input
  -- lines must not move the read boundary past the user's reply.
  lease.input_mark = api.nvim_buf_set_extmark(chat.bufnr, NS, lease.input_row - 1, 0, { right_gravity = false })
  chat.header_line = math.max(1, api.nvim_buf_line_count(chat.bufnr) - 2)
  lock(chat, false)
  function lease:rows()
    local separator = api.nvim_buf_get_extmark_by_id(chat.bufnr, NS, self.input_mark, {})[1]
    return api.nvim_buf_get_extmark_by_id(chat.bufnr, NS, self.first_mark, {})[1] or self.first,
      separator and (separator + 1) or self.input_row
  end
  function lease:submit(value)
    if self.closed or self.submitting then return true end
    local accepted = self.callback(value)
    if accepted ~= false and not self.closed then self.submitting = true; lock(chat, true) end
    return true
  end
  function lease:close()
    if self.closed then return end
    self.closed = true
    if chat._tool_input == self then chat._tool_input = nil end
    if valid(chat) then
      for key, callback in pairs(self.keys) do
        for _, map in ipairs(api.nvim_buf_get_keymap(chat.bufnr, "n")) do
          if map.lhs == key and map.callback == callback then vim.keymap.del("n", key, { buffer = chat.bufnr }); break end
        end
      end
      lock(chat, false)
      if chat.ui and chat.ui.write_lines then chat.ui:write_lines(api.nvim_buf_get_extmark_by_id(chat.bufnr, NS, self.first_mark, {})[1] or self.first, -1, {})
      else api.nvim_buf_set_lines(chat.bufnr, api.nvim_buf_get_extmark_by_id(chat.bufnr, NS, self.first_mark, {})[1] or self.first, -1, false, {}) end
      pcall(api.nvim_buf_del_extmark, chat.bufnr, NS, self.first_mark)
      pcall(api.nvim_buf_del_extmark, chat.bufnr, NS, self.input_mark)
      chat._last_role = self.saved.last_role
      if chat.builder and self.saved.builder then chat.builder.state = self.saved.builder end
      if chat.ui then chat.ui.last_role = self.saved.ui_last_role end
      if options.transient then
        chat.header_line = self.saved.header_line
        vim.bo[chat.bufnr].modifiable = self.saved.modifiable
        for win, view in pairs(self.views) do
          if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == chat.bufnr then
            pcall(api.nvim_win_call, win, function() vim.fn.winrestview(view) end)
          end
        end
      else lock(chat, true) end
    end
    M.restore_draft(self)
    self.callback = nil
    local relay = package.loaded["maxa.interactions.chat.tools.builtin.runtime.ask_relay"]
    if relay then relay.refresh(chat) end
  end
  local occupied = {}
  for _, map in ipairs(api.nvim_buf_get_keymap(chat.bufnr, "n")) do occupied[map.lhs] = true end
  lease.shortcuts = {}
  if options.mode == "choice" then
    local index = 0
    for _, row in ipairs(options.choices or {}) do
      for _, item in ipairs(row) do
        index = index + 1
        local key = "<M-" .. index .. ">"
        if index <= 9 and not occupied[key] then
          local value = item.value
          local callback = function()
            if api.nvim_get_current_buf() == chat.bufnr and chat._tool_input == lease then lease.selected = true; lease:submit(value) end
          end
          vim.keymap.set("n", key, callback, { buffer = chat.bufnr, nowait = true, desc = "input: " .. item.label })
          lease.keys[key], lease.shortcuts[index] = callback, true
        end
      end
    end
  end
  local win = vim.fn.bufwinid(chat.bufnr)
  if win ~= -1 then pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(chat.bufnr), 0 }) end
  return lease
end

function M.submit(chat, opts)
  local lease = chat._tool_input
  if not lease or lease.closed or (opts and opts.auto_submit) then return false end
  if not valid(chat) then return false end
  local _, input_row = lease:rows()
  return lease:submit(table.concat(api.nvim_buf_get_lines(chat.bufnr, input_row, -1, false), "\n"))
end

function M.cancel(chat, reason)
  local lease = chat._tool_input
  if not lease then return false end
  if lease.options.on_cancel then pcall(lease.options.on_cancel, reason) end
  lease:close()
  return true
end

return M
