local M = {}

local sessions = {}
local MAX_STDERR = 8000

local function notify(message, level)
  vim.notify("[upload] " .. message, level or vim.log.levels.INFO)
end

local function normalize(path)
  return tostring(path or ""):gsub("\\", "/"):gsub("/+$", "")
end

function M.project_root(bufnr)
  local root
  if type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) then
    root = vim.fs.root(bufnr, { ".maxa" })
  end
  if not root then
    local cwd = vim.uv.cwd() or vim.fn.getcwd(-1, -1)
    root = cwd and vim.fs.root(cwd, { ".maxa" }) or cwd
  end
  return normalize(root) ~= "" and normalize(root) or "."
end

local function is_chat_busy(chat)
  return chat.current_request ~= nil or chat.current_tool ~= nil or (chat.status ~= nil and chat.status ~= "")
end

local function unlock(state)
  if not state.locked then return end
  state.locked = false
  local chat = state.chat
  if chat and chat.ui and type(chat.ui.unlock_buf) == "function" and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(chat.ui.unlock_buf, chat.ui)
  end
end

local function clear_autocmd(state)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

local function kill(state)
  if state.handle and type(state.handle.kill) == "function" then
    pcall(state.handle.kill, state.handle, 15)
  end
end

local function replace_placeholder(state, replacement)
  if not vim.api.nvim_buf_is_valid(state.bufnr) then return false end
  local lines = replacement and vim.split(replacement, "\n", { plain = true }) or {}

  local range = state.placeholder_range
  if range then
    local got_text, current = pcall(
      vim.api.nvim_buf_get_text,
      state.bufnr,
      range.start.row,
      range.start.col,
      range["end"].row,
      range["end"].col,
      {}
    )
    if not got_text or table.concat(current, "\n") ~= state.placeholder_text then return false end
    local ok = pcall(
      vim.api.nvim_buf_set_text,
      state.bufnr,
      range.start.row,
      range.start.col,
      range["end"].row,
      range["end"].col,
      lines
    )
    if ok then state.placeholder_range = nil; state.placeholder_line = nil end
    return ok
  end

  if not state.placeholder_line then return false end
  local index = state.placeholder_line - 1
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  if index < 0 or index >= line_count then return false end
  local current = vim.api.nvim_buf_get_lines(state.bufnr, index, index + 1, false)[1]
  if current ~= state.placeholder_text then return false end
  local ok = pcall(vim.api.nvim_buf_set_lines, state.bufnr, index, index + 1, false, lines)
  if ok then state.placeholder_line = nil end
  return ok
end

local function finish(state, kind, detail)
  if state.finished then return false end
  state.finished = true
  sessions[state.bufnr] = nil
  clear_autocmd(state)
  unlock(state)
  require("maxa.interactions.chat.slash_commands.insertion").discard_anchor(
    state.chat,
    state.insertion_context
  )

  if kind == "submitted" then
    local content = table.concat(detail, "\n")
    if not replace_placeholder(state, content) then
      local ok, err = pcall(state.chat.add_buf_message, state.chat, { content = content })
      if not ok then
        notify("Upload succeeded but path insertion failed: " .. tostring(err) .. "\n" .. content, vim.log.levels.ERROR)
      end
    end
  else
    replace_placeholder(state, nil)
  end

  if kind == "error" then
    notify(detail or "Upload service failed", vim.log.levels.ERROR)
  elseif kind == "cancelled" and detail then
    notify(detail, vim.log.levels.INFO)
  end
  return true
end

