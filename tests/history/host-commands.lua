-- filepath: tests/history/host-commands.lua
--- Phase-4 W4-B host command wiring (headless):
---   * :MaxaHistory and :MaxaSave exist (vim.fn.exists == 2);
---   * with history disabled (no service injected): :MaxaSave notifies
---     "history disabled" — no crash, no view required;
---   * with a fixture project + a history service injected via
---     set_defaults({ history = ..., history_config = ... }):
---       - :MaxaSave with NO default view -> graceful notify, no crash;
---       - after a manual turn, :MaxaSave writes a chat file and emits
---         history.saved on the service bus;
---       - an explicit save_id is honored while the session is UNBOUND; once
---         bound, the session keeps its stable save_id (service contract:
---         bound wins over opts.save_id);
---       - View:close() with auto_save=false performs no extra close-save.
---
--- Fixture convention: prints HISTORY_OK: host-commands on success; throws.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")
local host = require("maxa.runtime.host.nvim")

local ctx = assert_mod.new()

local function chat_files(history_dir)
  return vim.fn.glob(history_dir .. "/chats/*.json", false, true)
end

-- 1. Commands exist whenever the host module is loaded.
ctx.assert_eq(vim.fn.exists(":MaxaHistory"), 2, "host-commands: :MaxaHistory registered")
ctx.assert_eq(vim.fn.exists(":MaxaSave"), 2, "host-commands: :MaxaSave registered")

-- 2. History disabled (no service): :MaxaSave notifies, never crashes, and no
-- history state exists on the host.
ctx.check(host._history == nil, "host-commands: host history nil when disabled")
pcall(vim.cmd, "MaxaSave") -- must not error (notify WARN path)

-- 3. History enabled via set_defaults (the maxa.setup wiring contract).
fixture_project.with_project(function(proj)
  local bus = events.new()
  local saved = {}
  bus.on("history.saved", function(payload)
    saved[#saved + 1] = payload
  end)
  -- auto_save=false: keep the fixture deterministic (only :MaxaSave writes).
  local service = history.new({ root = proj.root, events = bus, config = { auto_save = false } })
  host.set_defaults({ history = service, history_config = { enabled = true, auto_save = false, continue_last = false } })
  ctx.check(host._history == service, "host-commands: set_defaults stores the service")

  -- 3a. :MaxaSave with no default view -> graceful (notify), no crash, no file.
  host._default = nil
  pcall(vim.cmd, "MaxaSave")
  ctx.assert_eq(#chat_files(proj.history_dir), 0, "host-commands: no view -> no file written")

  -- 3b. Manual turn then :MaxaSave -> a chat file + history.saved + binding.
  local v = host._get_default()
  ctx.check(v ~= nil, "host-commands: default view created")
  local submit = v:submit("hello", { provider_params = { chunks = { "hi" } } })
  ctx.check(submit.rejected ~= true, "host-commands: manual turn accepted")
  vim.cmd("MaxaSave")
  ctx.assert_eq(#chat_files(proj.history_dir), 1, "host-commands: :MaxaSave wrote one chat file")
  ctx.assert_eq(#saved, 1, "host-commands: history.saved emitted")
  if saved[1] then
    ctx.assert_eq(saved[1].session_id, v.orch.session.id, "host-commands: saved payload session_id")
  end
  ctx.check(
    service:current_save_id(v.orch.session.id) == (saved[1] and saved[1].save_id or nil),
    "host-commands: session bound to save_id"
  )

  -- 3c. Explicit save_id is honored while the session is UNBOUND (fresh view);
  -- once bound, the session keeps its stable save_id (bound wins over opts).
  v:close()
  host._default = nil
  local v2 = host._get_default()
  local submit2 = v2:submit("second", { provider_params = { chunks = { "yo" } } })
  ctx.check(submit2.rejected ~= true, "host-commands: fresh view turn accepted")
  vim.cmd("MaxaSave custom-2")
  ctx.assert_eq(#chat_files(proj.history_dir), 2, "host-commands: explicit save_id writes a second chat")
  local custom = service:open("custom-2")
  ctx.check(custom ~= nil and custom.save_id == "custom-2", "host-commands: explicit save_id stored")
  vim.cmd("MaxaSave custom-ignored")
  ctx.assert_eq(#chat_files(proj.history_dir), 2, "host-commands: bound session keeps its stable save_id")

  -- 3d. View:close() with auto_save=false performs no extra close-save.
  v2:close()
  ctx.assert_eq(#chat_files(proj.history_dir), 2, "host-commands: close-save honors auto_save=false")

   -- Cleanup: reset the injected service so later state is inert. NOTE: Lua
   -- table literals with nil values do not create keys, so `set_defaults({history =
   -- nil})` is indistinguishable from an absent key — the host reset is done
   -- directly (test-only; production maxa.setup simply omits the key when
   -- history is disabled, which leaves the boot-time nil untouched).
   host._history = nil
   host._history_config = nil
   host._history_listening = false
   ctx.check(host._history == nil, "host-commands: host history reset")
   service:dispose()
 end)

if not ctx.ok then
  error("host-commands failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: host-commands")
