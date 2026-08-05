-- filepath: tests/protocol/unit_transport.lua
--- Minimal unit tests for lua/maxa/runtime/protocol/transport.lua (phase-1 W1).
---
--- Covers (all offline via a fake plenary.curl):
---   - non-stream success: body temp-file write/cleanup, on_done once
---   - stream success: on_chunk order, on_done(nil) once
---   - HTTP >= 400 -> typed error with granular class (body classification
---     wins over status fallback; raw body preserved in cause)
---   - curl-level failures: exit 28 -> TIMEOUT/timeout; exit 7 -> network
---   - cancel: job:shutdown called, status "cancelled", late callbacks
---     suppressed, exactly-once
---   - streamed JSON error bodies captured and classified, not forwarded
---   - retries parsed but not executed (phase-2 domain)
---   - proxy resolution (explicit > proxy_env > nil)
---   - M.classify_error / M.class_from_status / M.class_from_provider_type
---
---   nvim --headless -l tests/protocol/unit_transport.lua

vim.opt.runtimepath:prepend("/home/maxzhao/maxa")

local function ensure_ecosystem()
  if pcall(require, "plenary.curl") and pcall(require, "plenary.path") then
    return true
  end
  local deadline = vim.loop.hrtime() + 20000 * 1e6
  while vim.loop.hrtime() < deadline do
    if pcall(require, "plenary.curl") and pcall(require, "plenary.path") then
      return true
    end
    vim.wait(100)
  end
  return false
end

if not ensure_ecosystem() then
  print("UNIT_TRANSPORT_FAIL: plenary not ready (run `just setup` and boot nvim-maxa once)")
  vim.cmd("cq")
end

local transport = require("maxa.runtime.protocol.transport")

local failures = {}
local case_count = 0

