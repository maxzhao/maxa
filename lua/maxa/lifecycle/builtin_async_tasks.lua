-- Hook: cancel builtin async tasks when their originating Maxa AI chat exits.
--
-- Async tasks are session-local and must not outlive the chat that started them.
-- This hook only treats actual chat close / buffer delete / Neovim exit as exit
-- boundaries; ChatHidden/Stopped/Done do not cancel async tasks.

local M = {}

local installed = false

local function event_data(args)
  local data = args and args.data
  if type(data) == "table" then
    return data
  end
  return {}
end

local function event_chat_id(args)
  local data = event_data(args)
  if data.id ~= nil then
    local id = tostring(data.id)
    if id ~= "" then
      return id
    end
  end
  return nil
end

local function event_bufnr(args)
  local data = event_data(args)
  return tonumber(data.bufnr) or tonumber(args and args.buf)
end

local function registry()
  local ok, mod = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.async_registry")
  if ok then
    return mod
  end
  return nil
end

local function cancel_for_event(args, reason)
  local reg = registry()
  if not reg then
    return
  end

  local cancelled = {}
  local chat_id = event_chat_id(args)
  local bufnr = event_bufnr(args)

  if chat_id then
    vim.list_extend(cancelled, reg.cancel_by_chat(chat_id, reason))
  end
  if bufnr then
    vim.list_extend(cancelled, reg.cancel_by_bufnr(bufnr, reason))
  end

  return cancelled
end

function M.setup()
  if installed then
    return
  end
  installed = true

  local group = vim.api.nvim_create_augroup("MaxaBuiltinAsyncTasks", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIChatClosed",
    callback = function(args)
      cancel_for_event(args, "Maxa AI chat closed; async task cancelled.")
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      cancel_for_event(args, "Maxa AI chat buffer closed; async task cancelled.")
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      local reg = registry()
      if reg then
        reg.cancel_all("Neovim is exiting; async task cancelled.")
      end
    end,
  })
end

function M._cancel_for_event(args, reason)
  return cancel_for_event(args, reason)
end

return M
