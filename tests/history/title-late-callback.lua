-- filepath: tests/history/title-late-callback.lua
--- history/title-late-callback: auto 模式标题生成（fake provider 确定性文本）、
--- 刷新策略（refresh_every_n_prompts=2, max_refreshes=3：2/4/6 刷新、8 停止）、
--- 迟到回调 generation 守卫（expect 不匹配 -> 不应用不持久化）、format_title hook、
--- first_user/none 模式、生成失败回退 first_user。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 5000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

-- fake provider：确定性文本；可切换 delayed（异步）模式与 fail（错误）模式。
local provider = {
  text = "AI 标题",
  delayed = false,
  fail = false,
  pending_cb = nil,
  last_prompt = nil,
}
provider.request = function(prompt, cb)
  provider.last_prompt = prompt
  if provider.delayed then
    provider.pending_cb = cb
    return
  end
  if provider.fail then
    cb(nil, "provider exploded")
    return
  end
  cb(provider.text, nil)
end
local provider_resolver = function()
  return provider
end

local function user_msg(text)
  return { role = "user", content = { { type = "text", text = text } } }
end
local function asst_msg(text)
  return { role = "assistant", content = { { type = "text", text = text } } }
end

local function snap(msgs, extra)
  local s = {
    session_id = "sess-title",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = nil,
    messages = msgs,
    context_items = {},
    usage = {},
    status_snapshot = {},
    trace = { id = nil, membership = {} },
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function make_service(proj, config)
  return history.new({ root = proj.root, clock = now, provider_resolver = provider_resolver, config = config })
end

fixture_project.with_project(function(proj)
  -- 1) auto 生成 + format_title hook + 持久化（同步 provider，expect 匹配）。
  do
    local format_calls = 0
    local service = make_service(proj, {
      auto_save = false,
      title_provider = "auto",
      title_generation_opts = {
        refresh_every_n_prompts = 0,
        max_refreshes = 3,
        format_title = function(t)
          format_calls = format_calls + 1
          return "[" .. t .. "]"
        end,
      },
    })
    provider.delayed = false
    provider.fail = false
    provider.text = "AI 标题"
    local r = service:title(snap({ user_msg("first question") }), { expect = { session_id = "sess-title", generation = 1 } })
    ctx.check(r.ok == true and r.applied == true, "auto title applied")
    ctx.assert_eq(r.title, "[AI 标题]", "format_title hook applied")
    ctx.assert_eq(format_calls, 1, "format_title called once")
    ctx.check(provider.last_prompt:match("根据以下用户消息") ~= nil, "initial prompt is Chinese")
    local env, _ = service:open(r.save_id)
    ctx.check(env ~= nil, "titled chat readable")
    if env then
      ctx.assert_eq(env.title, "[AI 标题]", "title persisted")
      ctx.assert_eq(env.runtime_state.title_refresh_count or 0, 0, "initial no refresh count")
    end
  end

  -- 2) 刷新策略：refresh_every_n_prompts=2, max_refreshes=3 -> 2/4/6 刷新、8 停止。
  do
    local service = make_service(proj, {
      auto_save = false,
      title_provider = "auto",
      title_generation_opts = { refresh_every_n_prompts = 2, max_refreshes = 3, format_title = nil },
    })
    provider.text = "刷新标题"
    local base = service:title(snap({ user_msg("q1"), asst_msg("a1"), user_msg("q2") }), {
      expect = { session_id = "sess-title", generation = 1 },
    })
    ctx.check(base.ok == true and base.applied == true, "initial title generated")
    ctx.check(base.is_refresh == false, "initial is not refresh")
    local env1, _ = service:open(base.save_id)
    ctx.check(env1 ~= nil, "env1 readable")
    if env1 then
      ctx.assert_eq(env1.runtime_state.title_refresh_count or 0, 0, "no refresh count after initial")
    end

    local function refresh_with(count, prev)
      local msgs = {}
      for i = 1, count do
        msgs[#msgs + 1] = user_msg("q" .. i)
        msgs[#msgs + 1] = asst_msg("a" .. i)
      end
      return service:title(
        snap(msgs, { title = prev.title, runtime_state = { title_refresh_count = prev.runtime_state.title_refresh_count or 0 } }),
        { expect = { session_id = "sess-title", generation = 1 } }
      )
    end

    local ref1 = refresh_with(2, env1)
    ctx.check(ref1.ok == true and ref1.applied == true, "refresh @2 applied")
    ctx.check(ref1.is_refresh == true, "refresh @2 is refresh")
    ctx.check(provider.last_prompt:match("evolved") ~= nil, "refresh prompt is English")
    local env2, _ = service:open(ref1.save_id)
    ctx.check(env2 ~= nil, "env2 readable")
    if env2 then
      ctx.assert_eq(env2.runtime_state.title_refresh_count, 1, "refresh count 1")
    end

    local ref2 = refresh_with(4, env2)
    ctx.check(ref2.ok == true and ref2.applied == true, "refresh @4 applied")
    local env3, _ = service:open(ref2.save_id)
    ctx.check(env3 ~= nil, "env3 readable")
    if env3 then
      ctx.assert_eq(env3.runtime_state.title_refresh_count, 2, "refresh count 2")
    end

    local ref3 = refresh_with(6, env3)
    ctx.check(ref3.ok == true and ref3.applied == true, "refresh @6 applied")
    local env4, _ = service:open(ref3.save_id)
    ctx.check(env4 ~= nil, "env4 readable")
    if env4 then
      ctx.assert_eq(env4.runtime_state.title_refresh_count, 3, "refresh count 3 (max)")
    end

    local ref4 = refresh_with(8, env4)
    ctx.check(ref4.ok == true and ref4.skipped == true, "refresh stops at max (skipped)")
    ctx.assert_eq(ref4.title, env4.title, "skipped keeps current title")
  end

  -- 3) 迟到回调守卫：expect 表在回调前被更新（会话前进）-> 拒绝应用/持久化。
  do
    local service = make_service(proj, {
      auto_save = false,
      title_provider = "auto",
      title_generation_opts = { refresh_every_n_prompts = 0, max_refreshes = 3, format_title = nil },
    })
    provider.delayed = true
    local expect = { session_id = "sess-title", generation = 1 }
    local index_before = vim.tbl_count(service:list())
    local pr = service:title(snap({ user_msg("late question") }), { expect = expect })
    ctx.check(pr.ok == true and pr.pending == true, "async title pending")
    ctx.check(provider.pending_cb ~= nil, "provider callback stored")
    -- 会话前进：调用方将 expect 更新为当前状态（generation=2）。
    expect.generation = 2
    provider.pending_cb("迟到标题", nil)
    provider.pending_cb = nil
    ctx.check(service:current_save_id("sess-title") == nil, "no binding after refused apply")
    ctx.assert_eq(vim.tbl_count(service:list()), index_before, "no index entries after refused apply")
  end

  -- 4) 迟到但匹配：expect 未变 -> 回调到达后应用并持久化。
  do
    local service = make_service(proj, {
      auto_save = false,
      title_provider = "auto",
      title_generation_opts = { refresh_every_n_prompts = 0, max_refreshes = 3, format_title = nil },
    })
    provider.delayed = true
    local pr = service:title(snap({ user_msg("delayed question") }), { expect = { session_id = "sess-title", generation = 1 } })
    ctx.check(pr.ok == true and pr.pending == true, "matching async title pending")
    provider.pending_cb("迟到但匹配", nil)
    provider.pending_cb = nil
    local bound = service:current_save_id("sess-title")
    ctx.check(bound ~= nil, "matching callback bound save_id")
    local env, _ = service:open(bound)
    ctx.check(env ~= nil, "matching callback applied")
    if env then
      ctx.assert_eq(env.title, "迟到但匹配", "matching late callback title persisted")
    end
  end

  -- 5) first_user / none 模式。
  do
    local svc_none = make_service(proj, { auto_save = false, title_provider = "none" })
    local rn = svc_none:title(snap({ user_msg("x") }, { title = "Keep Me" }))
    ctx.check(rn.ok == true, "none provider ok")
    ctx.assert_eq(rn.title, "Keep Me", "none provider no-op keeps title")

    local svc_fu = make_service(proj, { auto_save = false, title_provider = "first_user" })
    local rf = svc_fu:title(snap({ user_msg("my first question") }))
    ctx.check(rf.ok == true, "first_user provider ok")
    ctx.assert_eq(rf.title, "my first question", "first_user uses first user message")
  end

  -- 6) 生成失败回退 first_user。
  do
    local service = make_service(proj, {
      auto_save = false,
      title_provider = "auto",
      title_generation_opts = { refresh_every_n_prompts = 0, max_refreshes = 3, format_title = nil },
    })
    provider.delayed = false
    provider.fail = true
    local rb = service:title(snap({ user_msg("fallback question") }))
    ctx.check(rb.ok == true, "failed generation still ok")
    ctx.check(rb.fallback == "first_user", "fallback to first_user")
    ctx.assert_eq(rb.title, "fallback question", "fallback title = first user message")
    provider.fail = false
  end
end)

if not ctx.ok then
  error("title-late-callback failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: title-late-callback")
