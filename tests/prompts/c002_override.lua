-- filepath: tests/prompts/c002_override.lua
--- C-002: `.maxa/system.md` precedence and deterministic placeholder
--- expansion; the development `.supermax/` is never consulted.
local assert_mod = require("tests.prompts.lib.assert")
local fp = require("tests.prompts.lib.fixture_project")
local prompts = require("maxa.runtime.prompts")

local ctx = assert_mod.new()

local OPTS = {
  now = "2026-08-06",
  machine = "Linux",
  vim_ver = "0.11.5",
  skills_state = { records = {} },
}

-- Wrapper with exactly one <system_prompt>: bundled text is injected; wrapper
-- text around the placeholder is preserved; compose is deterministic.
fp.with_project(function(proj)
  fp.write(
    proj,
    ".maxa/system.md",
    "# Project wrapper\n\n<system_prompt>\n\nProject-local rule: answer in Chinese.\n"
  )
  local res = prompts.compose(vim.tbl_extend("force", { root = proj.root }, OPTS))
  ctx.check(res.error == nil, "override compose must not error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(res.system_prompt:find("# Project wrapper", 1, true) ~= nil, "wrapper heading must be preserved")
  ctx.check(res.system_prompt:find("Project-local rule: answer in Chinese.", 1, true) ~= nil, "wrapper rule must be preserved")
  ctx.check(
    res.system_prompt:find("maxa runtime system contract", 1, true) ~= nil,
    "expanded <system_prompt> must contain bundled content"
  )
  ctx.check(res.manifest.used_fallback == false, "override compose must record used_fallback=false")
  ctx.check(
    res.manifest.override_path == proj.root .. "/.maxa/system.md",
    "manifest must record the override path"
  )
  local res2 = prompts.compose(vim.tbl_extend("force", { root = proj.root }, OPTS))
  ctx.assert_eq(res2.system_prompt, res.system_prompt, "identical override composes must be byte-identical")
  ctx.check(vim.deep_equal(res2.manifest, res.manifest), "identical override composes must have identical manifests")
end)

-- Wrapper without the placeholder: missing-system-prompt-placeholder, blocked.
fp.with_project(function(proj)
  fp.write(proj, ".maxa/system.md", "# Broken wrapper\nNo placeholder here.\n")
  local res = prompts.compose(vim.tbl_extend("force", { root = proj.root }, OPTS))
  ctx.check(res.system_prompt == nil, "missing placeholder must block composition (system_prompt nil)")
  ctx.check(
    res.error ~= nil and res.error.kind == "missing-system-prompt-placeholder",
    "missing placeholder must be a missing-system-prompt-placeholder error (got " .. vim.inspect(res.error) .. ")"
  )
end)

-- Wrapper with duplicate <system_prompt>: duplicate-system-prompt-placeholder.
fp.with_project(function(proj)
  fp.write(proj, ".maxa/system.md", "<system_prompt>\n<system_prompt>\n")
  local res = prompts.compose(vim.tbl_extend("force", { root = proj.root }, OPTS))
  ctx.check(
    res.error ~= nil and res.error.kind == "duplicate-system-prompt-placeholder",
    "duplicate <system_prompt> must be a typed error (got " .. vim.inspect(res.error) .. ")"
  )
end)

-- A `.supermax/system.md` next to a missing `.maxa/system.md` must NEVER be
-- used: fallback composes from bundled, output contains no .supermax content.
fp.with_project(function(proj)
  fp.write(proj, ".supermax/system.md", "SUPERMAX_SECRET_MARKER_ONLY_HERE\n")
  local res = prompts.compose(vim.tbl_extend("force", { root = proj.root }, OPTS))
  ctx.check(res.error == nil, "fallback compose must not error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(
    res.system_prompt:find("SUPERMAX_SECRET_MARKER_ONLY_HERE", 1, true) == nil,
    ".supermax/system.md must never be consulted"
  )
  ctx.check(res.manifest.used_fallback == true, "fallback manifest must be recorded")
end)

if not ctx.ok then
  error("c002_override failed", 0)
end
print("C002_OVERRIDE_OK")
return true
