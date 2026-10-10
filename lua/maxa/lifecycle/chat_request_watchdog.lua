-- Request-scoped effective-progress monitoring. Local tools own their deadlines.
local M = {}
local sessions = {}
local DEFAULTS = {
  connect_timeout_ms = 180000,
  first_response_timeout_ms = 180000,
  response_idle_timeout_ms = 180000,
  tool_args_idle_timeout_ms = 180000,
  check_interval_ms = 10000,
}

-- Normalize explicit declarations before config defaults obscure missing keys.
function M.normalize(opts)
  local result = vim.deepcopy(opts or {})
  if result.first_response_timeout_ms == nil then
    result.first_response_timeout_ms = result.no_message_warn_after_ms
  end
  for _, key in ipairs({ "response_idle_timeout_ms", "tool_args_idle_timeout_ms" }) do
    if result[key] == nil then result[key] = result.no_progress_warn_after_ms end
  end
  return result
end

function M.options(opts)
  local result = vim.tbl_extend("force", DEFAULTS, M.normalize(opts))
  for key, value in pairs(DEFAULTS) do
    value = result[key]
    assert(type(value) == "number" and value == value and value < math.huge
      and (value > 0 or (key ~= "check_interval_ms" and value == -1)),
      "maxa.lifecycle.watchdog." .. key .. " must be positive and finite" .. (key ~= "check_interval_ms" and " or -1" or ""))
  end
  return result
end

local function now() return vim.uv.hrtime() / 1000000 end
local function key(chat) return type(chat) == "table" and chat.bufnr or chat end

function M.finish(chat, id)
  local session = sessions[key(chat)]
  if not session or (id and session.id ~= id) then return end
  sessions[key(chat)] = nil
  if session.timer then
    session.timer:stop()
    session.timer:close()
  end
end

function M.start(chat, handle, opts)
  M.finish(chat)
  opts = M.options(opts)
  local session = { id = handle.id, handle = handle, phase = "first_response", last = now(),
    reason = "dispatch", opts = opts, calls = {} }
  sessions[chat.bufnr] = session
  local function check()
    if sessions[chat.bufnr] ~= session then return end
    if chat._closed then return M.finish(chat, session.id) end
    local field = session.phase == "first_response" and "first_response_timeout_ms"
      or session.phase == "tool_args" and "tool_args_idle_timeout_ms" or "response_idle_timeout_ms"
    local limit, elapsed = opts[field], now() - session.last
    if limit == -1 or elapsed < limit then return end
    M.finish(chat, session.id)
    handle.timeout({ code = "chat_communication_timeout", phase = session.phase, request_id = session.id,
      idle_ms = elapsed, timeout_ms = limit, last_progress = session.reason,
      message = string.format("Chat communication timed out: request=%s phase=%s idle=%.0fms limit=%sms last_progress=%s",
        session.id, session.phase, elapsed, limit, session.reason) })
  end
  if opts.first_response_timeout_ms ~= -1 or opts.response_idle_timeout_ms ~= -1 or opts.tool_args_idle_timeout_ms ~= -1 then
    session.timer = vim.uv.new_timer()
    session.timer:start(opts.check_interval_ms, opts.check_interval_ms, vim.schedule_wrap(check))
  end
  session.check = check
end

function M.observe(chat, id, observation)
  local session = sessions[key(chat)]
  if not session or session.id ~= id or not observation or observation.error then return end
  local bytes = tonumber(observation.bytes) or 0
  local boundary = false
  if observation.tool_started then
    local call = observation.tool_id or "tool"
    if not session.calls[call] then
      session.calls[call], boundary = "receiving", true
    elseif not observation.tool_delta then
      return
    end
  elseif observation.tool_done_all then
    for call, state in pairs(session.calls) do
      if state == "receiving" then session.calls[call], boundary = "done", true end
    end
  elseif observation.tool_done then
    local call = observation.tool_id or "tool"
    if session.calls[call] == "receiving" then session.calls[call], boundary = "done", true end
  end
  if bytes <= 0 and not boundary then return end
  session.last = now()
  session.phase = observation.phase or "response"
  session.reason = bytes > 0 and (session.phase .. "_output")
    or ((observation.tool_done or observation.tool_done_all) and "tool_args_done" or "tool_args_started")
end

function M.is_active(chat) return sessions[key(chat)] ~= nil end
function M._sessions() return sessions end
function M.setup() return true end
function M.reset_setup()
  for bufnr in pairs(sessions) do M.finish(bufnr) end
end

return M
