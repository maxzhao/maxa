-- filepath: tests/skills/project-overrides-global.lua
--- Phase-3 W5 fixture: `skill/project-overrides-global` (runtime-fixture-contract).
---   * a same-name project Skill shadows the global ones (bundled + config),
---   * a global Skill remains discoverable only when not shadowed,
---   * the loader provenance reflects the winning root.
---
--- Fixture convention: prints SKILL_PROJECT_OVERRIDES_GLOBAL_OK on success;
--- throws on failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")

local A = assert_mod.new()
local h = harness.new()

-- alpha exists in all three roots; beta only config; gamma only bundled.
h.write_skill(
  h.project_root,
  "alpha",
  { name = "alpha", description = "project alpha", triggers = { "alpha" } },
  "PROJECT BODY"
)
h.write_skill(
  h.config_root,
  "alpha",
  { name = "alpha", description = "config alpha", triggers = { "alpha" } },
  "CONFIG BODY"
)
h.write_skill(
  h.bundled_root,
  "alpha",
  { name = "alpha", description = "bundled alpha", triggers = { "alpha" } },
  "BUNDLED BODY"
)
h.write_skill(h.config_root, "beta", { name = "beta", description = "config beta", triggers = { "beta" } }, "BETA BODY")
h.write_skill(
  h.bundled_root,
  "gamma",
  { name = "gamma", description = "bundled gamma", triggers = { "gamma" } },
  "GAMMA BODY"
)

local d = h.discover()
d.scan()

-------------------------------------------------------------------------------
-- A. Project shadows config and bundled for the same id
-------------------------------------------------------------------------------
do
  local rec, err = d.resolve("alpha")
  A.check(rec ~= nil, "pog: alpha resolved")
  if rec then
    A.assert_eq(rec.root_kind, "project", "pog: alpha wins from the project root")
    A.assert_eq(rec.metadata.description, "project alpha", "pog: alpha metadata from project root")
    A.check(rec.body:find("PROJECT BODY", 1, true) ~= nil, "pog: alpha body from project root")
  end
end

-------------------------------------------------------------------------------
-- B. Unshadowed globals remain discoverable
-------------------------------------------------------------------------------
do
  local rec, err = d.resolve("beta")
  A.check(rec ~= nil and rec.root_kind == "config", "pog: beta discoverable from config root")
  local rec2, err2 = d.resolve("gamma")
  A.check(rec2 ~= nil and rec2.root_kind == "bundled", "pog: gamma discoverable from bundled root")
end

-------------------------------------------------------------------------------
-- C. The same id is indexed exactly once
-------------------------------------------------------------------------------
do
  local count = 0
  for _, rec in pairs(d.records()) do
    if rec.id == "alpha" then
      count = count + 1
    end
  end
  A.assert_eq(count, 1, "pog: alpha indexed exactly once")
end

-------------------------------------------------------------------------------
-- D. Loader provenance reflects the winning root
-------------------------------------------------------------------------------
do
  local l = h.loader(d)
  local rec, err = l.load("alpha")
  A.check(rec ~= nil, "pog: loader loaded alpha")
  if rec then
    A.assert_eq(rec.root_kind, "project", "pog: loaded alpha provenance = project")
    A.check(rec.file:sub(1, #h.project_root) == h.project_root, "pog: loaded alpha file under project root")
  end
  A.assert_eq(#l.list(), 1, "pog: exactly one loaded skill")
end

h.cleanup()
if A.ok then
  print("SKILL_PROJECT_OVERRIDES_GLOBAL_OK")
else
  error("SKILL_PROJECT_OVERRIDES_GLOBAL_FAILED count=" .. #A.failures)
end
