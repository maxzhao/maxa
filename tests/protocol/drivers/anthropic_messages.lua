-- filepath: tests/protocol/drivers/anthropic_messages.lua
--- Anthropic Messages fixture driver (phase-1 W5).
---
--- Loaded by tests/protocol/runner.lua via dofile per fixture; requiring the
--- adapter module registers it with maxa.runtime.protocol (idempotent), so the
--- runner's `protocol.get_adapter("anthropic_messages")` resolves after dofile.
---
--- Fixture flow (protocol-fixture-contract.md §"Anthropic Messages"):
---   1. adapter:setup(provider_options) -> params
---   2. adapter:build_request(params, {messages, tools}) vs request.expected_body
---   3. response feed:
---        streamed      -> sse parser feeds response.chunks (SSE frame text),
---                         adapter:parse_stream per frame (one at a time)
---        non_streamed  -> response.chunks[1] is the raw JSON body string,
---                         adapter:parse_nonstream(body)
---   4. assertions:
---        - event type sequence (expected_events)
---        - terminal (expected_terminal; expected_error {code, message?} for
---          failed scenarios)
---        - normalized message (role + content parts assembled from events)
---        - tool calls with decoded input (expected_tool_calls)
---        - usage key-subset (expected_usage; updated_at is non-deterministic)
---
--- Driver-specific fixture extensions (documented):
---   - provider_options.cancel_at: 1-based index of the LAST chunk fed before
---     cancel. The driver cancels before feeding the next chunk; all remaining
---     chunks are fed after cancel and MUST produce no events (late rejection).
---   - response.expected_error: { code=string, message?=string } asserted for
---     expected_terminal: failed.
local sse = require("maxa.runtime.protocol.sse")
local normalize = require("maxa.runtime.protocol.normalize")
require("maxa.runtime.protocol.adapters.anthropic_messages")

local M = {}
M.name = "driver.anthropic_messages"

