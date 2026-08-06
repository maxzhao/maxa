-- filepath: tests/status/runner.lua
--- Phase-5 W2 status/spine fixture runner.
---
--- Same contract as tests/state/runner.lua: discovers and sequentially executes
--- every fixture file directly under tests/status/ (the lib helpers are
--- preloaded into package.loaded so fixtures can require("tests.status.lib.*")
--- regardless of runtimepath layout). Before the fixtures the runner asserts
--- the import guard (no legacy families loaded).
---
--- Exit contract: returns true when everything passed; throws on any failure so
--- the standard headless wrapper (`pcall(dofile) -> qa!|cq`) maps failures to
--- exit code 1. Prints STATUS_RUNNER_OK on success.
---
--- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
---   local d='<root>/tests/status/runner.lua' local ok=pcall(dofile,d)
---   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/status")

-- Preload shared helpers (assert context + deterministic fake clock reused from
-- the phase-2 state suite; no copies kept in tests/status/).
package.loaded["tests.status.lib.assert"] = dofile(dir .. "/../state/lib/assert.lua")
package.loaded["tests.status.lib.fake_clock"] = dofile(dir .. "/../state/lib/fake_clock.lua")

local ok_all = true

local function check(cond, msg)
  if not cond then
    ok_all = false
    print("STATUS_RUNNER_FAIL: " .. msg)
  end
end

-- Import guard: nothing legacy may be loaded by the status suite.
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
      print("STATUS_RUNNER_PASS: " .. name)
    else
      failed = failed + 1
      ok_all = false
      print("STATUS_RUNNER_FAIL: " .. name .. " :: " .. tostring(err))
    end
  end
end

print(("STATUS_RUNNER_SUMMARY: %d passed, %d failed, %d total"):format(passed, failed, passed + failed))
if not ok_all then
  error(("STATUS_RUNNER_FAILED (%d failed)"):format(failed), 0)
end
print("STATUS_RUNNER_OK")
return true
