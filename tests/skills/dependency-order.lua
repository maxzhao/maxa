-- filepath: tests/skills/dependency-order.lua
--- Phase-3 W5 fixture: `skill/dependency-order` (runtime-fixture-contract).
---   * dependencies load before the requesting Skill (topological order),
---   * a shared dependency activates exactly once per session,
---   * cycles and missing dependencies fail typed and activate NOTHING,
---   * unknown ids fail typed (INVALID_ARGUMENT),
---   * dedup preserves first-load provenance; fresh session loader re-activates.
---
--- Fixture convention: prints SKILL_DEPENDENCY_ORDER_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")

local A = assert_mod.new()
local h = harness.new()

-- Project-root closure: base <- {lib-a, lib-b} <- app; cycle pair; broken dep.
h.write_skill(h.project_root, "base", { name = "base", description = "base lib", dependencies = {} }, "BASE BODY")
h.write_skill(h.project_root, "lib-a", { name = "lib-a", description = "lib a", dependencies = { "base" } }, "A BODY")
h.write_skill(h.project_root, "lib-b", { name = "lib-b", description = "lib b", dependencies = { "base" } }, "B BODY")
h.write_skill(
  h.project_root,
  "app",
  { name = "app", description = "app", dependencies = { "lib-a", "lib-b" } },
  "APP BODY"
)
h.write_skill(
  h.project_root,
  "cyc-x",
  { name = "cyc-x", description = "cycle x", dependencies = { "cyc-y" } },
  "X BODY"
)
h.write_skill(
  h.project_root,
  "cyc-y",
  { name = "cyc-y", description = "cycle y", dependencies = { "cyc-x" } },
  "Y BODY"
)
h.write_skill(
  h.project_root,
  "broken",
  { name = "broken", description = "broken", dependencies = { "nope" } },
  "BROKEN BODY"
)

local d = h.discover()
d.scan()
local l = h.loader(d)

-------------------------------------------------------------------------------
-- A. Topological order: dependencies before the requesting skill
-------------------------------------------------------------------------------
do
  local rec, err = l.load("app")
  A.check(rec ~= nil, "do: app loaded")
  A.assert_eq(table.concat(l.list(), ","), "base,lib-a,lib-b,app", "do: topological load order")
  A.check(l.is_loaded("base") and l.is_loaded("lib-a") and l.is_loaded("lib-b"), "do: all dependencies loaded")
end

-------------------------------------------------------------------------------
-- B. Dedup: second load returns the same record, no re-activation
-------------------------------------------------------------------------------
do
  local rec1 = l.record("app")
  local rec2, err = l.load("app")
  A.check(rec2 ~= nil and rec2 == rec1, "do: dedup returns the first-loaded record")
  A.assert_eq(#l.list(), 4, "do: no duplicate activation in one session")
end

-------------------------------------------------------------------------------
-- C. Cycle: typed failure, no partial activation
-------------------------------------------------------------------------------
do
  local rec, err = l.load("cyc-x")
  A.check(rec == nil and err ~= nil, "do: cycle load rejected")
  if err then
    A.assert_eq(err.code, "configuration", "do: cycle error typed CONFIGURATION")
    A.check(err.message:find("cycle", 1, true) ~= nil, "do: cycle error names the cycle")
  end
  A.check(not l.is_loaded("cyc-x") and not l.is_loaded("cyc-y"), "do: no partial activation on cycle")
  A.assert_eq(#l.list(), 4, "do: loader state unchanged after cycle")
end

-------------------------------------------------------------------------------
-- D. Missing dependency: typed failure, requesting skill not activated
-------------------------------------------------------------------------------
do
  local rec, err = l.load("broken")
  A.check(rec == nil and err ~= nil, "do: missing-dependency load rejected")
  if err then
    A.assert_eq(err.code, "configuration", "do: missing-dep error typed CONFIGURATION")
    A.check(err.message:find("nope", 1, true) ~= nil, "do: missing-dep error names the dependency")
  end
  A.check(not l.is_loaded("broken"), "do: broken skill not activated")
  A.assert_eq(#l.list(), 4, "do: loader state unchanged after missing dep")
end

-------------------------------------------------------------------------------
-- E. Unknown id: typed INVALID_ARGUMENT
-------------------------------------------------------------------------------
do
  local rec, err = l.load("nope")
  A.check(rec == nil and err ~= nil, "do: unknown skill rejected")
  if err then
    A.assert_eq(err.code, "invalid_argument", "do: unknown skill typed INVALID_ARGUMENT")
  end
end

-------------------------------------------------------------------------------
-- F. Per-session dedup: a fresh loader re-activates the closure
-------------------------------------------------------------------------------
do
  local l2 = h.loader(d)
  local rec, err = l2.load("app")
  A.check(rec ~= nil and #l2.list() == 4, "do: fresh session loader re-activates")
end

h.cleanup()
if A.ok then
  print("SKILL_DEPENDENCY_ORDER_OK")
else
  error("SKILL_DEPENDENCY_ORDER_FAILED count=" .. #A.failures)
end
