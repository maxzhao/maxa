-- filepath: tests/skills/hook-post-observer.lua
--- Phase-3 W6 fixture: post/observer hooks.
---   * observers receive an IMMUTABLE deep copy of the payload: mutating
---     ctx.data inside an observer never changes the already-sent request;
---   * observer return values are ignored (nothing is injected into the
---     composed request);
---   * listener failures are isolated and typed: a failing observer does not
---     stop other observers and never corrupts the main flow.
---
--- Fixture convention: prints HOOK_POST_OBSERVER_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")

-- Shared side-effect ledger for the lua observer hooks.
_G.hook_post_fixture = { runs = {} }

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "obs-ok", { name = "obs-ok", description = "observer ok" }, "BODY")
h.write_hook_lua(
  h.project_root,
  "obs-ok",
  "ResponseCompleted",
  [[
return {
  load = "on_load",
  scope = "global",
  inject_at = "post",
  render = function(ctx)
    -- Mutation on the observer's copy: must never reach the sent request.
    ctx.data.request.text = "MUTATED"
    _G.hook_post_fixture.runs[#_G.hook_post_fixture.runs + 1] = "obs-ok"
    return { { role = "user", content = "IGNORED OBSERVER PROMPT" } }
  end,
}
]]
)
h.write_skill(h.project_root, "obs-fail", { name = "obs-fail", description = "observer failing" }, "BODY")
h.write_hook_lua(
  h.project_root,
  "obs-fail",
  "ResponseCompleted",
  [[
return {
  load = "on_load",
  scope = "global",
  inject_at = "post",
  render = function(ctx)
    error("observer boom")
  end,
}
]]
)
h.write_skill(h.project_root, "obs-ok2", { name = "obs-ok2", description = "observer ok 2" }, "BODY")
h.write_hook_lua(
  h.project_root,
  "obs-ok2",
  "ResponseCompleted",
  [[
return {
  load = "on_load",
  scope = "global",
  inject_at = "post",
  render = function(ctx)
    _G.hook_post_fixture.runs[#_G.hook_post_fixture.runs + 1] = "obs-ok2"
    return { { role = "llm", content = "ALSO IGNORED" } }
  end,
}
]]
)
h.write_skill(h.project_root, "obs-md", { name = "obs-md", description = "md observer" }, "BODY")
h.write_hook_md(
  h.project_root,
  "obs-md",
  "ResponseCompleted",
  { load = "on_load", scope = "global", inject_at = "post" },
  "## system\n\nMD OBSERVER PROMPT\n"
)

local d = h.discover()
d.scan()
local env = h.hook_env()

for _, id in ipairs({ "obs-ok", "obs-fail", "obs-ok2", "obs-md" }) do
  local record = d.resolve(id)
  skills.register_skill_hooks(record, "s1", { registry = env.registry })
end

-------------------------------------------------------------------------------
-- A. immutable sent request + ignored return values + failure isolation
-------------------------------------------------------------------------------
do
  local payload = { session_id = "s1", request_id = "req-1", request = { text = "sent" } }
  local res = env.fire.post("ResponseCompleted", payload, {})
  A.check(res.ok == false, "post: dispatch reports failure (observer boom)")
  A.assert_eq(res.observers, 3, "post: 3 observers ran (obs-ok, obs-ok2, obs-md)")
  A.assert_eq(#res.failures, 1, "post: exactly 1 isolated failure")
  A.check(
    res.failures[1] and res.failures[1].error and res.failures[1].error.code == "internal",
    "post: failure is typed INTERNAL"
  )
  A.check(res.failures[1] and res.failures[1].skill_id == "obs-fail", "post: failure identifies the failing hook")

  -- The already-sent request is unchanged.
  A.assert_eq(payload.request.text, "sent", "post: observer mutation never reaches the sent request")

  -- Returned prompts are ignored: nothing injected.
  A.assert_eq(#env.stack.messages, 0, "post: observer return values are ignored (no injection)")

  -- Both healthy observers ran despite the failure.
  A.assert_eq(#_G.hook_post_fixture.runs, 2, "post: healthy observers still ran")
  table.sort(_G.hook_post_fixture.runs)
  A.assert_eq(table.concat(_G.hook_post_fixture.runs, ","), "obs-ok,obs-ok2", "post: observer run ledger")
end

-------------------------------------------------------------------------------
-- B. validation + async scheduling
-------------------------------------------------------------------------------
do
  local unknown = env.fire.post("never.registered.event", { session_id = "s1" }, {})
  A.check(unknown.ok == false and unknown.error ~= nil, "post: unknown event fails validation")

  local no_session = env.fire.post("ResponseCompleted", { request = {} }, {})
  A.check(no_session.ok == false and no_session.error ~= nil, "post: missing session_id fails validation")

  -- chat.closed has no registered observers: the scheduled dispatch is
  -- side-effect free after the fixture exits.
  local async = env.fire.post("chat.closed", { session_id = "s1" }, { async = true })
  A.check(async.scheduled == true, "post: async option schedules dispatch")
end

if not A.ok then
  error("hook-post-observer FAILED", 0)
end
h.cleanup()
_G.hook_post_fixture = nil
print("HOOK_POST_OBSERVER_OK")
