-- filepath: tests/skills/hook-lua-failure.lua
--- Phase-3 W6 fixture: lua hook failures are typed and isolated.
---   * a render() error fails that hook with a typed INTERNAL error without
---     stopping other hooks and without corrupting the message stack;
---   * an invalid render() return shape fails with a typed INVALID_ARGUMENT
---     error (still isolated);
---   * a failing lua filter() fails with a typed error and skips the hook;
---   * parse-level lua hook errors (file does not return a table) surface in
---     scan_hooks/register diagnostics and register nothing.
---
--- Fixture convention: prints HOOK_LUA_FAILURE_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")
local parser = require("maxa.runtime.skills.parser")

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "good", { name = "good", description = "healthy md hook" }, "BODY")
h.write_hook_md(
  h.project_root,
  "good",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre" },
  "## user\n\nGOOD PROMPT\n"
)

h.write_skill(h.project_root, "boom", { name = "boom", description = "render errors" }, "BODY")
h.write_hook_lua(
  h.project_root,
  "boom",
  "ChatSubmitted",
  [[
return {
  load = "startup",
  scope = "global",
  inject_at = "pre",
  render = function(ctx)
    error("render boom")
  end,
}
]]
)

h.write_skill(h.project_root, "badprompts", { name = "badprompts", description = "invalid render result" }, "BODY")
h.write_hook_lua(
  h.project_root,
  "badprompts",
  "ChatSubmitted",
  [[
return {
  load = "startup",
  scope = "global",
  inject_at = "pre",
  render = function(ctx)
    return "not a prompt list"
  end,
}
]]
)

h.write_skill(h.project_root, "badfilter", { name = "badfilter", description = "filter errors" }, "BODY")
h.write_hook_lua(
  h.project_root,
  "badfilter",
  "ChatSubmitted",
  [[
return {
  load = "startup",
  scope = "global",
  inject_at = "pre",
  filter = function(ctx)
    error("filter boom")
  end,
  render = function(ctx)
    return { { role = "user", content = "SHOULD NEVER INJECT" } }
  end,
}
]]
)

h.write_skill(h.project_root, "badlua", { name = "badlua", description = "invalid lua hook file" }, "BODY")
h.write_hook_lua(h.project_root, "badlua", "ResponseCompleted", [[return "not a table"]])

local d = h.discover()
d.scan()
local env = h.hook_env()

-------------------------------------------------------------------------------
-- A. parse-level failure: no registration, typed diagnostics
-------------------------------------------------------------------------------
do
  local scanned = parser.scan_hooks(h.skill_dir(h.project_root, "badlua"), "badlua")
  A.assert_eq(#scanned.hooks, 0, "lua-failure: invalid lua hook registers nothing")
  A.assert_eq(#scanned.errors, 1, "lua-failure: one parse error")
  if scanned.errors[1] then
    A.check(scanned.errors[1].message:find("must return a table", 1, true) ~= nil, "lua-failure: parse error message")
  end
end

-------------------------------------------------------------------------------
-- B. dispatch-time typed isolation, no request corruption
-------------------------------------------------------------------------------
do
  local setup = skills.setup_startup_hooks({ discover = d, registry = env.registry })
  A.assert_eq(setup.registered, 4, "lua-failure: good+boom+badprompts+badfilter registered")

  local res = env.fire.pre("ChatSubmitted", { session_id = "s1" }, { stack = env.stack })
  A.check(res.ok == false, "lua-failure: dispatch reports failures")
  A.assert_eq(res.injected, 1, "lua-failure: healthy hook still injected")
  A.assert_eq(#res.failures, 3, "lua-failure: three typed failures")
  A.assert_eq(#env.stack.messages, 1, "lua-failure: no partial/corrupt messages in the stack")

  local by_skill = {}
  for _, failure in ipairs(res.failures) do
    by_skill[failure.skill_id] = failure.error
  end
  A.check(by_skill["boom"] ~= nil and by_skill["boom"].code == "internal", "lua-failure: render error typed INTERNAL")
  A.check(
    by_skill["badprompts"] ~= nil and by_skill["badprompts"].code == "invalid_argument",
    "lua-failure: bad prompt list typed INVALID_ARGUMENT"
  )
  A.check(
    by_skill["badfilter"] ~= nil and by_skill["badfilter"].code == "internal",
    "lua-failure: filter error typed INTERNAL"
  )
  A.check(by_skill["good"] == nil, "lua-failure: healthy hook has no failure")

  -- The failed hooks never injected: only the good prompt is present.
  A.assert_eq(
    env.stack.messages[1]._meta.provenance.skill_id,
    "good",
    "lua-failure: stack contains only the good injection"
  )
  A.assert_eq(env.stack.messages[1].content[1].text, "GOOD PROMPT", "lua-failure: good content intact")
end

if not A.ok then
  error("hook-lua-failure FAILED", 0)
end
h.cleanup()
print("HOOK_LUA_FAILURE_OK")
