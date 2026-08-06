-- filepath: tests/history/fork.lua
--- history/fork (H-002): fork 创建新 save_id + parent_session_id；messages/
--- context_items/provider/model 复制；generation 重置 0；trace membership 复制
--- 但生成新 span（W3 语义：root_trace_id 共享、span_id 不同、parent_span_id 指向
--- 源 span）；子会话独立——父再次保存不影响子文件。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 1000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root, clock = now })

  local function text_message(role, text)
    return { role = role, content = { { type = "text", text = text } } }
  end

  local function snapshot(gen, extra)
    local s = {
      session_id = "sess-fork",
      project_id = "proj-1",
      generation = gen,
      provider_id = "mock",
      protocol = "mock",
      model = "mock-model",
      title = nil,
      messages = { text_message("user", "fork question"), text_message("assistant", "fork answer") },
      context_items = { { id = "ctx-1" } },
      usage = { prompt_tokens = 10 },
      status_snapshot = { state = "waiting_for_user" },
      trace = {
        id = "trace-1",
        membership = { root_trace_id = "trace-1", span_id = "span-1", session_role = "primary" },
      },
    }
    for k, v in pairs(extra or {}) do
      s[k] = v
    end
    return s
  end

  -- 保存父会话（绑定 save_id）。
  local parent = service:save(snapshot(1))
  ctx.check(parent.ok == true, "parent save ok")
  ctx.check(type(parent.save_id) == "string", "parent save_id present")

  -- fork：新 save_id + parent_session_id = snapshot.session_id（未提供 parent_save_id 时）。
  local f = service:fork(snapshot(1))
  ctx.check(f.ok == true, "fork ok")
  ctx.assert_eq(f.parent_session_id, "sess-fork", "fork parent_session_id = snapshot.session_id")
  ctx.check(f.save_id ~= parent.save_id, "fork save_id differs from parent")

  local child, cerr = service:open(f.save_id)
  ctx.check(child ~= nil and cerr == nil, "child bundle readable")
  if child then
    ctx.assert_eq(child.save_id, f.save_id, "child save_id")
    ctx.assert_eq(child.parent_session_id, "sess-fork", "child envelope parent_session_id")
    ctx.assert_eq(child.runtime_state.generation, 0, "fork generation reset to 0")
    ctx.assert_eq(child.messages[1].content[1].text, "fork question", "fork messages copied (1)")
    ctx.assert_eq(child.messages[2].content[1].text, "fork answer", "fork messages copied (2)")
    ctx.assert_eq(child.context_items[1].id, "ctx-1", "fork context_items copied")
    ctx.assert_eq(child.provider_id, "mock", "fork provider copied")
    ctx.assert_eq(child.protocol, "mock", "fork protocol copied")
    ctx.assert_eq(child.model, "mock-model", "fork model copied")
    ctx.check(child.trace ~= nil, "child trace present")
    if child.trace then
      ctx.assert_eq(child.trace.id, "trace-1", "fork trace.id preserved")
      ctx.assert_eq(child.trace.membership.root_trace_id, "trace-1", "fork trace root copied")
      ctx.check(child.trace.membership.span_id ~= "span-1", "fork child span differs (new span)")
      ctx.assert_eq(child.trace.membership.parent_span_id, "span-1", "fork parent_span_id = source span")
      ctx.assert_eq(child.trace.membership.session_role, "primary", "fork session role inherited")
    end
  end

  -- 父会话再次保存（新 generation）不得影响子文件（不同 save_id，互不覆盖）。
  local parent2 = service:save(snapshot(2))
  ctx.check(parent2.ok == true, "parent re-save ok")
  ctx.assert_eq(parent2.save_id, parent.save_id, "parent re-save keeps same save_id")
  local parent_env, perr = service:open(parent.save_id)
  ctx.check(parent_env ~= nil and perr == nil, "parent still readable")
  if parent_env then
    ctx.assert_eq(parent_env.runtime_state.generation, 2, "parent generation updated")
    ctx.assert_eq(parent_env.parent_session_id, nil, "parent has no parent")
    ctx.assert_eq(parent_env.messages[1].content[1].text, "fork question", "parent messages intact")
  end
  local child2, cerr2 = service:open(f.save_id)
  ctx.check(child2 ~= nil and cerr2 == nil, "child still readable after parent save")
  if child2 then
    ctx.assert_eq(child2.runtime_state.generation, 0, "child generation untouched")
    ctx.assert_eq(child2.messages[1].content[1].text, "fork question", "child messages untouched")
  end

  -- 两个独立持久化文件。
  ctx.check(vim.fn.filereadable(proj.history_dir .. "/chats/" .. parent.save_id .. ".json") == 1, "parent file exists")
  ctx.check(vim.fn.filereadable(proj.history_dir .. "/chats/" .. f.save_id .. ".json") == 1, "child file exists")
  ctx.check(service:list()[f.save_id] ~= nil, "child index entry present")
  ctx.check(service:list()[parent.save_id] ~= nil, "parent index entry present")

  -- fork 带显式 parent save_id。
  local f2 = service:fork(snapshot(2), { parent_save_id = parent.save_id })
  ctx.check(f2.ok == true, "fork with explicit parent ok")
  ctx.assert_eq(f2.parent_session_id, parent.save_id, "explicit parent_save_id honored")
  local child3, _ = service:open(f2.save_id)
  ctx.check(child3 ~= nil, "second fork readable")
  if child3 then
    ctx.assert_eq(child3.parent_session_id, parent.save_id, "second fork parent_session_id")
  end
end)

if not ctx.ok then
  error("fork failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: fork")
