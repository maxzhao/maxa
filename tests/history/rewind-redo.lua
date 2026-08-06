-- filepath: tests/history/rewind-redo.lua
--- history/rewind-redo (H-003 数据侧): rewind 截断到最后一条 manual user 消息
--- （丢弃计数正确、保留消息原样）、generation+1 保存；redo 由 snapshot.messages
--- 重建 stack 返回；redo 服务级幂等（重复调用结果一致、无重复状态）。
--- 真实 redo 提交（恰一次，kind=restore）在 W4 集成层验证。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local conversation = require("maxa.runtime.conversation")

local ctx = assert_mod.new()

local clock = { t = 4000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root, clock = now })

  -- 规范化消息栈：q1/a1/q2/a2。
  local stack = conversation.new_stack()
  stack:add_message({ role = "user", content = { { type = "text", text = "q1" } } })
  stack:add_message({ role = "assistant", content = { { type = "text", text = "a1" } } })
  stack:add_message({ role = "user", content = { { type = "text", text = "q2" } } })
  stack:add_message({ role = "assistant", content = { { type = "text", text = "a2" } } })

  local function snap(gen, msgs)
    return {
      session_id = "sess-rewind",
      project_id = "proj-1",
      generation = gen,
      provider_id = "mock",
      protocol = "mock",
      model = "mock-model",
      title = nil,
      messages = msgs or stack:to_table(),
      context_items = {},
      usage = { total_tokens = 99 },
      status_snapshot = { state = "waiting_for_user" },
      trace = { id = nil, membership = {} },
    }
  end

  -- 基线保存（gen 3，绑定 save_id）。
  local saved = service:save(snap(3))
  ctx.check(saved.ok == true, "baseline save ok")

  -- rewind：截断 a2（最后 manual user = q2 保留）。
  local rw = service:rewind(snap(3))
  ctx.check(rw.ok == true, "rewind ok")
  ctx.assert_eq(rw.truncated_count, 1, "rewind dropped 1 message")
  ctx.assert_eq(rw.save_id, saved.save_id, "rewind keeps same save_id")
  ctx.assert_eq(rw.status, "saved", "rewind status saved")

  local bundle, berr = service:open(rw.save_id)
  ctx.check(bundle ~= nil and berr == nil, "rewound bundle readable")
  if bundle then
    ctx.assert_eq(bundle.runtime_state.generation, 4, "rewind saves with generation+1")
    ctx.assert_eq(#bundle.messages, 3, "rewind retained 3 messages")
    ctx.assert_eq(bundle.messages[1].content[1].text, "q1", "retained message 1")
    ctx.assert_eq(bundle.messages[2].content[1].text, "a1", "retained message 2")
    ctx.assert_eq(bundle.messages[3].content[1].text, "q2", "last manual user preserved")
  end

  -- 二次 rewind：栈已以 user 结尾 -> 丢弃 0。
  local rw2 = service:rewind(snap(4, bundle and bundle.messages or nil))
  ctx.check(rw2.ok == true, "second rewind ok")
  ctx.assert_eq(rw2.truncated_count, 0, "second rewind drops 0 messages")

  -- redo：由 snapshot.messages 重建 stack（数据侧）。
  local rd = service:redo(snap(3))
  ctx.check(rd.ok == true, "redo ok")
  ctx.check(rd.submitted == true, "redo submitted marker")
  ctx.assert_eq(#rd.messages, 4, "redo rebuilt 4 messages")
  ctx.assert_eq(rd.messages[1].content[1].text, "q1", "redo message order (1)")
  ctx.assert_eq(rd.messages[4].content[1].text, "a2", "redo message order (4)")

  -- 幂等：重复调用返回相同结果、无重复持久化状态。
  local rd2 = service:redo(snap(3))
  ctx.check(rd2.ok == true and rd2.submitted == true, "redo repeat ok")
  ctx.assert_eq(rd2.save_id, rd.save_id, "redo idempotent save_id")
  ctx.assert_same_table(rd2.messages, rd.messages, "redo idempotent messages")
  local idx = service:list()
  local count = 0
  for _ in pairs(idx) do
    count = count + 1
  end
  ctx.assert_eq(count, 1, "no duplicate durable state after repeated redo")

  -- 无效快照拒绝。
  local bad = service:redo({ session_id = "sess-rewind", project_id = "p", generation = 1, messages = "nope" })
  ctx.check(bad.ok == false and bad.code == "invalid_snapshot", "redo rejects invalid snapshot")
end)

if not ctx.ok then
  error("rewind-redo failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: rewind-redo")
