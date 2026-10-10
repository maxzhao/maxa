local config_mod = require("maxa.session.telegram_bridge.config")

local M = {}

local function encode_json(value)
  local ok, encoded = pcall(vim.json.encode, value or {})
  if ok then
    return encoded
  end
  return "{}"
end

local function decode_json(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, value)
  if ok then
    return decoded
  end
  return nil
end

local function request(method, path, body, opts, cb)
  opts = opts or {}
  local cfg = config_mod.get()
  local url = cfg.url .. path
  local cmd = {
    "curl",
    "-sS",
    "--noproxy",
    "*",
    "--max-time",
    tostring(opts.timeout or 35),
    "-X",
    method,
    url,
    "-H",
    "Content-Type: application/json",
    "-w",
    "\n%{http_code}",
  }
  if cfg.token and cfg.token ~= "" then
    vim.list_extend(cmd, { "-H", "X-Maxa-Bridge-Token: " .. cfg.token })
  end
  local system_opts = { text = true }
  if body ~= nil then
    system_opts.stdin = encode_json(body)
    vim.list_extend(cmd, { "--data-binary", "@-" })
  end
  vim.system(cmd, system_opts, function(result)
    local stdout = result.stdout or ""
    local body, status_text = stdout:match("^(.*)\n(%d%d%d)$")
    if not body then
      body = stdout
    end
    local status_code = tonumber(status_text)
    result.stdout = body
    result.http_status = status_code
    local ok = result.code == 0 and status_code ~= nil and status_code >= 200 and status_code < 300
    local decoded = decode_json(body)
    if cb then
      vim.schedule(function()
        cb(ok, decoded, result)
      end)
    end
  end)
end

function M.health(cb)
  request("GET", "/v1/health", nil, { timeout = 5 }, cb)
end

function M.register_instance(payload, cb)
  request("POST", "/v1/instances/register", payload, nil, cb)
end

function M.heartbeat(instance_id, payload, cb)
  request("POST", "/v1/instances/" .. vim.uri_encode(instance_id) .. "/heartbeat", payload, nil, cb)
end

function M.create_chat_upload(payload, cb)
  request("POST", "/v1/chat-uploads", payload, { timeout = 35 }, cb)
end

function M.poll_chat_upload(request_id, timeout, cb)
  local wait = math.max(0, math.min(tonumber(timeout) or 30, 30))
  local path = "/v1/chat-uploads/" .. vim.uri_encode(request_id) .. "?timeout=" .. tostring(wait)
  request("GET", path, nil, { timeout = wait + 5 }, cb)
end

function M.cancel_chat_upload(request_id, payload, cb)
  request("POST", "/v1/chat-uploads/" .. vim.uri_encode(request_id) .. "/cancel", payload, { timeout = 10 }, cb)
end

local function notification_chunks(message)
  local chunks, parts, units = {}, {}, 0
  -- Telegram counts UTF-16 units; keep each UTF-8 scalar intact.
  for char in message:gmatch(".[\128-\191]*") do
    local size = #char == 4 and 2 or 1
    if units + size > 3900 then
      chunks[#chunks + 1] = table.concat(parts)
      parts, units = {}, 0
    end
    parts[#parts + 1], units = char, units + size
  end
  if #parts > 0 or #chunks == 0 then chunks[#chunks + 1] = table.concat(parts) end
  return chunks
end

function M.notify_human_assist(payload, cb, is_current)
  local chunks = not payload.photo and (not payload.parse_mode or payload.parse_mode == "") and type(payload.message) == "string"
      and notification_chunks(payload.message) or { payload.message }
  local index = 1
  local function send()
    if is_current and not is_current() then return end
    local part = vim.tbl_extend("force", {}, payload, { message = chunks[index] })
    request("POST", "/v1/human-assist/notify", part, { timeout = 35 }, function(ok, decoded, result)
      if not ok then
        -- A higher-level retry must not replay earlier successful segments.
        result.telegram_partial_delivery = index > 1
        if cb then cb(false, decoded, result) end
      elseif index < #chunks then
        index = index + 1
        send()
      elseif cb then
        cb(true, decoded, result, {
          message_id = type(decoded) == "table" and decoded.message_id or nil,
          message = chunks[index],
        })
      end
    end)
  end
  send()
end

-- Optional status edits never participate in delivery retries or Chat errors.
function M.edit_human_assist_notification(payload)
  request("POST", "/v1/human-assist/notify/edit", payload, { timeout = 5 })
end

function M.create_human_assist_prompt(payload, cb)
  request("POST", "/v1/human-assist/prompts", payload, { timeout = 35 }, cb)
end

function M.create_human_assist_input(payload, cb)
  request("POST", "/v1/human-assist/inputs", payload, { timeout = 35 }, cb)
end

function M.poll_human_assist(request_id, timeout, cb)
  local wait = math.max(0, math.min(tonumber(timeout) or 20, 30))
  local path = "/v1/human-assist/requests/" .. vim.uri_encode(request_id) .. "?timeout=" .. tostring(wait)
  request("GET", path, nil, { timeout = wait + 10 }, cb)
end

function M.complete_human_assist(request_id, cb)
  request(
    "POST",
    "/v1/human-assist/requests/" .. vim.uri_encode(request_id) .. "/complete",
    { source = "chat" },
    { timeout = 10 },
    cb
  )
end

function M.cancel_human_assist(request_id, cb)
  request("POST", "/v1/human-assist/requests/" .. vim.uri_encode(request_id) .. "/cancel", {}, { timeout = 10 }, cb)
end

function M.download_human_assist_file(request_id, destination, cb)
  local cfg = config_mod.get()
  destination = destination or ("/tmp/telegram_photo_" .. tostring(request_id) .. ".jpg")
  local cmd = {
    "curl",
    "-sS",
    "--noproxy",
    "*",
    "--fail",
    "--max-time",
    "35",
    cfg.url .. "/v1/human-assist/files/" .. vim.uri_encode(request_id),
    "-o",
    destination,
  }
  if cfg.token and cfg.token ~= "" then
    vim.list_extend(cmd, { "-H", "X-Maxa-Bridge-Token: " .. cfg.token })
  end
  vim.system(cmd, { text = true }, function(result)
    if cb then
      vim.schedule(function()
        cb(result.code == 0, destination, result)
      end)
    end
  end)
end

function M.error_message(decoded, result)
  if type(decoded) == "table" and type(decoded.detail) == "string" and decoded.detail ~= "" then
    return decoded.detail
  end
  local stderr = type(result) == "table" and vim.trim(result.stderr or "") or ""
  if stderr ~= "" then
    return stderr
  end
  local status = type(result) == "table" and result.http_status or nil
  return status and ("Telegram Bridge HTTP " .. tostring(status)) or "Telegram Bridge request failed"
end

function M.poll(instance_id, timeout, cb)
  local path = "/v1/events/poll?instance_id=" .. vim.uri_encode(instance_id) .. "&timeout=" .. tostring(timeout or 30)
  request("GET", path, nil, { timeout = (timeout or 30) + 5 }, cb)
end

function M.ack(event_id, cb)
  request("POST", "/v1/events/" .. tostring(event_id) .. "/ack", {}, nil, cb)
end

function M.event_result(event_id, payload, cb)
  request("POST", "/v1/events/" .. tostring(event_id) .. "/result", payload or {}, nil, cb)
end

M._request = request
M._encode_json = encode_json
M._decode_json = decode_json

return M
