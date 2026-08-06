-- filepath: tests/history/restart-recovery.lua
--- history/restart-recovery (service level): restore_bundle returns the FULL
--- recovery bundle a host needs after a restart.
---   * runtime_state verbatim（loop.decisions / generation / usage /
---     title_refresh_count / compact_protected_prefix_count / opaque 透传字段）；
---   * messages round-trip identical（stack_from_table -> to_table）；
---   * trace {id, membership} 保留（恢复后 host 可续写同一 trace）；
---   * status_snapshot / context_items / provider/model/title/身份字段保留；
---   * open() 向后兼容：与 restore_bundle 同形状；
---   * history.restored 事件发出一次；缺失会话 typed not_found。
--- 说明：本层为服务级恢复束；view 缺席/MCP 不可用在此处不相关
--- （host wave 接线时保证），孤儿 tool 修复由 orchestrator restore_agent_loop
--- 复用（阶段 0 已实现，不在本 fixture 断言范围）。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")
local conv = require("maxa.runtime.conversation")

local ctx = assert_mod.new()

local clock = { t = 7000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

fixture_project.with_project(function(proj)
  local bus = events.new()
  local restored_events = {}
  bus.on("history.restored", function(payload)
    restored_events[#restored_events + 1] = payload
  end)
  local service = history.new({ root = proj.root, clock = now, events = bus })

  local stack = conv.new_stack()
  stack:add_message({ role = "user", content = { { type = "text", text = "restart q1" } } })
  stack:add_message({ role = "assistant", content = { { type = "text", text = "restart a1" } } })
  local msgs = stack:to_table()

  local runtime_state = {
    generation = 3,
    cwd = proj.root,
    project_root = proj.root,
    compact_protected_prefix_count = 2,
    title_refresh_count = 1,
    usage = { total_tokens = 456, input_tokens = 200, output_tokens = 256 },
    loop = {
      decisions = {
        { key = "d-1", decision_kind = "continue", request_id = "r1" },
        { key = "d-2", decision_kind = "wait" },
      },
    },
    nested = { opaque = { value = "x" } },
  }
  local membership = {
    root_trace_id = "trace-restart-1",
    root_save_id = "root-save-restart",
    span_id = "span-restart-1",
    session_role = "root",
    started_at = 100,
    active = true,
  }
  local status_snapshot = { state = "waiting_for_user", running = false, terminal = {} }
  local snapshot = {
    session_id = "sess-restart",
    project_id = "proj-1",
    generation = 3,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "restart chat",
    messages = msgs,
    context_items = { { id = "ctx-restart" } },
    runtime_state = runtime_state,
    trace = { id = "trace-restart-1", membership = membership },
    status_snapshot = status_snapshot,
  }
  local sv = service:save(snapshot)
  ctx.check(sv.ok == true, "restart save ok")
  ctx.assert_eq(sv.status, "saved", "restart save status")

  local bundle, berr = service:restore_bundle(sv.save_id)
  ctx.check(bundle ~= nil and berr == nil, "restore_bundle returns bundle")
  if bundle then
    -- runtime_state byte-identical（含 loop.decisions/usage/计数/透传字段）
    ctx.assert_same_table(bundle.runtime_state, runtime_state, "runtime_state verbatim")
    ctx.assert_eq(bundle.runtime_state.generation, 3, "generation preserved")
    ctx.check(bundle.runtime_state.loop ~= nil and #bundle.runtime_state.loop.decisions == 2, "loop.decisions preserved")
    ctx.assert_eq(bundle.runtime_state.compact_protected_prefix_count, 2, "compact_protected_prefix_count preserved")
    ctx.assert_eq(bundle.runtime_state.title_refresh_count, 1, "title_refresh_count preserved")
    ctx.assert_eq(bundle.runtime_state.usage.total_tokens, 456, "usage preserved")
    -- messages round-trip via stack_from_table + to_table（归一恢复）
    local rebuilt = conv.stack_from_table(bundle.messages)
    ctx.assert_same_table(rebuilt:to_table(), msgs, "messages round-trip identical")
    -- trace membership 保留
    ctx.assert_eq(bundle.trace.id, "trace-restart-1", "trace id preserved")
    ctx.assert_same_table(bundle.trace.membership, membership, "trace membership preserved")
    -- 其余恢复束字段
    ctx.assert_same_table(bundle.status_snapshot, status_snapshot, "status_snapshot preserved")
    ctx.assert_eq(bundle.context_items[1].id, "ctx-restart", "context_items preserved")
    ctx.assert_eq(bundle.session_id, "sess-restart", "session_id preserved")
    ctx.assert_eq(bundle.project_id, "proj-1", "project_id preserved")
    ctx.assert_eq(bundle.parent_session_id, nil, "parent_session_id nil")
    ctx.assert_eq(bundle.title, "restart chat", "title preserved")
    ctx.assert_eq(bundle.provider_id, "mock", "provider_id preserved")
    ctx.assert_eq(bundle.protocol, "mock", "protocol preserved")
    ctx.assert_eq(bundle.model, "mock-model", "model preserved")
  end

  -- open() 向后兼容：与 restore_bundle 同形状（W2 既有调用面不变）。
  local ob = service:open(sv.save_id)
  ctx.check(ob ~= nil, "open backward compat returns bundle")
  if ob then
    ctx.assert_same_table(ob, bundle, "open() equals restore_bundle()")
  end

  -- history.restored 事件：restore_bundle 与 open()（委托 restore_bundle）各发出一次。
  ctx.check(#restored_events == 2, "history.restored emitted for restore_bundle + open (got " .. tostring(#restored_events) .. ")")
  if restored_events[1] then
    ctx.assert_eq(restored_events[1].save_id, sv.save_id, "restored payload save_id")
    ctx.assert_eq(restored_events[1].session_id, "sess-restart", "restored payload session_id")
  end

  -- 缺失会话：typed not_found（restore 路径与 open 路径一致）。
  local missing, merr = service:restore_bundle("20260101_000000_001_000001_absent")
  ctx.check(missing == nil, "restore_bundle missing returns nil")
  ctx.check(merr ~= nil and merr.cause and merr.cause.history_code == "not_found", "restore_bundle missing typed not_found")
end)

if not ctx.ok then
  error("restart-recovery failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: restart-recovery")
