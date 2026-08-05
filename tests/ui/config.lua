-- filepath: tests/ui/config.lua
-- chat-ui config wiring headless validation (phase 1.5 subpackage 3.6):
--   A. default setup: without a ui block, host view defaults are unchanged
--      (show_reasoning stays false) and require("maxa").setup() is safe.
--   B. ui.show_reasoning wiring: a project `.maxa/runtime.yaml` with
--      `ui.show_reasoning: true` flows through config.load -> unfreeze ->
--      host.set_defaults -> a new view renders reasoning expanded.
--   C. terminal import-guard assert (nothing legacy loaded).
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/ui/config.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("UICFG_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")
local config = require("maxa.runtime.config")

--------------------------------------------------------------------------------
-- A. Default setup leaves host defaults untouched
--------------------------------------------------------------------------------
do
  local before = host.DEFAULT_SHOW_REASONING
  local ok_pcall = pcall(function()
    require("maxa").setup({})
  end)
  check(ok_pcall, "A: require('maxa').setup({}) did not error")
  assert_eq(host.DEFAULT_SHOW_REASONING, before, "A: default show_reasoning unchanged without ui block")
  local v = host.new({ provider = "mock", events = events.new() })
  assert_eq(v.show_reasoning, false, "A: new view defaults to collapsed reasoning")
end

--------------------------------------------------------------------------------
-- B. ui.show_reasoning wiring through a temp project config
--------------------------------------------------------------------------------
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/.maxa", "p")
  local yaml = [[
schema_version: 1
project_id: ui-wiring-test
ui:
  show_reasoning: true
  layout: horizontal
]]
  local f = io.open(tmp .. "/.maxa/runtime.yaml", "w")
  f:write(yaml)
  f:close()
  local snap, cerr = config.load(tmp, { resolve_root = false })
  check(snap ~= nil, "B: temp config loads (" .. tostring(cerr and cerr.message or "") .. ")")
  local raw = snap and config.unfreeze(snap._view)
  check(raw ~= nil, "B: unfreeze yields the real view")
  assert_eq(raw.ui.show_reasoning, true, "B: ui.show_reasoning parsed")
  assert_eq(raw.ui.layout, "horizontal", "B: ui.layout parsed")
  -- Same wiring as require("maxa").setup: host defaults follow the ui block.
  host.set_defaults({ show_reasoning = raw.ui.show_reasoning, layout = raw.ui.layout })
  assert_eq(host.DEFAULT_SHOW_REASONING, true, "B: host default follows ui.show_reasoning")
  assert_eq(host.DEFAULT_LAYOUT, "horizontal", "B: host default layout follows ui.layout")
  local v = host.new({ provider = "mock", events = events.new() })
  assert_eq(v.show_reasoning, true, "B: new view renders reasoning expanded")
  -- Restore the defaults for any later tests in this session.
  host.set_defaults({ show_reasoning = false, layout = "vertical" })
end

--------------------------------------------------------------------------------
-- C. Terminal import-guard assert (nothing legacy loaded)
--------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "C: import-guard: no legacy families loaded")
end

if ok_all then
  print("UI_CFG_OK")
else
  print("UI_CFG_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
