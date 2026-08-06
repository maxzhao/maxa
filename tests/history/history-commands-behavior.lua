-- filepath: tests/history/history-commands-behavior.lua
--- Phase-4 W4-B behavior fixes (headless):
---   * :MaxaHistory restore now OPENS the chat window immediately
---     (restore_chat -> view:open(); previously only _render ran, so the next
---     :MaxaChat surfaced the restored session as if it were new);
---   * :MaxaHistory choosing the ALREADY-ACTIVE saved session is a no-op
---     (returns nil, the current view/session is untouched);
---   * :MaxaChat with history.continue_last unset/false ALWAYS opens a NEW
---     session window (the current default view is closed first — close-save
---     protects committed messages — then a fresh view opens);
---   * :MaxaChat with no default view creates one and opens it.
---
--- Fixture convention: prints HISTORY_OK: history-commands-behavior; throws.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")
local host = require("maxa.runtime.host.nvim")

local ctx = assert_mod.new()

fixture_project.with_project(function(proj)
  local bus = events.new()
  local service = history.new({ root = proj.root, events = bus, config = { auto_save = false } })
  host.set_defaults({
    history = service,
    history_config = { enabled = true, auto_save = false, continue_last = false },
  })

  -- 1. Create session S1 and save it.
  local v1 = host._get_default()
  local ok1 = v1:submit("first", { provider_params = { chunks = { "one" } } })
  ctx.check(ok1.rejected ~= true, "behavior: first turn accepted")
  vim.cmd("MaxaSave s1")
  local bound1 = service:current_save_id(v1.orch.session.id)
  ctx.check(bound1 == "s1", "behavior: session v1 bound to s1")

  -- 2. restore_chat(s1) while v1 IS s1 -> no-op (nil, view untouched).
  local res_noop = host.restore_chat("s1")
  ctx.check(res_noop == nil, "behavior: restoring the active session is a no-op")
  ctx.check(host._default == v1 and not v1:_is_closed_view(), "behavior: no-op leaves the active view open")
  ctx.check(service:current_save_id(v1.orch.session.id) == "s1", "behavior: no-op keeps the binding")

  -- 3. Create session S2 (replace default view), save it.
  v1:close()
  host._default = nil
  local v2 = host._get_default()
  local ok2 = v2:submit("second", { provider_params = { chunks = { "two" } } })
  ctx.check(ok2.rejected ~= true, "behavior: second turn accepted")
  vim.cmd("MaxaSave s2")
  ctx.check(service:current_save_id(v2.orch.session.id) == "s2", "behavior: session v2 bound to s2")

  -- 4. restore_chat(s1) while v2 is s2 -> s1 restored AND the window is OPEN.
  local v3 = host.restore_chat("s1")
  ctx.check(v3 ~= nil, "behavior: restore returns the restored view")
  ctx.check(v3._opened == true, "behavior: restored view window is opened")
  ctx.check(v2:_is_closed_view(), "behavior: previous view closed by restore")
  ctx.check(service:current_save_id(v3.orch.session.id) == "s1", "behavior: restored view rebound to s1")
  local bundle3 = service:open("s1")
  ctx.check(
    bundle3 ~= nil and #(bundle3.messages or {}) >= 2,
    "behavior: restored s1 messages persisted (user + assistant)"
  )

  -- 5. :MaxaChat (continue_last=false) while v3 (s1) is open -> NEW session window.
  local old_id = v3.orch.session.id
  local v4 = host.open()
  ctx.check(v4 ~= nil and v4 ~= v3, "behavior: :MaxaChat returns a fresh view")
  ctx.check(v4._opened == true, "behavior: :MaxaChat new view window is opened")
  ctx.check(v3:_is_closed_view(), "behavior: :MaxaChat closed the previous view (close-save path)")
  ctx.check(v4.orch.session.id ~= old_id, "behavior: :MaxaChat created a NEW session (not the history one)")
  ctx.check(service:current_save_id(v4.orch.session.id) == nil, "behavior: fresh session is unbound (untracked)")

  -- 6. :MaxaChat with NO default view -> creates one and opens it.
  v4:close()
  host._default = nil
  local v5 = host.open()
  ctx.check(v5 ~= nil and v5._opened == true, "behavior: :MaxaChat with no view creates + opens one")
  ctx.check(service:current_save_id(v5.orch.session.id) == nil, "behavior: reopened fresh session unbound")

  -- Cleanup: reset injected service (host reset is direct; see host-commands.lua).
  v5:close()
  host._default = nil
  host._history = nil
  host._history_config = nil
  host._history_listening = false
  service:dispose()
end)

if not ctx.ok then
  error("history-commands-behavior failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: history-commands-behavior")
