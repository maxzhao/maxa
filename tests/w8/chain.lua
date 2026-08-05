-- filepath: tests/w8/chain.lua
--- W8 full-chain headless validation: events augmentation + orchestrator/host
--- parts upgrade end-to-end.
---
--- Scenarios:
---   A. mock provider, default text-only stream: event order + host state +
---      local_estimate usage path.
---   B. mock provider with scripted normalized events injected through
---      provider_params (reasoning + tool_call fragments + usage snapshots):
---      exact bus event order, host parts rendering state, persisted parts.
---   C. .maxa/runtime.yaml loads; config.resolve_provider binds the registered
---      openai_chat adapter; orchestrator:use_provider_record falls back to mock
---      without a key and binds the real adapter with one (no network).
---   D. rendering lines: reasoning collapsed summary vs full (show_reasoning),
---      tool_call status line, normalized usage status line (in/out/total).
---
--- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
---   local d='<root>/tests/w8/chain.lua' local ok=pcall(dofile,d)
---   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
--- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("CHAIN_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

-- W8 injectable chunk sequence (normalized events through the mock stream).
local function parts_chunks()
  local n = require("maxa.runtime.protocol.normalize")
  return {
    n.reasoning_delta("think "),
    n.message_delta("Hello "),
    n.tool_call_started("call_1", "read_file"),
    n.tool_args_delta("call_1", '{"path":'),
    n.tool_args_delta("call_1", '"x"}'),
    n.tool_call_completed("call_1", '{"path":"x"}'),
    n.message_delta("world"),
    n.usage_updated(n.normalize_usage({ input_tokens = 10, output_tokens = 20, total_tokens = 30 })),
    n.usage_updated(n.normalize_usage({ input_tokens = 10, output_tokens = 20, total_tokens = 30 }, { final = true })),
  }
end

-- Record every emitted bus event name in order. `session.created` is emitted
-- when the orchestrator session is created (before the submit), so it is
-- excluded from the per-request event-order assertions.
local function watch(bus)
  local seen = {}
  for key, name in pairs(bus.events or {}) do
    if type(key) == "string" and name ~= "session.created" then
      bus.on(name, function()
        seen[#seen + 1] = name
      end)
    end
  end
  return seen
end

local function has_line(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- Scenario A: text-only mock stream
-------------------------------------------------------------------------------
do
  local events = require("maxa.runtime.events")
  local host = require("maxa.runtime.host.nvim")
  local bus = events.new()
  local seen = watch(bus)
  local v = host.new({ provider = "mock", events = bus, provider_params = { chunks = { "Hello from maxa ", "mock/echo provider." } } })
  local res = v:submit("hello")
  assert_eq(res.terminal_state, "completed", "A: sync submit terminal_state")
  local want = {
    "request.submitted",
    "request.started",
    "response.started",
    "message.delta",
    "message.delta",
    "response.completed",
  }
  assert_eq(table.concat(seen, ","), table.concat(want, ","), "A: bus event order")
  assert_eq(v.status, "completed", "A: host status")
  assert_eq(v.orch.messages:len(), 2, "A: persisted user + assistant")
  check(v.usage ~= nil and v.usage.source == "local_estimate", "A: local_estimate usage path (got " .. tostring(v.usage and v.usage.source) .. ")")
  local last = v.items[#v.items]
  check(last ~= nil and last.role == "assistant" and last.text == "Hello from maxa mock/echo provider.", "A: assistant text item")
end

-------------------------------------------------------------------------------
-- Scenario B: injected reasoning + tool_call + usage through the mock stream
-------------------------------------------------------------------------------
do
  local events = require("maxa.runtime.events")
  local host = require("maxa.runtime.host.nvim")
  local bus = events.new()
  local seen = watch(bus)
  local v = host.new({ provider = "mock", events = bus, provider_params = { chunks = parts_chunks() } })
  local res = v:submit("use the tool")
  assert_eq(res.terminal_state, "completed", "B: sync submit terminal_state")
  local want = {
    "request.submitted",
    "request.started",
    "response.started",
    "reasoning.delta",
    "message.delta",
    "tool_call.started",
    "tool_call.delta",
    "tool_call.delta",
    "tool_call.completed",
    "message.delta",
    "usage.updated",
    "usage.updated",
    "response.completed",
  }
  assert_eq(table.concat(seen, ","), table.concat(want, ","), "B: bus event order")
  assert_eq(v.status, "completed", "B: host status")
  -- Final usage: the provider_final snapshot (final=true) wins over local estimate.
  check(v.usage ~= nil and v.usage.source == "provider_final", "B: provider_final usage (got " .. tostring(v.usage and v.usage.source) .. ")")
  assert_eq(v.usage and v.usage.input_tokens, 10, "B: usage input_tokens")
  assert_eq(v.usage and v.usage.output_tokens, 20, "B: usage output_tokens")
  -- Host parts rendering state.
  local last = v.items[#v.items]
  check(last ~= nil and last.role == "assistant", "B: last item is assistant")
  assert_eq(last.text, "Hello world", "B: accumulated assistant text")
  assert_eq(last.reasoning, "think ", "B: accumulated reasoning")
  check(last.tool_calls ~= nil and #last.tool_calls == 1, "B: one tool_call tracked")
  assert_eq(last.tool_calls[1].call_id, "call_1", "B: tool call_id")
  assert_eq(last.tool_calls[1].name, "read_file", "B: tool name")
  assert_eq(last.tool_calls[1].status, "completed", "B: tool status")
  -- Persisted assistant message parts (reasoning + text + tool_call).
  local msg = v.orch.messages:last()
  check(msg ~= nil and msg.role == "assistant", "B: persisted assistant message")
  check(msg.content ~= nil and #msg.content == 3, "B: three content parts (got " .. tostring(#(msg.content or {})) .. ")")
  assert_eq(msg.content[1].type, "reasoning", "B: part[1] reasoning")
  assert_eq(msg.content[1].content, "think ", "B: part[1] reasoning content")
  assert_eq(msg.content[1].provider, "mock", "B: part[1] reasoning provider")
  assert_eq(msg.content[2].type, "text", "B: part[2] text")
  assert_eq(msg.content[2].text, "Hello world", "B: part[2] text content")
  assert_eq(msg.content[3].type, "tool_call", "B: part[3] tool_call")
  assert_eq(msg.content[3].call_id, "call_1", "B: part[3] call_id")
  assert_eq(msg.content[3].name, "read_file", "B: part[3] name")
  assert_eq(msg.content[3].arguments, '{"path":"x"}', "B: part[3] encoded args")
end

-------------------------------------------------------------------------------
-- Scenario C: config + provider record binding (offline, no network)
-------------------------------------------------------------------------------
do
  local config = require("maxa.runtime.config")
  local orchestrator = require("maxa.runtime.orchestrator")
  -- Register the real adapter so resolve_provider can bind it (fixture path).
  local openai_chat = require("maxa.runtime.protocol.adapters.openai_chat")
  check(type(openai_chat) == "table", "C: openai_chat adapter loads")

  local snap, err = config.load("/home/maxzhao/maxa")
  check(snap ~= nil, "C: .maxa/runtime.yaml parses (err=" .. tostring(err and err.message) .. ")")
  if snap then
    local record, rerr = config.resolve_provider(snap)
    check(record ~= nil, "C: resolve_provider ok (err=" .. tostring(rerr and rerr.message) .. ")")
    if record then
      assert_eq(record.protocol, "openai_chat", "C: default provider protocol")
      assert_eq(record.model, "deepseek-v4-flash", "C: default provider model")
      check(record.adapter ~= nil, "C: adapter bound to record")

      -- Without a key: offline fallback to the local mock provider.
      vim.env.DEEPSEEK_TEST_KEY = nil
      local record_nokey = config.resolve_provider(snap)
      local orch = orchestrator.new({ provider_record = record_nokey })
      assert_eq(orch._real_adapter, false, "C: no key -> fallback flag false")
      assert_eq(orch.provider.name, "mock", "C: no key -> mock provider bound")
      assert_eq(orch.model, "deepseek-v4-flash", "C: no key -> record model label kept")

      -- With a key: re-resolve (api_key is snapshotted at resolve time) and bind
      -- the real adapter (no network call made here).
      vim.env.DEEPSEEK_TEST_KEY = "test-key"
      local record_key = config.resolve_provider(snap)
      check(record_key ~= nil, "C: resolve_provider with key ok")
      local orch2 = orchestrator.new({ provider_record = record_key })
      assert_eq(orch2._real_adapter, true, "C: key -> real adapter flag true")
      assert_eq(orch2.provider.name, "openai_chat", "C: key -> real adapter bound")
      vim.env.DEEPSEEK_TEST_KEY = nil
    end
  end
end

-------------------------------------------------------------------------------
-- Scenario D: rendering lines (reasoning fold + tool line + usage status)
-------------------------------------------------------------------------------
do
  local events = require("maxa.runtime.events")
  local host = require("maxa.runtime.host.nvim")

  -- Default view: collapsed reasoning summary.
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus, provider_params = { chunks = parts_chunks() } })
  local res = v:submit("use the tool")
  assert_eq(res.terminal_state, "completed", "D: default view submit")
  local lines = v:_build_lines()
  check(has_line(lines, "[reasoning 6 chars]"), "D: collapsed reasoning summary line")
  check(not has_line(lines, "think"), "D: collapsed view hides reasoning content")
  check(has_line(lines, "[tool read_file] (completed)"), "D: tool_call status line")
  check(has_line(lines, "status: completed (in=10 out=20 total=30)"), "D: normalized usage status line")

  -- show_reasoning=true view: full reasoning content.
  local bus2 = events.new()
  local v2 = host.new({ provider = "mock", events = bus2, show_reasoning = true, provider_params = { chunks = parts_chunks() } })
  local res2 = v2:submit("use the tool")
  assert_eq(res2.terminal_state, "completed", "D: show_reasoning submit")
  local lines2 = v2:_build_lines()
  check(has_line(lines2, "[reasoning]"), "D: reasoning header line")
  check(has_line(lines2, "think"), "D: reasoning content visible when show_reasoning")
end

-------------------------------------------------------------------------------
-- Terminal import-guard assert (nothing legacy loaded)
-------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "import-guard: no legacy families loaded")
end

if ok_all then
  print("W8_CHAIN_OK")
else
  print("W8_CHAIN_FAILED count=" .. #failures)
  vim.cmd("cq")
end
