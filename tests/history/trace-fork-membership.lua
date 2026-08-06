-- filepath: tests/history/trace-fork-membership.lua
--- history/trace-fork-membership: fork 复制 trace membership 语义（W3）。
--- 父/子共享 root_trace_id；子 span 不同（copy_membership new_span）；
--- 子 parent_span_id = 源 span；子保存后信封持久化 trace.membership；
--- 子会话独立可变。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 3000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root, clock = now })
  local trace = history.trace

  local function text_message(role, text)
    return { role = role, content = { { type = "text", text = text } } }
  end

  local snapshot = {
    session_id = "sess-fork-trace",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "fork trace",
    messages = { text_message("user", "fork me"), text_message("assistant", "done") },
    context_items = {},
    status_snapshot = {},
    trace = {
      id = "trace-fork-root",
      membership = {
        root_trace_id = "trace-fork-root",
        root_save_id = "trace-fork-root",
        span_id = "span-parent",
        parent_span_id = nil,
        session_role = "primary",
        started_at = 100,
        active = true,
      },
    },
  }

  -- 父保存：信封持久化 trace.membership。
  local parent = service:save(snapshot)
  ctx.check(parent.ok == true, "parent save ok")
  if parent.ok then
    local penv, _ = service:open(parent.save_id)
    ctx.check(penv ~= nil, "parent readable")
    if penv then
      ctx.assert_eq(penv.trace.id, "trace-fork-root", "parent envelope trace.id")
      ctx.assert_eq(penv.trace.membership.span_id, "span-parent", "parent envelope membership span")
      ctx.assert_eq(penv.trace.membership.root_trace_id, "trace-fork-root", "parent membership root")
    end
  end

  -- fork：membership 复制 + 新 span。
  local f = service:fork(snapshot)
  ctx.check(f.ok == true, "fork ok")
  ctx.check(f.save_id ~= parent.save_id, "fork save_id differs")
  if f.ok then
    local child, cerr = service:open(f.save_id)
    ctx.check(child ~= nil and cerr == nil, "child readable")
    if child then
      ctx.check(child.trace ~= nil, "child trace present")
      if child.trace then
        ctx.assert_eq(child.trace.id, "trace-fork-root", "child trace.id = root")
        local m = child.trace.membership
        ctx.check(type(m) == "table", "child membership present")
        if type(m) == "table" then
          ctx.assert_eq(m.root_trace_id, "trace-fork-root", "child root_trace_id same as parent")
          ctx.assert_eq(m.root_save_id, "trace-fork-root", "child root_save_id same as parent")
          ctx.check(m.span_id ~= "span-parent", "child span_id differs from parent")
          ctx.check(type(m.span_id) == "string" and m.span_id ~= "", "child span_id non-empty")
          ctx.assert_eq(m.parent_span_id, "span-parent", "child parent_span_id = source span")
          ctx.assert_eq(m.session_role, "primary", "child session_role inherited")
          ctx.check(m.active ~= false, "child membership active")
        end
      end
    end
    -- 子信封文件本身已持久化 membership（fork 即保存）。
    local child2, cerr2 = service:open(f.save_id)
    ctx.check(child2 ~= nil and cerr2 == nil, "child reopen ok")
    if child2 and child2.trace then
      ctx.assert_eq(child2.trace.membership.root_trace_id, "trace-fork-root", "child persisted membership root")
      ctx.assert_eq(child2.trace.membership.parent_span_id, "span-parent", "child persisted parent_span_id")
    end
  end

  -- 子独立可变：父再次保存不影响子 membership。
  local parent2 = service:save(snapshot)
  ctx.check(parent2.ok == true, "parent re-save ok")
  local child3, _ = service:open(f.save_id)
  ctx.check(child3 ~= nil, "child readable after parent re-save")
  if child3 and child3.trace then
    ctx.check(type(child3.trace.membership.span_id) == "string", "child span still present")
    ctx.assert_eq(child3.trace.membership.root_trace_id, "trace-fork-root", "child root stable")
  end

  -- trace 模块级 copy_membership 直接断言（get/set 信封兼容）。
  local source_holder = {
    trace = { id = "trace-fork-root", membership = { root_trace_id = "trace-fork-root", span_id = "span-a", session_role = "primary" } },
  }
  local target_holder = { trace = { id = "trace-fork-root", membership = {} } }
  local copied = trace.copy_membership(source_holder, target_holder, { new_span = true })
  ctx.check(type(copied) == "table", "copy_membership returns membership")
  if type(copied) == "table" then
    ctx.assert_eq(copied.root_trace_id, "trace-fork-root", "copied root_trace_id")
    ctx.check(copied.span_id ~= "span-a", "copied span differs")
    ctx.assert_eq(copied.parent_span_id, "span-a", "copied parent_span_id = source span")
    ctx.assert_eq(target_holder.trace.membership, copied, "set_membership wrote envelope trace.membership")
  end
end)

if not ctx.ok then
  error("trace-fork-membership failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: trace-fork-membership")
