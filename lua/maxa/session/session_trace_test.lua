-- filepath: lua/maxa/session/session_trace_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/session_trace_test.lua

local history_core = require("maxa.session.history_core")
local session_trace = require("maxa.session.session_trace")
local get_trace_tool = require("maxa.session.tools.get_trace")

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end

local function assert_true(value, msg)
  if not value then
    error(msg or "expected true")
  end
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_table(value, msg)
  if type(value) ~= "table" then
    error((msg or "expected table") .. ": got " .. type(value))
  end
end

local original_get_history_dir = history_core.get_history_dir
local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")
history_core.get_history_dir = function()
  local history_dir = tmp_root .. "/.maxa/history"
  vim.fn.mkdir(history_dir .. "/chats", "p")
  return history_dir
end

local function write_chat(save_id, data)
  local path = history_core.get_chat_path(save_id)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, encoded = pcall(vim.json.encode, data)
  assert_true(ok, "chat JSON encode")
  vim.fn.writefile({ encoded }, path)
end

local function fake_response()
  local response = { text_value = nil, error_value = nil }
  function response:text(value)
    self.text_value = value
    return self
  end
  function response:error(value)
    self.error_value = value
    return self
  end
  function response:send()
    return self
  end
  return response
end

print("\n=== Testing session session_trace ===\n")

test("rejects unsafe trace ids", function()
  local _, err = session_trace.validate_trace_id("../bad")
  assert_true(err ~= nil, "path traversal id should be rejected")
  local dir, dir_err = session_trace.get_trace_dir("bad/id")
  assert_true(dir == nil and dir_err ~= nil, "slash id should not produce a path")
end)

test("creates manifest and trace paths under project history", function()
  local manifest, err = session_trace.ensure_manifest("root_safe", { root_title = "Root" })
  assert_table(manifest, err)
  assert_eq("root_safe", manifest.root_trace_id, "manifest root")
  local paths = session_trace.paths("root_safe")
  assert_true(vim.fn.filereadable(paths.manifest) == 1, "manifest file exists")
  assert_true(vim.fn.filereadable(paths.events) == 1, "events file exists")
  assert_true(paths.trace_dir:match("/%.maxa/history/traces/root_safe$") ~= nil, "trace dir location")
end)

test("sets persistent membership shape", function()
  local chat = { _meta = {} }
  local membership, err = session_trace.set_membership(chat, session_trace.create_root_membership("root_safe", { span_id = "span_root" }))
  assert_table(membership, err)
  assert_eq("root_safe", chat._meta.session_trace.root_trace_id, "root trace id")
  assert_eq("span_root", chat._meta.session_trace.span_id, "span id")
  assert_eq("root", chat._meta.session_trace.session_role, "session role")
  assert_eq(true, chat._meta.session_trace.active, "active flag")
end)

