-- filepath: tests/history/auto-save.lua
--- Phase-4 W4-B auto-save wiring (service level):
---   * service:new with a LATER-assigned snapshot_provider field (host wiring
---     contract: the field is read at event time, not construction time);
---   * service:listen() subscribes response.completed / tool_batch.finished /
---     chat.soft_stop_completed / chat.closed;
---   * response.completed {session_id} -> snapshot_provider called -> chat file
---     written + history.saved event on the bus;
---   * chat.closed -> also saved (same save_id binding, one chat file);
---   * unsavable (scratch) binding -> auto-save skipped (provider not called,
---     no new file, no saved event);
---   * dispose() unsubscribes: further emits write nothing.
---
--- Fixture convention: prints HISTORY_OK: auto-save on success; throws.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()

local function chat_files(history_dir)
  return vim.fn.glob(history_dir .. "/chats/*.json", false, true)
end

fixture_project.with_project(function(proj)
  local bus = events.new()
  local saved = {}
  bus.on("history.saved", function(payload)
    saved[#saved + 1] = payload
  end)
  local service = history.new({ root = proj.root, events = bus, config = { auto_save = true } })

  -- Host wiring contract: snapshot_provider is assigned AFTER construction.
  local provider_calls = 0
  service.snapshot_provider = function(session_id, payload)
    provider_calls = provider_calls + 1
    ctx.check(type(session_id) == "string" and session_id ~= "", "auto-save: provider receives session_id")
    ctx.check(type(payload) == "table", "auto-save: provider receives payload")
    return {
      session_id = session_id,
      project_id = "proj-auto",
      generation = 1,
      provider_id = "mock",
      protocol = "mock",
      model = "mock-model",
      title = "auto-save chat",
      messages = { { role = "user", content = { { type = "text", text = "auto" } } } },
      context_items = {},
      runtime_state = { generation = 1 },
    }
  end
  service:listen()

  -- response.completed -> snapshot_provider -> saved.
  bus.emit("response.completed", { session_id = "s1" })
  ctx.assert_eq(provider_calls, 1, "auto-save: provider called once after response.completed")
  ctx.assert_eq(#saved, 1, "auto-save: history.saved emitted once")
  ctx.assert_eq(#chat_files(proj.history_dir), 1, "auto-save: one chat file written")
  if saved[1] then
    ctx.assert_eq(saved[1].session_id, "s1", "auto-save: saved payload session_id")
  end

  -- chat.closed -> also saved (same save_id binding; file count stays 1).
  bus.emit("chat.closed", { session_id = "s1" })
  ctx.assert_eq(provider_calls, 2, "auto-save: provider called again for chat.closed")
  ctx.assert_eq(#saved, 2, "auto-save: history.saved emitted twice")
  ctx.assert_eq(#chat_files(proj.history_dir), 1, "auto-save: same save_id -> one chat file")
  local sid = service:current_save_id("s1")
  ctx.check(type(sid) == "string" and sid ~= "", "auto-save: session bound to a save_id")

  -- Unsavable (scratch) binding -> skipped: provider NOT called, no file, no event.
  service:scratch({ session_id = "s2" })
  local calls_before = provider_calls
  local events_before = #saved
  bus.emit("response.completed", { session_id = "s2" })
  ctx.assert_eq(provider_calls, calls_before, "auto-save: unsavable binding skipped (provider not called)")
  ctx.assert_eq(#saved, events_before, "auto-save: unsavable binding emits no saved event")
  ctx.assert_eq(#chat_files(proj.history_dir), 1, "auto-save: unsavable writes no chat file")

  -- dispose() unsubscribes: further emits write nothing.
  service:dispose()
  local files_before = #chat_files(proj.history_dir)
  bus.emit("response.completed", { session_id = "s1" })
  ctx.assert_eq(#chat_files(proj.history_dir), files_before, "auto-save: dispose unsubscribes (no new write)")
  ctx.assert_eq(provider_calls, calls_before, "auto-save: dispose unsubscribes (provider not called)")
end)

if not ctx.ok then
  error("auto-save failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: auto-save")
