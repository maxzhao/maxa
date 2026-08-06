-- filepath: tests/history/history-tail-normalize.lua
--- Phase-4 MaxaHistory tail normalization (headless):
---   * _normalize_restored_tail pure-function rules:
---       1. last message must not be an unfinished tool call — orphan
---          tool_call parts removed from the tail assistant message; a pure
---          tool-call message is dropped entirely (loop until tail is not a
---          tool-call shape);
---       2. trailing consecutive EMPTY user messages collapse into ONE empty
---          user message;
---       3. if (after 1+2) the last message is a user message, it is removed
---          from the list and its text becomes the pre-filled input
---          (Enter re-sends it); otherwise input is empty.
---   * restore_chat integration: a saved chat whose last message is a user
---     message restores with that text in the input buffer (read back from
---     the chat buffer lines below the input header).
---
--- Fixture convention: prints HISTORY_OK: history-tail-normalize; throws.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")
local host = require("maxa.runtime.host.nvim")

local ctx = assert_mod.new()

local function user(text)
  local content = {}
  if text and text ~= "" then
    content[#content + 1] = { type = "text", text = text }
  end
  return { role = "user", content = content }
end
local function assistant(text, calls)
  local content = {}
  if text and text ~= "" then
    content[#content + 1] = { type = "text", text = text }
  end
  for _, c in ipairs(calls or {}) do
    content[#content + 1] = { type = "tool_call", call_id = c.id, name = c.name, arguments = c.args or "{}" }
  end
  return { role = "assistant", content = content }
end
local function tool_result(call_id)
  return {
    role = "tool",
    content = { { type = "tool_result", call_id = call_id, status = "success", content = "ok" } },
  }
end

local norm = host._normalize_restored_tail

-- 1a. Tail assistant with text + orphan tool_call -> tool_call parts removed,
--     text kept, no input lift (last message is assistant).
do
  local r = norm({ user("hi"), assistant("working", { { id = "c1", name = "t" } }) })
  ctx.assert_eq(#r.messages, 2, "tail-normalize: text+tool_call keeps both messages")
  ctx.check(r.messages[2].role == "assistant", "tail-normalize: tail is assistant")
  local types = {}
  for _, p in ipairs(r.messages[2].content or {}) do
    types[#types + 1] = p.type
  end
  ctx.assert_eq(table.concat(types, ","), "text", "tail-normalize: orphan tool_call parts removed")
  ctx.check(r.input == nil, "tail-normalize: assistant tail -> no input lift")
end

-- 1b. Tail pure tool_call message -> dropped entirely; the preceding user
--     message then becomes the last message and is lifted into input.
do
  local r = norm({ user("please run"), assistant(nil, { { id = "c1", name = "t" } }) })
  ctx.assert_eq(#r.messages, 0, "tail-normalize: pure tool-call tail dropped + user lifted")
  ctx.assert_eq(r.input, "please run", "tail-normalize: lifted user text becomes input")
end

-- 1c. Paired tool round at the tail (assistant tool_call + tool result) ->
--     untouched (last message is a tool result, not a tool call).
do
  local msgs = { user("go"), assistant(nil, { { id = "c1", name = "t" } }), tool_result("c1") }
  local r = norm(msgs)
  ctx.assert_eq(#r.messages, 3, "tail-normalize: completed tool round preserved")
  ctx.check(r.messages[3].role == "tool", "tail-normalize: tail is tool result")
  ctx.check(r.input == nil, "tail-normalize: tool-result tail -> no input lift")
end

-- 2. Trailing user message -> removed from the list, text lifted as input.
do
  local r = norm({ assistant("reply"), user("continue here") })
  ctx.assert_eq(#r.messages, 1, "tail-normalize: trailing user removed from list")
  ctx.assert_eq(r.messages[1].role, "assistant", "tail-normalize: list ends at assistant")
  ctx.assert_eq(r.input, "continue here", "tail-normalize: trailing user text lifted")
end

-- 3. Trailing consecutive EMPTY user messages -> collapsed into one empty user
--    message, which is then lifted (input = "" -> blank input buffer).
do
  local r = norm({ assistant("reply"), user(""), user("") })
  ctx.assert_eq(#r.messages, 1, "tail-normalize: empty user run collapsed + lifted")
  ctx.assert_eq(r.input, "", "tail-normalize: empty user run yields empty input")
end

-- 4. Normal assistant tail -> untouched, no input.
do
  local r = norm({ user("q"), assistant("a") })
  ctx.assert_eq(#r.messages, 2, "tail-normalize: normal tail untouched")
  ctx.check(r.input == nil, "tail-normalize: normal tail -> no input")
end

-- Integration: restore_chat pre-fills the input buffer with the lifted user text.
fixture_project.with_project(function(proj)
  local bus = events.new()
  local service = history.new({ root = proj.root, events = bus, config = { auto_save = false } })
  host.set_defaults({
    history = service,
    history_config = { enabled = true, auto_save = false, continue_last = false },
  })

  -- Build a saved chat whose last message is a user message ("pick up here").
  local v1 = host._get_default()
  local ok1 = v1:submit("first", { provider_params = { chunks = { "one" } } })
  ctx.check(ok1.rejected ~= true, "tail-integration: first turn accepted")
  -- Append a second user message (pending input that was never answered).
  local conv = require("maxa.runtime.conversation")
  v1.orch:_stack():add_message({ role = "user", content = { conv.text_part("pick up here") } })
  vim.cmd("MaxaSave tail-session")
  ctx.check(service:current_save_id(v1.orch.session.id) == "tail-session", "tail-integration: saved")

  -- Switch away from the saved session first (the active chat is bound to
  -- tail-session; restoring it now would be a no-op by design). A fresh empty
  -- view simulates "opening a history entry from another conversation".
  v1:close()
  host._default = nil
  local v_other = host._get_default()
  ctx.check(v_other ~= nil, "tail-integration: fresh view created")
  -- Restore: the trailing user message must NOT be part of the restored stack
  -- and its text must sit in the input buffer (lines after the input header).
  local v2 = host.restore_chat("tail-session")
  ctx.check(v2 ~= nil, "tail-integration: restore ok")
  ctx.check(v2._opened == true, "tail-integration: window opened")
  local stack_len = v2.orch:_stack():len()
  ctx.check(stack_len >= 2, "tail-integration: restored stack has the answered turn")
  local last_msg = v2.orch:_stack():get(stack_len)
  ctx.check(last_msg.role ~= "user" or last_msg.content == nil or #(last_msg.content or {}) == 0,
    "tail-integration: trailing user NOT re-added to the stack")
  -- Input buffer: header row at render_end, user content after it.
  local buf = v2._buf
  ctx.check(buf ~= nil and vim.api.nvim_buf_is_valid(buf), "tail-integration: chat buffer valid")
  local render_end = v2._render_end or 0
  local area = vim.api.nvim_buf_get_lines(buf, render_end, -1, false)
  ctx.check(area[1] == host.UI.user, "tail-integration: input header present")
  local joined = table.concat(area, "\n")
  ctx.check(joined:find("pick up here", 1, true) ~= nil, "tail-integration: lifted user text in input buffer")

  v2:close()
  host._default = nil
  host._history = nil
  host._history_config = nil
  host._history_listening = false
  service:dispose()
end)

if not ctx.ok then
  error("history-tail-normalize failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: history-tail-normalize")
