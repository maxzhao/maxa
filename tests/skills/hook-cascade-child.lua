-- filepath: tests/skills/hook-cascade-child.lua
--- Phase-3 W6 fixture: cascade hooks follow explicit parent-session lineage.
---   * a declared cascade hook is inherited by child sessions only through
---     explicit register_parent_chain edges;
---   * unrelated sessions never inherit;
---   * lineage is transitive (grandchild sessions inherit through the chain);
---   * inheritance flows downward only (an ancestor of the owner does not
---     receive the hook);
---   * inherit_session_hooks copy-registers session-scoped hooks into a child
---     (subagent fork semantics).
---
--- Fixture convention: prints HOOK_CASCADE_CHILD_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "cascade-skill", { name = "cascade-skill", description = "cascade hook fixture" }, "BODY")
h.write_hook_md(
  h.project_root,
  "cascade-skill",
  "ChatSubmitted",
  { load = "on_load", scope = "cascade", inject_at = "pre" },
  "## user\n\nCASCADE PROMPT\n"
)
h.write_skill(h.project_root, "fork-skill", { name = "fork-skill", description = "session fork fixture" }, "BODY")
h.write_hook_md(
  h.project_root,
  "fork-skill",
  "ChatSubmitted",
  { load = "on_load", scope = "session", inject_at = "pre" },
  "## user\n\nFORK SESSION PROMPT\n"
)

local d = h.discover()
d.scan()
local env = h.hook_env()

local cascade_record = d.resolve("cascade-skill")
local fork_record = d.resolve("fork-skill")

-------------------------------------------------------------------------------
-- A. cascade hook registered at the loading session
-------------------------------------------------------------------------------
do
  local reg = skills.register_skill_hooks(cascade_record, "sessA", { registry = env.registry })
  A.assert_eq(reg.registered, 1, "cascade: hook registered at owner")
  local res = env.fire.pre("ChatSubmitted", { session_id = "sessA" }, { stack = env.stack })
  A.check(res.ok, "cascade: owner dispatch ok")
  A.assert_eq(res.injected, 1, "cascade: owner session injected")
end

-------------------------------------------------------------------------------
-- B. unrelated sessions do NOT inherit without an explicit lineage edge
-------------------------------------------------------------------------------
do
  local res = env.fire.pre("ChatSubmitted", { session_id = "sessUnrelated" }, { stack = env.stack })
  A.check(res.ok, "cascade: unrelated dispatch ok")
  A.assert_eq(res.injected, 0, "cascade: unrelated session NOT injected")
end

-------------------------------------------------------------------------------
-- C. explicit parent chain inherits to child (and transitively to grandchild)
-------------------------------------------------------------------------------
do
  env.registry.register_parent_chain("sessA", "sessB")
  local res_b = env.fire.pre("ChatSubmitted", { session_id = "sessB" }, { stack = env.stack })
  A.check(res_b.ok, "cascade: child dispatch ok")
  A.assert_eq(res_b.injected, 1, "cascade: child session injected through lineage")

  env.registry.register_parent_chain("sessB", "sessC")
  local res_c = env.fire.pre("ChatSubmitted", { session_id = "sessC" }, { stack = env.stack })
  A.check(res_c.ok, "cascade: grandchild dispatch ok")
  A.assert_eq(res_c.injected, 1, "cascade: grandchild session injected through transitive lineage")
end

-------------------------------------------------------------------------------
-- D. inheritance flows downward only
-------------------------------------------------------------------------------
do
  env.registry.register_parent_chain("sessX", "sessA") -- sessA becomes a child of sessX
  local res_x = env.fire.pre("ChatSubmitted", { session_id = "sessX" }, { stack = env.stack })
  A.check(res_x.ok, "cascade: ancestor dispatch ok")
  A.assert_eq(res_x.injected, 0, "cascade: ancestor of the owner does NOT receive the hook")
end

-------------------------------------------------------------------------------
-- E. inherit_session_hooks (subagent fork): session hooks copy to the child
-------------------------------------------------------------------------------
do
  skills.register_skill_hooks(fork_record, "sessParent", { registry = env.registry })
  local inherited = env.registry.inherit_session_hooks("sessParent", "sessChild")
  A.assert_eq(inherited, 1, "cascade: fork inherits 1 session hook")

  local res = env.fire.pre("ChatSubmitted", { session_id = "sessChild" }, { stack = env.stack })
  A.check(res.ok, "cascade: child fork dispatch ok")
  A.assert_eq(res.injected, 1, "cascade: fork child session injected")
  A.assert_eq(res.skipped, 2, "cascade: fork child skips cascade + parent-bound session hooks")

  -- Inheriting again is idempotent (dedup identity).
  local again = env.registry.inherit_session_hooks("sessParent", "sessChild")
  A.assert_eq(again, 0, "cascade: repeated fork inheritance dedups")
end

if not A.ok then
  error("hook-cascade-child FAILED", 0)
end
h.cleanup()
print("HOOK_CASCADE_CHILD_OK")
