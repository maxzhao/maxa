-- filepath: tests/skills/hook-once-restore.lua
--- Phase-3 W6 fixture: once/tombstone durability and restore.
---   * a once hook injects exactly once per session (later fires skip);
---   * once + ephemeral writes a hidden tombstone message after the injected
---     payload (durable once marker);
---   * restore_once_state rebuilds fired-once state from history (injected
---     once markers + tombstones) so a restored session never injects a
---     second time; skill.hook_restored is emitted.
---
--- Fixture convention: prints HOOK_ONCE_RESTORE_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")
local events_mod = require("maxa.runtime.events")

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "once-skill", { name = "once-skill", description = "once hook" }, "BODY")
h.write_hook_md(
  h.project_root,
  "once-skill",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre", opts = { once = true } },
  "## user\n\nONCE PROMPT\n"
)
h.write_skill(h.project_root, "ephem-skill", { name = "ephem-skill", description = "once ephemeral hook" }, "BODY")
h.write_hook_md(
  h.project_root,
  "ephem-skill",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre", opts = { once = true, ephemeral = true } },
  "## user\n\nEPHEMERAL ONCE PROMPT\n"
)

local d = h.discover()
d.scan()
local env = h.hook_env()
skills.setup_startup_hooks({ discover = d, registry = env.registry })

-------------------------------------------------------------------------------
-- A. once: single injection, later fires skip
-------------------------------------------------------------------------------
do
  local fired_events = 0
  env.bus.on(events_mod.events.skill_hook_fired, function()
    fired_events = fired_events + 1
  end)

  local first = env.fire.pre("ChatSubmitted", { session_id = "s1" }, { stack = env.stack })
  A.check(first.ok, "once: first dispatch ok")
  A.assert_eq(first.injected, 2, "once: both once hooks injected on first fire")
  A.assert_eq(fired_events, 2, "once: two skill.hook_fired projections")

  local second = env.fire.pre("ChatSubmitted", { session_id = "s1" }, { stack = env.stack })
  A.check(second.ok, "once: second dispatch ok")
  A.assert_eq(second.injected, 0, "once: no second injection")
  A.assert_eq(second.skipped, 2, "once: both once hooks skipped")

  local other = env.fire.pre("ChatSubmitted", { session_id = "s2" }, { stack = env.stack })
  A.check(other.ok, "once: other session dispatch ok")
  A.assert_eq(other.injected, 2, "once: once state is per-session (s2 injects)")
end

-------------------------------------------------------------------------------
-- B. tombstone for once + ephemeral
-------------------------------------------------------------------------------
do
  -- Dispatch order is skill_id asc: ephem-skill before once-skill, so the
  -- stack is [ephem(user), tombstone(ephem), once(user), ...] per session.
  local messages = env.stack.messages
  A.check(#messages >= 6, "once: stack holds injected + tombstone messages")

  local function find_msg(skill_id, tag)
    for _, m in ipairs(messages) do
      local p = m._meta and m._meta.provenance
      if p and p.skill_id == skill_id and (tag == nil or m._meta.tag == tag) then
        return m
      end
    end
    return nil
  end

  local tomb = find_msg("ephem-skill", "skill_hook_tombstone")
  A.check(tomb ~= nil, "once: tombstone exists")
  if tomb then
    A.assert_eq(tomb._meta.tag, "skill_hook_tombstone", "once: tombstone tag")
    A.assert_eq(tomb.role, "system", "once: tombstone role")
    A.assert_eq(tomb.visibility, "hidden", "once: tombstone hidden")
    A.check(type(tomb._meta.provenance.once_key) == "string", "once: tombstone provenance once_key")
    A.assert_eq(tomb._meta.provenance.skill_id, "ephem-skill", "once: tombstone provenance skill_id")
  end
  -- The ephemeral payload itself also carries the once marker.
  local ephem = find_msg("ephem-skill", "skill_hook")
  A.check(ephem ~= nil, "once: ephemeral payload exists")
  if ephem then
    A.assert_eq(ephem._meta.provenance.once, true, "once: ephemeral payload provenance.once")
  end
  local once_msg = find_msg("once-skill", "skill_hook")
  A.check(once_msg ~= nil, "once: once payload exists")
  if once_msg then
    A.assert_eq(once_msg._meta.provenance.once, true, "once: once payload provenance.once")
    A.check(type(once_msg._meta.provenance.once_key) == "string", "once: once payload provenance once_key")
  end
end

-------------------------------------------------------------------------------
-- C. restore_once_state: no second injection after history restore
-------------------------------------------------------------------------------
do
  local history = env.stack:to_table()

  -- Fresh environment = restored session with empty in-memory once state.
  -- A restored session re-registers its hooks first (restore_hooks_from_messages
  -- flow), so register them here before the restore assertions.
  local env2 = h.hook_env()
  skills.setup_startup_hooks({ discover = d, registry = env2.registry })
  local restored_events = 0
  local restored_count = 0
  env2.bus.on(events_mod.events.skill_hook_restored, function(payload)
    restored_events = restored_events + 1
    restored_count = payload.restored
  end)

  local n = env2.injector.restore_once_state("s1", history)
  A.assert_eq(n, 2, "once: restore rebuilds both once keys")
  A.assert_eq(restored_events, 1, "once: skill.hook_restored emitted once")
  A.assert_eq(restored_count, 2, "once: restored count in payload")

  local res = env2.fire.pre("ChatSubmitted", { session_id = "s1" }, { stack = env2.stack })
  A.check(res.ok, "once: restored dispatch ok")
  A.assert_eq(res.injected, 0, "once: no second injection after restore")
  A.assert_eq(res.skipped, 2, "once: both hooks skipped after restore")

  -- Tombstone-only history also restores (simulate a cleaned ephemeral payload).
  local env3 = h.hook_env()
  skills.setup_startup_hooks({ discover = d, registry = env3.registry })
  local tombstone_msg = nil
  for _, m in ipairs(history) do
    if m._meta and m._meta.tag == "skill_hook_tombstone" then
      tombstone_msg = m
      break
    end
  end
  A.check(tombstone_msg ~= nil, "once: tombstone found in history")
  local tomb_history = { tombstone_msg }
  local n3 = env3.injector.restore_once_state("s1", tomb_history)
  A.assert_eq(n3, 1, "once: tombstone alone restores once state")
  local res3 = env3.fire.pre("ChatSubmitted", { session_id = "s1" }, { stack = env3.stack })
  -- Only the ephem hook's once state was persisted (tombstone): it is
  -- skipped; the once-skill hook (no tombstone) legitimately fires again.
  A.assert_eq(res3.injected, 1, "once: only the non-tombstoned hook fires after tombstone-only restore")
  A.assert_eq(res3.skipped, 1, "once: tombstone-restored ephem hook skipped")
  local injected_skills = {}
  for _, m in ipairs(env3.stack.messages) do
    injected_skills[m._meta.provenance.skill_id] = true
  end
  A.check(injected_skills["ephem-skill"] == nil, "once: ephem hook never injects again after tombstone restore")
  A.check(injected_skills["once-skill"] == true, "once: once-skill fires when its state was not restored")
end

if not A.ok then
  error("hook-once-restore FAILED", 0)
end
h.cleanup()
print("HOOK_ONCE_RESTORE_OK")
