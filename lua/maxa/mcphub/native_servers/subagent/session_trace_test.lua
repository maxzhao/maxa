local session_trace = require("maxa.session.session_trace")
local subagent_trace = require("maxa.mcphub.native_servers.subagent.session_trace")
local history_core = require("maxa.session.history_core")

local total = 0
local passed = 0

local function assert_true(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

local function assert_nil(value, message)
  if value ~= nil then
    error((message or "expected nil") .. ", got " .. vim.inspect(value), 2)
  end
end

local function assert_eq(expected, actual, message)
  if expected ~= actual then
    error((message or "assertion failed") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual), 2)
  end
end

local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    print("✗ " .. name)
    print(err)
    os.exit(1)
  end
end

local function cleanup(root_trace_id)
  local dir = session_trace.get_trace_dir(root_trace_id)
  if dir then
    vim.fn.delete(dir, "rf")
  end
end

local function make_parent(root_trace_id)
  local parent = {
    opts = { save_id = root_trace_id, title = "parent" },
    _meta = {},
    messages = {},
  }
  session_trace.set_membership(parent, session_trace.create_root_membership(root_trace_id, {
    span_id = "span_root_" .. root_trace_id,
    session_role = "root",
  }))
  session_trace.ensure_manifest(root_trace_id, { root_title = "parent" })
  return parent
end

local function read_events(root_trace_id)
  local events, err = session_trace.read_events(root_trace_id)
  assert_true(events, err)
  return events
end

local function count_kind(events, kind)
  local count = 0
  for _, event in ipairs(events) do
    if event.kind == kind then
      count = count + 1
    end
  end
  return count
end

test("start_child propagates tracked parent membership and records started event", function()
  local root = "trace_subagent_child_test"
  cleanup(root)
  local parent = make_parent(root)
  local child = { opts = { save_id = "child_save" }, _meta = {}, messages = {} }

  local state, err = subagent_trace.start_child("run_agent", {
    caller = { maxa_ai = { tool = { function_call = { id = "call_run" } } } },
  }, parent, child, {
    session_role = "subagent",
    mode = "new_chat",
    params = { title = "child", messages = { { role = "user", content = "do work" } } },
  })

  assert_true(state, err)
  local membership = session_trace.get_membership(child)
  assert_eq(root, membership.root_trace_id)
  assert_eq(parent._meta.session_trace.span_id, membership.parent_span_id)
  assert_eq("subagent", membership.session_role)
  assert_eq(state.started_event_id, membership.source_event_id)

  local events = read_events(root)
  assert_eq(1, count_kind(events, "subagent.started"))
  assert_eq("run_agent", events[1].tool.name)
  assert_eq("new_chat", events[1].tool.mode)
  cleanup(root)
end)

test("temporary child trace event keeps unsavable session but no fake persistent save_id", function()
  local root = "trace_subagent_temp_test"
  cleanup(root)
  local parent = make_parent(root)
  local child = {
    opts = { save_id = history_core.make_unsavable_save_id("run_agent") },
    _meta = {},
    messages = {},
  }

  subagent_trace.start_child("run_agent", nil, parent, child, {
    session_role = "subagent",
    mode = "temporary",
    params = { title = "temp", run_mode = "temporary", messages = { { role = "user", content = "temp" } } },
  })
  subagent_trace.record_subagent_completed("run_agent", child, {
    content = "temporary result",
    run_mode = "temporary",
    save_id = nil,
    context_status = { save_id = nil },
  }, { mode = "temporary" })

  local events = read_events(root)
  assert_eq(1, count_kind(events, "subagent.started"))
  assert_eq(1, count_kind(events, "subagent.completed"))
  assert_true(events[1].session.temporary)
  assert_nil(events[2].result.save_id)
  cleanup(root)
end)

