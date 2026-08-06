-- filepath: tests/prompts/dump.lua
--- dump() shares the compose pipeline; same system_prompt, adds a redacted
--- source manifest (`redacted=true`) with paths/hashes only — no secrets.
local assert_mod = require("tests.prompts.lib.assert")
local fp = require("tests.prompts.lib.fixture_project")
local prompts = require("maxa.runtime.prompts")

local ctx = assert_mod.new()

local OPTS = {
  now = "2026-08-06",
  machine = "Linux",
  vim_ver = "0.11.5",
}

fp.with_project(function(proj)
  fp.write(
    proj,
    ".maxa/system.md",
    "# Wrapper\n\n<system_prompt>\n\n<skill_system_prompt_fragments:code>\n"
  )
  local opts = vim.tbl_extend("force", {
    root = proj.root,
    skills_state = {
      records = {
        ["code-skill"] = {
          id = "code-skill",
          root_kind = "config",
          file = "/fake-skills/code-skill/SKILL.md",
          valid = true,
          metadata = {
            name = "Code Skill",
            visibility = "global",
            system = { slot = "code", content = "SECRET_SNIPPET_CONTENT" },
          },
        },
      },
    },
  }, OPTS)

  local composed = prompts.compose(opts)
  local dumped = prompts.dump(opts)
  ctx.check(dumped.error == nil, "dump must not error (got " .. vim.inspect(dumped.error) .. ")")
  ctx.assert_eq(dumped.system_prompt, composed.system_prompt, "dump must not change the composed output")
  ctx.check(dumped.redacted == true, "dump must set redacted=true")
  ctx.check(type(dumped.sources) == "table" and #dumped.sources >= 2, "dump must include a source manifest")
  local kinds = {}
  for _, s in ipairs(dumped.sources) do
    kinds[s.kind] = true
  end
  ctx.check(kinds.bundled == true, "dump sources must include the bundled prompt")
  ctx.check(kinds.override == true, "dump sources must include the project override")
  -- Redaction: sources/manifest carry paths + hashes, never fragment content.
  for _, s in ipairs(dumped.sources) do
    ctx.check(
      vim.inspect(s):find("SECRET_SNIPPET_CONTENT", 1, true) == nil,
      "redacted sources must not contain fragment content"
    )
  end
  local mf = dumped.manifest.fragments
  ctx.check(mf ~= nil and #mf == 1 and mf[1].id == "code-skill" and mf[1].slot == "code",
    "dump manifest must record the fragment trace (id/slot/path/hash)")
  ctx.check(
    mf[1].path == "/fake-skills/code-skill/SKILL.md" and type(mf[1].hash) == "string",
    "fragment trace must carry source path and content hash"
  )
  ctx.check(
    vim.inspect(dumped.manifest):find("SECRET_SNIPPET_CONTENT", 1, true) == nil,
    "manifest must never carry fragment content"
  )
end)

if not ctx.ok then
  error("dump failed", 0)
end
print("DUMP_OK")
return true