local function expect(cond, msg)
  case_count = case_count + 1
  if not cond then
    failures[#failures + 1] = msg
  end
end

------------------------------------------------------------
-- Fake plenary.curl (network-free)
------------------------------------------------------------
--- Build a fake `post` that mirrors plenary semantics: with `callback` (or
--- `stream`) it starts a job and returns it; callbacks fire via vim.schedule.
---
--- Behavior is resolved per post from a caller-supplied function
--- `behavior(curl_opts) -> { status?, body?, chunks?, exit? }`, which keeps
--- transport's request options free of test-only keys (transport copies only
--- its known fields into the curl options, so fake controls must not travel
--- through request_opts).
---@param behavior? fun(opts: table) -> table resolved fake response
---@return table fake { post=fun(opts)->job, state={posts=table[], jobs=table[]} }
local function make_fake_curl(behavior)
  local state = { posts = {}, jobs = {} }
  local post = function(opts)
    state.posts[#state.posts + 1] = opts
    local job = { opts = opts, shutdown_called = false }
    job.shutdown = function()
      job.shutdown_called = true
    end
    state.jobs[#state.jobs + 1] = job
    vim.schedule(function()
      if job.shutdown_called then
        return
      end
      local b = (behavior and behavior(opts)) or {}
      if b.exit and b.exit ~= 0 then
        opts.on_error({ message = "fake curl failure", stderr = "fake stderr", exit = b.exit })
        return
      end
      if opts.stream then
        for _, chunk in ipairs(b.chunks or {}) do
          if job.shutdown_called then
            return
          end
          opts.stream(job, chunk)
        end
        if job.shutdown_called then
          return
        end
      end
      opts.callback({ status = b.status or 200, body = b.body or "", headers = {}, exit = 0 })
    end)
    return job
  end
  return { post = post, state = state }
end

--- Poll until the handle reaches a terminal state (or deadline).
---@param handle table transport handle
---@return boolean terminal
local function wait_terminal(handle, ms)
  local deadline = vim.loop.hrtime() + (ms or 2000) * 1e6
  while vim.loop.hrtime() < deadline do
    local s = handle.status()
    if s == "success" or s == "error" or s == "cancelled" then
      return true
    end
    vim.wait(10)
  end
  return false
end

--- Build a transport client wired to a fresh fake curl + temp file spies.
---@param behavior? fun(curl_opts: table) -> table fake response for each post
---@return table env { client=table, fake=table, temps={created=table[], removed=table[]} }
local function make_env(behavior)
  local fake = make_fake_curl(behavior)
  local temps = { created = {}, removed = {} }
  local client = transport.new({
    post = fake.post,
    tempname = function()
      local path = "/tmp/maxa_unit_body" .. tostring(#temps.created + 1)
      temps.created[#temps.created + 1] = path
      return path
    end,
    fs_rm = function(path)
      temps.removed[#temps.removed + 1] = path
    end,
  })
  return { client = client, fake = fake, temps = temps }
end

local function read_body_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

------------------------------------------------------------
-- 1. Non-stream success
------------------------------------------------------------
do
  local env = make_env()
  local calls = { done = 0, error = 0 }
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    headers = { ["Authorization"] = "Bearer test" },
    body = { model = "m", messages = {} },
    connect_timeout_ms = 5000,
    timeout_ms = 30000,
  }, {
    on_done = function(response)
      calls.done = calls.done + 1
      expect(response and response.status == 200, "non-stream on_done status")
    end,
    on_error = function()
      calls.error = calls.error + 1
    end,
  })
  expect(wait_terminal(handle), "non-stream reaches terminal")
  expect(calls.done == 1 and calls.error == 0, "non-stream exactly one on_done")
  expect(handle.status() == "success", "non-stream status success")
  expect(#env.fake.state.posts == 1, "one curl post issued")
  local post_opts = env.fake.state.posts[1]
  expect(type(post_opts.body) == "string" and post_opts.body ~= "", "body passed as temp file path")
  local body_text = read_body_file(post_opts.body)
  expect(body_text and body_text:match('"model"%s*:%s*"m"') ~= nil, "temp body contains JSON")
  expect(post_opts.raw and vim.tbl_contains(post_opts.raw, "--connect-timeout"), "connect-timeout raw arg")
  expect(post_opts.raw and vim.tbl_contains(post_opts.raw, "--max-time"), "max-time raw arg")
  expect(#env.temps.removed == 1, "temp body file cleaned up after terminal")
end

------------------------------------------------------------
-- 2. Stream success: chunk order + single on_done
------------------------------------------------------------
do
  local env = make_env(function()
    return { chunks = { "a", "b", "c" } }
  end)
  local chunks, done = {}, 0
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = { stream = true },
    stream = true,
  }, {
    on_chunk = function(data)
      chunks[#chunks + 1] = data
    end,
    on_done = function()
      done = done + 1
    end,
  })
  expect(wait_terminal(handle), "stream reaches terminal")
  -- Transport normalizes plenary's line-split output: each delivered line is
  -- reattached with "\n" (see transport.lua stream path).
  expect(#chunks == 3 and chunks[1] == "a\n" and chunks[2] == "b\n" and chunks[3] == "c\n", "stream chunk order")
  expect(done == 1, "stream exactly one on_done")
  expect(handle.status() == "success", "stream status success")
  local post_opts = env.fake.state.posts[1]
  expect(post_opts.compressed == false, "stream disables compression")
  expect(post_opts.raw and vim.tbl_contains(post_opts.raw, "--no-buffer"), "stream no-buffer raw arg")
end

------------------------------------------------------------
-- 2b. Stream line normalization: empty separator lines survive
------------------------------------------------------------
do
  local env = make_env(function()
    return { chunks = { "data: {\"a\":1}", "", "data: {\"b\":2}", "" } }
  end)
  local chunks = {}
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = { stream = true },
    stream = true,
  }, {
    on_chunk = function(data)
      chunks[#chunks + 1] = data
    end,
  })
  expect(wait_terminal(handle), "2b reaches terminal")
  expect(
    #chunks == 4 and chunks[1] == 'data: {"a":1}\n' and chunks[2] == "\n" and chunks[3] == 'data: {"b":2}\n' and chunks[4] == "\n",
    "empty separator lines forwarded as \\n"
  )
end

------------------------------------------------------------
-- 3. HTTP 401 -> authentication typed error (body preserved)
------------------------------------------------------------
do
  local env = make_env(function()
    return { status = 401, body = '{"error":{"message":"bad key","type":"authentication_error"}}' }
  end)
  local errors = {}
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = { model = "m" },
  }, {
    on_error = function(err)
      errors[#errors + 1] = err
    end,
  })
  expect(wait_terminal(handle), "http error reaches terminal")
  expect(errors[1] ~= nil, "http error exactly one on_error")
  expect(errors[1] and errors[1].code == "provider", "http error code provider")
  expect(errors[1] and errors[1].terminal == true, "http error terminal")
  expect(errors[1] and errors[1].cause and errors[1].cause.class == transport.CLASS.AUTHENTICATION, "401 class authentication")
  expect(errors[1] and errors[1].cause and errors[1].cause.status == 401, "401 status in cause")
  expect(errors[1] and errors[1].cause and errors[1].cause.provider_type == "authentication_error", "provider type preserved")
  expect(errors[1] and errors[1].cause and errors[1].cause.body:match("bad key") ~= nil, "error body preserved")
  expect(handle.status() == "error", "http error status")
end

------------------------------------------------------------
-- 4. Body classification wins over status (429 + insufficient_quota)
------------------------------------------------------------
do
  local env = make_env(function()
    return { status = 429, body = '{"error":{"type":"insufficient_quota","message":"quota"}}' }
  end)
  local errors = {}
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = {},
  }, {
    on_error = function(err)
      errors[#errors + 1] = err
    end,
  })
  expect(wait_terminal(handle), "quota error terminal")
  expect(errors[1] and errors[1].cause.class == transport.CLASS.QUOTA, "insufficient_quota -> quota class")
end

------------------------------------------------------------
-- 5. HTTP 500 empty body -> provider_unavailable
------------------------------------------------------------
do
  local env = make_env(function()
    return { status = 500 }
  end)
  local errors = {}
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = {},
  }, {
    on_error = function(err)
      errors[#errors + 1] = err
    end,
  })
  expect(wait_terminal(handle), "500 error terminal")
  expect(errors[1] and errors[1].cause.class == transport.CLASS.PROVIDER_UNAVAILABLE, "500 -> provider_unavailable")
end

------------------------------------------------------------
-- 6. curl exit 28 -> TIMEOUT
------------------------------------------------------------
do
  local env = make_env(function()
    return { exit = 28 }
  end)
  local errors = {}
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = {},
  }, {
    on_error = function(err)
      errors[#errors + 1] = err
    end,
  })
  expect(wait_terminal(handle), "curl 28 terminal")
  expect(errors[1] and errors[1].code == "timeout", "exit 28 code timeout")
  expect(errors[1] and errors[1].cause.class == transport.CLASS.TIMEOUT, "exit 28 class timeout")
