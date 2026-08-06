-- filepath: tests/history/scratch.lua
--- history/scratch: unsavable 边界（含 `/` 永不落盘）、无 index 条目、显式
--- save({promote=...}) 转正生成正规 save_id；auto_save 接线跳过 unsavable、
--- 常规会话事件触发保存。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 2000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

local function make_snapshot(session_id, gen)
  return {
    session_id = session_id,
    project_id = "proj-1",
    generation = gen or 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = nil,
    messages = { { role = "user", content = { { type = "text", text = "scratch content" } } } },
    context_items = {},
    usage = {},
    status_snapshot = {},
    trace = { id = nil, membership = {} },
  }
end

fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root, clock = now })

  -- scratch 返回 unsavable save_id。
  local s = service:scratch({ session_id = "sess-scratch" })
  ctx.check(s.unsavable == true, "scratch returns unsavable=true")
  ctx.check(type(s.save_id) == "string", "scratch save_id present")
  ctx.check(history.ids.is_unsavable_save_id(s.save_id), "scratch save_id is unsavable")
  ctx.check(s.save_id:match("_cc_history_unsavable_scratch/") ~= nil, "scratch kind prefix")

  -- 不写文件、不建 index。
  local files = vim.fn.glob(proj.history_dir .. "/chats/*.json", false, true)
  ctx.check(#files == 0, "no chat files written by scratch")
  ctx.check(vim.tbl_isempty(service:list()), "no index entries after scratch")

  -- current_save_id 返回 unsavable（auto_save 依赖此判定）。
  ctx.assert_eq(service:current_save_id("sess-scratch"), s.save_id, "current_save_id returns unsavable")

  -- promote 转正：save(snapshot, {promote=unsavable_id}) -> 新正规 save_id + index 条目。
  local p = service:save(make_snapshot("sess-scratch", 1), { promote = s.save_id })
  ctx.check(p.ok == true, "promote save ok")
  ctx.assert_eq(p.status, "saved", "promote status saved")
  ctx.check(p.save_id ~= s.save_id, "promoted save_id differs from unsavable")
  ctx.check(not history.ids.is_unsavable_save_id(p.save_id), "promoted save_id is regular")
  ctx.assert_eq(service:current_save_id("sess-scratch"), p.save_id, "binding promoted to regular save_id")
  ctx.check(vim.fn.filereadable(proj.history_dir .. "/chats/" .. p.save_id .. ".json") == 1, "promoted file exists")
  ctx.check(service:list()[p.save_id] ~= nil, "index entry after promote")
  ctx.check(vim.fn.filereadable(proj.history_dir .. "/chats/" .. s.save_id .. ".json") == 0, "no unsavable file written")

  -- promote mismatch：非绑定 id 拒绝。
  local bad = service:save(make_snapshot("sess-scratch", 2), { promote = "_cc_history_unsavable_scratch/bogus" })
  ctx.check(bad.ok == false, "promote mismatch rejected")
  ctx.assert_eq(bad.code, "promote_mismatch", "promote mismatch code")

  -- auto_save：unsavable 会话跳过（save_fn 不被调用）。
  do
    local called = false
    local svc = history.new({
      root = proj.root,
      clock = now,
      config = { auto_save = true },
      save_fn = function()
        called = true
        return nil
      end,
    })
    svc:scratch({ session_id = "sess-auto-skip" })
    svc:listen()
    svc.events.emit("chat.closed", { session_id = "sess-auto-skip", generation = 1 })
    ctx.check(called == false, "auto_save skips unsavable sessions (provider not called)")
    ctx.check(history.ids.is_unsavable_save_id(svc:current_save_id("sess-auto-skip")), "unsavable binding kept")
    svc:dispose()
  end

  -- auto_save：常规会话在既有事件上保存并绑定 save_id。
  do
    local captured
    local svc = history.new({
      root = proj.root,
      clock = now,
      config = { auto_save = true },
      save_fn = function(sid, payload)
        captured = payload
        return make_snapshot(sid, payload and payload.generation or 1)
      end,
    })
    svc:listen()
    svc.events.emit("tool_batch.finished", { session_id = "sess-auto-ok", generation = 7 })
    ctx.check(captured ~= nil, "auto_save provider called with payload")
    local bound = svc:current_save_id("sess-auto-ok")
    ctx.check(bound ~= nil, "auto_save bound save_id")
    if bound then
      ctx.check(not history.ids.is_unsavable_save_id(bound), "auto_save save_id regular")
      local env, _ = svc:open(bound)
      ctx.check(env ~= nil, "auto_save chat persisted")
      if env then
        ctx.assert_eq(env.runtime_state.generation, 7, "auto_save generation from payload")
      end
    end
    svc:dispose()
  end
end)

if not ctx.ok then
  error("scratch failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: scratch")
