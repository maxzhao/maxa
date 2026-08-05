-- filepath: tests/protocol/drivers/openai_chat.lua
--- OpenAI Chat Completions fixture driver (phase-1 W4).
---
--- Consumed by tests/protocol/runner.lua: dofile'd per openai_chat fixture, then
--- `run_fixture(fixture, adapter, runner)` is called with the registered adapter.
--- Loading this file requires the adapter module, which self-registers under
--- "openai_chat" (the runner resolves it right after this dofile).
---
--- Execution model (protocol-fixture-contract.md "OpenAI Chat Completions"):
---   1. adapter:setup(provider_options) -> params
---   2. adapter:build_request(params, {messages, tools}) -> body
---      deep-equal against request.expected_body (object key order irrelevant);
---      strict_json:true additionally compares vim.json.encode snapshots so
---      empty-object-vs-empty-array shapes are pinned.
---   3. streamed mode: each response.chunks[i] is an SSE frame body with the
---      `data:` prefix but WITHOUT its terminating blank line (TinyYaml cannot
---      represent trailing blank lines inside list-item scalars; single-quoted
---      scalars keep the JSON quotes readable). The driver feeds
---      sse:feed(chunk .. "\n\n") one chunk at a time so every chunk produces
---      exactly one SSE frame -> adapter:parse_stream(frame) events.
---      response.cancel_after=N: after feeding N chunks the driver calls
---      adapter:cancel() (terminal cancelled error event), then feeds the
---      remaining chunks and asserts the adapter rejects every late frame.
---   4. non_streamed mode: response.chunks[1] is the full JSON response body
---      (no SSE framing) -> adapter:parse_nonstream(decoded). An optional
---      response.status >= 400 makes the driver classify the body through
---      transport.classify_error (mirrors the transport HTTP-error path) and
---      emit the typed error event instead of parsing a success body.
---   5. terminal: the driver appends normalize.completed() when no terminal
---      (error/completed) event was produced; [DONE]/EOF is never completion
---      by itself when an earlier typed failure exists.
---
--- Assertions:
---   - event type sequence == response.expected_events (types only)
---   - exactly one terminal event (error xor completed)
---   - terminal outcome == response.expected_terminal
---     (error code "cancelled" -> cancelled, other error -> failed, else completed)
---   - normalized assistant message built from events == response.expected_message
---     (text parts from message_delta accumulation; tool_call parts from
---     tool_call_completed with encoded arguments string)
---   - normalized tool calls (call_id/name/decoded arguments) ==
---     response.expected_tool_calls (decode only at the assertion boundary)
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
local transport = require("maxa.runtime.protocol.transport")
local schema = require("maxa.runtime.schema")
-- Side effect: registers the openai_chat adapter with the protocol registry.
require("maxa.runtime.protocol.adapters.openai_chat")

local M = {}

M.name = "driver.openai_chat"

--- Normalize a parse_stream return (nil | event | event[]) into a list.
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

