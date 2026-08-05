-- filepath: tests/skills/hook-on-load-session.lua
--- Phase-3 W6 fixture: on-load session hooks.
---   * register_skill_hooks binds scope=session hooks to the loading session
---     only (unrelated sessions never receive the injection);
---   * scope=global on_load hooks are unbound and fire for any session;
---   * unregister_session removes the session's hooks (session close).
---
--- Fixture convention: prints HOOK_ON_LOAD_SESSION_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "sess-skill", { name = "sess-skill", description = "session hook fixture" }, "BODY")
h.write_hook_md(
  h.project_root,
  "sess-skill",
  "ChatSubmitted",
  { load = "on_load", scope = "session", inject_at = "pre" },
  "## user\n\nSESSION ONLY PROMPT\n"
)
h.write_skill(
  h.project_root,
  "global-skill",
  { name = "global-skill", description = "global on_load hook fixture" },
  "BODY"
)
h.write_hook_md(
  h.project_root,
  "global-skill",
  "ChatSubmitted",
  { load = "on_load", scope = "global", inject_at = "pre" },
  "## user\n\nGLOBAL ONLOAD PROMPT\n"
)

local d = h.discover()
d.scan()
local env = h.hook_env()

local sess_record = d.resolve("sess-skill")
local glob_record = d.resolve("global-skill")

-------------------------------------------------------------------------------
-- A. session-scoped hook binds only to the loading session
-------------------------------------------------------------------------------
do
  local reg = skills.register_skill_hooks(sess_record, "sessA", { registry = env.registry })
  A.assert_eq(reg.registered, 1, "on-load: session hook registered")
  A.assert_eq(#reg.errors, 0, "on-load: no registration errors")
end

do
  local res_a = env.fire.pre("ChatSubmitted", { session_id = "sessA" }, { stack = env.stack })
  A.check(res_a.ok, "on-load: sessA dispatch ok")
  A.assert_eq(res_a.injected, 1, "on-load: bound session injected")

  local res_b = env.fire.pre("ChatSubmitted", { session_id = "sessB" }, { stack = env.stack })
  A.check(res_b.ok, "on-load: sessB dispatch ok")
  A.assert_eq(res_b.injected, 0, "on-load: unrelated session NOT injected")
  A.assert_eq(res_b.skipped, 1, "on-load: unrelated session skipped by scope")
end

-------------------------------------------------------------------------------
-- B. session close unregisters
-------------------------------------------------------------------------------
do
  env.registry.unregister_session("sessA")
  local res = env.fire.pre("ChatSubmitted", { session_id = "sessA" }, { stack = env.stack })
  A.check(res.ok, "on-load: post-unregister dispatch ok")
  A.assert_eq(res.injected, 0, "on-load: unregistered session no longer injected")
  A.assert_eq(env.registry.state().total, 0, "on-load: registry empty after unregister")
end

-------------------------------------------------------------------------------
-- C. global on_load hook is unbound
-------------------------------------------------------------------------------
do
  local reg = skills.register_skill_hooks(glob_record, "sessB", { registry = env.registry })
  A.assert_eq(reg.registered, 1, "on-load: global hook registered")
  local res = env.fire.pre("ChatSubmitted", { session_id = "sessB" }, { stack = env.stack })
  A.check(res.ok, "on-load: global dispatch ok")
  A.assert_eq(res.injected, 1, "on-load: global on_load hook fires for the session")
  local res_any = env.fire.pre("ChatSubmitted", { session_id = "sess-other" }, { stack = env.stack })
  A.check(res_any.ok, "on-load: any-session dispatch ok")
  A.assert_eq(res_any.injected, 1, "on-load: global on_load hook fires for any session")
end

if not A.ok then
  error("hook-on-load-session FAILED", 0)
end
h.cleanup()
print("HOOK_ON_LOAD_SESSION_OK")
