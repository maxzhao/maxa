-- filepath: tests/host/phase5-wiring.lua
--- phase-5 W6 wiring validation (status spine service + Action/Command
--- registry through the real maxa.setup assembly).
---
---   A. maxa.setup() assembles the status service; host exposes it and the
---      spine snapshot is readable (revision bumps on bus events).
---   B. The Action/Command registry is registered with built-ins; discover
---      over the default view context returns a non-empty deterministic list.
---   C. :MaxaActions palette path dispatches through vim.ui.select and a
---      typed dispatch failure never locks the Chat.
---   D. import-guard assert (nothing legacy loaded).
---
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/host/phase5-wiring.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.
local ok_all = true
local failures = {}
local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("WIRING_FAIL: " .. msg)
  end
end

-- A. Real setup assembly: status service + actions registry wired into host.
do
  local maxa = require("maxa")
  local cfg = maxa.setup({ provider = { default = "mock" }, history = { enabled = false } })
  check(type(cfg) == "table", "A: setup returned effective config")

  local host = require("maxa.runtime.host.nvim")
  check(host._status_service ~= nil, "A: host status service wired")
  check(host._actions ~= nil, "A: host actions registry wired")

  -- Spine snapshot readable; revision bumps after a bus event.
  local events = require("maxa.runtime.events")
  local svc = host._status_service
  local snap0 = svc:snapshot()
  check(type(snap0) == "table", "A: spine snapshot readable")
  local rev0 = snap0.revision or 0
  events.emit(events.events.request_started or "request.started", {
    session_id = "wiring-test-session",
    provider = "mock",
    model = "mock-model",
  })
  local snap1 = svc:snapshot()
  check((snap1.revision or 0) > rev0, "A: spine revision bumped after request.started")
  check(snap1.active_requests >= 1, "A: active_requests incremented")

  -- Registry discover over a real default view context (registry item shape).
  local view = host._get_default()
  check(view ~= nil, "A: default view exists")
  local items = host._actions:discover({
    request_busy = false,
    set_provider = function()
      return true
    end,
    set_model = function()
      return true
    end,
    config = function()
      return cfg
    end,
  })
  check(type(items) == "table" and #items > 0, "A: registry discover non-empty")
  local found = false
  for _, it in ipairs(items) do
    if it.id == "chat.stop" then
      found = true
    end
  end
  check(found, "A: builtin chat.stop discoverable")
end

-- B. Palette dispatch path through vim.ui.select (injected) -> typed result.
do
  local host = require("maxa.runtime.host.nvim")
  local view = host._get_default()
  local orig_select = vim.ui.select
  local chosen_id = nil
  vim.ui.select = function(items, opts, cb)
    chosen_id = items and items[1] and items[1].id
    cb(items and items[1])
  end
  local ok_pal, pal_err = pcall(host.actions_palette, host)
  vim.ui.select = orig_select
  check(ok_pal, "B: actions_palette did not raise (" .. tostring(pal_err) .. ")")
  check(chosen_id ~= nil, "B: palette selected an action id")
  -- A typed dispatch failure path: unknown id must not lock the Chat.
  local res = host._actions:dispatch("no.such.action", {}, { request_busy = false })
  check(res ~= nil and res.ok == false and res.code == "not_found", "B: unknown action -> typed not_found")
  -- The view can still submit afterwards (Chat not locked).
  local ok_sub = pcall(function()
    view:submit("still alive", {})
  end)
  check(ok_sub, "B: Chat remains usable after failed dispatch")
end

-- C. View lifecycle + status integration do not break the wiring.
do
  local host = require("maxa.runtime.host.nvim")
  local view = host._get_default()
  local orig_select = vim.ui.select
  vim.ui.select = function(_, _, cb)
    cb(nil) -- no choice: palette must not raise
  end
  local ok_pal, pal_err = pcall(view.actions_palette, view)
  vim.ui.select = orig_select
  check(ok_pal, "C: View:actions_palette did not raise (" .. tostring(pal_err) .. ")")
end

-- D. Import guard: nothing legacy loaded by this suite.
do
  local guard = require("maxa.runtime.guard")
  local gok, gerr = pcall(guard.assert_no_forbidden)
  check(gok, "D: import-guard clean (" .. tostring(gerr) .. ")")
end

-- E. Lualine auto-mount + real project .maxa/system.md override (C-002).
do
  local ok_lualine, lualine = pcall(require, "lualine")
  if ok_lualine and type(lualine.get_config) == "function" then
    local lc = lualine.get_config()
    local found = false
    for _, c in ipairs((lc.sections and lc.sections.lualine_x) or {}) do
      if type(c) == "table" and c.name == "maxa_status" then
        found = true
      end
    end
    check(found, "E: lualine auto-mounted maxa_status component")
  else
    print("WIRING_SKIP: lualine not loaded in headless; auto-mount skipped")
  end
  -- Real project fallback: composing in this repository root must fall back
  -- to the bundled runtime prompt (C-001) because the mother repository does
  -- not use a .maxa/system.md override (2026-08-06 user decision; the override
  -- feature itself is covered by tests/prompts C-002 fixtures).
  local composer = require("maxa.runtime.prompts")
  local res = composer.compose({ root = "/home/maxzhao/maxa", config = nil })
  check(res ~= nil and res.system_prompt ~= nil, "E: compose over repo root returns prompt")
  if res and res.system_prompt then
    check(
      res.system_prompt:find("Project composition snapshot", 1, true) == nil,
      "E: no .maxa/system.md override in repo root (bundled fallback selected)"
    )
    check(
      res.system_prompt:find("maxa runtime system contract", 1, true) ~= nil,
      "E: bundled runtime prompt fallback selected"
    )
    check(
      res.system_prompt:find("The active project root is `/home/maxzhao/maxa`", 1, true) ~= nil,
      "E: <root_dir> expanded deterministically in bundled fallback"
    )
  end
end

if not ok_all then
  error(("WIRING_FAILED (%d failures)"):format(#failures), 0)
end
print("PHASE5_WIRING_OK")
return true
