-- filepath: tests/ui/config.lua
-- chat-ui config wiring headless validation (phase 1.5 subpackage 3.6):
--   A. default setup: bundled defaults leave host defaults unchanged
--      (show_reasoning=false, layout=vertical) and require("maxa").setup() is safe.
--   B. ui.show_reasoning wiring: LazyVim opts with `ui.show_reasoning: true`
--      and `ui.layout: "horizontal"` flow through config.configure ->
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
local maxa_mod = require("maxa")
--------------------------------------------------------------------------------
-- A. Default setup: bundled defaults flow into host defaults
--------------------------------------------------------------------------------
do
  local before = host.DEFAULT_SHOW_REASONING
  assert_eq(before, false, "A: host default show_reasoning is false")
  local ok_pcall = pcall(function()
    require("maxa").setup({})
  end)
  check(ok_pcall, "A: require('maxa').setup({}) did not error")
  assert_eq(host.DEFAULT_SHOW_REASONING, false, "A: defaults keep show_reasoning false")
  assert_eq(config.effective.ui.show_reasoning, false, "A: effective ui.show_reasoning from defaults")
  local v = host.new({ provider = "mock", events = events.new() })
  assert_eq(v.show_reasoning, false, "A: new view defaults to collapsed reasoning")
end
--------------------------------------------------------------------------------
-- B. ui.show_reasoning wiring through LazyVim opts
--------------------------------------------------------------------------------
do
  -- Same wiring as require("maxa").setup: user opts merge over defaults and
  -- host defaults follow the effective ui block.
  local cfg, cerr = config.configure(maxa_mod.defaults, {
    ui = { show_reasoning = true, layout = "horizontal" },
  })
  check(cfg ~= nil, "B: opts configure ok (" .. tostring(cerr and cerr.message or "") .. ")")
  if cfg then
    assert_eq(cfg.ui.show_reasoning, true, "B: ui.show_reasoning merged")
    assert_eq(cfg.ui.layout, "horizontal", "B: ui.layout merged")
    host.set_defaults({ show_reasoning = cfg.ui.show_reasoning, layout = cfg.ui.layout })
    assert_eq(host.DEFAULT_SHOW_REASONING, true, "B: host default follows ui.show_reasoning")
    assert_eq(host.DEFAULT_LAYOUT, "horizontal", "B: host default layout follows ui.layout")
    local v = host.new({ provider = "mock", events = events.new() })
    assert_eq(v.show_reasoning, true, "B: new view renders reasoning expanded")
  end
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
