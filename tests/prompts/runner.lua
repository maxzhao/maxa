-- filepath: tests/prompts/runner.lua
--- Phase-5 W5 prompt-composition fixture runner (C-001..C-004 core).
---
--- Discovers and sequentially executes every fixture file directly under
--- tests/prompts/ (files in tests/prompts/lib/ are shared helpers, never
--- fixtures). Fixture convention: print an OK marker on success; throw
--- (error) on failure. Before the fixtures the runner asserts the import
--- guard (no legacy families loaded) and preloads the shared lib helpers
--- into package.loaded so fixtures can require them regardless of runtimepath.
---
--- Exit contract: returns true when everything passed; throws on any failure so
--- the standard headless wrapper (`pcall(dofile) -> qa!|cq`) maps failures to
--- exit code 1. Prints `PROMPTS_RUNNER_OK` when the whole suite passed.
local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/prompts")
-- Preload shared helpers for fixtures.
package.loaded["tests.prompts.lib.assert"] = dofile(dir .. "/lib/assert.lua")
package.loaded["tests.prompts.lib.fixture_project"] = dofile(dir .. "/lib/fixture_project.lua")
local ok_all = true
local function check(cond, msg)
  if not cond then
    ok_all = false
    print("PROMPTS_RUNNER_FAIL: " .. msg)
  end
end
-- Import guard: nothing legacy may be loaded by the prompts suite.
do
  local guard = require("maxa.runtime.guard")
  local gok, gerr = pcall(guard.assert_no_forbidden)
  check(gok, "import-guard: no legacy families loaded (" .. tostring(gerr) .. ")")
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
      print("PROMPTS_RUNNER_PASS: " .. name)
    else
      failed = failed + 1
      ok_all = false
      print("PROMPTS_RUNNER_FAIL: " .. name .. ": " .. tostring(err))
    end
  end
end
print(("PROMPTS_RUNNER: passed=%d failed=%d"):format(passed, failed))
if not ok_all or failed > 0 then
  error("prompts runner failed", 0)
end
print("PROMPTS_RUNNER_OK")
return true