end

------------------------------------------------------------
-- 7. curl exit 7 -> network class
------------------------------------------------------------
do
  local env = make_env(function()
    return { exit = 7 }
  end)
  local errors = {}
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = {},
  }, {
    on_error = function(err)
      errors[#errors + 1] = err
    end,
  })
  expect(wait_terminal(handle), "curl 7 terminal")
  expect(errors[1] and errors[1].cause.class == transport.CLASS.NETWORK, "exit 7 class network")
end

------------------------------------------------------------
-- 8. Cancel: exactly-once, shutdown, late callbacks suppressed
------------------------------------------------------------
do
  local env = make_env(function()
    return { chunks = { "a", "b", "c" } }
  end)
  local seen = { chunk = 0, done = 0, error = 0 }
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = {},
    stream = true,
  }, {
    on_chunk = function()
      seen.chunk = seen.chunk + 1
    end,
    on_done = function()
      seen.done = seen.done + 1
    end,
    on_error = function()
      seen.error = seen.error + 1
    end,
  })
  -- Cancel synchronously before any scheduled delivery runs.
  expect(handle.cancel() == true, "cancel returns true first time")
  expect(handle.cancel() == false, "cancel returns false second time (already terminal)")
  expect(handle.status() == "cancelled", "status cancelled after cancel")
  expect(env.fake.state.jobs[1].shutdown_called == true, "job:shutdown called on cancel")
  vim.wait(150) -- drain any scheduled callbacks
  expect(seen.chunk == 0 and seen.done == 0 and seen.error == 0, "late callbacks suppressed after cancel")
end

