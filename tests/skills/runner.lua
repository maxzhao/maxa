-- filepath: tests/skills/runner.lua
--- Phase-3 W5 Skill discovery/loading fixture runner.
---
--- Discovers and sequentially executes every fixture file directly under
--- tests/skills/ (files in tests/skills/lib/ are shared helpers, never
--- fixtures). Fixture convention: print an OK marker on success; throw
--- (error) on failure. Before the fixtures the runner asserts the import
--- guard (no legacy families loaded) and preloads the shared lib helpers
--- from tests/state/lib/ and tests/skills/lib/ into package.loaded so
--- fixtures can require them regardless of runtimepath layout.
---
--- Exit contract: returns true when everything passed; throws on any failure
--- so the standard headless wrapper (`pcall(dofile) -> qa!|cq`) maps failures
--- to exit code 1.

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/skills")

-- Preload shared helpers (phase-2 R-STATE test base + phase-3 W5 skills harness).
package.loaded["tests.state.lib.assert"] = dofile(dir .. "/../state/lib/assert.lua")
package.loaded["tests.skills.lib.harness"] = dofile(dir .. "/lib/harness.lua")

local ok_all = true

local function check(cond, msg)
  if not cond then
    ok_all = false
    print("SKILLS_RUNNER_FAIL: " .. msg)
  end
end

-- Import guard: nothing legacy may be loaded by the skills suite.
do
  local guard = require("maxa.runtime.guard")
  local gok, gerr = pcall(guard.assert_no_forbidden)
  check(gok, "import-guard: no legacy families loaded (" .. tostring(gerr) .. ")")
end

-- Demo-skill sanity: the repo-root bundled demo skill exists (gate/W6 anchor).
do
  local repo_root = dir:match("^(.*)/tests/skills$") or (vim.fn.getcwd())
  local demo = repo_root .. "/skills/demo-echo/SKILL.md"
  check(vim.uv.fs_stat(demo) ~= nil, "demo skill exists at " .. demo)
end

local files = vim.fn.glob(dir .. "/*.lua", false, true)
table.sort(files)

local passed = 0
local failed = 0
for _, path in ipairs(files) do
  local name = path:match("([^/]+)%.lua$")
  if name ~= "runner" then
    local ok, err = pcall(dofile, path)
    if ok then
      passed = passed + 1
      print("SKILLS_RUNNER_PASS: " .. name)
    else
      failed = failed + 1
      ok_all = false
      print("SKILLS_RUNNER_FAIL: " .. name .. " :: " .. tostring(err))
    end
  end
end

print(("SKILLS_RUNNER_SUMMARY: %d passed, %d failed, %d total"):format(passed, failed, passed + failed))
if not ok_all then
  error(("SKILLS_RUNNER_FAILED (%d failed)"):format(failed), 0)
end
print("SKILLS_RUNNER_OK")
return true
