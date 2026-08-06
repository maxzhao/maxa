-- filepath: tests/config/verify-orchestrator.lua
--- phase-5 W6 orchestrator-config wiring validation: the `orchestrator`
--- LazyVim-opts sub-block (tool_concurrency/watchdog/context_stop) must be
--- (a) merged over M.defaults, (b) validated fail-closed by config.configure,
--- and (c) actually consumed by host-created orchestrators (host.new forwards
--- config.effective.orchestrator -> orchestrator.resolve_orchestrator_config).
---
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/config/verify-orchestrator.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.
local ok_all = true
local failures = {}
local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("ORCH_CFG_FAIL: " .. msg)
  end
end

local maxa = require("maxa")
local config = require("maxa.runtime.config")

-- A. Defaults: M.defaults carries the full orchestrator section with the
-- documented defaults (aligned with orchestrator ORCHESTRATOR_DEFAULTS).
do
  local d = maxa.defaults.orchestrator
  check(type(d) == "table", "A: M.defaults.orchestrator is a table")
  check(d.tool_concurrency == 1, "A: default tool_concurrency == 1")
  check(type(d.watchdog) == "table" and d.watchdog.enabled == false, "A: default watchdog disabled")
  check(d.watchdog.timeout_ms == 180000, "A: default watchdog.timeout_ms == 180000")
  check(d.watchdog.max_retries == 3, "A: default watchdog.max_retries == 3")
  check(type(d.context_stop) == "table" and d.context_stop.enabled == false, "A: default context_stop disabled")
end

-- B. Configure validation: fail-closed on unknown keys and type errors.
do
  local function rejects(opts, needle)
    local merged, err = config.configure(maxa.defaults, opts)
    return merged == nil and err ~= nil and (needle == nil or tostring(err.message):find(needle, 1, true) ~= nil)
  end
  check(rejects({ orchestrator = { bogus = 1 } }, "unknown key"), "B: unknown orchestrator key rejected")
  check(rejects({ orchestrator = { tool_concurrency = 0 } }, "positive integer"), "B: tool_concurrency=0 rejected")
  check(rejects({ orchestrator = { tool_concurrency = "x" } }, "positive integer"), "B: tool_concurrency string rejected")
  check(rejects({ orchestrator = { watchdog = { bogus = true } } }, "unknown key"), "B: watchdog unknown key rejected")
  check(rejects({ orchestrator = { watchdog = { enabled = "yes" } } }, "boolean"), "B: watchdog.enabled type rejected")
  check(rejects({ orchestrator = { watchdog = { timeout_ms = -1 } } }, "positive integer"), "B: timeout_ms negative rejected")
  check(rejects({ orchestrator = { watchdog = { max_retries = -1 } } }, "non-negative integer"), "B: max_retries negative rejected")
  check(rejects({ orchestrator = { context_stop = { bogus = 1 } } }, "unknown key"), "B: context_stop unknown key rejected")
  -- Valid configuration merges and resolves.
  local merged, merr = config.configure(maxa.defaults, {
    orchestrator = { tool_concurrency = 2, watchdog = { enabled = true, timeout_ms = 99999, max_retries = 5 } },
  })
  check(merged ~= nil, "B: valid orchestrator block accepted (" .. tostring(merr and merr.message) .. ")")
  if merged then
    check(merged.orchestrator.tool_concurrency == 2, "B: tool_concurrency merged")
    check(merged.orchestrator.watchdog.enabled == true and merged.orchestrator.watchdog.timeout_ms == 99999, "B: watchdog merged")
    check(merged.orchestrator.watchdog.max_retries == 5, "B: max_retries merged")
  end
end

-- C. Runtime wiring: a host-created orchestrator consumes the effective
-- config.orchestrator block (host.new forwards orchestrator_config).
do
  local cfg = maxa.setup({
    provider = { default = "mock" },
    history = { enabled = false },
    orchestrator = { tool_concurrency = 2, watchdog = { enabled = true, timeout_ms = 99999, max_retries = 5 } },
  })
  check(cfg ~= nil, "C: setup returned effective config")
  check(cfg.orchestrator.tool_concurrency == 2, "C: effective orchestrator.tool_concurrency == 2")
  local host = require("maxa.runtime.host.nvim")
  local v = host.new({ provider = "mock" })
  local oc = v.orch.orchestrator_config
  check(type(oc) == "table", "C: orchestrator resolved config present")
  check(oc.tool_concurrency == 2, "C: host orch consumed tool_concurrency == 2")
  check(oc.watchdog.enabled == true and oc.watchdog.timeout_ms == 99999, "C: host orch consumed watchdog block")
  check(oc.watchdog.max_retries == 5, "C: host orch consumed max_retries == 5")
  check(oc.context_stop.enabled == false, "C: context_stop default preserved (false)")
  v:close()
end

-- D. Import guard: nothing legacy loaded.
do
  local guard = require("maxa.runtime.guard")
  local gok, gerr = pcall(guard.assert_no_forbidden)
  check(gok, "D: import-guard clean (" .. tostring(gerr) .. ")")
end

if not ok_all then
  error(("ORCH_CFG_FAILED (%d failures)"):format(#failures), 0)
end
print("ORCH_CFG_OK")
return true
