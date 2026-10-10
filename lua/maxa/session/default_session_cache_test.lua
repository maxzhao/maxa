-- filepath: lua/maxa/session/default_session_cache_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/default_session_cache_test.lua

local history_core = require("maxa.session.history_core")
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
    error(msg or "expected true, got false")
  end
end

local function assert_false(value, msg)
  if value then
    error(msg or "expected false, got true")
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

package.loaded["maxa.config"] = {
  constants = {
    USER_ROLE = "user",
    LLM_ROLE = "llm",
    SYSTEM_ROLE = "system",
    TOOL_ROLE = "tool",
  },
}

package.loaded["maxa.adapters"] = {
  call_handler = function(adapter, name, ...)
    if name == "build_parameters" and adapter.handlers and adapter.handlers.build_parameters then
      return adapter.handlers.build_parameters(adapter, ...)
    end
    if name == "build_messages" and adapter.handlers and adapter.handlers.build_messages then
      return adapter.handlers.build_messages(adapter, ...)
    end
    if name == "build_tools" and adapter.handlers and adapter.handlers.build_tools then
      return adapter.handlers.build_tools(adapter, ...)
    end
    if name == "build_body" and adapter.handlers and adapter.handlers.build_body then
      return adapter.handlers.build_body(adapter, ...)
    end
    if name == "build_reasoning" and adapter.handlers and adapter.handlers.build_reasoning then
      return adapter.handlers.build_reasoning(adapter, ...)
    end
    if name == "format_calls" and adapter.handlers and adapter.handlers.format_calls then
      return adapter.handlers.format_calls(adapter, ...)
    end
    return nil
  end,
}

local dsc = require("maxa.session.default_session_cache")
local private = dsc._private

local function make_chat(extra)
  local chat = {
    adapter = {
      type = "http",
      name = "test_adapter",
      model = { name = "test_model" },
      parameters = { model = "test_model" },
      body = { stream = true },
      map_roles = function(_, messages)
        return messages
      end,
      map_schema_to_params = function(self, settings)
        self.parameters = vim.tbl_extend("force", self.parameters or {}, settings or {})
        return self
      end,
      _last_usage = nil,
      handlers = {
        build_parameters = function(_, params)
          return params
        end,
        build_messages = function(_, messages)
          return { messages = messages }
        end,
        build_tools = function(_, tools)
          return { tools = tools }
        end,
        build_reasoning = function(_, chunks)
          local content = {}
          for _, chunk in ipairs(chunks or {}) do
            table.insert(content, type(chunk) == "table" and chunk.content or chunk)
          end
          return { content = table.concat(content, "") }
        end,
        format_calls = function(_, tools)
          return tools
        end,
      },
    },
    settings = { model = "test_model" },
    messages = {
      { role = "system", content = "system", _meta = { tag = "system_prompt_from_config" }, opts = { visible = false } },
      { role = "user", content = "rules", _meta = { tag = "rules" }, opts = { visible = false } },
    },
    context_items = {
      { source = "rules", id = "<rules>.maxa/AGENTS.md</rules>", path = ".maxa/AGENTS.md" },
    },
    tool_registry = {
      schemas = {
        ["<tool>read</tool>"] = { name = "read", description = "read" },
      },
      in_use = {
        ["read"] = true,
      },
    },
    buffer_context = { project_root = "/tmp/project" },
    opts = {},
    done = function() end,
    submit = function(self)
      self._submit_count = (self._submit_count or 0) + 1
      local payload = { messages = self.adapter:map_roles(vim.deepcopy(self.messages)), tools = {} }
      if self._submit_http then
        self:_submit_http(payload)
      elseif self.done then
        self:done({}, nil, nil, nil, nil)
      end
    end,
    _submit_http = function(self, payload)
      self._last_payload = payload
      if self.done then
        self:done({}, nil, nil, nil, nil)
      end
    end,
  }
  if extra then
    for k, v in pairs(extra) do
      chat[k] = v
    end
  end
  return chat
end

local function cache_dir()
  return history_core.get_history_dir() .. "/caches"
end

print("\n=== Testing default_session_cache ===\n")

