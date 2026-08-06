-- filepath: tests/history/runner.lua
--- Phase-4 W1 history fixture runner (same pattern as tests/state/runner.lua).
---
--- Discovers and sequentially executes every fixture file directly under
--- tests/history/ (files in tests/history/lib/ are shared helpers, never fixtures).
--- Fixture convention: print an OK marker on success; throw (error) on failure.
--- Before the fixtures the runner asserts the import guard (no legacy families
--- loaded) and preloads the shared lib helpers into package.loaded so fixtures
--- can `require("tests.history.lib.*")` regardless of runtimepath layout.
---
--- Exit contract: returns true when everything passed; throws on any failure so
--- the standard headless wrapper (`pcall(dofile) -> qa!|cq`) maps failures to
--- exit code 1.

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/history")

-- Preload shared helpers for fixtures.
package.loaded["tests.history.lib.assert"] = dofile(dir .. "/lib/assert.lua")
package.loaded["tests.history.lib.fixture_project"] = dofile(dir .. "/lib/fixture_project.lua")

local ok_all = true

local function check(cond, msg)
  if not cond then
    ok_all = false
    print("RUNNER_FAIL: " .. msg)
  end
end

-- Import guard: nothing legacy may be loaded by the history suite.
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
      print("HISTORY_RUNNER_PASS: " .. name)
    else
      failed = failed + 1
      ok_all = false
      print("HISTORY_RUNNER_FAIL: " .. name .. " :: " .. tostring(err))
    end
  end
end

print(("HISTORY_RUNNER_SUMMARY: %d passed, %d failed, %d total"):format(passed, failed, passed + failed))
if not ok_all then
  error(("HISTORY_RUNNER_FAILED (%d failed)"):format(failed), 0)
end
print("HISTORY_RUNNER_OK")
return true
