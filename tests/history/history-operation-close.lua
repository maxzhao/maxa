-- filepath: tests/history/history-operation-close.lua
--- async/history-operation-close（服务级）: late save / late title callback cannot
--- resurrect or overwrite a superseded session generation.
---   * 迟到 save（stale generation）被 storage generation guard 拒绝
---     （generation_conflict），durable 内容不变；
---   * 迟到 title 回调（expect {session_id, generation} 不匹配——会话已前进）
---     不应用、不持久化（title 保持旧值；无 index 条目、无绑定）；
---   * dispose() 后 listen() 注册的 auto-save handler 不再触发
---     （无 auto-save 副作用）。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()

local clock = { t = 8000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

local function user_msg(text)
  return { role = "user", content = { { type = "text", text = text } } }
end

local function snap(msgs, generation)
  return {
    session_id = "sess-close",
    project_id = "proj-1",
    generation = generation or 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = nil,
    messages = msgs,
    context_items = {},
    runtime_state = { generation = generation or 1 },
    status_snapshot = {},
    trace = { id = nil, membership = {} },
  }
end

fixture_project.with_project(function(proj)
  -- 1) 迟到 save 不能覆盖 superseded generation（storage generation guard）。
  do
    local service = history.new({ root = proj.root, clock = now })
    local r1 = service:save(snap({ user_msg("g1") }, 1))
    ctx.check(r1.ok == true, "gen1 save ok")
    local sid = r1.save_id
    local r2 = service:save(snap({ user_msg("g2") }, 2))
    ctx.check(r2.ok == true, "gen2 save ok")
    ctx.assert_eq(r2.save_id, sid, "gen2 same save_id")

    local rs = service:save(snap({ user_msg("stale late") }, 1))
    ctx.check(rs.ok == false and rs.code == "generation_conflict", "stale generation rejected (generation_conflict)")
    local env = service.storage:load_chat(sid)
    ctx.check(env ~= nil, "durable chat readable")
    if env then
      ctx.assert_eq(env.runtime_state.generation, 2, "durable generation unchanged")
      ctx.assert_eq(#env.messages, 1, "durable message count unchanged")
      ctx.assert_eq(env.messages[1].content[1].text, "g2", "durable content unchanged")
    end
  end

  -- 2) 迟到 title 回调（expect 不匹配 session+generation）不应用、不持久化。
  do
    local provider = { delayed = true, pending_cb = nil }
    provider.request = function(prompt, cb)
      provider.pending_cb = cb
    end
    local service = history.new({
      root = proj.root,
      clock = now,
      events = events.new(),
      provider_resolver = function()
        return provider
      end,
    })
    local expect = { session_id = "sess-close", generation = 1 }
    local index_before = vim.tbl_count(service:list())
    local pr = service:title(snap({ user_msg("late title q") }, 1), { expect = expect })
    ctx.check(pr.ok == true and pr.pending == true, "async title pending")
    ctx.check(provider.pending_cb ~= nil, "provider callback stored")
    expect.generation = 2 -- 会话前进（superseded）
    provider.pending_cb("迟到标题", nil)
    provider.pending_cb = nil
    ctx.check(service:current_save_id("sess-close") == nil, "no binding after refused title apply")
    ctx.assert_eq(vim.tbl_count(service:list()), index_before, "no index entries after refused title apply")
  end

  -- 3) dispose() 后 listen() handler 不再触发（无 auto-save 副作用）。
  -- 同一 fixture 项目根已有 block(1) 的 1 个 index 条目，故用增量断言。
  do
    local bus = events.new()
    local service = history.new({
      root = proj.root,
      clock = now,
      events = bus,
      save_fn = function(session_id)
        return snap({ user_msg("auto " .. tostring(session_id)) }, 1)
      end,
    })
    local index_before = vim.tbl_count(service:list())
    service:listen()
    ctx.check(service._listening == true, "listening after listen()")
    bus.emit("response.completed", { session_id = "sess-close" })
    ctx.assert_eq(vim.tbl_count(service:list()), index_before + 1, "auto-save wrote once")
    service:dispose()
    ctx.check(service._listening == false, "not listening after dispose()")
    ctx.check(bus.count("response.completed") == 0, "listeners removed after dispose()")
    bus.emit("response.completed", { session_id = "sess-close" })
    ctx.assert_eq(vim.tbl_count(service:list()), index_before + 1, "no auto-save side effects after dispose()")
  end
end)

if not ctx.ok then
  error("history-operation-close failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: history-operation-close")
