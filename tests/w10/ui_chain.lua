-- filepath: tests/w10/ui_chain.lua
-- W10 headless UI full-chain validation: real DeepSeek providers through the
-- host Chat View (View:set_provider -> orchestrator -> real protocol adapter).
-- Modeled on tests/w8/chain.lua; live-request plumbing follows
-- tests/protocol/live.lua (key read from <root>/.env, never echoed).
--
-- Scenarios:
--   A-C. For each of deepseek-chat / deepseek-responses / deepseek-anthropic:
--         set_provider(name) resolves through the effective LazyVim opts config
--         and binds the real adapter; one real message is submitted through the View; the
--         stream must reach exactly one terminal event with status completed,
--         the assistant item must carry a non-empty text part, the normalized
--         usage snapshot must be non-empty, and the view must have shown busy
--         before completing. deepseek-responses / deepseek-anthropic must also
--         render the reasoning collapsible block (`### Reasoning` section;
--         (deepseek-v4-flash emits reasoning on both protocols; the captured
--         live fixtures prove it: 23 reasoning_text.delta events on /responses
--         and thinking blocks on /messages).
--   D. :MaxaStop path: mock async stream cancelled via View:stop -> cancelled.
--   E. Terminal import-guard assert (nothing legacy loaded).
--
-- Key handling: DEEPSEEK_TEST_KEY must exist in <root>/.env. Without it the
-- suite prints W10_UI_CHAIN_SKIP and exits 0 -- an honest SKIP, never a fake
-- PASS. Real request failures (network/key) are reported as FAIL, never faked.
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/w10/ui_chain.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.

local ROOT = "/home/maxzhao/maxa"

--- Read a KEY=VALUE line from <root>/.env without echoing the value.
---@param key string
---@return string|nil value
local function read_env_file(key)
  local f = io.open(ROOT .. "/.env", "rb")
  if not f then
    return nil
  end
  local body = f:read("*a")
  f:close()
  for line in body:gmatch("[^\r\n]+") do
    local value = line:match("^%s*" .. key .. "%s*=%s*(.-)%s*$")
    if value then
      return value
    end
  end
  return nil
end

--- Wait (keeping the event loop alive) until done or timeout.
---@param deadline_ms integer
---@param is_done fun(): boolean
---@return boolean finished_before_timeout
local function wait_for(deadline_ms, is_done)
  local waited = 0
  while waited < deadline_ms do
    if is_done() then
      return true
    end
    vim.wait(50)
    waited = waited + 50
  end
  return is_done()
end

local key = read_env_file("DEEPSEEK_TEST_KEY")
if not key then
  print("W10_UI_CHAIN_SKIP: DEEPSEEK_TEST_KEY not found in " .. ROOT .. "/.env (live UI chain not run)")
  return true -- honest SKIP; caller exits 0
end
-- Inject into the process env (resolve_provider reads it by name). Never echoed.
vim.env.DEEPSEEK_TEST_KEY = key

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("W10_FAIL: " .. msg)
  end
end

local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")
-- W10.2: real providers come from the mother-repository LazyVim opts
-- (lua/plugins/maxa.lua), merged over bundled defaults by maxa.setup; the
-- effective config (config.effective) feeds View:set_provider. Dev-asset
-- credential injection reads <root>/.env for DEEPSEEK_TEST_KEY (never persisted).
local maxa_mod = require("maxa")
local spec = require("plugins.maxa")[1]
local ok_setup, setup_err = pcall(maxa_mod.setup, spec.opts or {})
if not ok_setup then
  error("w10/ui_chain.lua: maxa.setup failed: " .. tostring(setup_err))
end

local function has_reasoning_fold(lines)
  for _, l in ipairs(lines) do
    if l == "### Reasoning" then
      return true
    end
  end
  return false
end

--- One real provider round trip through the View (scenarios A-C).
---@param provider_id string config provider id (deepseek-chat/responses/anthropic)
---@param expect_reasoning boolean assert the `[reasoning N chars]` fold line
local function run_case(provider_id, expect_reasoning)
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus })

  -- W10.2: set_provider resolves the real provider through the effective opts config.
  local ok_set = v:set_provider(provider_id)
  check(ok_set, provider_id .. ": set_provider ok")
  if not ok_set then
    v:close()
    return
  end
  -- The real adapter must be bound (key present -> not the offline mock fallback).
  check(
    v.orch._real_adapter == true,
    provider_id .. ": real adapter bound (got _real_adapter=" .. tostring(v.orch._real_adapter) .. ")"
  )

  -- Deterministic busy observation: subscribe AFTER the view (host listener
  -- runs first and sets status=busy), then request.started must see busy.
  local busy_seen = false
  bus.on(bus.events.request_started or "request.started", function()
    if v.status == "busy" then
      busy_seen = true
    end
  end)
  -- Exactly one terminal event per request.
  local terminal_count = 0
  for _, ev in ipairs({ "response.completed", "response.failed", "response.cancelled" }) do
    bus.on(bus.events[ev] or ev, function()
      terminal_count = terminal_count + 1
    end)
  end

  local res = v:submit("Reply with exactly: OK", { async = true })
  check(
    res ~= nil and res.async == true,
    provider_id .. ": async submit started (got " .. vim.inspect(res and res.terminal_state) .. ")"
  )
  if not (res and res.async) then
    v:close()
    return
  end

  -- W10.4: busy -> completed transition; real network stream.
  check(wait_for(30000, function()
    return busy_seen
  end), provider_id .. ": status became busy during stream")
  local finished = wait_for(120000, function()
    return v.status == "completed" or v.status == "failed" or v.status == "cancelled"
  end)
  check(finished, provider_id .. ": stream reached terminal within 120s (status=" .. v.status .. ")")
  check(v.status == "completed", provider_id .. ": final status completed (got " .. v.status .. ")")
  check(busy_seen, provider_id .. ": busy observed before terminal")
  check(terminal_count == 1, provider_id .. ": exactly one terminal event (got " .. terminal_count .. ")")

  -- Assistant text part rendered in the view items.
  local last = v.items[#v.items]
  check(
    last ~= nil and last.role == "assistant" and type(last.text) == "string" and last.text ~= "",
    provider_id .. ": assistant item with non-empty text part"
  )

  -- Normalized usage snapshot present (provider-reported or estimated).
  check(
    v.usage ~= nil and (v.usage.input_tokens ~= nil or v.usage.output_tokens ~= nil),
    provider_id .. ": usage snapshot non-empty (source=" .. tostring(v.usage and v.usage.source) .. ")"
  )

  -- Reasoning fold line (W10.4) for the protocols whose adapters surface it.
  if expect_reasoning then
    local lines = v:_build_lines()
    check(has_reasoning_fold(lines), provider_id .. ": reasoning fold block rendered")
  end

  v:close()
end

run_case("deepseek-chat", false)
run_case("deepseek-responses", true)
run_case("deepseek-anthropic", true)

------------------------------------------------------------------------------
-- Scenario D: :MaxaStop cancel path (mock async stream, offline/deterministic).
------------------------------------------------------------------------------
do
  -- A long mock stream (100 chunks, 1ms yield after every chunk) so the async
  -- driver stays alive across several 20ms polls and View:stop has a real
  -- cancel window. (Short streams with a large `delay` complete inside a single
  -- vim.wait(20) and never expose a busy state to the caller.)
  local chunks = {}
  for i = 1, 100 do
    chunks[i] = ("chunk-%d "):format(i)
  end
  local bus = events.new()
  local v = host.new({
    provider = "mock",
    events = bus,
    provider_params = { chunks = chunks, delay = 1 },
  })
  local res = v:submit("stop me", { async = true })
  check(res ~= nil and res.async == true, "stop: async submit started")
  local stopped = false
  local waited = 0
  while waited < 8000 and not stopped do
    if v.status == "busy" then
      stopped = v:stop()
    end
    vim.wait(10)
    waited = waited + 10
  end
  check(stopped, "stop: View:stop won the cancel")
  check(wait_for(8000, function()
    return v.status == "cancelled"
  end), "stop: status reached cancelled (got " .. v.status .. ")")
  v:close()
end

------------------------------------------------------------------------------
-- Scenario E: terminal import-guard assert (nothing legacy loaded)
------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "import-guard: no legacy families loaded")
end

if ok_all then
  print("W10_UI_CHAIN_OK")
else
  print("W10_UI_CHAIN_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
