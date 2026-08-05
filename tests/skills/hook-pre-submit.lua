-- filepath: tests/skills/hook-pre-submit.lua
--- Phase-3 W6 fixture: pre-submit hooks.
---   * pre injection is synchronous and completes before request composition
---     (the fire.pre return already reflects persisted messages);
---   * deterministic dispatch order: priority desc, then skill_id asc, then
---     registration sequence;
---   * injected messages are normalized conversation messages with
---     provenance {skill_id, event_name, inject_at, role} persisted into the
---     session stack; hook role llm maps to assistant;
---   * firing an unknown event / incomplete payload (missing session_id) /
---     matched pre hook without a stack fails validation with typed errors.
---
--- Fixture convention: prints HOOK_PRE_SUBMIT_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
-- High priority hook.
h.write_skill(h.project_root, "skill-a", { name = "skill-a", description = "priority hook" }, "BODY")
h.write_hook_md(
  h.project_root,
  "skill-a",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre", opts = { priority = 10 } },
  "## user\n\nFROM A\n"
)
-- Default priority; skill_id tie-break with skill-c.
h.write_skill(h.project_root, "skill-b", { name = "skill-b", description = "default priority hook" }, "BODY")
h.write_hook_md(
  h.project_root,
  "skill-b",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre" },
  "## user\n\nFROM B\n"
)
h.write_skill(h.project_root, "skill-c", { name = "skill-c", description = "default priority hook c" }, "BODY")
h.write_hook_md(
  h.project_root,
  "skill-c",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre" },
  "## user\n\nFROM C\n"
)
-- Multi-role hook (llm maps to assistant).
h.write_skill(h.project_root, "roles", { name = "roles", description = "role mapping hook" }, "BODY")
h.write_hook_md(
  h.project_root,
  "roles",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre" },
  "## user\n\nUSER ROLE TEXT\n\n## llm\n\nLLM ROLE TEXT\n\n## system\n\nSYSTEM ROLE TEXT\n"
)

local d = h.discover()
d.scan()
local env = h.hook_env()
skills.setup_startup_hooks({ discover = d, registry = env.registry })

-------------------------------------------------------------------------------
-- A. synchronous injection with provenance, deterministic order
-------------------------------------------------------------------------------
do
  local res = env.fire.pre("ChatSubmitted", { session_id = "s1" }, { stack = env.stack })
  A.check(res.ok, "pre: dispatch ok")
  -- skill-a (priority 10) first; skill-b and skill-c (priority 0) by skill_id;
  -- roles hook contributes 3 prompts (user/llm/system).
  A.assert_eq(res.injected, 6, "pre: 6 messages injected (a, b, c, roles x3)")
  A.assert_eq(#env.stack.messages, 6, "pre: stack length equals injected count (synchronous)")
  local order = {}
  for i, msg in ipairs(env.stack.messages) do
    order[i] = msg._meta.provenance.skill_id
  end
  -- skill-a (priority 10) first; then priority-0 hooks by skill_id asc:
  -- "roles" < "skill-b" < "skill-c".
  A.assert_eq(
    table.concat(order, ","),
    "skill-a,roles,roles,roles,skill-b,skill-c",
    "pre: deterministic priority/skill-id order"
  )

  local first = env.stack.messages[1]
  A.assert_eq(first._meta.provenance.kind, "skill_hook", "pre: provenance kind")
  A.assert_eq(first._meta.provenance.event_name, "ChatSubmitted", "pre: provenance event_name")
  A.assert_eq(first._meta.provenance.inject_at, "pre", "pre: provenance inject_at")
  A.assert_eq(first._meta.provenance.role, "user", "pre: provenance role")
  A.assert_eq(first.content[1].text, "FROM A", "pre: injected content persisted")
end

-------------------------------------------------------------------------------
-- B. role mapping (llm -> assistant)
-------------------------------------------------------------------------------
do
  -- roles hook injected at indices 2..4 (after priority-10 skill-a).
  local roles_msg = env.stack.messages[2]
  A.assert_eq(roles_msg._meta.provenance.skill_id, "roles", "pre: roles hook message found")
  A.assert_eq(roles_msg.role, "user", "pre: user role mapped to user")
  A.assert_eq(roles_msg.content[1].text, "USER ROLE TEXT", "pre: user content persisted")
  -- Second message from the roles hook is the llm section.
  local roles_msg2 = env.stack.messages[3]
  A.check(roles_msg2 ~= nil, "pre: roles llm message exists")
  if roles_msg2 then
    A.assert_eq(roles_msg2.role, "assistant", "pre: llm role mapped to assistant")
    A.assert_eq(roles_msg2.content[1].text, "LLM ROLE TEXT", "pre: llm content persisted")
  end
  local roles_msg3 = env.stack.messages[4]
  A.check(roles_msg3 ~= nil, "pre: roles system message exists")
  if roles_msg3 then
    A.assert_eq(roles_msg3.role, "system", "pre: system role mapped to system")
    A.assert_eq(roles_msg3.content[1].text, "SYSTEM ROLE TEXT", "pre: system content persisted")
  end
end

-------------------------------------------------------------------------------
-- C. validation failures
-------------------------------------------------------------------------------
do
  -- Unknown event.
  local unknown = env.fire.pre("never.registered.event", { session_id = "s1" }, { stack = env.stack })
  A.check(unknown.ok == false, "pre: unknown event fails validation")
  A.check(unknown.error ~= nil and unknown.error.code == "invalid_argument", "pre: unknown event typed error")
  A.assert_eq(unknown.injected, 0, "pre: unknown event injects nothing")

  -- Incomplete payload (missing session_id).
  local no_session = env.fire.pre("ChatSubmitted", { text = "hi" }, { stack = env.stack })
  A.check(no_session.ok == false, "pre: missing session_id fails validation")
  A.check(no_session.error ~= nil and no_session.error.code == "invalid_argument", "pre: missing session typed error")

  -- Matched pre hook without a stack.
  local no_stack = env.fire.pre("ChatSubmitted", { session_id = "s2" }, {})
  A.check(no_stack.ok == false, "pre: matched pre hook without stack fails validation")
  A.check(no_stack.error ~= nil and no_stack.error.message:find("stack", 1, true) ~= nil, "pre: stack error message")
end

if not A.ok then
  error("hook-pre-submit FAILED", 0)
end
h.cleanup()
print("HOOK_PRE_SUBMIT_OK")
