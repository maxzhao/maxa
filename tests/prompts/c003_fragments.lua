-- filepath: tests/prompts/c003_fragments.lua
--- C-003: Skill SYSTEM.md fragment slots — default/named rendering, ordering,
--- eligibility (allow_non_global), duplicate/unbound/malformed typed errors.
local assert_mod = require("tests.prompts.lib.assert")
local fp = require("tests.prompts.lib.fixture_project")
local prompts = require("maxa.runtime.prompts")

local ctx = assert_mod.new()

local OPTS = {
  now = "2026-08-06",
  machine = "Linux",
  vim_ver = "0.11.5",
}

--- Synthetic discovery record helper (shape: skills.discover parse record).
---@param id string
---@param root_kind string "project"|"config"|"bundled"
---@param system table|nil frontmatter `system` mapping
---@return table
local function rec(id, root_kind, system)
  return {
    id = id,
    root_kind = root_kind,
    file = "/fake-skills/" .. id .. "/SKILL.md",
    valid = true,
    metadata = {
      name = id,
      visibility = root_kind == "project" and "local" or "global",
      system = system,
    },
  }
end

local function records(...)
  local out = {}
  for _, r in ipairs({ ... }) do
    out[r.id] = r
  end
  return out
end

-- Default slot: fragments render at the bundled `<skill_system_prompt_fragments>`
-- position, ordered by priority ascending, then skill id ascending.
fp.with_project(function(proj)
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = {
      records = records(
        rec("z-slow", "config", { content = "FRAG_Z" }),
        rec("a-fast", "config", { content = "FRAG_A" }),
        rec("m-mid", "bundled", { priority = 50, content = "FRAG_M" }),
        rec("x-low", "config", { priority = 200, content = "FRAG_X" })
      ),
    },
  }, OPTS))
  ctx.check(res.error == nil, "default slot compose must not error (got " .. vim.inspect(res.error) .. ")")
  local out = res.system_prompt
  local pos_m = out:find("FRAG_M", 1, true)
  local pos_a = out:find("FRAG_A", 1, true)
  local pos_z = out:find("FRAG_Z", 1, true)
  local pos_x = out:find("FRAG_X", 1, true)
  ctx.check(pos_m ~= nil and pos_m < pos_a, "priority 50 fragment must render before default-100 fragments")
  ctx.check(pos_a ~= nil and pos_a < pos_z, "same priority must order by skill id ascending (a-fast before z-slow)")
  ctx.check(pos_z ~= nil and pos_z < pos_x, "priority 200 fragment must render last")
  ctx.check(
    res.manifest.fragments ~= nil and #res.manifest.fragments == 4,
    "manifest must record all 4 fragments (got " .. vim.inspect(res.manifest.fragments) .. ")"
  )
  local mf = res.manifest.fragments
  ctx.check(mf[1].id == "m-mid" and mf[1].slot == "default" and type(mf[1].hash) == "string" and #mf[1].hash > 0,
    "manifest fragment 1 must be m-mid with a content hash")
  ctx.check(mf[2].id == "a-fast", "manifest fragment 2 must be a-fast (id asc at equal priority)")
  ctx.check(mf[4].id == "x-low", "manifest fragment 4 must be x-low (priority 200)")
end)

-- Named slot: `<skill_system_prompt_fragments:code>` renders declared fragments.
fp.with_project(function(proj)
  fp.write(
    proj,
    ".maxa/system.md",
    "# W\n\n<system_prompt>\n\n## Code rules\n\n<skill_system_prompt_fragments:code>\n"
  )
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = {
      records = records(
        rec("style-keeper", "config", { slot = "code", content = "Always use stylua style." }),
        rec("noise", "project", { slot = "code", content = "SHOULD_NOT_ELEVATE" })
      ),
    },
  }, OPTS))
  ctx.check(res.error == nil, "named slot compose must not error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(
    res.system_prompt:find("Always use stylua style.", 1, true) ~= nil,
    "named slot fragment must render at its placeholder"
  )
  ctx.check(
    res.system_prompt:find("SHOULD_NOT_ELEVATE", 1, true) == nil,
    "non-global fragment without allow_non_global must not elevate"
  )
  ctx.check(
    res.system_prompt:find("<skill_system_prompt_fragments:code>", 1, true) == nil,
    "named slot placeholder must be fully replaced"
  )
