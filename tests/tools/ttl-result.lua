-- filepath: tests/tools/ttl-result.lua
--- Phase-3 W2 fixture: TTL(result) lifecycle changes only retention metadata /
--- auxiliary content ownership; provider-facing result content and the
--- durable trace (persisted tool message) are untouched (fixture contract
--- tool/ttl-result; tool-runtime §Result and UI separation / §Async and
--- retained results).
---   * every completed result carries a default retention record (keep,
---     owner, set_at, source="default") attached AFTER persistence,
---   * discard removes only the auxiliary payload (result.aux) + metadata,
---   * defer records rounds + deadline (rounds -> deadline_ms via
---     TTL_ROUND_MS, or opts.round counter); invalid rounds rejected without
---     mutating the existing policy,
---   * keep clears defer state; persist marks compaction/recovery retention,
---   * expire marks expired metadata only,
---   * foreign-owner retain/expire rejected (owner_mismatch) with the policy
---     unchanged,
---   * task-level retain/expire convenience mirrors the module API and never
---     touches provider-facing content.
---
--- Fixture convention: prints TOOLS_TTL_RESULT_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local fake_clock = require("tests.state.lib.fake_clock")
local registry_mod = require("maxa.runtime.tools.registry")
local task_mod = require("maxa.runtime.tools.task")
local harness = require("tests.tools.lib.harness")

local A = assert_mod.new()