test("resume in_place preserves source span and new_chat creates linked span", function()
  local root = "trace_subagent_resume_test"
  cleanup(root)
  local source = { save_id = "source_save", _meta = {}, messages = {} }
  session_trace.set_membership(source, {
    root_trace_id = root,
    root_save_id = root,
    span_id = "span_source",
    parent_span_id = "span_parent",
    session_role = "subagent",
    active = true,
  })
  session_trace.ensure_manifest(root, { root_title = "resume" })

  local in_place = { opts = { save_id = "source_save" }, _meta = {}, messages = {} }
  subagent_trace.start_resume("resume_agent", nil, nil, { chat_data = source }, in_place, {
    source_save_id = "source_save",
    resume_mode = "in_place",
    params = { save_id = "source_save", resume_mode = "in_place" },
  })
  local in_place_membership = session_trace.get_membership(in_place)
  assert_eq("span_source", in_place_membership.span_id)
  assert_eq("span_parent", in_place_membership.parent_span_id)

  local new_chat = { opts = { save_id = "resume_new" }, _meta = {}, messages = {} }
  subagent_trace.start_resume("resume_agent", nil, nil, { chat_data = source }, new_chat, {
    source_save_id = "source_save",
    resume_mode = "new_chat",
    params = { save_id = "source_save", resume_mode = "new_chat" },
  })
  local new_membership = session_trace.get_membership(new_chat)
  assert_eq(root, new_membership.root_trace_id)
  assert_true(new_membership.span_id ~= "span_source")
  assert_eq("span_source", new_membership.parent_span_id)
  cleanup(root)
end)

test("completion references matching natural final turn instead of duplicating content", function()
  local root = "trace_subagent_nodup_test"
  cleanup(root)
  local parent = make_parent(root)
  local child = { opts = { save_id = "child_save" }, _meta = {}, messages = {} }
  subagent_trace.start_child("run_agent", nil, parent, child, { mode = "new_chat", params = {} })
  child._session_trace_last_turn_event = {
    event_id = "evt_final_reply",
    kind = "main_turn.agent_reply",
    message_index = 5,
    content_hash = session_trace.hash("same final content"),
  }

  subagent_trace.record_subagent_completed("run_agent", child, {
    content = "same final content",
    finish_reason = "completed",
    save_id = "child_save",
  }, { mode = "new_chat" })

  local events = read_events(root)
  local completed
  for _, event in ipairs(events) do
    if event.kind == "subagent.completed" then
      completed = event
    end
  end
  assert_true(completed, "missing completed event")
  assert_eq("evt_final_reply", completed.result.final_turn_event_ref.event_id)
  assert_nil(completed.result.content, "duplicated final content")
  assert_eq(session_trace.hash("same final content"), completed.result.content_hash)
  cleanup(root)
end)

test("ask_llm and multi_agent are recorded as tool-only events on parent span", function()
  local root = "trace_subagent_tool_only_test"
  cleanup(root)
  local parent = make_parent(root)
  local req = {
    caller = {
      maxa_ai = {
        chat = parent,
        tool = { function_call = { id = "call_tool_only" } },
      },
    },
  }

  subagent_trace.record_tool_completed("ask_llm", req, {
    messages = { { role = "user", content = "question" } },
  }, {
    content = "answer",
    adapter = "inherited",
  })
  subagent_trace.record_tool_completed("multi_agent", req, {
    title = "discussion",
    task = "debate",
    final_agent = "run",
    final_prompt = "summarize",
  }, {
    success = true,
    data = { content = "final", save_id = "phase2" },
  })

  local events = read_events(root)
  assert_eq(1, count_kind(events, "ask_llm.completed"))
  assert_eq(1, count_kind(events, "multi_agent.completed"))
  assert_eq(0, count_kind(events, "subagent.started"))
  for _, event in ipairs(events) do
    assert_eq(parent._meta.session_trace.span_id, event.span_id)
  end
  cleanup(root)
end)

print(string.format("Results: %d passed, %d failed", passed, total - passed))
