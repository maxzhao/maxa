-- Process-local request measurements shared by every consumer of an adapter.
local M = {}
local totals = {}
local active = {}

local function now()
  return vim.uv.hrtime() / 1e9
end

local function empty()
  return { tokens = 0, tokens_known = true, output_tokens = 0, duration = 0, first_token_time = 0, first_token_count = 0, requests = 0 }
end

local function add(target, sample)
  if sample.tokens then target.tokens = target.tokens + sample.tokens else target.tokens_known = false end
  target.output_tokens = target.output_tokens + sample.output_tokens
  target.duration = target.duration + sample.duration
  target.requests = target.requests + 1
  if sample.ttft then
    target.first_token_time = target.first_token_time + sample.ttft
    target.first_token_count = target.first_token_count + 1
  end
end

local function snapshot(value)
  if not value then return {} end
  return {
    tokens = value.requests > 0 and value.tokens_known and value.tokens or nil,
    ttft = value.first_token_count > 0 and value.first_token_time / value.first_token_count or nil,
    tks = value.duration > 0 and value.output_tokens / value.duration or nil,
  }
end

function M.begin(adapter)
  local request = { adapter = adapter, name = adapter.name, started = now(), bytes = 0, usage = {} }
  active[request] = true
  return request
end

function M.observe(request, data)
  if not active[request] then return end
  local handler = require("maxa.adapters").get_handler(request.adapter, "parse_metrics")
  if not handler then return end
  local ok, observation = pcall(handler, request.adapter, data)
  if not ok or type(observation) ~= "table" then return end
  if observation.error then request.failed = true end
  for key, value in pairs(observation.usage or {}) do
    if type(value) == "number" and value >= 0 then request.usage[key] = value end
  end
  local bytes = observation.bytes or 0
  if request.bytes == 0 then bytes = bytes + (observation.fallback_bytes or 0) end
  local at = now()
  if bytes > 0 or observation.first_output then request.first = request.first or at end
  if bytes > 0 then
    request.bytes = request.bytes + bytes
  end
  return observation
end

function M.finish(request, success)
  if not active[request] then return request.result end
  active[request] = nil
  local duration = now() - request.started
  if not success or request.failed or duration <= 0 then return end
  local usage = request.usage
  local output = usage.output_tokens
  if not output or (output == 0 and request.bytes > 0) then output = math.ceil(request.bytes / 4) end
  if output <= 0 and not request.first then return end
  local result = {
    tokens = usage.total_tokens or (usage.input_tokens and usage.input_tokens + output),
    output_tokens = output,
    duration = duration,
    ttft = request.first and request.first - request.started or nil,
  }
  request.result = result
  totals[request.name] = totals[request.name] or empty()
  add(totals[request.name], result)
  local state = package.loaded["maxa.session.status.state"]
  if state then state.refresh() end
  return result
end

function M.adapter_status(name)
  local value = vim.tbl_extend("force", empty(), totals[name] or {})
  local at = now()
  for request in pairs(active) do
    if request.name == name and request.first and not request.failed then
      local output = math.max(request.usage.output_tokens or 0, request.bytes / 4)
      add(value, {
        tokens = request.usage.total_tokens or (request.usage.input_tokens and request.usage.input_tokens + output),
        output_tokens = output,
        duration = at - request.started,
        ttft = request.first - request.started,
      })
    end
  end
  return snapshot(value)
end

function M.start_turn(chat)
  chat._request_metrics = empty()
end

function M.record_turn(chat, sample)
  if sample and chat._request_metrics then add(chat._request_metrics, sample) end
end

function M.finish_turn(chat)
  if chat._request_metrics then
    chat._last_turn_metrics = snapshot(chat._request_metrics)
    chat._request_metrics = nil
  end
  return chat._last_turn_metrics
end

function M.format(value, include_tokens)
  value = value or {}
  local parts = {}
  if include_tokens then
    local tokens = value.tokens
    local text = "--"
    if tokens then
      text = tokens >= 1000000 and string.format("%.1fm", tokens / 1000000)
        or tokens >= 1000 and string.format("%.1fk", tokens / 1000) or tostring(math.floor(tokens))
    end
    parts[#parts + 1] = "[" .. text .. " tok]"
  end
  parts[#parts + 1] = "[" .. (value.ttft and string.format("%.1fs", value.ttft) or "--") .. "]"
  parts[#parts + 1] = "[" .. (value.tks and string.format("%.1f", value.tks) or "--") .. " tks]"
  return table.concat(parts, " ")
end

return M
