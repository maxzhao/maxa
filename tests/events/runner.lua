-- filepath: tests/events/runner.lua
--- Phase-5 W1 event-bus fixture runner.
---
--- Discovers and sequentially executes every fixture file directly under
--- tests/events/ (no subdirectories; shared helpers live under
--- tests/state/lib/ and are preloaded below).
--- Fixture convention: print an OK marker on success; throw (error) on failure.
--- Before the fixtures the runner asserts the import guard (no legacy families
--- loaded) and preloads the shared lib helpers into package.loaded so fixtures
--- can `require("tests.state.lib.*")` regardless of runtimepath layout.
---
--- Exit contract: returns true when everything passed; throws on any failure so
--- the standard headless wrapper (`pcall(dofile) -> qa!|cq`) maps failures to
--- exit code 1.

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/events")

-- Preload shared helpers for fixtures (reused from the state suite).
package.loaded["tests.state.lib.assert"] = dofile(dir .. "/../state/lib/assert.lua")
package.loaded["tests.state.lib.fake_clock"] = dofile(dir .. "/../state/lib/fake_clock.lua")

local ok_all = true

local function check(cond, msg)
  if not cond then
    ok_all = false
    print("RUNNER_FAIL: " .. msg)
  end
end

-- Import guard: nothing legacy may be loaded by the events suite.
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
      print("EVENTS_RUNNER_PASS: " .. name)
    else
      failed = failed + 1
      ok_all = false
      print("EVENTS_RUNNER_FAIL: " .. name .. " :: " .. tostring(err))
    end
  end
end

print(("EVENTS_RUNNER_SUMMARY: %d passed, %d failed, %d total"):format(passed, failed, passed + failed))
if not ok_all then
  error(("EVENTS_RUNNER_FAILED (%d failed)"):format(failed), 0)
end
print("EVENTS_RUNNER_OK")
return true