------------------------------------------------------------
-- 9. Streamed JSON error body: captured, classified, not forwarded
------------------------------------------------------------
do
  local env = make_env(function()
    return {
      status = 400,
      chunks = { '{"error":{"message":"bad","type":"invalid_request_error"}}', '{"ok":1}' },
    }
  end)
  local chunks, errors = {}, {}
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = {},
    stream = true,
  }, {
    on_chunk = function(data)
      chunks[#chunks + 1] = data
    end,
    on_error = function(err)
      errors[#errors + 1] = err
    end,
  })
  expect(wait_terminal(handle), "stream error terminal")
  expect(#chunks == 1 and chunks[1] == '{"ok":1}\n', "error-shaped chunk not forwarded")
  expect(#errors == 1, "stream error exactly one on_error")
  expect(errors[1].cause.class == transport.CLASS.INVALID_REQUEST, "stream error class from body")
  expect(errors[1].cause.body:match('"bad"') ~= nil, "stream error body captured")
end

------------------------------------------------------------
-- 10. retries parsed only (no auto-retry in phase 1)
------------------------------------------------------------
do
  local env = make_env(function()
    return { status = 503 }
  end)
  local handle = env.client:post({
    url = "https://example.invalid/v1/chat/completions",
    body = {},
    retries = 3,
  }, {
    on_error = function() end,
  })
  expect(handle.retries == 3, "retries recorded on handle")
  expect(wait_terminal(handle), "retry case terminal")
  expect(#env.fake.state.posts == 1, "no automatic retry (phase-2 domain)")
end

------------------------------------------------------------
-- 11. Proxy resolution
------------------------------------------------------------
do
  vim.fn.setenv("MAXA_TEST_PROXY", "http://127.0.0.1:10808")
  expect(
    transport.resolve_proxy({ proxy = "http://direct", proxy_env = "MAXA_TEST_PROXY" }) == "http://direct",
    "explicit proxy wins"
  )
  expect(transport.resolve_proxy({ proxy_env = "MAXA_TEST_PROXY" }) == "http://127.0.0.1:10808", "proxy_env resolved")
  expect(transport.resolve_proxy({ proxy_env = "MAXA_TEST_MISSING" }) == nil, "missing proxy_env -> nil")
  vim.fn.setenv("MAXA_TEST_PROXY", vim.NIL)
  expect(transport.resolve_proxy({}) == nil, "no proxy options -> nil")
end

------------------------------------------------------------
-- 12. Pure classification helpers
------------------------------------------------------------
do
  expect(transport.class_from_status(401) == transport.CLASS.AUTHENTICATION, "401 status class")
  expect(transport.class_from_status(403) == transport.CLASS.AUTHENTICATION, "403 status class")
  expect(transport.class_from_status(429) == transport.CLASS.RATE_LIMITED, "429 status class")
  expect(transport.class_from_status(408) == transport.CLASS.TIMEOUT, "408 status class")
  expect(transport.class_from_status(400) == transport.CLASS.INVALID_REQUEST, "400 status class")
  expect(transport.class_from_status(502) == transport.CLASS.PROVIDER_UNAVAILABLE, "502 status class")
  expect(
    transport.class_from_provider_type("RESOURCE_EXHAUSTED") == transport.CLASS.QUOTA,
    "gemini RESOURCE_EXHAUSTED -> quota"
  )
  expect(
    transport.class_from_provider_type("rate_limit_error") == transport.CLASS.RATE_LIMITED,
    "anthropic rate_limit_error"
  )
  expect(
    transport.class_from_provider_type("overloaded_error") == transport.CLASS.PROVIDER_UNAVAILABLE,
    "anthropic overloaded_error"
  )
  expect(transport.class_from_provider_type("unknown_thing") == nil, "unknown provider type -> nil")
  local info = transport.classify_error(429, '{"error":{"status":"RESOURCE_EXHAUSTED"}}')
  expect(
    info.class == transport.CLASS.QUOTA and info.provider_type == "RESOURCE_EXHAUSTED",
    "classify_error gemini shape"
  )
  info = transport.classify_error(429, "not-json")
  expect(info.class == transport.CLASS.RATE_LIMITED and info.provider_type == nil, "classify_error fallback")
  info = transport.classify_error(401, '{"type":"authentication_error","error":{}}')
  expect(info.class == transport.CLASS.AUTHENTICATION, "classify_error anthropic root type")
end

------------------------------------------------------------
-- 13. Invalid body argument
------------------------------------------------------------
do
  local env = make_env()
  local handle, err = env.client:post({ url = "https://example.invalid/", body = 42 }, {})
  expect(handle == nil and type(err) == "string", "invalid body rejected")
end

if #failures == 0 then
  print(("UNIT_TRANSPORT_OK cases=%d"):format(case_count))
else
  print(("UNIT_TRANSPORT_FAIL failures=%d"):format(#failures))
  for _, f in ipairs(failures) do
    print("  - " .. f)
  end
  vim.cmd("cq")
end

return transport