test("canonical_json should be deterministic for dictionary key order", function()
  local a = private.canonical_json({ b = 2, a = { z = 1, y = 2 } })
  local b = private.canonical_json({ a = { y = 2, z = 1 }, b = 2 })
  assert_equal('{"a":{"y":2,"z":1},"b":2}', a, "canonical json should sort object keys")
  assert_equal(a, b, "canonical json should match")
end)

test("canonical_json should preserve array/object shape", function()
  local value = {
    z = { b = 2, a = 1 },
    arr = {
      { y = 2, x = 1 },
      vim.empty_dict(),
      {},
    },
  }
  assert_equal('{"arr":[{"x":1,"y":2},{},[]],"z":{"a":1,"b":2}}', private.canonical_json(value), "canonical json should preserve arrays and objects")
end)

test("build_payload_snapshot should match Chat.submit payload shape", function()
  local chat = make_chat()
  local payload = private.build_payload_snapshot(chat, chat.messages)
  assert_true(type(payload.messages) == "table", "messages should exist")
  assert_true(type(payload.tools) == "table", "tools should exist")
  assert_equal(1, #payload.tools, "tools should be wrapped as one schema group")
  assert_true(payload.tools[1]["<tool>read</tool>"] ~= nil, "schema should be preserved")
end)

test("default chat should be detected", function()
  local ok, reason, count = private.is_default_chat(make_chat())
  assert_true(ok, "default chat should pass: " .. tostring(reason))
  assert_equal(2, count, "prefix count")
end)

test("split Runtime and Soul both belong to default cache prefix", function()
  local chat = make_chat()
  table.insert(chat.messages, 2, { role = "system", content = "soul", _meta = { tag = "soul_prompt_from_config" } })
  local ok, reason, count = private.is_default_chat(chat)
  assert_true(ok, "split default chat should pass: " .. tostring(reason))
  assert_equal(3, count, "prefix includes Soul")
end)

test("history-restored chat should not enable default cache", function()
  local ok, reason = private.is_default_chat(make_chat({ opts = { _history_restored = true } }))
  assert_false(ok, "history restored chat should reject")
  assert_equal("history_restored", reason, "reject reason")
end)

test("tool context should be allowed for default mcpx tools", function()
  local chat = make_chat()
  table.insert(chat.context_items, { source = "tool", id = "<tool>read</tool>" })
  local ok, reason = private.is_default_chat(chat)
  assert_true(ok, "tool context from default tools should pass: " .. tostring(reason))
end)

test("non-rules/tool context should reject default chat", function()
  local ok = private.is_default_chat(make_chat({ context_items = { { source = "file" } } }))
  assert_false(ok, "file context should reject")
end)

test("split_messages should keep prefix and tail", function()
  local chat = make_chat()
  table.insert(chat.messages, { role = "user", content = "real task" })
  local prefix, tail = private.split_messages(chat, 2)
  assert_equal(2, #prefix, "prefix size")
  assert_equal(1, #tail, "tail size")
  assert_equal("real task", tail[1].content, "tail content")
end)

test("request snapshot should include same body-level structures as final HTTP request", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs)
  local payload = private.build_payload_snapshot(chat, msgs)
  local request = private.build_request_body_snapshot(chat, payload)
  assert_equal("test_model", request.body.model, "mapped model setting should be present")
  assert_true(type(request.body.messages) == "table", "request messages should be present")
  assert_true(type(request.body.tools) == "table", "request tools should be present")
end)

test("fingerprint should be stable and include warmup payload", function()
  local chat = make_chat()
  local msgs1 = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs1)
  local msgs2 = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs2)
  local fp1 = private.fingerprint(chat, msgs1)
  local fp2 = private.fingerprint(chat, msgs2)
  assert_equal(fp1.hash, fp2.hash, "hash stable")
  assert_equal(fp1.payload_digest, fp2.payload_digest, "payload digest stable")
  assert_equal(fp1.request_digest, fp2.request_digest, "request digest stable")
end)