end)

-- allow_non_global=true lets a project fragment elevate.
fp.with_project(function(proj)
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = {
      records = records(
        rec("proj-elevated", "project", { allow_non_global = true, content = "PROJECT_ELEVATED_OK" }),
        rec("proj-plain", "project", { content = "PROJECT_PLAIN_SKIP" })
      ),
    },
  }, OPTS))
  ctx.check(res.error == nil, "allow_non_global compose must not error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(
    res.system_prompt:find("PROJECT_ELEVATED_OK", 1, true) ~= nil,
    "project fragment with allow_non_global=true must render"
  )
  ctx.check(
    res.system_prompt:find("PROJECT_PLAIN_SKIP", 1, true) == nil,
    "project fragment without allow_non_global must not render"
  )
end)

-- Placeholder without fragments renders empty (no error).
fp.with_project(function(proj)
  fp.write(proj, ".maxa/system.md", "<system_prompt>\n<skill_system_prompt_fragments:ghost>\n")
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = { records = records(rec("only-default", "config", { content = "D" })) },
  }, OPTS))
  ctx.check(res.error == nil, "empty-slot placeholder must not error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(
    res.system_prompt:find("<skill_system_prompt_fragments:ghost>", 1, true) == nil,
    "placeholder without fragments must render empty"
  )
end)

-- Duplicate slot placeholder -> duplicate-skill-slot-placeholder.
fp.with_project(function(proj)
  fp.write(
    proj,
    ".maxa/system.md",
    "<system_prompt>\n<skill_system_prompt_fragments:code>\n<skill_system_prompt_fragments:code>\n"
  )
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = { records = records(rec("c", "config", { slot = "code", content = "C" })) },
  }, OPTS))
  ctx.check(
    res.error ~= nil and res.error.kind == "duplicate-skill-slot-placeholder",
    "duplicate slot placeholder must be a typed error (got " .. vim.inspect(res.error) .. ")"
  )
end)

-- Declared non-default slot without placeholder -> unbound-skill-system-slot.
fp.with_project(function(proj)
  fp.write(proj, ".maxa/system.md", "<system_prompt>\n")
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = { records = records(rec("doc-skill", "config", { slot = "doc", content = "D" })) },
  }, OPTS))
  ctx.check(
    res.error ~= nil and res.error.kind == "unbound-skill-system-slot",
    "unbound declared slot must be a typed error (got " .. vim.inspect(res.error) .. ")"
  )
end)

-- Malformed named slot placeholder -> malformed-skill-slot-placeholder.
fp.with_project(function(proj)
  fp.write(proj, ".maxa/system.md", "<system_prompt>\n<skill_system_prompt_fragments:bad!name>\n")
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = { records = {} },
  }, OPTS))
  ctx.check(
    res.error ~= nil and res.error.kind == "malformed-skill-slot-placeholder",
    "malformed named slot must be a typed error (got " .. vim.inspect(res.error) .. ")"
  )
end)

-- Invalid slot characters in a declaration fail that fragment (never elevates).
fp.with_project(function(proj)
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = { records = records(rec("bad-slot", "config", { slot = "no space", content = "BAD_SLOT_CONTENT" })) },
  }, OPTS))
  ctx.check(res.error == nil, "invalid declaration slot must fail only that fragment (got " .. vim.inspect(res.error) .. ")")
  ctx.check(
    res.system_prompt:find("BAD_SLOT_CONTENT", 1, true) == nil,
    "invalid-slot declaration must not elevate"
  )
end)

-- Literal angle-bracket text outside the declared grammar is preserved.
fp.with_project(function(proj)
  fp.write(proj, ".maxa/system.md", "<system_prompt>\n<totally_unknown_thing>\n")
  local res = prompts.compose(vim.tbl_extend("force", {
    root = proj.root,
    skills_state = { records = {} },
  }, OPTS))
  ctx.check(res.error == nil, "unknown placeholder must be preserved, not an error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(
    res.system_prompt:find("<totally_unknown_thing>", 1, true) ~= nil,
    "unknown angle-bracket text must stay literal"
  )
end)

if not ctx.ok then
  error("c003_fragments failed", 0)
end
print("C003_FRAGMENTS_OK")
return true