do
  local reg = registry_mod.new()
  reg:register({
    id = "demo/async-ttl",
    name = "async-ttl",
    description = "async tool with a retained result",
    input_schema = { type = "object" },
    execution = { mode = "async" },
    run = function()
      return nil
    end,
  })
  local clock = fake_clock.new({ now = 5000 })
  local exec, h = harness.new({
    registry = reg,
    clock = clock,
    calls = {
      { call_id = "c1", name = "async-ttl", arguments = "{}" },
    },
  })
  exec:run_all()
  local task = h.batch.calls[1].task
  task.complete("provider content")
  local result = h.batch.calls[1].result
  local part = h.stack:get(1).content[1]
  local provider_content = result.content
  A.assert_eq(provider_content, "provider content", "ttl: provider content baseline")

  -- Default retention attached on completion (aux-payload policy, after
  -- persistence: the stack message already exists and is untouched).
  A.check(result.retention ~= nil, "ttl: default retention metadata attached")
  A.assert_eq(result.retention.action, "keep", "ttl: default action keep")
  A.assert_eq(result.retention.source, "default", "ttl: default source")
  A.assert_eq(result.retention.owner.session_id, "s-tools", "ttl: retention owner session")
  A.assert_eq(result.retention.set_at_ms, 5000, "ttl: retention set_at from clock")
  A.check(task.result.retention ~= nil, "ttl: task result retention attached")

  -- Provider-facing content stays byte-identical across every TTL action.
  local function provider_intact(tag)
    A.assert_eq(result.content, provider_content, "ttl: provider content unchanged (" .. tag .. ")")
    A.assert_eq(result.status, "success", "ttl: result status unchanged (" .. tag .. ")")
    A.assert_eq(part.content, provider_content, "ttl: persisted message unchanged (" .. tag .. ")")
  end

  -- discard: removes ONLY the auxiliary payload + retention metadata.
  result.aux = { summary = "compact display", bytes = 12 }
  local r2, rerr = task_mod.retain(result, "discard", {
    owner = { session_id = "s-tools", request_id = "r-tools", batch_id = h.batch.id },
  })
  A.check(r2 == result and rerr == nil, "ttl: discard accepted")
  A.assert_eq(result.retention.action, "discard", "ttl: action discard")
  A.check(result.retention.removed == true, "ttl: discard removed flag")
  A.check(result.aux == nil, "ttl: aux payload removed by discard")
  provider_intact("discard")

  -- defer: rounds + deadline derived from rounds (metadata only).
  local _, derr = task_mod.retain(result, "defer", { rounds = 3, clock = clock })
  A.check(derr == nil, "ttl: defer accepted")
  A.assert_eq(result.retention.action, "defer", "ttl: action defer")
  A.assert_eq(result.retention.rounds, 3, "ttl: defer rounds")
  A.assert_eq(result.retention.deadline_ms, 5000 + 3 * task_mod.TTL_ROUND_MS, "ttl: defer deadline derived from rounds")
  A.check(result.retention.removed == false, "ttl: defer clears removed")
  provider_intact("defer")

  -- defer with an explicit round counter records deadline_round.
  local _, derr2 = task_mod.retain(result, "defer", { rounds = 2, round = 7, clock = clock })
  A.check(derr2 == nil, "ttl: defer with round counter accepted")
  A.assert_eq(result.retention.deadline_round, 9, "ttl: deadline round recorded")
  A.check(result.retention.deadline_ms == 5000 + 2 * task_mod.TTL_ROUND_MS, "ttl: deadline follows latest defer")

  -- invalid rounds: rejected BEFORE any mutation (policy unchanged).
  local rbad, berr = task_mod.retain(result, "defer", { rounds = 0 })
  A.check(rbad == nil and berr ~= nil and berr.code == "invalid_rounds", "ttl: invalid rounds rejected")
  A.assert_eq(result.retention.rounds, 2, "ttl: failed defer left rounds unchanged")
  A.assert_eq(result.retention.action, "defer", "ttl: failed defer left action unchanged")

  -- keep: session retention, no deadline.
  local _, kerr = task_mod.retain(result, "keep")
  A.check(kerr == nil, "ttl: keep accepted")
  A.assert_eq(result.retention.action, "keep", "ttl: action keep")
  A.check(result.retention.deadline_ms == nil, "ttl: keep clears deadline")
  A.check(result.retention.deadline_round == nil, "ttl: keep clears deadline round")
  A.check(result.retention.rounds == nil, "ttl: keep clears rounds")
  provider_intact("keep")

  -- persist: compaction/recovery retention, no deadline.
  local _, perr = task_mod.retain(result, "persist")
  A.check(perr == nil, "ttl: persist accepted")
  A.assert_eq(result.retention.action, "persist", "ttl: action persist")
  A.check(result.retention.persistent == true, "ttl: persist flag")
  A.check(result.retention.deadline_ms == nil, "ttl: persist no deadline")
  provider_intact("persist")

  -- expire: availability metadata only (aux kept until a discard removes it).
  local _, eerr = task_mod.expire(result, { at_ms = 7000 })
  A.check(eerr == nil, "ttl: expire accepted")
  A.check(result.retention.expired == true, "ttl: expired flag")
  A.assert_eq(result.retention.expired_at_ms, 7000, "ttl: expired at recorded")
  provider_intact("expire")

  -- Ownership: a foreign owner cannot change the policy; nothing mutates.
  local rforeign, ferr = task_mod.retain(result, "discard", {
    owner = { session_id = "other", request_id = "x", batch_id = "b" },
  })
  A.check(rforeign == nil and ferr ~= nil and ferr.code == "owner_mismatch", "ttl: foreign owner rejected")
  A.assert_eq(result.retention.action, "persist", "ttl: rejected retain left policy unchanged")
  local eforeign, ef_err = task_mod.expire(result, { owner = { session_id = "other" } })
  A.check(eforeign == nil and ef_err ~= nil and ef_err.code == "owner_mismatch", "ttl: foreign expire rejected")
  provider_intact("foreign-owner")

  -- Task-level convenience: task:retain / task:expire operate on task.result
  -- and never touch provider-facing content.
  local tr, terr = task.retain("defer", { rounds = 1, clock = clock })
  A.check(tr ~= nil and terr == nil, "ttl: task:retain works")
  A.assert_eq(task.result.retention.action, "defer", "ttl: task result retention updated")
  A.assert_eq(task.result.retention.owner.session_id, "s-tools", "ttl: task retention owner")
  A.check(task.result.retention.deadline_ms == 5000 + 1 * task_mod.TTL_ROUND_MS, "ttl: task retention deadline")
  local te, teerr = task.expire({ at_ms = 9000 })
  A.check(te ~= nil and teerr == nil, "ttl: task:expire works")
  A.check(task.result.retention.expired == true, "ttl: task result expired")
  A.assert_eq(task.result.retention.expired_at_ms, 9000, "ttl: task result expired at")
  A.assert_eq(task.result.content, provider_content, "ttl: task result content unchanged")
  A.assert_eq(result.content, provider_content, "ttl: call result content unchanged after task TTL")
  A.assert_eq(part.content, provider_content, "ttl: persisted message unchanged after task TTL")
end

if A.ok then
  print("TOOLS_TTL_RESULT_OK")
else
  error("TOOLS_TTL_RESULT_FAILED count=" .. #A.failures)
end
