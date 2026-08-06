-- filepath: tests/prompts/placeholders.lua
--- Scalar placeholders: `<date>` `<vim_ver>` `<machine>` `<root_dir>` expand
--- from the injected composition snapshot; `<skills_table>` renders a
--- deterministic table.
local assert_mod = require("tests.prompts.lib.assert")
local fp = require("tests.prompts.lib.fixture_project")
local prompts = require("maxa.runtime.prompts")

local ctx = assert_mod.new()

fp.with_project(function(proj)
  local res = prompts.compose({
    root = proj.root,
    now = "2026-08-06",
    machine = "Linux",
    vim_ver = "0.11.5",
    skills_state = {
      records = {
        ["b-skill"] = {
          id = "b-skill",
          root_kind = "config",
          file = "/fake-skills/b-skill/SKILL.md",
          valid = true,
          metadata = { name = "B Skill", visibility = "global", system = nil },
        },
        ["a-skill"] = {
          id = "a-skill",
          root_kind = "project",
          file = "/fake-skills/a-skill/SKILL.md",
          valid = true,
          metadata = { name = "A Skill", visibility = "local", system = nil },
        },
        ["broken"] = {
          id = "broken",
          root_kind = "project",
          file = "/fake-skills/broken/SKILL.md",
          valid = false,
          metadata = { name = "Broken", visibility = "local", system = nil },
        },
      },
    },
  })
  ctx.check(res.error == nil, "placeholder compose must not error (got " .. vim.inspect(res.error) .. ")")
  local out = res.system_prompt
  ctx.check(out:find("2026-08-06", 1, true) ~= nil, "<date> must expand to the injected snapshot date")
  ctx.check(out:find("0.11.5", 1, true) ~= nil, "<vim_ver> must expand to the injected version")
  ctx.check(out:find("Linux", 1, true) ~= nil, "<machine> must expand to the injected host class")
  ctx.check(
    out:find(proj.root, 1, true) ~= nil,
    "<root_dir> must expand to the resolved project root"
  )
  ctx.check(out:find("| a-skill |", 1, true) ~= nil, "skills table must contain a-skill (sorted first)")
  ctx.check(out:find("| b-skill |", 1, true) ~= nil, "skills table must contain b-skill")
  ctx.check(out:find("| broken |", 1, true) == nil, "invalid records must not appear in the skills table")
  local pa = out:find("| a-skill |", 1, true)
  local pb = out:find("| b-skill |", 1, true)
  ctx.check(pa ~= nil and pb ~= nil and pa < pb, "skills table must be deterministic by id ascending")
  ctx.check(
    out:find("<date>", 1, true) == nil and out:find("<root_dir>", 1, true) == nil and out:find("<skills_table>", 1, true) == nil,
    "no recognized scalar placeholder may remain unexpanded"
  )
  ctx.check(res.manifest.date == "2026-08-06" and res.manifest.machine == "Linux" and res.manifest.vim_ver == "0.11.5",
    "manifest must record the composition snapshot scalars")
  ctx.check(res.manifest.skills_table_count == 2, "skills table count must exclude invalid records")
end)

-- Default machine/vim_ver detection path must not raise (runtime defaults).
fp.with_project(function(proj)
  local res = prompts.compose({ root = proj.root, skills_state = { records = {} } })
  ctx.check(res.error == nil, "default scalar detection must not error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(type(res.system_prompt) == "string" and #res.system_prompt > 0, "default-scalar output must be non-empty")
  ctx.check(res.manifest.machine ~= nil and res.manifest.vim_ver ~= nil, "default scalars must be recorded in the manifest")
end)

if not ctx.ok then
  error("placeholders failed", 0)
end
print("PLACEHOLDERS_OK")
return true
