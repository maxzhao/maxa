-- filepath: tests/protocol/drivers/gemini.lua
--- Gemini native fixture driver (phase-1 W7).
---
--- Consumed by tests/protocol/runner.lua: dofile'd per gemini fixture, then
--- `run_fixture(fixture, adapter, runner)` is called with the registered adapter.
--- Loading this file requires the adapter module, which self-registers under
--- "gemini" (the runner resolves it right after this dofile).
---
--- Execution model (protocol-fixture-contract.md §"Gemini native API"):
---   1. adapter:setup(provider_options) -> params
---   2. adapter:build_request(params, {messages, tools}) -> body
---      deep-equal against request.expected_body (object key order irrelevant)
---   3. streamed mode: each response.chunks[i] is one SSE frame body with the
---      `data:` prefix but WITHOUT its terminating blank line (TinyYaml cannot
---      represent trailing blank lines inside list-item scalars; single-quoted
---      scalars keep the JSON quotes readable). The driver feeds
---      sse:feed(chunk .. "\n\n") one chunk at a time so every chunk dispatches
---      exactly one SSE frame -> adapter:parse_stream(frame) events.
---      response.cancel_after=N: after feeding N chunks the driver calls
---      adapter:cancel() (one terminal cancelled error event), then feeds the
---      remaining chunks plus the parser tail and asserts the adapter rejects
---      every late frame (no events leak).
---      At EOF the driver calls adapter:finish_stream() (the Gemini empty-
---      candidates check) and appends the terminal completed event only when no
---      terminal event exists yet (exactly-one-terminal invariant).
---   4. non_streamed mode: response.chunks[1] is the full JSON response body
---      (no SSE framing) -> adapter:parse_nonstream(decoded) (it emits its own
---      terminal completed/error).
---   5. terminal: exactly one terminal event (error xor completed) overall.
---
--- Assertions:
---   - event type sequence == response.expected_events (types only)
---   - exactly one terminal event (error xor completed)
---   - terminal outcome == response.expected_terminal
---   - normalized assistant message built from events == response.expected_message
---     (text parts from message_delta accumulation; tool_call parts keyed by
---     call id with the encoded arguments string)
---   - normalized tool calls (call_id/name/decoded arguments) ==
---     response.expected_tool_calls (decoded only at the assertion boundary)
---   - usage snapshot == response.expected_usage: subset comparison
---     (keys present in expected must match; missing/null keys in expected are
---     tolerated; updated_at is wall-clock and never asserted)
---   - optional response.expected_error {code, terminal} matches the error event
---     when the fixture declares it
---
--- Dependencies: maxa runtime protocol modules only. Never loads
--- codecompanion.* / mcphub.* / lua/util/hooks/*.
local sse = require("maxa.runtime.protocol.sse")
local normalize = require("maxa.runtime.protocol.normalize")
local schema = require("maxa.runtime.schema")
-- Side effect: registers the gemini adapter with the protocol registry.
require("maxa.runtime.protocol.adapters.gemini")

local M = {}

M.name = "driver.gemini"

--- Normalize a parse_stream/parse_nonstream return (nil | event | event[]) into
--- a list.
---@param out any
---@return table[] events
local function as_list(out)
  if out == nil then
    return {}
  end
  if type(out) == "table" and out.type ~= nil then
    return { out }
  end
  if type(out) == "table" then
    return out
  end
  return {}
end

--- Whether the event list already contains a terminal event.
---@param events table[] normalized events
---@return boolean
local function has_terminal(events)
  for _, ev in ipairs(events) do
    if ev.type == normalize.events.error or ev.type == normalize.events.completed then
      return true
    end
  end
  return false
end

--- Assemble the normalized assistant message content parts from the event
--- stream (ordered part builders; consecutive deltas of the same kind merge
--- into one part; tool_call parts keyed by call id).
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

--- Terminal outcome of the collected events ("cancelled"|"failed"|"completed").
---@param events table[] normalized events
---@return string terminal
local function terminal_of(events)
  for _, ev in ipairs(events) do
    if ev.type == normalize.events.error then
      if ev.error and ev.error.code == schema.ERROR.CANCELLED then
        return "cancelled"
      end
      return "failed"
    end
  end
  return "completed"
end

--- Run one gemini fixture through the adapter.
---@param fixture table loaded fixture { path, data }
---@param adapter table registered adapter
---@param runner table runner helpers (assert_eq/expect/diff_desc)
---@return string[] failures
function M.run_fixture(fixture, adapter, runner)
  local failures = {}
  local data = fixture.data
  local req = data.request or {}
  local res = data.response or {}

  -- 1. setup
  local params, serr = adapter:setup(req.provider_options or {})
  if not params then
    return { "setup failed: " .. tostring(serr) }
  end

  -- 2. request body
  local body = adapter:build_request(params, {
    messages = req.normalized_messages or {},
    tools = req.normalized_tools or {},
  })
  runner.assert_eq(body, req.expected_body or {}, "build_request body", failures)

  -- 3. response processing
  local events = {}
  local late_events = {}
  local parser = sse.new()
  local cancelled = false

  local function feed(text, target)
    for _, frame in ipairs(parser:feed(text)) do
      local evs = as_list(adapter:parse_stream(frame))
      for _, ev in ipairs(evs) do
        target[#target + 1] = ev
      end
    end
  end

  if data.mode == "streamed" then
    local chunks = res.chunks or {}
    local cancel_after = res.cancel_after
    for i, chunk in ipairs(chunks) do
      if not cancelled then
        -- Each fixture chunk is one SSE frame body; append the terminating
        -- blank line so every chunk dispatches exactly one frame.
        feed(chunk .. "\n\n", events)
        if cancel_after and i >= cancel_after then
          local cev = adapter:cancel()
          if cev then
            events[#events + 1] = cev
          end
          cancelled = true
        end
      else
        feed(chunk .. "\n\n", late_events)
      end
    end
    -- Leftover parser tail (frames without a trailing blank line).
    if cancelled then
      for _, frame in ipairs(parser:finish()) do
        local evs = as_list(adapter:parse_stream(frame))
        for _, ev in ipairs(evs) do
          late_events[#late_events + 1] = ev
        end
      end
    else
      for _, frame in ipairs(parser:finish()) do
        local evs = as_list(adapter:parse_stream(frame))
        for _, ev in ipairs(evs) do
          events[#events + 1] = ev
        end
      end
      -- EOF finalization: the Gemini empty-candidates check, then the terminal
      -- completed event exactly once (never after a typed failure).
      local fin = as_list(adapter:finish_stream())
      for _, ev in ipairs(fin) do
        events[#events + 1] = ev
      end
      if not has_terminal(events) then
        events[#events + 1] = normalize.completed()
      end
    end
  else -- non_streamed
    local body_text = res.chunks and res.chunks[1]
    if type(body_text) ~= "string" or body_text == "" then
      return { "non_streamed fixture must provide chunks[1] as the response body" }
    end
    local ok, decoded = pcall(vim.json.decode, body_text)
    if not ok or type(decoded) ~= "table" then
      return { "non_streamed response body must be valid JSON" }
    end
    local evs = as_list(adapter:parse_nonstream(decoded))
    for _, ev in ipairs(evs) do
      events[#events + 1] = ev
    end
  end

  -- 4a. event type sequence
  local types = {}
  for _, ev in ipairs(events) do
    types[#types + 1] = ev.type
  end
  runner.assert_eq(types, res.expected_events or {}, "event type sequence", failures)

  -- 4b. exactly one terminal event (error xor completed)
  local terminal_count = 0
  for _, ev in ipairs(events) do
    if ev.type == normalize.events.error or ev.type == normalize.events.completed then
      terminal_count = terminal_count + 1
    end
  end
  runner.expect(
    terminal_count == 1,
    ("expected exactly one terminal event, got %d"):format(terminal_count),
    failures
  )

  -- 4c. terminal outcome
  local terminal = terminal_of(events)
  runner.expect(
    terminal == res.expected_terminal,
    ("terminal mismatch: %s vs %s"):format(terminal, tostring(res.expected_terminal)),
    failures
  )

  -- 4d. normalized message (role + content parts; identity fields are runtime-owned)
  local expected_message = res.expected_message or {}
  if not vim.tbl_isempty(expected_message) then
    local role
    for _, ev in ipairs(events) do
      if ev.type == "response_started" then
        role = ev.role
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

  -- 4e. tool calls (decoded at the assertion boundary)
  local expected_tool_calls = res.expected_tool_calls or {}
  if #expected_tool_calls > 0 then
    local calls, cerr = extract_tool_calls(events)
    if cerr then
      failures[#failures + 1] = cerr
    else
      runner.assert_eq(calls, expected_tool_calls, "tool calls", failures)
    end
  end

  -- 4f. usage (key-subset compare; updated_at is non-deterministic)
  local expected_usage = res.expected_usage or {}
  if not vim.tbl_isempty(expected_usage) then
    local usage
    for _, ev in ipairs(events) do
      if ev.type == "usage_updated" then
        usage = ev.usage
      end
    end
    runner.expect(usage ~= nil, "expected usage but no usage_updated event was produced", failures)
    if usage then
      for k, v in pairs(expected_usage) do
        if v ~= nil then
          runner.assert_eq(usage[k], v, ("usage.%s"):format(tostring(k)), failures)
        end
      end
    end
  end

  -- 4g. optional expected_error {code, terminal}
  local expected_error = res.expected_error
  if expected_error then
    local error_event = nil
    for _, ev in ipairs(events) do
      if ev.type == normalize.events.error then
        error_event = ev
      end
    end
    if not error_event then
      failures[#failures + 1] = "expected_error declared but no error event was produced"
    else
      if expected_error.code ~= nil then
        runner.assert_eq(error_event.error.code, expected_error.code, "error code", failures)
      end
      if expected_error.terminal ~= nil then
        runner.assert_eq(error_event.error.terminal, expected_error.terminal, "error terminal", failures)
      end
    end
  end

  -- 4h. late events after cancel must be rejected (cancel-and-late fixtures)
  if cancelled and #late_events > 0 then
    failures[#failures + 1] = ("late frames after cancel produced %d event(s)"):format(#late_events)
  end

  return failures
end

return M