--- Build the normalized assistant message from collected events.
---@param events table[] normalized events
---@return table message { role="assistant", content=table[] }
local function message_from_events(events)
  local text = {}
  local tool_parts = {}
  for _, ev in ipairs(events) do
    if ev.type == normalize.events.message_delta then
      text[#text + 1] = ev.delta
    elseif ev.type == normalize.events.tool_call_completed then
      tool_parts[#tool_parts + 1] = {
        type = "tool_call",
        call_id = ev.call_id,
        name = ev.name or "",
        arguments = ev.encoded_args,
      }
    end
  end
  local content = {}
  local full = table.concat(text)
  if full ~= "" then
    content[#content + 1] = { type = "text", text = full }
  end
  for _, tp in ipairs(tool_parts) do
    content[#content + 1] = tp
  end
  return { role = "assistant", content = content }
end

--- Build normalized tool call records (arguments decoded at this boundary).
---@param events table[] normalized events
---@param failures string[] accumulator
---@return table[] calls
local function tool_calls_from_events(events, failures)
  local calls = {}
  for _, ev in ipairs(events) do
    if ev.type == normalize.events.tool_call_completed then
      local args, err = normalize.decode_encoded_args(ev.encoded_args)
      if err then
        failures[#failures + 1] = ("tool_call %q: %s"):format(tostring(ev.call_id), err)
      end
      calls[#calls + 1] = {
        call_id = ev.call_id,
        name = ev.name or "",
        arguments = args,
      }
    end
  end
  return calls
end

--- Subset usage assertion: every non-nil key in `expected` must deep-equal the
--- actual value. Extra actual keys (e.g. wall-clock updated_at) are tolerated;
--- explicit-null expected keys are ignored (omit fields instead of writing null).
---@param actual table normalized usage snapshot
---@param expected table fixture expected_usage
---@param runner table runner helpers
---@param failures string[] accumulator
local function assert_usage(actual, expected, runner, failures)
  for k, v in pairs(expected) do
    if v ~= nil then
      if actual[k] == nil then
        failures[#failures + 1] = ("usage: expected key %q missing in actual"):format(tostring(k))
      else
        local d = runner.diff_desc(actual[k], v)
        if d then
          failures[#failures + 1] = ("usage.%s: %s"):format(tostring(k), d)
        end
      end
    end
  end
end

--- Last usage_updated event's usage snapshot (nil when none).
---@param events table[] normalized events
---@return table|nil usage
local function last_usage(events)
  local usage = nil
  for _, ev in ipairs(events) do
    if ev.type == normalize.events.usage_updated then
      usage = ev.usage
    end
  end
  return usage
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

--- Run one openai_chat fixture through the adapter.
---@param fx table loaded fixture { path, data }
---@param adapter table registered adapter
---@param runner table runner helpers (assert_eq/expect/diff_desc)
---@return string[] failures
function M.run_fixture(fx, adapter, runner)
  local failures = {}
  local data = fx.data
  local req = data.request
  local res = data.response

  -- 1. setup
  local params, perr = adapter:setup(req.provider_options or {})
  if not params then
    failures[#failures + 1] = "setup failed: " .. tostring(perr)
    return failures
  end

  -- 2. request body
  local body = adapter:build_request(params, {
    messages = req.normalized_messages,
    tools = req.normalized_tools,
  })
  runner.assert_eq(body, req.expected_body, "build_request body", failures)
  if data.strict_json then
    local ok_a, enc_a = pcall(vim.json.encode, body)
    local ok_b, enc_b = pcall(vim.json.encode, req.expected_body)
    if ok_a and ok_b then
      runner.expect(enc_a == enc_b, "strict_json: encoded body mismatch", failures)
    else
      failures[#failures + 1] = "strict_json: encode failed"
    end
  end

  -- 3. response processing
  local events = {}
  local status = res.status

  if status and status >= 400 then
    -- HTTP-error path (mirrors transport): classify the body, emit typed error.
    local body_text = res.chunks and res.chunks[1] or ""
    local info = transport.classify_error(status, body_text)
    local err = normalize.error_from_class(
      info.class,
      ("HTTP %d error from provider (class=%s)"):format(status, info.class),
      { status = status, body = body_text, provider_type = info.provider_type }
    )
    events[#events + 1] = normalize.error(err)
  elseif data.mode == "streamed" then
    local parser = sse.new()
    local cancel_after = res.cancel_after
    local cancelled = false

    local function feed_chunk(chunk, expect_rejected)
      -- Each fixture chunk is one SSE frame body; the driver appends the
      -- terminating blank line so every chunk dispatches exactly one frame.
      local frames = parser:feed(chunk .. "\n\n")
      for _, frame in ipairs(frames) do
        local evs = as_list(adapter:parse_stream(frame))
        if expect_rejected then
          if #evs > 0 then
            failures[#failures + 1] = ("late frame produced %d event(s) after cancel"):format(#evs)
          end
        else
          for _, ev in ipairs(evs) do
            events[#events + 1] = ev
          end
        end
      end
    end

    for i, chunk in ipairs(res.chunks or {}) do
      if not cancelled then
        feed_chunk(chunk, false)
        if cancel_after and i >= cancel_after then
          local cev = adapter:cancel()
          if cev then
            events[#events + 1] = cev
          end
          cancelled = true
        end
      else
        feed_chunk(chunk, true)
      end
    end
    -- Leftover parser tail (frames without a trailing blank line): rejected
    -- after cancel, processed normally otherwise.
    for _, frame in ipairs(parser:finish()) do
      local evs = as_list(adapter:parse_stream(frame))
      if cancelled then
        if #evs > 0 then
          failures[#failures + 1] = ("late tail frame produced %d event(s) after cancel"):format(#evs)
        end
      else
        for _, ev in ipairs(evs) do
          events[#events + 1] = ev
        end
      end
    end
    if not cancelled and not has_terminal(events) then
      -- End-of-stream finalization: flush any still-open tool calls, then the
      -- terminal completed (mirrors transport on_done in the live path).
      local fin = adapter:finish_stream()
      for _, ev in ipairs(as_list(fin)) do
        events[#events + 1] = ev
      end
      events[#events + 1] = normalize.completed()
    end
  else -- non_streamed
    local body_text = res.chunks and res.chunks[1]
    if type(body_text) ~= "string" or body_text == "" then
      failures[#failures + 1] = "non_streamed fixture must provide chunks[1] as the response body"
      return failures
    end
    local ok, decoded = pcall(vim.json.decode, body_text)
    if not ok or type(decoded) ~= "table" then
      failures[#failures + 1] = "non_streamed response body must be valid JSON"
      return failures
    end
    for _, ev in ipairs(as_list(adapter:parse_nonstream(decoded))) do
      events[#events + 1] = ev
    end
    if not has_terminal(events) then
      events[#events + 1] = normalize.completed()
    end
  end

  -- 4. assertions
  local types = {}
  for _, ev in ipairs(events) do
    types[#types + 1] = ev.type
  end
  runner.assert_eq(types, res.expected_events, "event type sequence", failures)

  local terminal_count = 0
  for _, ev in ipairs(events) do
    if ev.type == normalize.events.error or ev.type == normalize.events.completed then
      terminal_count = terminal_count + 1
    end
  end
  runner.expect(terminal_count == 1, ("expected exactly one terminal event, got %d"):format(terminal_count), failures)

  local terminal = terminal_of(events)
  runner.expect(
    terminal == res.expected_terminal,
    ("terminal mismatch: %s vs %s"):format(terminal, res.expected_terminal),
    failures
  )

  runner.assert_eq(message_from_events(events), res.expected_message, "normalized assistant message", failures)
  runner.assert_eq(tool_calls_from_events(events, failures), res.expected_tool_calls, "normalized tool calls", failures)

  if not vim.tbl_isempty(res.expected_usage or {}) then
    local usage = last_usage(events)
    if not usage then
      failures[#failures + 1] = "expected usage but no usage_updated event was produced"
    else
      assert_usage(usage, res.expected_usage, runner, failures)
    end
  end

  if res.expected_error then
    local error_event = nil
    for _, ev in ipairs(events) do
      if ev.type == normalize.events.error then
        error_event = ev
      end
    end
    if not error_event then
      failures[#failures + 1] = "expected_error declared but no error event was produced"
    else
      if error_event.error.code ~= res.expected_error.code then
        failures[#failures + 1] = ("error code mismatch: %s vs %s"):format(
          error_event.error.code,
          res.expected_error.code
        )
      end
      if error_event.error.terminal ~= res.expected_error.terminal then
        failures[#failures + 1] = ("error terminal mismatch: %s vs %s"):format(
          tostring(error_event.error.terminal),
          tostring(res.expected_error.terminal)
        )
      end
    end
  end

  return failures
end

return M