test("warmup response should not persist reasoning or extra meta", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.append_warmup_response(
    chat,
    msgs,
    { "ok" },
    nil,
    { "hidden thinking" },
    { thinking = "secret", extra = "metadata" }
  )
  local last = msgs[#msgs]
  assert_equal("ok", last.content, "response content")
  assert_true(last.reasoning == nil, "reasoning should not be persisted")
  assert_equal("default_session_cache_warmup_response", last._meta.tag, "tag should remain")
  assert_true(last._meta.thinking == nil, "thinking meta should not be persisted")
  assert_true(last._meta.extra == nil, "extra meta should not be persisted")
end)

test("warmup tool response should preserve reasoning for thinking continuation", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.append_warmup_response(
    chat,
    msgs,
    {},
    {
      {
        id = "call-1",
        call_id = "call-1",
        ["function"] = { name = "tool", arguments = "{}" },
      },
    },
    { { content = "tool reasoning" } },
    {}
  )
  local response = msgs[#msgs - 1]
  assert_equal("tool reasoning", response.reasoning.content, "tool reasoning should be persisted")
  assert_equal(1, #response.tools.calls, "tool call should be persisted")

  local changed = private.sanitize_warmup_cached_messages(msgs)
  assert_false(changed, "valid tool reasoning should not be sanitized")
  assert_equal("tool reasoning", response.reasoning.content, "tool reasoning should survive cache sanitation")
end)

test("old cache record should be sanitized before reuse", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs)
  table.insert(msgs, {
    role = "llm",
    content = "ok",
    reasoning = { "old hidden thinking" },
    opts = { visible = false },
    _meta = { tag = "default_session_cache_warmup_response", thinking = "secret" },
  })
  local changed = private.sanitize_warmup_cached_messages(msgs)
  assert_true(changed, "old cache should be changed")
  local last = msgs[#msgs]
  assert_true(last.reasoning == nil, "reasoning should be removed")
  assert_equal("default_session_cache_warmup_response", last._meta.tag, "tag should remain")
  assert_true(last._meta.thinking == nil, "extra meta should be removed")
end)

test("preflight should validate cached request digest", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs)
  local fp = private.fingerprint(chat, msgs)
  table.insert(msgs, { role = "llm", content = "ok", opts = { visible = false }, _meta = { tag = "default_session_cache_warmup_response" } })
  local record = {
    messages = msgs,
    fingerprint = { request_digest = fp.request_digest },
  }
  assert_true(private.preflight_cached_prefix(chat, record), "matching digest should pass")
  table.insert(record.messages, {
    role = "llm",
    content = "ok",
    opts = { visible = false },
    _meta = { tag = "default_session_cache_warmup_response" },
  })
  assert_true(private.preflight_cached_prefix(chat, record), "cached warmup response should not affect preflight")
  record.fingerprint.request_digest = "bad"
  assert_false(private.preflight_cached_prefix(chat, record), "mismatched digest should fail")
end)

test("checked cache state should persist on first prefix message and match request digest", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs)
  local fp = private.fingerprint(chat, msgs)
  assert_false(private.has_cache_state(chat, fp), "missing state should not match")
  assert_true(private.set_cache_state(chat, fp, "applied"), "state should be written")
  assert_true(private.has_cache_state(chat, fp), "matching state should skip")
  local state = private.get_cache_state(chat)
  assert_equal("applied", state.status, "state status")
  assert_equal(fp.request_digest, state.request_digest, "state digest")

  local other = vim.deepcopy(fp)
  other.request_digest = "different"
  chat._default_session_cache_checked = nil
  assert_false(private.has_cache_state(chat, other), "different digest should not skip")
end)

test("cache miss usage should be detected only when supported and zero", function()
  local chat = make_chat()
  chat.adapter._last_usage = { cache_metric_supported = true, cached_tokens = 0 }
  assert_true(private.cache_miss_from_usage(chat), "zero cached tokens should be miss")
  chat.adapter._last_usage = { cache_metric_supported = true, cached_tokens = 10 }
  assert_false(private.cache_miss_from_usage(chat), "positive cached tokens should not be miss")
  chat.adapter._last_usage = { cache_metric_supported = false }
  assert_false(private.cache_miss_from_usage(chat), "unknown metrics should not be miss")
end)

test("cached submit should sanitize old cached warmup reasoning before inserting history", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs)
  local fp = private.fingerprint(chat, msgs)
  table.insert(msgs, {
    role = "llm",
    content = "ok",
    reasoning = { "old hidden thinking" },
    opts = { visible = false },
    _meta = { tag = "default_session_cache_warmup_response", thinking = "secret" },
  })
  local record = {
    version = 2,
    hash = fp.hash,
    model = "test_model",
    adapter = "test_adapter",
    fingerprint = { payload_digest = fp.payload_digest, request_digest = fp.request_digest },
    messages = msgs,
    context_items = chat.context_items,
    schemas = chat.tool_registry.schemas,
    in_use = chat.tool_registry.in_use,
  }
  private.write_json_atomic(fp.path, record)

  dsc.configure_chat(chat, { mode = "force", prefix_count = 2 })
  table.insert(chat.messages, { role = "user", content = "real task" })
  chat:submit({ auto_submit = true })
  vim.fn.delete(fp.path)

  assert_equal("ok", chat.messages[4].content, "warmup response should be inserted")
  assert_true(chat.messages[4].reasoning == nil, "cached reasoning should be stripped")
  assert_true(chat.messages[4]._meta.thinking == nil, "cached thinking meta should be stripped")
  assert_equal("real task", chat.messages[5].content, "live user message should remain as tail")
end)

