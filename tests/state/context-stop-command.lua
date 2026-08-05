-- filepath: tests/state/context-stop-command.lua
-- W6.5 context-stop UI command validation: orchestrator default usage provider,
-- context_stop_arm target parsing (absolute/relative), fail-closed without
-- usage, provider context_window config wiring (docs/runtime-config.md).
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -l tests/state/runner.lua
-- (or standalone: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(
--   function() local d='<root>/tests/state/context-stop-command.lua'
--   local ok=pcall(dofile,d) vim.cmd(ok and 'qa!' or 'cq') end, 2000)")
local ok_all = true
local failures = {}
local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("CTXSTOP_FAIL: " .. msg)
  end
end
local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local normalize = require("maxa.runtime.protocol.normalize")
local config = require("maxa.runtime.config")

--------------------------------------------------------------------------------
-- A. Default usage provider: local estimate when no provider usage snapshot
--------------------------------------------------------------------------------
do
  local orch = orchestrator.new({ events = events.new() })
  check(type(orch.usage_provider) == "function", "A: default usage_provider installed")
  local usage = orch.usage_provider()
  check(type(usage) == "table" and type(usage.ratio) == "number", "A: usage snapshot has numeric ratio")
  assert_eq(usage.source, "local_estimate", "A: empty stack falls back to local estimate")
  assert_eq(usage.context_window, 128000, "A: default context window 128000 without record")
  check(usage.tokens >= 1 and usage.ratio > 0, "A: tokens/ratio positive")
  orch:close()
end

--------------------------------------------------------------------------------
-- B. Provider usage snapshot wins over the local estimate
--------------------------------------------------------------------------------
do
  local orch = orchestrator.new({ events = events.new() })
  orch._current = { usage = normalize.normalize_usage({ input_tokens = 100, output_tokens = 50 }) }
  local usage = orch.usage_provider()
  assert_eq(usage.source, "provider", "B: provider snapshot preferred")
  assert_eq(usage.tokens, 150, "B: total tokens summed (input+output)")
  assert_eq(usage.ratio, 150 / 128000, "B: ratio = total / default window")
  orch:close()
end

--------------------------------------------------------------------------------
-- C. Provider record context_window drives the ratio
--------------------------------------------------------------------------------
do
  local orch = orchestrator.new({ events = events.new() })
  orch.provider_record = { context_window = 1000 }
  orch._current = { usage = normalize.normalize_usage({ input_tokens = 400, output_tokens = 100 }) }
  local usage = orch.usage_provider()
  assert_eq(usage.tokens, 500, "C: tokens summed")
  assert_eq(usage.ratio, 0.5, "C: ratio = 500 / record window 1000")
  assert_eq(usage.context_window, 1000, "C: context_window from record")
  orch:close()
end

--------------------------------------------------------------------------------
-- D. context_stop_arm: absolute / percent / relative / invalid
--------------------------------------------------------------------------------
do
  local orch = orchestrator.new({ events = events.new() })
  local ok, err = orch:context_stop_arm("70")
  check(ok == true and err == nil, "D: arm 70 absolute accepted (" .. tostring(err and err.message or "") .. ")")
  check(orch._context_stop.enabled == true, "D: armed state enabled")
  check(math.abs((orch._context_stop.target_ratio or 0) - 0.7) < 1e-9, "D: target_ratio 0.7")

  ok, err = orch:context_stop_arm("70%")
  check(ok == true and err == nil, "D: arm 70% accepted")

  -- Relative: current ratio (local estimate on empty stack) + 10%.
  local before = orch.usage_provider().ratio
  ok, err = orch:context_stop_arm("+10")
  check(ok == true and err == nil, "D: arm +10 relative accepted (" .. tostring(err and err.message or "") .. ")")
  check(
    math.abs((orch._context_stop.target_ratio or 0) - (before + 0.1)) < 1e-6,
    "D: relative target = current + 10%"
  )

  ok, err = orch:context_stop_arm("abc")
  check(ok == false and err ~= nil, "D: invalid target rejected")
  check(err.code == "invalid_argument", "D: invalid target typed error")

  ok = orch:context_stop_disarm()
  check(orch._context_stop.enabled == false, "D: disarm clears armed state")
  orch:close()
end

--------------------------------------------------------------------------------
-- E. Fail-closed: usage unavailable -> arm rejected (no silent arming)
--------------------------------------------------------------------------------
do
  local orch = orchestrator.new({ events = events.new() })
  orch:set_usage_provider(function()
    return nil
  end)
  local ok, err = orch:context_stop_arm("70")
  check(ok == false and err ~= nil, "E: arm fails closed without usage")
  check(orch._context_stop.enabled == false, "E: no armed state on fail-closed")
  orch:close()
end

--------------------------------------------------------------------------------
-- F. config: provider context_window schema + record wiring
--------------------------------------------------------------------------------
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/.maxa", "p")
  local legal = [[
schema_version: 1
project_id: ctxwin-test
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://example.com
      model: m1
      context_window: 4096
]]
  local f = io.open(tmp .. "/.maxa/runtime.yaml", "w")
  f:write(legal)
  f:close()
  local snap, cerr = config.load(tmp, { resolve_root = false })
  check(snap ~= nil, "F: legal context_window loads (" .. tostring(cerr and cerr.message or "") .. ")")
  if snap then
    local record, rerr = config.resolve_provider(snap, "p1")
    check(record ~= nil, "F: provider resolves (" .. tostring(rerr and rerr.message or "") .. ")")
    assert_eq(record.context_window, 4096, "F: record carries context_window")
  end

  -- Illegal: negative context_window fails closed.
  local bad = [[
schema_version: 1
project_id: ctxwin-test
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://example.com
      model: m1
      context_window: -5
]]
  local f2 = io.open(tmp .. "/.maxa/runtime.yaml", "w")
  f2:write(bad)
  f2:close()
  local snap2, cerr2 = config.load(tmp, { resolve_root = false })
  check(snap2 == nil and cerr2 ~= nil, "F: negative context_window rejected fail-closed")
end

if ok_all then
  print("CONTEXT_STOP_COMMAND_OK")
else
  print("CONTEXT_STOP_COMMAND_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
