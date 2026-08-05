-- filepath: tests/skills/metadata-parse.lua
--- Phase-3 W5 fixture: SKILL.md metadata parsing (frontmatter contract).
---   * every supported frontmatter field normalizes to the W5 metadata shape,
---     extra fields are preserved, body is extracted as sanitized context,
---   * one-level subskill ids are stable (`main/sub`); deeper nesting is not
---     a skill,
---   * invalid metadata fails closed (missing name / no frontmatter / broken
---     yaml / non-mapping document) with typed CONFIGURATION errors and scan
---     diagnostics,
---   * a broken project claim blocks global fallback (fail-closed shadowing).
---
--- Fixture convention: prints SKILL_METADATA_PARSE_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")

local A = assert_mod.new()
local h = harness.new()

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "full", {
  name = "full",
  description = "full metadata fixture",
  visibility = "local",
  triggers = { "one", "two" },
  dependencies = { "dep-a", "dep-b" },
  mcp_dependencies = { "server-x" },
  resources = { "references/guide.md" },
  hooks = {},
  system = {},
  exclude = { "SYSTEM.md" },
}, "FULL BODY MARKER")
h.write_skill(h.project_root, "main/sub", { name = "sub", description = "sub skill", triggers = { "sub" } }, "SUB BODY")
h.write_skill(
  h.project_root,
  "main/sub/deep",
  { name = "deep", description = "deep skill", triggers = { "deep" } },
  "DEEP BODY"
)

-- Invalid metadata (fail-closed cases).
h.write_skill_raw(
  h.project_root,
  "bad-missing-name/SKILL.md",
  "---\ndescription: no name here\ntriggers:\n  - x\n---\nBODY\n"
)
h.write_skill_raw(h.project_root, "bad-no-frontmatter/SKILL.md", "# No Frontmatter\nBODY\n")
h.write_skill_raw(
  h.project_root,
  "bad-broken-yaml/SKILL.md",
  "---\nname: bad-broken-yaml\n description: bad indent\n---\nBODY\n"
)
h.write_skill_raw(h.project_root, "bad-list-doc/SKILL.md", "---\n- a\n- b\n---\nBODY\n")

local d = h.discover()
d.scan()

-------------------------------------------------------------------------------
-- A. Full metadata parse
-------------------------------------------------------------------------------
do
  local rec, err = d.resolve("full")
  A.check(rec ~= nil, "mp: full skill resolved")
  if rec then
    local m = rec.metadata
    A.assert_eq(m.name, "full", "mp: metadata.name")
    A.assert_eq(m.description, "full metadata fixture", "mp: metadata.description")
    A.assert_eq(m.visibility, "local", "mp: metadata.visibility")
    A.assert_eq(table.concat(m.triggers, ","), "one,two", "mp: metadata.triggers")
    A.assert_eq(table.concat(m.dependencies, ","), "dep-a,dep-b", "mp: metadata.dependencies")
    A.assert_eq(table.concat(m.mcp_dependencies, ","), "server-x", "mp: metadata.mcp_dependencies")
    A.assert_eq(table.concat(m.resources, ","), "references/guide.md", "mp: metadata.resources")
    A.check(type(m.hooks) == "table" and #m.hooks == 0, "mp: metadata.hooks parsed (empty list)")
    A.check(type(m.system) == "table" and #m.system == 0, "mp: metadata.system parsed (empty list)")
    A.check(m.extra.exclude ~= nil, "mp: extra fields preserved verbatim")
    A.check(rec.body:find("FULL BODY MARKER", 1, true) ~= nil, "mp: body extracted as context")
  end
end

-------------------------------------------------------------------------------
-- B. Subskill depth: one level supported, deeper nesting ignored
-------------------------------------------------------------------------------
do
  local rec, err = d.resolve("main/sub")
  A.check(rec ~= nil, "mp: subskill resolved")
  if rec then
    A.assert_eq(rec.id, "main/sub", "mp: subskill stable relative id")
  end
  local deep, derr = d.resolve("main/sub/deep")
  A.check(deep == nil, "mp: depth-2 nested skill not resolvable")
  local count = 0
  for id in pairs(d.records()) do
    if id == "main/sub/deep" then
      count = count + 1
    end
  end
  A.assert_eq(count, 0, "mp: depth-2 nested skill not indexed")
end

-------------------------------------------------------------------------------
-- C. Invalid metadata fails closed with typed errors + diagnostics
-------------------------------------------------------------------------------
do
  local cases = {
    { id = "bad-missing-name", label = "mp: missing name rejected" },
    { id = "bad-no-frontmatter", label = "mp: missing frontmatter rejected" },
    { id = "bad-broken-yaml", label = "mp: broken yaml rejected" },
    { id = "bad-list-doc", label = "mp: non-mapping document rejected" },
  }
  for _, c in ipairs(cases) do
    local rec, err = d.resolve(c.id)
    A.check(rec == nil and err ~= nil, c.label)
    if err then
      A.assert_eq(err.code, "configuration", c.label .. " (typed CONFIGURATION)")
    end
  end
end
do
  local seen = {}
  for _, bad in ipairs(d.invalid_skills()) do
    seen[bad.id] = true
  end
  A.check(
    seen["bad-missing-name"] and seen["bad-broken-yaml"] and seen["bad-list-doc"],
    "mp: scan diagnostics recorded"
  )
end

-------------------------------------------------------------------------------
-- D. Broken project claim blocks global fallback (fail-closed shadowing)
-------------------------------------------------------------------------------
do
  h.write_skill(
    h.config_root,
    "clash",
    { name = "clash", description = "config clash", triggers = { "clash" } },
    "CFG BODY"
  )
  h.write_skill_raw(h.project_root, "clash/SKILL.md", "---\ndescription: broken project clash\n---\nBODY\n")
  d.scan()
  local rec, err = d.resolve("clash")
  A.check(rec == nil and err ~= nil, "mp: broken project claim blocks global fallback")
  if err then
    A.assert_eq(err.code, "configuration", "mp: shadowed-invalid typed CONFIGURATION")
  end
end

h.cleanup()
if A.ok then
  print("SKILL_METADATA_PARSE_OK")
else
  error("SKILL_METADATA_PARSE_FAILED count=" .. #A.failures)
end
