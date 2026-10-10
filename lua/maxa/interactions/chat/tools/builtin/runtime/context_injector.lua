-- Deferred context injection for builtin load_* tools.
--
-- Loading tools run while MaxaAI is still processing tool calls. If they
-- append context immediately, the message may land between assistant tool_calls
-- and tool results. Instead, queue context/image messages and append them after
-- MaxaAIToolsFinished, preserving append-only history:
--   assistant(tool_calls) -> tool_result(s) -> loaded context/image

local M = {}

---@type table<number, { chat: table, transactions: table[] }>
local pending = {}
local listener_active = false

local function get_chat_from_event(args)
  local data = args and args.data
  local bufnr = data and data.bufnr
  if not bufnr then
    return nil
  end

  local ok, maxa_ai = pcall(require, "maxa")
  if ok and maxa_ai.buf_get_chat then
    return maxa_ai.buf_get_chat(bufnr)
  end

  return nil
end

local function chat_key(chat)
  return chat and (chat.id or chat.bufnr or tostring(chat)) or nil
end

local function flush_key(key)
  local batch = pending[key]
  pending[key] = nil
  if not batch or not batch.chat or not batch.transactions then
    return
  end

  local chat = batch.chat
  if not chat.messages then
    return
  end

  for _, transaction in ipairs(batch.transactions) do
    local commit_ok, commit_err = true, nil
    if transaction.commit then
      commit_ok, commit_err = pcall(transaction.commit, chat)
      if commit_ok and commit_err == false then
        commit_ok = false
        commit_err = "transaction commit rejected"
      end
    end
    if commit_ok then
      for _, msg in ipairs(transaction.messages) do
        table.insert(chat.messages, msg)
      end
      if transaction.after_commit then
        local after_ok, after_err = pcall(transaction.after_commit, chat)
        if not after_ok then
          vim.notify("[Maxa AI] post-commit Ability event failed: " .. tostring(after_err), vim.log.levels.ERROR)
        end
      end
    else
      if transaction.on_discard then pcall(transaction.on_discard, chat) end
      vim.notify("[Maxa AI] deferred context transaction failed: " .. tostring(commit_err), vim.log.levels.ERROR)
    end
  end
end

local function ensure_listener()
  if listener_active then
    return
  end
  listener_active = true

  vim.api.nvim_create_autocmd("User", {
    pattern = "MaxaAIToolsFinished",
    callback = function(args)
      local chat = get_chat_from_event(args)
      if not chat then
        return
      end
      local key = chat_key(chat)
      if key and pending[key] then
        flush_key(key)
      end
    end,
  })
end

---Queue one atomic hidden context/image batch after the current tool batch.
---@param chat table Maxa AI chat object
---@param messages table[]
function M.enqueue_batch(chat, messages)
  if not chat or not chat.messages or type(messages) ~= "table" or #messages == 0 then
    return false
  end
  for _, message in ipairs(messages) do
    if type(message) ~= "table" then
      return false
    end
  end

  local key = chat_key(chat)
  if not key then
    return false
  end

  if not pending[key] then
    pending[key] = { chat = chat, transactions = {} }
  end
  pending[key].transactions[#pending[key].transactions + 1] = { messages = messages }
  ensure_listener()
  return true
end

local function discard_key(key)
  local batch = pending[key]
  pending[key] = nil
  for _, transaction in ipairs(batch and batch.transactions or {}) do
    if transaction.on_discard then
      pcall(transaction.on_discard, batch.chat)
    end
  end
end

local function discard_chat(bufnr)
  for key, batch in pairs(pending) do
    if batch.chat and batch.chat.bufnr == bufnr then
      discard_key(key)
    end
  end
end

---Discard uncommitted context transactions for an explicitly cancelled operation.
function M.discard(chat)
  local key = chat_key(chat)
  if key then discard_key(key) end
end

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  callback = function(args)
    discard_chat(args.buf)
  end,
})

---Queue one atomic context transaction. The commit callback runs after the
---tool result exists and before messages publish; after_commit runs only after
---the complete message batch is visible.
---@param chat table
---@param messages table[]
---@param commit? fun(chat: table): any
---@param after_commit? fun(chat: table): any
function M.enqueue_transaction(chat, messages, commit, after_commit, on_discard)
  if not chat or not chat.messages or type(messages) ~= "table" or #messages == 0 then
    return false
  end
  for _, message in ipairs(messages) do
    if type(message) ~= "table" then
      return false
    end
  end
  local key = chat_key(chat)
  if not key then
    return false
  end
  if not pending[key] then
    pending[key] = { chat = chat, transactions = {} }
  end
  pending[key].transactions[#pending[key].transactions + 1] = {
    messages = messages,
    commit = commit,
    after_commit = after_commit,
    on_discard = on_discard,
  }
  ensure_listener()
  return true
end

---Queue one hidden context/image message after the current tool batch.
---@param chat table Maxa AI chat object
---@param message table message to append
function M.enqueue(chat, message)
  return M.enqueue_batch(chat, { message })
end

---Flush queued messages for a chat immediately. Intended for tests/fallbacks.
---@param chat table
function M.flush(chat)
  local key = chat_key(chat)
  if key then
    flush_key(key)
  end
end

---Flush the complete pending batch before an observer such as history autosave.
---@param chat table
---@param observer fun(chat: table): any
function M.flush_before(chat, observer)
  M.flush(chat)
  return observer(chat)
end

---Return pending count for tests/debugging.
---@param chat table
---@return number
function M.pending_count(chat)
  local key = chat_key(chat)
  local batch = key and pending[key]
  if not batch then
    return 0
  end
  local count = 0
  for _, transaction in ipairs(batch.transactions or {}) do
    count = count + #(transaction.messages or {})
  end
  return count
end

return M
