-- filepath: tests/ui/status.lua
-- chat-ui-status headless validation (phase 1.5 subpackage 3.5):
--   A. projection lifecycle: idle -> busy (spinner frame prefixed) -> completed
--      (usage text); failure/cancelled states project too.
--   B. spinner determinism: frame derives from clock time; two calls in the
--      same tick return the same frame; frames stay within the known set.
--   C. lualine component: empty without an active view; projects the active
--      view's text after set_active_view; clearing restores empty.
--   D. terminal import-guard assert (nothing legacy loaded).
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/ui/status.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("STATUS_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")
local status = require("maxa.runtime.host.nvim.status")

local function wait_for(deadline_ms, is_done)
  local waited = 0
  while waited < deadline_ms do
    if is_done() then
      return true
    end
    vim.wait(20)
    waited = waited + 20
  end
  return is_done()
end

--------------------------------------------------------------------------------
-- A. Projection lifecycle (idle -> busy -> completed + usage)
--------------------------------------------------------------------------------
do
  local chunks = {}
  for i = 1, 20 do
    chunks[i] = "chunk-" .. i .. " "
  end
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus, provider_params = { chunks = chunks, delay = 5 } })
  local p = v:projection()
  assert_eq(p.status, "idle", "A: projection idle")
  check(p.text:find("idle", 1, true) ~= nil, "A: idle text")

  -- Busy: spinner frame prefixed, status busy. The mock stream's busy window
  -- is only a few ms, so poll tightly (2ms) to observe it.
  v:submit("hi", { async = true })
  local busy = false
  local t0 = vim.loop.now()
  while vim.loop.now() - t0 < 3000 and v.status ~= "completed" do
    if v.status == "busy" then
      busy = true
      break
    end
    vim.wait(2)
  end
  check(busy, "A: reached busy")
  local p2 = v:projection()
  assert_eq(p2.status, "busy", "A: projection busy")
  local has_frame = false
  for _, f in ipairs(status.SPINNER_FRAMES) do
    if p2.text:sub(1, #f) == f then
      has_frame = true
      break
    end
  end
  check(has_frame, "A: busy projection prefixed by a spinner frame (got " .. tostring(p2.text) .. ")")
  check(p2.text:find("streaming", 1, true) ~= nil, "A: busy text mentions streaming")

  -- Completed: usage projected (set via usage.updated by the mock stream).
  local done = wait_for(5000, function()
    return v.status == "completed"
  end)
  check(done, "A: reached completed")
  local p3 = v:projection()
  assert_eq(p3.status, "completed", "A: projection completed")
  check(p3.text:find("completed", 1, true) ~= nil, "A: completed text")
  if v.usage then
    check(p3.text:find("in=", 1, true) ~= nil, "A: usage input projected")
    check(p3.text:find("out=", 1, true) ~= nil, "A: usage output projected")
  end
  v:close()
end

--------------------------------------------------------------------------------
-- B. Spinner determinism
--------------------------------------------------------------------------------
do
  local f1 = status.spinner_frame()
  local f2 = status.spinner_frame()
  assert_eq(f1, f2, "B: same-tick frames equal")
  local known = false
  for _, f in ipairs(status.SPINNER_FRAMES) do
    if f == f1 then
      known = true
      break
    end
  end
  check(known, "B: frame in known set (got " .. tostring(f1) .. ")")
end

--------------------------------------------------------------------------------
-- C. Lualine component projection
--------------------------------------------------------------------------------
do
  local comp = status.lualine_component()
  status.set_active_view(nil)
  assert_eq(comp(), "", "C: empty without active view")
  local v = host.new({ provider = "mock", events = events.new() })
  status.set_active_view(v)
  local text = comp()
  check(type(text) == "string" and text ~= "", "C: projects active view text (got " .. tostring(text) .. ")")
  check(text:find("idle", 1, true) ~= nil, "C: projected idle text")
  status.set_active_view(nil)
  assert_eq(comp(), "", "C: empty after clearing")
end

--------------------------------------------------------------------------------
-- D. Terminal import-guard assert (nothing legacy loaded)
--------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "D: import-guard: no legacy families loaded")
end

if ok_all then
  print("UI_STATUS_OK")
else
  print("UI_STATUS_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