test("cached submit should replace live history with cached warmup prefix plus live user tail", function()
  local chat = make_chat()
  local msgs = vim.deepcopy(chat.messages)
  private.add_warmup_user(msgs)
  local fp = private.fingerprint(chat, msgs)
  local record = {
    version = 2,
    hash = fp.hash,
    model = "test_model",
    adapter = "test_adapter",
    fingerprint = { payload_digest = fp.payload_digest, request_digest = fp.request_digest },
    messages = msgs,
    context_items = chat.context_items,
    schemas = chat.tool_registry.schemas,
    in_use = chat.tool_registry.in_use,
  }
  private.write_json_atomic(fp.path, record)

  dsc.configure_chat(chat, { mode = "force", prefix_count = 2 })
  table.insert(chat.messages, { role = "user", content = "real task" })
  chat:submit({ auto_submit = true })
  vim.fn.delete(fp.path)

  assert_equal(4, #chat.messages, "live chat history should include cached warmup prefix plus live user tail")
  assert_equal("不要思考，直接回复`ok`，不要有任何多余字符。", chat.messages[3].content, "warmup message should be visible in history data")
  assert_equal("real task", chat.messages[4].content, "live user message should remain as tail")
  assert_equal(4, #chat._last_payload.messages, "request payload should match cached history plus live user tail")
  assert_equal("real task", chat._last_payload.messages[4].content, "request payload should include user tail")
end)

test("checked cache state should skip subsequent submit in same chat", function()
  local chat = make_chat()
  dsc.configure_chat(chat, { mode = "force", prefix_count = 2 })
  local original_send_warmup = private.send_warmup
  private.set_send_warmup_for_test(function(_, _, callback)
    callback(true, { output = { "ok" }, reasoning = {}, tools = {}, meta = {} }, nil)
  end)

  table.insert(chat.messages, { role = "user", content = "first task" })
  chat:submit({ auto_submit = true })
  local first_count = chat._submit_count
  chat:submit({ auto_submit = true })
  private.set_send_warmup_for_test(original_send_warmup)

  assert_equal(first_count + 1, chat._submit_count, "second submit should call original submit exactly once")
  assert_true(chat._default_session_cache_checked, "memory state should be set after first submit")
  local state = private.get_cache_state(chat)
  assert_true(state and state.checked, "persistent state should be written after first submit")
end)

test("newly created cache should not be deleted by first request cache-miss usage", function()
  local chat = make_chat()
  dsc.configure_chat(chat, { mode = "force", prefix_count = 2 })
  local original_send_warmup = private.send_warmup
  private.set_send_warmup_for_test(function(_, _, callback)
    callback(true, { output = { "ok" }, reasoning = {}, tools = {}, meta = {} }, nil)
  end)
  chat.adapter._last_usage = { cache_metric_supported = true, cached_tokens = 0 }
  chat:submit({ auto_submit = true })
  private.set_send_warmup_for_test(original_send_warmup)

  local found = false
  for _, name in ipairs(vim.fn.readdir(cache_dir())) do
    local path = cache_dir() .. "/" .. name
    local data = vim.fn.readfile(path)
    local text = table.concat(data, "\n")
    if text:find("system", 1, true) and text:find("default_session_cache_warmup", 1, true) then
      found = true
      vim.fn.delete(path)
      break
    end
  end
  assert_true(found, "created cache should remain after first request")
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