test("append_event dedupes by dedupe_key", function()
  session_trace.ensure_manifest("dedupe_root", {})
  local event = {
    kind = "trace.started",
    span_id = "span_a",
    session = { save_id = "dedupe_root", role = "root", temporary = false },
    dedupe_key = "same-key",
  }
  local first, first_err = session_trace.append_event("dedupe_root", event)
  assert_table(first, first_err)
  assert_eq(true, first.appended, "first append")
  local second, second_err = session_trace.append_event("dedupe_root", event)
  assert_table(second, second_err)
  assert_eq(false, second.appended, "second skipped")
  assert_eq(true, second.duplicate, "duplicate flag")
  local events = session_trace.read_events("dedupe_root")
  assert_eq(1, #events, "one durable event")
end)

test("backfill writes visible user and assistant messages idempotently", function()
  session_trace.ensure_manifest("backfill_root", {})
  local chat = {
    opts = { save_id = "backfill_root" },
    _meta = {},
    messages = {
      { role = "system", content = "system" },
      { role = "user", content = "prompt" },
      { role = "llm", content = "answer" },
      { role = "user", content = "hidden", opts = { visible = false } },
      { role = "user", content = "rules", _meta = { tag = "rules" } },
      { role = "user", content = "compact summary", _meta = { tag = "compact_summary" } },
      { role = "user", content = "fragment", _meta = { inserted_from_fragment = "frag-1" } },
      { role = "llm", content = "legacy tool call", tools = { calls = { { id = "c1", ["function"] = { name = "x", arguments = "{}" } } } } },
      { role = "assistant", content = "openai tool call", tool_calls = { { id = "c2", ["function"] = { name = "y", arguments = "{}" } } } },
    },
  }
  local membership = session_trace.set_membership(chat, session_trace.create_root_membership("backfill_root", { span_id = "span_backfill" }))
  local first = session_trace.backfill_chat("backfill_root", chat, { membership = membership })
  assert_eq(2, first.added, "two natural turn events added")
  assert_eq(0, first.skipped, "no skipped natural turns first run")
  local second = session_trace.backfill_chat("backfill_root", chat, { membership = membership })
  assert_eq(0, second.added, "no natural turn duplicates second run")
  assert_eq(2, second.skipped, "two natural turn duplicates skipped")
  local events = session_trace.read_events("backfill_root")
  assert_eq(3, #events, "two turns plus one trace.backfilled event")
end)

test("read_trace returns bounded summary content", function()
  session_trace.ensure_manifest("summary_root", {})
  local event = {
    kind = "main_turn.agent_reply",
    span_id = "span_summary",
    session = { save_id = "summary_root", role = "root", temporary = false },
    message = { role = "assistant", content = string.rep("x", 500), message_index = 1 },
    dedupe_key = "summary-long",
  }
  session_trace.append_event("summary_root", event)
  local result, err = session_trace.read_trace("summary_root", { mode = "summary", take = 1 })
  assert_table(result, err)
  assert_eq("recorded", result.source, "recorded source")
  assert_eq(1, result.returned_events, "returned count")
  assert_true(#result.events[1].message.content < 500, "summary truncates content")
end)

test("synthesizes missing trace from saved chat with gaps", function()
  write_chat("saved_synth", {
    save_id = "saved_synth",
    title = "Saved Synth",
    updated_at = 123,
    messages = {
      { role = "user", content = "hello" },
      { role = "llm", content = "world" },
      { role = "user", content = "fragment should not synthesize", _meta = { inserted_from_fragment = "frag-1" } },
      { role = "user", content = "summary should not synthesize", _meta = { tag = "compact_summary" } },
      { role = "assistant", content = "tool call should not synthesize", tool_calls = { { id = "c3", ["function"] = { name = "z", arguments = "{}" } } } },
      { role = "tool", content = "not a natural turn" },
    },
  })
  local result, err = session_trace.synthesize_trace("saved_synth", { mode = "summary" })
  assert_table(result, err)
  assert_eq("synthesized", result.source, "synthesized source")
  assert_eq(3, result.total_events, "two synthesized natural turns plus one fragment action")
  local natural_turns = 0
  for _, event in ipairs(result.events or {}) do
    if event.kind == "main_turn.user_prompt" or event.kind == "main_turn.agent_reply" or event.kind == "main_turn.agent_error" then
      natural_turns = natural_turns + 1
    end
  end
  assert_eq(2, natural_turns, "fragment and compact summary messages are not natural turns")
  assert_true(type(result.gaps) == "table" and #result.gaps >= 1, "gap reporting")
end)

test("get_trace tool reads recorded trace", function()
  session_trace.ensure_manifest("tool_recorded", {})
  session_trace.append_event("tool_recorded", { kind = "trace.started", span_id = "span_tool", dedupe_key = "tool-recorded-start" })
  local res = fake_response()
  get_trace_tool.handler({ params = { root_trace_id = "tool_recorded", mode = "summary" } }, res)
  assert_true(not res.error_value, res.error_value)
  local decoded = vim.json.decode(res.text_value)
  assert_eq("recorded", decoded.data.source, "tool recorded source")
  assert_eq("tool_recorded", decoded.data.root_trace_id, "tool root id")
end)

 test("get_trace tool synthesizes fallback", function()
   write_chat("tool_synth", {
     save_id = "tool_synth",
     title = "Tool Synth",
     updated_at = 456,
     messages = {
       { role = "user", content = "prompt" },
       { role = "llm", content = "reply" },
     },
   })
   local res = fake_response()
   get_trace_tool.handler({ params = { save_id = "tool_synth", mode = "summary" } }, res)
   assert_true(not res.error_value, res.error_value)
   local decoded = vim.json.decode(res.text_value)
   assert_eq("synthesized", decoded.data.source, "tool synthesized source")
   assert_eq(2, decoded.data.total_events, "tool synthesized events")
 end)
 
 test("compression archive extracts only trace-relevant turns", function()
   local turns, counts = session_trace.extract_compression_archive_turns({
     { role = "system", content = "system prompt" },
     { role = "user", content = "real prompt" },
     { role = "assistant", content = "tool call", tool_calls = { { id = "call-1" } } },
     { role = "tool", content = "tool result", tools = { call_id = "call-1" } },
     { role = "user", content = "context", _meta = { tag = "context_file" } },
     { role = "user", content = "revision", _meta = { tag = "ability_revision" } },
     { role = "user", content = "instructions", _meta = { tag = "ability_instructions" } },
     { role = "user", content = "guidance", _meta = { tag = "ability_guidance" } },
     { role = "user", content = "catalog", _meta = { tag = "ability_catalog" } },
     { role = "user", content = "legacy Skill evidence", _meta = { tag = "skill" } },
     { role = "assistant", content = "final reply" },
     { role = "assistant", content = "", status = "stopped", reason = "user_stopped" },
     { role = "assistant", content = "summary", _meta = { tag = "collapse_summary" } },
   }, 1, 13)
 
   assert_eq(3, #turns, "only prompt/reply/error turns archived")
   assert_eq("main_turn.user_prompt", turns[1].kind, "prompt kind")
   assert_eq("real prompt", turns[1].content, "prompt content")
   assert_eq("main_turn.agent_reply", turns[2].kind, "reply kind")
   assert_eq("final reply", turns[2].content, "reply content")
   assert_eq("main_turn.agent_error", turns[3].kind, "error kind")
   assert_eq("stopped", turns[3].status, "error status")
   assert_eq(13, counts.total_messages, "range total")
   assert_eq(10, counts.omitted_count, "tool/current Ability/legacy capability/system omitted")
 end)
 
 test("compression archive is idempotent and stable under root_trace_id", function()
   session_trace.ensure_manifest("archive_root", {})
   local source = {
     source_type = "saved",
     save_id = "source_save",
     messages = {
       { role = "user", content = "archive prompt" },
       { role = "assistant", content = "archive reply" },
       { role = "tool", content = "not archived", tools = { call_id = "call-x" } },
     },
     chat_data = {
       save_id = "source_save",
       _meta = {},
     },
   }
   local membership = session_trace.set_membership(
     source.chat_data,
     session_trace.create_root_membership("archive_root", { span_id = "span_archive" })
   )
   assert_table(membership, "membership")
 
   local first, first_err = session_trace.archive_compression_range(source, {
     start_index = 1,
     end_index = 3,
     action = "delete",
   }, { tool_name = "compact_range", mode = "overwrite" })
   assert_table(first, first_err)
   assert_eq(true, first.appended, "first archive event appended")
   assert_eq(2, first.turn_count, "only two turns archived")
   assert_true(first.path:match("/%.maxa/history/traces/archive_root/archives/"), "archive path stays under root trace")
 
   local second, second_err = session_trace.archive_compression_range(source, {
     start_index = 1,
     end_index = 3,
     action = "delete",
   }, { tool_name = "compact_range", mode = "overwrite" })
   assert_table(second, second_err)
   assert_eq(false, second.appended, "duplicate archive event skipped")
   assert_eq(true, second.duplicate, "duplicate flag")
 
   local events = session_trace.read_events("archive_root")
   assert_eq(1, #events, "one logical archive event")
   local trace = session_trace.read_trace("archive_root", { mode = "full", include_archives = true })
   assert_eq(1, #trace.archives, "one archive file")
   assert_eq("archive_root", trace.archives[1].root_trace_id, "root trace immutable")
   assert_eq("source_save", trace.archives[1].source_save_id, "source save recorded")
 end)
 
 test("compression applied records old and new save ids without renaming trace", function()
   session_trace.ensure_manifest("applied_root", {})
   local source = {
     source_type = "saved",
     save_id = "old_save",
     messages = {
       { role = "user", content = "p" },
       { role = "assistant", content = "r" },
     },
     chat_data = { save_id = "old_save", _meta = {} },
   }
   session_trace.set_membership(
     source.chat_data,
     session_trace.create_root_membership("applied_root", { span_id = "span_applied" })
   )
   local archive = session_trace.archive_compression_range(source, {
     start_index = 1,
     end_index = 2,
     action = "collapse",
   }, { tool_name = "collapse_tail", mode = "new" })
   local result, err = session_trace.append_compression_applied(source, {
     tool_name = "collapse_tail",
     mode = "new",
     action = "collapse_tail",
     new_save_id = "new_save",
     original_save_id = "old_save",
     archives = { archive },
     stats = { total_before = 2, total_after = 1 },
   })
   assert_table(result, err)
   assert_eq(true, result.appended, "applied event appended")
   local recorded = session_trace.read_events("applied_root")
   assert_eq(2, #recorded, "archive plus applied")
   assert_eq("compression.applied", recorded[2].kind, "applied kind")
   assert_eq("applied_root", recorded[2].root_trace_id, "root trace id unchanged")
   assert_eq("old_save", recorded[2].compression.source_save_id, "old save recorded")
   assert_eq("new_save", recorded[2].compression.new_save_id, "new save recorded")
 end)
 
 test("untracked compression archive helpers are no-op", function()
   local source = {
     source_type = "saved",
     save_id = "untracked_save",
     messages = {
       { role = "user", content = "prompt" },
       { role = "assistant", content = "reply" },
     },
     chat_data = { save_id = "untracked_save" },
   }
   local archive_result, archive_err = session_trace.archive_compression_ranges(source, {
     { start_index = 1, end_index = 2, action = "delete" },
   }, { tool_name = "compact_range" })
   assert_table(archive_result, archive_err)
   assert_eq(false, archive_result.tracked, "archive no-op")
   assert_eq(0, #archive_result.archives, "no archives")
   local applied_result, applied_err = session_trace.append_compression_applied(source, { tool_name = "compact_range" })
   assert_table(applied_result, applied_err)
   assert_eq(false, applied_result.tracked, "applied no-op")
 end)
 
 history_core.get_history_dir = original_get_history_dir
vim.fn.delete(tmp_root, "rf")

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
