-- filepath: tests/skills/hook-startup-global.lua
--- Phase-3 W6 fixture: startup-global hooks.
---   * setup_startup_hooks registers load=startup hooks exactly once per
---     runtime startup (a second setup call dedups, identity provenance keeps
---     the first registration);
---   * the registered global hook fires for any session (pre dispatch).
---
--- Fixture convention: prints HOOK_STARTUP_GLOBAL_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "startup-skill", { name = "startup-skill", description = "startup hook fixture" }, "BODY")
h.write_hook_md(
  h.project_root,
  "startup-skill",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre" },
  "## user\n\nSTARTUP PROMPT\n"
)

local d = h.discover()
d.scan()
local env = h.hook_env()

-------------------------------------------------------------------------------
-- A. registered once per runtime startup
-------------------------------------------------------------------------------
do
  local first = skills.setup_startup_hooks({ discover = d, registry = env.registry })
  A.assert_eq(first.registered, 1, "startup: first setup registers 1 hook")
  A.assert_eq(first.deduped, 0, "startup: first setup dedups 0")
  A.assert_eq(#first.errors, 0, "startup: no errors on first setup")

  local second = skills.setup_startup_hooks({ discover = d, registry = env.registry })
  A.assert_eq(second.registered, 0, "startup: second setup registers 0 new hooks")
  A.assert_eq(second.deduped, 1, "startup: second setup dedups the existing hook")

  local state = env.registry.state()
  A.assert_eq(state.total, 1, "startup: exactly one entry after two setups")
end

-------------------------------------------------------------------------------
-- B. fires for any session (global scope)
-------------------------------------------------------------------------------
do
  local res = env.fire.pre("ChatSubmitted", { session_id = "sess-one" }, { stack = env.stack })
  A.check(res.ok, "startup: pre dispatch ok")
  A.assert_eq(res.injected, 1, "startup: injected 1 message")
  A.assert_eq(#env.stack.messages, 1, "startup: stack has 1 message")
  local msg = env.stack.messages[1]
  A.assert_eq(msg._meta.provenance.skill_id, "startup-skill", "startup: provenance skill_id")
  A.assert_eq(msg._meta.provenance.inject_at, "pre", "startup: provenance inject_at")
  A.assert_eq(msg.content[1].text, "STARTUP PROMPT", "startup: injected content")

  local res2 = env.fire.pre("ChatSubmitted", { session_id = "sess-two" }, { stack = env.stack })
  A.check(res2.ok, "startup: second session dispatch ok")
  A.assert_eq(res2.injected, 1, "startup: global hook fires for a different session too")
end

if not A.ok then
  error("hook-startup-global FAILED", 0)
end
h.cleanup()
print("HOOK_STARTUP_GLOBAL_OK")
