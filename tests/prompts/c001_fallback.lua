-- filepath: tests/prompts/c001_fallback.lua
--- C-001: runtime prompt fallback when the project override is absent.
--- A temp project without `.maxa/system.md` composes from the bundled
--- `lua/maxa/prompts/system.md`; no error, output contains bundled content.
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
    skills_state = { records = {} },
  })
  ctx.check(res.error == nil, "fallback compose must not error (got " .. vim.inspect(res.error) .. ")")
  ctx.check(type(res.system_prompt) == "string" and #res.system_prompt > 0, "fallback output must be non-empty")
  ctx.check(
    res.system_prompt:find("maxa runtime system contract", 1, true) ~= nil,
    "fallback output must contain bundled content"
  )
  ctx.check(res.manifest.used_fallback == true, "manifest must record used_fallback=true")
  ctx.check(res.manifest.override_path == nil, "manifest must not record an override path")
  ctx.check(
    type(res.manifest.bundled_path) == "string" and res.manifest.bundled_path:find("lua/maxa/prompts/system%.md$") ~= nil,
    "manifest must record the bundled prompt path"
  )
  -- Determinism: a second compose with identical inputs is identical.
  local res2 = prompts.compose({
    root = proj.root,
    now = "2026-08-06",
    machine = "Linux",
    vim_ver = "0.11.5",
    skills_state = { records = {} },
  })
  ctx.assert_eq(res2.system_prompt, res.system_prompt, "identical fallback composes must be byte-identical")
end)

if not ctx.ok then
  error("c001_fallback failed", 0)
end
print("C001_FALLBACK_OK")
return true
