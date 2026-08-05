-- filepath: tests/state/retry-submit.lua
--- Phase-2 W3 fixture: retry chains a new request generation to the failed
--- request (request.retry_of), reuses the original turn (no new manual user
--- message), and rejects retry_of that is unknown or not terminal-failed.
---
--- Fixture convention: prints RETRY_SUBMIT_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

do
  local bus = events.new()
  local orch = orchestrator.new({ provider = mock, events = bus })

  -- Seed: provider failure at chunk 1 -> terminal failed.
  local first = orch:submit("hello", {
    provider_params = { error = true, error_at = 1, chunks = { "boom" } },
  })
  A.assert_eq(first.terminal_state, "failed", "retry: seed failed")
  A.check(first.request.terminal.state == "failed", "retry: seed request terminal-failed")

  -- Retry: new generation linked to the failed request, no new user turn.
  local retry = orch:submit("", {
    kind = "retry",
    retry_of = first.request.id,
    provider_params = { chunks = { "recovered" } },
  })
  A.assert_eq(retry.terminal_state, "completed", "retry: retry completed")
  A.assert_eq(retry.request.intent, "retry", "retry: request intent retry")
  A.assert_eq(retry.request.generation, 2, "retry: new request generation")
  A.assert_eq(retry.request.retry_of, first.request.id, "retry: chained to failed request")
  A.assert_eq(retry.intent.kind, "retry", "retry: intent kind retry")
  A.check(#orch.session.requests == 2, "retry: two request records")

  local stack = orch.messages
  A.assert_eq(stack:len(), 2, "retry: no new user turn (user + assistant)")
  A.assert_eq(stack:get(1).role, "user", "retry: user message first")
  A.assert_eq(stack:get(1).content[1].text, "hello", "retry: original user message reused")
  A.assert_eq(stack:get(2).role, "assistant", "retry: retried assistant reply")
end

-- retry_of must reference an existing terminal-failed request.
do
  local bus = events.new()
  local orch = orchestrator.new({ provider = mock, events = bus })

  local r1 = orch:submit("no-such", { kind = "retry", retry_of = "req-ghost" })
  A.check(r1.rejected == true, "retry-bad: unknown retry_of rejected")
  A.check(r1.request == nil, "retry-bad: no request for unknown retry_of")

  local seed = orch:submit("seed", { provider_params = { chunks = { "ok" } } })
  A.assert_eq(seed.terminal_state, "completed", "retry-bad: seed completed")
  local r2 = orch:submit("", { kind = "retry", retry_of = seed.request.id })
  A.check(r2.rejected == true, "retry-bad: completed request is not retryable")
end

if A.ok then
  print("RETRY_SUBMIT_OK")
else
  error("RETRY_SUBMIT_FAILED count=" .. #A.failures)
end