local function validate_paths(state, paths)
  if type(paths) ~= "table" or #paths == 0 then return nil, "submitted.paths must be a non-empty array" end
  local prefix = ".maxa/upload/" .. state.session_id .. "/"
  local seen, valid = {}, {}
  for index, value in ipairs(paths) do
    if type(value) ~= "string" or value:sub(1, 1) == "/" or value:sub(1, #prefix) ~= prefix then
      return nil, "submitted.paths contains an invalid path at index " .. index
    end
    local normalized = normalize(value)
    for segment in normalized:gmatch("[^/]+") do
      if segment == "." or segment == ".." then
        return nil, "submitted.paths contains a traversal segment at index " .. index
      end
    end
    if seen[normalized] then return nil, "submitted.paths contains a duplicate path" end
    seen[normalized] = true
    local absolute = vim.fs.joinpath(state.project_root, normalized)
    local stat = vim.uv.fs_stat(absolute)
    if not stat or stat.type ~= "file" then return nil, "submitted path is not an existing file: " .. normalized end
    table.insert(valid, normalized)
  end
  return valid
end

local function protocol_failure(state, message)
  kill(state)
  finish(state, "error", "Upload protocol error: " .. message)
end

local function expected_hostname()
  return require("maxa.config").runtime().chat_upload.hostname
end

local function valid_ready(event)
  local host = expected_hostname()
  local loopback = host == "127.0.0.1"
  if event.bind ~= (loopback and "127.0.0.1" or "0.0.0.0") or event.host ~= host then return false end
  if type(event.port) ~= "number" or event.port % 1 ~= 0 or event.port < 1 or event.port > 65535 then return false end
  if type(event.url) ~= "string" or type(event.session_id) ~= "string" or event.session_id == "" then return false end
  local scheme, url_host, port, token = event.url:match("^(https?)://([^:/]+):(%d+)/session/([^/]+)/$")
  return scheme == (loopback and "http" or "https") and url_host == host
    and tonumber(port) == event.port and token ~= nil and token ~= ""
end

local function handle_event(state, event)
  if state.finished then return end
  if type(event) ~= "table" or type(event.event) ~= "string" then
    return protocol_failure(state, "event object/type is invalid")
  end

  if event.event == "error" then
    if state.terminal then return protocol_failure(state, "duplicate terminal event") end
    state.terminal = true
    return finish(state, "error", tostring(event.message or event.code or "Upload service error"))
  end

  if event.event == "ready" then
    if state.ready then return protocol_failure(state, "duplicate ready event") end
    if not valid_ready(event) then return protocol_failure(state, "ready event fields are invalid") end
    state.ready = true
    state.session_id = event.session_id
    state.placeholder_text = "请使用这个地址上传文件：" .. event.url
    local inserted, line_or_error, _, write_range = pcall(
      require("maxa.interactions.chat.slash_commands.insertion").add,
      state.chat,
      state.insertion_context,
      { content = state.placeholder_text }
    )
    if not inserted or type(line_or_error) ~= "number" then
      return protocol_failure(state, "could not insert upload placeholder: " .. tostring(line_or_error))
    end
    state.placeholder_line = line_or_error
    state.placeholder_range = write_range
    local ok, err = pcall(state.chat.ui.lock_buf, state.chat.ui)
    if not ok then return protocol_failure(state, "could not lock Chat: " .. tostring(err)) end
    state.locked = true
    return
  end

  if not state.ready then return protocol_failure(state, "terminal event arrived before ready") end
  if state.terminal then return protocol_failure(state, "duplicate terminal event") end
  state.terminal = true

  if event.event == "submitted" then
    local paths, err = validate_paths(state, event.paths)
    if not paths then return protocol_failure(state, err) end
    state.pending_terminal = { kind = "submitted", detail = paths }
  elseif event.event == "cancelled" then
    state.pending_terminal = { kind = "cancelled" }
  else
    protocol_failure(state, "unsupported event: " .. event.event)
  end
end

local function consume_stdout(state, chunk)
  if state.finished or not chunk then return end
  state.stdout = state.stdout .. chunk
  while true do
    local newline = state.stdout:find("\n", 1, true)
    if not newline then break end
    local line = state.stdout:sub(1, newline - 1)
    state.stdout = state.stdout:sub(newline + 1)
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if not ok then return protocol_failure(state, "stdout contains non-JSON data") end
      handle_event(state, event)
      if state.finished then return end
    end
  end
end

local function install_close_hook(state)
  state.augroup = vim.api.nvim_create_augroup("maxa_chat_upload_" .. state.bufnr, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = state.augroup,
    pattern = "MaxaAIChatClosed",
    callback = function(args)
      if args.data and args.data.bufnr == state.bufnr and not state.finished then
        kill(state)
        finish(state, "cancelled")
      end
    end,
  })
end

function M.start(chat, opts)
  opts = opts or {}
  if type(chat) ~= "table" or type(chat.bufnr) ~= "number" or type(chat.add_buf_message) ~= "function" or not chat.ui then
    notify("Active Chat is not available", vim.log.levels.ERROR)
    return nil
  end
  if is_chat_busy(chat) then
    notify("Chat is busy; finish the current request or tool first", vim.log.levels.WARN)
    return nil
  end
  if sessions[chat.bufnr] then
    notify("An upload session is already active for this Chat", vim.log.levels.WARN)
    return nil
  end

  local project_root = opts.project_root or M.project_root(chat.bufnr)
  local config_root = vim.fn.stdpath("config")
  local upload_config = require("maxa.config").runtime().chat_upload
  local cli = opts.cli or upload_config.cli
  if vim.fn.filereadable(cli) ~= 1 then
    notify("Upload service entrypoint not found: " .. cli, vim.log.levels.ERROR)
    return nil
  end

  local state = {
    chat = chat,
    bufnr = chat.bufnr,
    project_root = project_root,
    stdout = "",
    stderr = "",
    ready = false,
    terminal = false,
    finished = false,
    locked = false,
    insertion_context = opts.context,
  }
  sessions[state.bufnr] = state
  install_close_hook(state)

  local spawn = opts.spawn or vim.system
  local command = opts.command or { "node", cli, "--project-root", project_root, "--hostname", upload_config.hostname }
  local ok, handle = pcall(spawn, command, {
    cwd = config_root,
    text = true,
    stdout = function(err, data)
      vim.schedule(function()
        if err and not state.finished then return protocol_failure(state, tostring(err)) end
        consume_stdout(state, data)
      end)
    end,
    stderr = function(_, data)
      if data then state.stderr = (state.stderr .. data):sub(-MAX_STDERR) end
    end,
  }, function(result)
    vim.schedule(function()
      state.handle = nil
      if state.finished then return end
      local trailing = vim.trim(state.stdout)
      if trailing ~= "" then
        local decode_ok, event = pcall(vim.json.decode, trailing)
        state.stdout = ""
        if not decode_ok then return protocol_failure(state, "unterminated non-JSON stdout") end
        handle_event(state, event)
      end
      if state.finished then return end
      if state.pending_terminal and result.code == 0 then
        return finish(state, state.pending_terminal.kind, state.pending_terminal.detail)
      end
      local detail = vim.trim(state.stderr)
      local message = string.format("Upload service exited unexpectedly (code %s)", tostring(result.code))
      if state.pending_terminal then message = message .. " after " .. state.pending_terminal.kind end
      if detail ~= "" then message = message .. ": " .. detail end
      finish(state, "error", message)
    end)
  end)
  if not ok or not handle then
    sessions[state.bufnr] = nil
    clear_autocmd(state)
    notify("Could not start upload service: " .. tostring(handle), vim.log.levels.ERROR)
    return nil
  end
  state.handle = handle
  require("maxa.interactions.chat.slash_commands.insertion").track_context(chat, opts.context)
  return state
end

function M.active(bufnr)
  return sessions[bufnr]
end

M._consume_stdout = consume_stdout
M._handle_event = handle_event
M._finish = finish
M._sessions = sessions

return M
