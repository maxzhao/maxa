-- filepath: tests/tools/runner.lua
--- Phase-3 W1 tool-registry fixture runner.
---
--- Discovers and sequentially executes every fixture file directly under
--- tests/tools/ (files in tests/state/lib/ are shared helpers, never fixtures).
--- Fixture convention: print an OK marker on success; throw (error) on failure.
--- Before the fixtures the runner asserts the import guard (no legacy families
--- loaded) and preloads the shared lib helpers from tests/state/lib/ into
--- package.loaded so fixtures can `require("tests.state.lib.*")` regardless of
--- runtimepath layout.
---
--- Exit contract: returns true when everything passed; throws on any failure so
--- the standard headless wrapper (`pcall(dofile) -> qa!|cq`) maps failures to
--- exit code 1.

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/tools")
local state_lib = (dir:match("^(.*)/tools$") or dir) .. "/state/lib"

-- Preload shared helpers (reused from the phase-2 R-STATE test base).
package.loaded["tests.state.lib.assert"] = dofile(state_lib .. "/assert.lua")
package.loaded["tests.state.lib.fake_clock"] = dofile(state_lib .. "/fake_clock.lua")
package.loaded["tests.state.lib.recorder"] = dofile(state_lib .. "/recorder.lua")
package.loaded["tests.state.lib.stuck"] = dofile(state_lib .. "/stuck.lua")
-- Phase-3 W1 tools-suite harness (lib/ subdir; never a fixture itself).
package.loaded["tests.tools.lib.harness"] = dofile(dir .. "/lib/harness.lua")

local ok_all = true

local function check(cond, msg)
  if not cond then
    ok_all = false
    print("TOOLS_RUNNER_FAIL: " .. msg)
  end
end

-- Import guard: nothing legacy may be loaded by the tools suite.
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
      print("TOOLS_RUNNER_PASS: " .. name)
    else
      failed = failed + 1
      ok_all = false
      print("TOOLS_RUNNER_FAIL: " .. name .. " :: " .. tostring(err))
    end
  end
end

print(("TOOLS_RUNNER_SUMMARY: %d passed, %d failed, %d total"):format(passed, failed, passed + failed))
if not ok_all then
  error(("TOOLS_RUNNER_FAILED (%d failed)"):format(failed), 0)
end
print("TOOLS_RUNNER_OK")
return true
