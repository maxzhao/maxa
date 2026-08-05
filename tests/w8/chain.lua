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
---      W4: the recorded tool_call now EXECUTES (no handler registered ->
---      standard unknown-tool error result persisted), the batch barrier fires
---      (tool_batch.started/tool_call.finished/tool_batch.finished), and the
---      direct pass-through continuation submits one automatic request with
---      the default echo body, which completes the chain. The final displayed
---      usage is the continuation's local estimate (out=8).
---   C. LazyVim opts config merges (config.configure); resolve_provider binds the registered
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
    -- W4/W5 ToolBatch phase: the recorded tool_call executes (read_file has no
    -- injected handler -> standard unknown-tool error result, persisted), the
    -- barrier fires once, then the W5 continuation decision point persists the
    -- decision (continuation.decided, additive) and submits one automatic
    -- request (default echo body, no tool calls) which streams to its own
    -- response.completed. The added continuation.decided sits between the
    -- batch terminal and the next request.submitted (spec §Persistence/event
    -- order: emit batch terminal -> persist continuation decision -> schedule
    -- next intent).
    "tool_batch.started",
    "tool_call.finished",
    "tool_batch.finished",
    "continuation.decided",
    "request.submitted",
    "request.started",
    "response.started",
    "message.delta",
    "message.delta",
    "response.completed",
  }
  assert_eq(table.concat(seen, ","), table.concat(want, ","), "B: bus event order")
  assert_eq(v.status, "completed", "B: host status")
  -- W4: the final displayed usage is the continuation turn's local estimate
  -- (default echo emits no usage events), not the request-1 provider_final
  -- snapshot (35 echo chars / 4 -> out=8; input unknown -> absent).
  check(v.usage ~= nil and v.usage.source == "local_estimate", "B: continuation local_estimate usage (got " .. tostring(v.usage and v.usage.source) .. ")")
  assert_eq(v.usage and v.usage.output_tokens, 8, "B: continuation usage output_tokens")
  -- Host parts rendering state: the automatic continuation reuses the same
  -- assistant item (no user boundary) and its accumulated text replaces the
  -- request-1 text; the tool_call status stays "completed".
  local last = v.items[#v.items]
  check(last ~= nil and last.role == "assistant", "B: last item is assistant")
  assert_eq(last.text, "Hello from maxa mock/echo provider.", "B: final accumulated text (continuation echo)")
  assert_eq(last.reasoning, "think ", "B: accumulated reasoning")
  check(last.tool_calls ~= nil and #last.tool_calls == 1, "B: one tool_call tracked")
  assert_eq(last.tool_calls[1].call_id, "call_1", "B: tool call_id")
  assert_eq(last.tool_calls[1].name, "read_file", "B: tool name")
  assert_eq(last.tool_calls[1].status, "completed", "B: tool status")
  -- Persisted messages: user + assistant(tool_call) + tool(result) + assistant.
  check(v.orch.messages:len() == 4, "B: four persisted messages (got " .. tostring(v.orch.messages:len()) .. ")")
  local msg = v.orch.messages:get(2)
  check(msg ~= nil and msg.role == "assistant", "B: persisted assistant message (tool_call)")
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
  -- W4 tool result persisted before the continuation: unknown tool error.
  local tool_msg = v.orch.messages:get(3)
  check(tool_msg ~= nil and tool_msg.role == "tool", "B: persisted tool result message")
  assert_eq(tool_msg.content[1].status, "error", "B: unknown tool result is error")
  check(tool_msg.content[1].is_error == true, "B: unknown tool result is_error")
  check(tool_msg.content[1].content:find("unknown tool", 1, true) ~= nil, "B: unknown tool diagnostic")
  -- The continuation assistant message is the stack tail.
  local last_msg = v.orch.messages:last()
  check(last_msg.role == "assistant" and last_msg.content[1].text == "Hello from maxa mock/echo provider.", "B: continuation assistant message")
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

  -- Real provider definitions come from the mother-repository LazyVim opts
  -- (lua/plugins/maxa.lua), merged over the bundled defaults (LazyVim config model).
  local spec = require("plugins.maxa")[1]
  local cfg, cerr = config.configure(require("maxa").defaults, spec.opts or {})
  check(cfg ~= nil, "C: opts config merges (err=" .. tostring(cerr and cerr.message) .. ")")
  if cfg then
    local record, rerr = config.resolve_provider(cfg)
    check(record ~= nil, "C: resolve_provider ok (err=" .. tostring(rerr and rerr.message) .. ")")
    if record then
      assert_eq(record.protocol, "openai_chat", "C: default provider protocol")
      assert_eq(record.model, "deepseek-v4-flash", "C: default provider model")
      check(record.adapter ~= nil, "C: adapter bound to record")

      -- Without a key: offline fallback to the local mock provider.
      vim.env.DEEPSEEK_TEST_KEY = nil
      local record_nokey = config.resolve_provider(cfg)
      local orch = orchestrator.new({ provider_record = record_nokey })
      assert_eq(orch._real_adapter, false, "C: no key -> fallback flag false")
      assert_eq(orch.provider.name, "mock", "C: no key -> mock provider bound")
      assert_eq(orch.model, "deepseek-v4-flash", "C: no key -> record model label kept")

      -- With a key: re-resolve (api_key is resolved at call time) and bind
      -- the real adapter (no network call made here).
      vim.env.DEEPSEEK_TEST_KEY = "test-key"
      local record_key = config.resolve_provider(cfg)
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

  -- Default view: full reasoning rendered; folding is a buffer-level
  -- interaction (asserted in tests/ui/render.lua E), so the snapshot keeps
  -- the `### Reasoning` / `### Response` block and the tool status line uses
  -- the chat-ui-folds status icon.
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus, provider_params = { chunks = parts_chunks() } })
  local res = v:submit("use the tool")
  assert_eq(res.terminal_state, "completed", "D: default view submit")
  local lines = v:_build_lines()
  check(has_line(lines, "### Reasoning"), "D: reasoning header rendered by default")
  check(has_line(lines, "think"), "D: reasoning content rendered by default")
  check(has_line(lines, "### Response"), "D: response header closes the fold")
  check(has_line(lines, "✅ read_file"), "D: tool_call status line with icon")
  -- W4: after the automatic continuation the latest turn's usage is the echo
  -- local estimate (out=8), not the request-1 provider_final snapshot.
  check(has_line(lines, "status: completed (out=8)"), "D: normalized usage status line (continuation local estimate)")

  -- show_reasoning=true view: full reasoning content.
  local bus2 = events.new()
  local v2 = host.new({ provider = "mock", events = bus2, show_reasoning = true, provider_params = { chunks = parts_chunks() } })
  local res2 = v2:submit("use the tool")
  assert_eq(res2.terminal_state, "completed", "D: show_reasoning submit")
  local lines2 = v2:_build_lines()
  check(has_line(lines2, "### Reasoning"), "D: reasoning transition header")
  check(has_line(lines2, "### Response"), "D: response transition header")
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