--- Flatten parse_stream/parse_nonstream output (single event, nil, or list).
---@param ev table|table[]|nil
---@param target table[] event accumulator
local function collect(ev, target)
  if ev == nil then
    return
  end
  if ev.type then
    target[#target + 1] = ev
  else
    for _, e in ipairs(ev) do
      target[#target + 1] = e
    end
  end
end

--- Assemble the normalized assistant message parts from the event stream.
--- Mirrors the W8 orchestrator assembly: ordered part builders; consecutive
--- deltas of the same kind merge into one part; tool_call parts are keyed by
--- call id; reasoning signature rides reasoning_delta.signature.
---@param events table[] normalized events
---@return table[] content parts
local function assemble_parts(events)
  local parts = {}
  local function ensure_part(typ)
    local last = parts[#parts]
    if last and last.type == typ then
      return last
    end
    local p = { type = typ }
    parts[#parts + 1] = p
    return p
  end
  for _, e in ipairs(events) do
    if e.type == "message_delta" then
      local p = ensure_part("text")
      p.text = (p.text or "") .. (e.delta or "")
    elseif e.type == "reasoning_delta" then
      local p = ensure_part("reasoning")
      p.content = (p.content or "") .. (e.delta or "")
      if e.signature ~= nil then
        p.signature = e.signature
      end
    elseif e.type == "tool_call_started" then
      parts[#parts + 1] = { type = "tool_call", call_id = e.call_id, name = e.name, arguments = "" }
    elseif e.type == "tool_args_delta" then
      for i = #parts, 1, -1 do
        if parts[i].type == "tool_call" and parts[i].call_id == e.call_id then
          parts[i].arguments = parts[i].arguments .. (e.fragment or "")
          break
        end
      end
    elseif e.type == "tool_call_completed" then
      for i = #parts, 1, -1 do
        if parts[i].type == "tool_call" and parts[i].call_id == e.call_id then
          parts[i].arguments = e.encoded_args or ""
          break
        end
      end
    end
  end
  return parts
end

--- Extract ordered tool calls with decoded arguments. Decoding happens at the
--- tool boundary (fixture contract); empty encoded args decode to {}.
---@param events table[] normalized events
---@return table[]|nil calls { call_id, name, arguments=table }
---@return string|nil err
local function extract_tool_calls(events)
  local order = {}
  local by_id = {}
  for _, e in ipairs(events) do
    if e.type == "tool_call_started" then
      by_id[e.call_id] = { call_id = e.call_id, name = e.name, arguments = "" }
      order[#order + 1] = e.call_id
    elseif e.type == "tool_args_delta" and by_id[e.call_id] then
      by_id[e.call_id].arguments = by_id[e.call_id].arguments .. (e.fragment or "")
    elseif e.type == "tool_call_completed" and by_id[e.call_id] then
      by_id[e.call_id].arguments = e.encoded_args or ""
    end
  end
  local calls = {}
  for _, id in ipairs(order) do
    local call = by_id[id]
    local decoded
    if call.arguments == "" then
      decoded = {}
    else
      local derr
      decoded, derr = normalize.decode_encoded_args(call.arguments)
      if derr then
        return nil, ("tool call %s: %s"):format(id, derr)
      end
    end
    calls[#calls + 1] = { call_id = call.call_id, name = call.name, arguments = decoded }
  end
  return calls, nil
end

---@param fixture table loaded fixture (runner.load_fixture output)
---@param adapter table registered anthropic_messages adapter
---@param runner table protocol runner module (assert helpers)
---@return string[] failures (empty when the fixture passes)
function M.run_fixture(fixture, adapter, runner)
  local failures = {}
  local data = fixture.data
  local req = data.request or {}
  local res = data.response or {}
  local opts = req.provider_options or {}

  -- 1. setup -> normalized params
  local params, serr = adapter:setup(opts)
  if serr then
    return { "setup: " .. tostring(serr) }
  end

  -- 2. build_request vs expected_body
  local body = adapter:build_request(params, {
    messages = req.normalized_messages or {},
    tools = req.normalized_tools or {},
  })
  runner.assert_eq(body, req.expected_body or {}, "build_request body", failures)

  -- 3. feed the response
  local events = {}
  local late_events = {}
  local cancel_at = opts.cancel_at
  local cancelled = false
  local parser = sse.new()
  local function feed(text, target)
    for _, frame in ipairs(parser:feed(text)) do
      collect(adapter:parse_stream(frame), target)
    end
  end
  if data.mode == "streamed" then
    local chunks = res.chunks or {}
    for i, chunk in ipairs(chunks) do
      if cancel_at and i == cancel_at + 1 then
        cancelled = true
        adapter:cancel_stream()
      end
      feed(chunk, cancelled and late_events or events)
    end
    for _, frame in ipairs(parser:finish()) do
      collect(adapter:parse_stream(frame), cancelled and late_events or events)
    end
  else
    local body_text = (res.chunks or {})[1]
    if type(body_text) ~= "string" then
      return { "non_streamed fixture: response.chunks[1] must be the raw JSON body string" }
    end
    collect(adapter:parse_nonstream(body_text), events)
  end

  -- 4a. event type sequence
  local types = {}
  for _, e in ipairs(events) do
    types[#types + 1] = e.type
  end
  runner.assert_eq(types, res.expected_events or {}, "event type sequence", failures)

  -- 4b. terminal
  local term = res.expected_terminal
  if term == "completed" then
    runner.expect(
      events[#events] and events[#events].type == "completed",
      "terminal: expected completed, got " .. tostring(events[#events] and events[#events].type),
      failures
    )
  elseif term == "failed" then
    local last_type = events[#events] and events[#events].type
    runner.expect(last_type == "error", "terminal: expected error, got " .. tostring(last_type), failures)
    local expected_error = res.expected_error
    if expected_error and expected_error.code then
      local err_ev
      for _, e in ipairs(events) do
        if e.type == "error" then
          err_ev = e
        end
      end
      runner.expect(err_ev ~= nil, "terminal: expected an error event", failures)
      if err_ev then
        runner.assert_eq(err_ev.error.code, expected_error.code, "error code", failures)
        if expected_error.message ~= nil then
          runner.assert_eq(err_ev.error.message, expected_error.message, "error message", failures)
        end
      end
    end
  elseif term == "cancelled" then
    runner.expect(cancelled, "terminal: expected cancelled but cancel was never simulated", failures)
    runner.expect(
      #late_events == 0,
      ("terminal: late events after cancel must be rejected (%d leaked)"):format(#late_events),
      failures
    )
  else
    failures[#failures + 1] = "terminal: unsupported expected_terminal " .. tostring(term)
  end

  -- 4c. normalized message (role + parts only; identity fields are runtime-owned)
  local expected_message = res.expected_message or {}
  if not vim.tbl_isempty(expected_message) then
    local role
    for _, e in ipairs(events) do
      if e.type == "response_started" then
        role = e.role
        break
      end
    end
    runner.assert_eq(
      { role = role or "assistant", content = assemble_parts(events) },
      expected_message,
      "normalized message",
      failures
    )
  end

  -- 4d. tool calls (decoded input)
  if res.expected_tool_calls and #res.expected_tool_calls > 0 then
    local calls, cerr = extract_tool_calls(events)
    if cerr then
      failures[#failures + 1] = cerr
    else
      runner.assert_eq(calls, res.expected_tool_calls, "tool calls", failures)
    end
  end

  -- 4e. usage (key-subset compare; updated_at is non-deterministic)
  local expected_usage = res.expected_usage or {}
  if not vim.tbl_isempty(expected_usage) then
    local usage
    for _, e in ipairs(events) do
      if e.type == "usage_updated" then
        usage = e.usage
      end
    end
    runner.expect(usage ~= nil, "usage: expected a usage_updated event", failures)
    if usage then
      for k, v in pairs(expected_usage) do
        runner.assert_eq(usage[k], v, ("usage.%s"):format(k), failures)
      end
    end
  end

  return failures
end

return M
