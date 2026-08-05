-- filepath: lua/maxa/runtime/mcp/client.lua
--- maxa external MCP stdio JSON-RPC client (phase-3 W3).
---
--- Contract (see `specs/modules/mcp-skill-runtime/spec.md` §MCP requests and
--- `specs/runtime-fixture-contract.md` §MCP lifecycle):
---   * stdio transport with `Content-Length` framing (both `\r\n` and `\n`
---     header terminators; JSON-RPC 1.0/1.1 style headers accepted).
---   * request ids are paired through a pending table; each request carries the
---     client `generation`; a response whose entry generation differs from the
---     current generation is discarded with a diagnostic (generation late
---     response rejection).
---   * per-request timeout via the injectable clock (`request_timeout_ms` /
---     `startup_timeout_ms`); explicit `cancel(id)` sends the
---     `notifications/cancelled` notification and settles the pending call.
---   * transport/process failure settles every pending call with a typed error
---     (`schema.new_error`, codes: TIMEOUT/CANCELLED/NETWORK/PROTOCOL) so
---     ToolBatch completion can never hang.
---   * protocol sequence: `initialize` (protocolVersion/capabilities/serverInfo
---     validated) -> `notifications/initialized` -> `tools/list` (cursor
---     pagination) -> `tools/call`.
---   * notifications (`log`/progress etc.) are dispatched to an injected
---     `on_notification(method, params)` callback; server-initiated *requests*
---     (e.g. sampling) are answered with method-not-found (-32601).
---   * process layer is an injectable seam: default `M.stdio_process_factory`
---     is a thin `vim.loop` raw-pipe process (plenary.job is line-oriented and
---     cannot deliver newline-less MCP frames; see the factory docstring);
---     tests inject a fake process implementing the same contract
---     { set_callbacks, start, write, shutdown, close }.
---
--- This module never loads codecompanion.* / mcphub.* / lua/util/hooks/*.

local schema = require("maxa.runtime.schema")
local clock_lib = require("maxa.runtime.clock")

local M = {}
M.name = "mcp.client"

--- MCP protocol version this client speaks.
M.PROTOCOL_VERSION = "2024-11-05"
--- Client identity sent in `initialize.clientInfo`.
M.CLIENT_INFO = { name = "maxa", version = "0.1.0" }

--- Bounded frame buffer cap (bytes) to protect against a streaming server
--- that never completes a frame (fail-closed diagnostic instead of unbounded
--- memory growth).
M.MAX_BUFFER_BYTES = 16 * 1024 * 1024

--------------------------------------------------------------------------------
-- Typed errors
--------------------------------------------------------------------------------

---@param code string schema.ERROR.*
---@param message string
---@param cause? table|nil
---@return table err
local function typed(code, message, cause)
  return schema.new_error(code, message, cause)
end

local function timeout_error(method, timeout_ms)
  return typed(schema.ERROR.TIMEOUT, ("mcp request %q timed out after %dms"):format(method, timeout_ms), {
    reason = "request_timeout",
    method = method,
    timeout_ms = timeout_ms,
  })
end

local function cancel_error(method, reason)
  return typed(schema.ERROR.CANCELLED, ("mcp request %q cancelled"):format(method), {
    reason = reason or "cancelled",
    method = method,
  })
end

local function network_error(message, cause)
  return typed(schema.ERROR.NETWORK, message, cause)
end

local function protocol_error(message, cause)
  return typed(schema.ERROR.PROTOCOL, message, cause)
end

local function rpc_error(err, method)
  return typed(
    schema.ERROR.PROTOCOL,
    ("mcp request %q failed: %s"):format(method, tostring(err.message or err.code or "rpc error")),
    {
      reason = "rpc_error",
      method = method,
      code = err.code,
      data = err.data,
    }
  )
end

--------------------------------------------------------------------------------
-- Frame codec (Content-Length framing)
--------------------------------------------------------------------------------

--- Parse all complete frames out of a buffer; returns the decoded bodies, the
--- remaining incomplete tail, and an error on malformed framing.
---@param buf string raw stream bytes
---@return string[] frames complete frame bodies
---@return string rest incomplete tail
---@return string|nil err framing error (nil when only incomplete)
function M.parse_frames(buf)
  local frames, rest = {}, buf
  while true do
    -- Header terminator: prefer \r\n\r\n, tolerate \n\n (JSON-RPC 1.0/1.1).
    local crlf = rest:find("\r\n\r\n", 1, true)
    local lf = rest:find("\n\n", 1, true)
    local sep
    if crlf and lf then
      sep = crlf < lf and "\r\n\r\n" or "\n\n"
    elseif crlf then
      sep = "\r\n\r\n"
    elseif lf then
      sep = "\n\n"
    else
      return frames, rest, nil
    end
    local start = rest:find(sep, 1, true)
    local header = rest:sub(1, start - 1)
    local content_length
    for line in header:gmatch("[^\r\n]+") do
      local k, v = line:match("^([^:]+):%s*(.*)$")
      if k and v and k:lower() == "content-length" then
        content_length = tonumber(v)
      end
    end
    if not content_length then
      return frames, rest, "missing Content-Length header"
    end
    local body_start = start + #sep
    if #rest < body_start + content_length - 1 then
      return frames, rest, nil -- incomplete body; wait for more data
    end
    local body = rest:sub(body_start, body_start + content_length - 1)
    frames[#frames + 1] = body
    rest = rest:sub(body_start + content_length)
  end
end

--- Encode a JSON-RPC message as one Content-Length frame.
---@param msg table message (jsonrpc/id/method/params/result/error)
---@return string frame
function M.encode_frame(msg)
  local body = vim.json.encode(msg)
  return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

--- Decode a frame body into a message (nil + err on malformed JSON).
---@param body string frame body
---@return table|nil msg
---@return string|nil err
function M.decode_frame(body)
  local ok, msg = pcall(vim.json.decode, body)
  if not ok or type(msg) ~= "table" then
    return nil, "malformed JSON-RPC message"
  end
  return msg, nil
end

--------------------------------------------------------------------------------
-- Process layer (injectable)
--------------------------------------------------------------------------------

--- Default stdio process factory: `vim.loop` (uv) raw pipe process.
---
--- 生态缺位最小替代 (ecosystem-missing minimal substitute): `plenary.job`'s
--- stdout reader is LINE-ORIENTED (it only delivers complete `\n`-terminated
--- lines, holding partial trailing data until EOF), while MCP `Content-Length`
--- frames are byte-exact and carry NO trailing newline. A long-lived MCP
--- server's responses would therefore never reach the client through
--- plenary.job. This thin adapter wraps `vim.loop` spawn + raw pipe reads and
--- implements the SAME process contract as the test fake:
---
---   * set_callbacks({ on_stdout = fun(chunk), on_stderr = fun(chunk),
---                    on_exit = fun(code, signal) })
---   * start()   -- spawn (callbacks must be set first)
---   * write(data) -- write raw bytes to stdin
---   * shutdown()  -- close stdin (EOF)
---   * close()     -- terminate/kill; on_exit may fire afterwards (client
---                   distinguishes deliberate close via its `closed` flag)
---
---@param config table normalized server record (command/args/env/cwd)
---@return table process
function M.stdio_process_factory(config)
  local uv = vim.uv or vim.loop
  local cbs = {}
  local handle
  local pipes = {}
  local proc = {}
  function proc.set_callbacks(c)
    cbs = c or {}
  end
  -- Env: declared variables are merged over the parent environment (the child
  -- keeps PATH etc.); an empty declared env is omitted (inherit everything).
  -- uv.spawn expects a "VAR=VALUE" list.
  local env_list
  if config.env and next(config.env) ~= nil then
    local env_dict = vim.fn.environ()
    for k, v in pairs(config.env) do
      env_dict[k] = v
    end
    env_list = {}
    for k, v in pairs(env_dict) do
      env_list[#env_list + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  -- Colon methods: the client invokes them with the process as the first
  -- argument (pcall(proc.start, proc) / pcall(proc.write, proc, frame) ...).
  function proc:start()
    local stdin_pipe = uv.new_pipe(false)
    local stdout_pipe = uv.new_pipe(true)
    local stderr_pipe = uv.new_pipe(true)
    local h, perr = uv.spawn(config.command, {
      args = config.args,
      cwd = config.cwd,
      env = env_list,
      stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    }, function(code, signal)
      pcall(stdin_pipe.close, stdin_pipe)
      pcall(stdout_pipe.close, stdout_pipe)
      pcall(stderr_pipe.close, stderr_pipe)
      if cbs.on_exit then
        vim.schedule(function()
          pcall(cbs.on_exit, code, signal)
        end)
      end
    end)
    if not h then
      error(("mcp client: failed to spawn %q: %s"):format(config.command, tostring(perr)), 0)
    end
    handle = h
    pipes.stdin, pipes.stdout, pipes.stderr = stdin_pipe, stdout_pipe, stderr_pipe
    uv.read_start(stdout_pipe, function(err, data)
      if data and cbs.on_stdout then
        -- Dispatch on the main loop: libuv callbacks are a fast-event context
        -- where vimscript APIs (e.g. vim.fn.tempname in transport.post) are
        -- forbidden; tool completion cascades (barrier -> automatic
        -- continuation -> provider request) must run outside it.
        vim.schedule(function()
          pcall(cbs.on_stdout, data)
        end)
      end
    end)
    uv.read_start(stderr_pipe, function(err, data)
      if data and cbs.on_stderr then
        vim.schedule(function()
          pcall(cbs.on_stderr, data)
        end)
      end
    end)
  end
  function proc:write(data)
    if pipes.stdin and handle then
      pcall(pipes.stdin.write, pipes.stdin, data)
    end
  end
  function proc:shutdown()
    if pipes.stdin and handle then
      pcall(pipes.stdin.shutdown, pipes.stdin, function()
        pcall(pipes.stdin.close, pipes.stdin)
      end)
      pipes.stdin = nil
    end
  end
  function proc:close()
    if handle then
      pcall(handle.kill, handle, "sigterm")
      pcall(handle.close, handle)
      handle = nil
    end
    for _, pipe in ipairs({ pipes.stdin, pipes.stdout, pipes.stderr }) do
      if pipe then
        pcall(pipe.close, pipe)
      end
    end
    pipes = {}
  end
  return proc
end

--------------------------------------------------------------------------------
-- Client
--------------------------------------------------------------------------------

local Client = {}
Client.__index = Client

--- Create a stdio MCP client.
---@param opts table {
---   server_id: string (diagnostics),
---   config: table normalized server record (command/args/env/cwd/timeouts),
---   clock?: table|nil deterministic clock (clock.default()),
---   process_factory?: fun(config)->process|nil (default stdio_process_factory),
---   generation?: integer|nil initial generation (default 1),
---   on_notification?: fun(method, params)|nil,
---   on_diagnostic?: fun(kind, info)|nil,
---   on_process_exit?: fun(code, signal)|nil -- unexpected exit (not deliberate close),
--- }
---@return table client
function M.new(opts)
  assert(type(opts) == "table" and type(opts.server_id) == "string", "mcp.client.new: server_id required")
  local self = setmetatable({
    server_id = opts.server_id,
    config = opts.config,
    clock = opts.clock or clock_lib.default(),
    process_factory = opts.process_factory or M.stdio_process_factory,
    generation = opts.generation or 1,
    on_notification = opts.on_notification,
    on_diagnostic = opts.on_diagnostic,
    on_process_exit = opts.on_process_exit,
    proc = nil,
    _buf = "",
    _pending = {},
    _next_id = 1,
    _closed = false,
    _initialized = false,
    server_info = nil,
    _diagnostics = {},
    _requests = {}, -- ordered decoded client requests (diagnostics/tests)
  }, Client)
  self.request_timeout_ms = opts.config and opts.config.request_timeout_ms
  self.startup_timeout_ms = opts.config and opts.config.startup_timeout_ms
  return self
end

---@param kind string diagnostic kind
---@param info table detail
function Client:_diagnostic(kind, info)
  self._diagnostics[#self._diagnostics + 1] = { kind = kind, info = info, at_ms = self.clock.now_ms() }
  if self.on_diagnostic then
    pcall(self.on_diagnostic, kind, info)
  end
end

---@return table[] recorded diagnostics (bounded copy)
function Client:diagnostics()
  return self._diagnostics
end

---@return integer number of in-flight pending requests
function Client:pending_count()
  local n = 0
  for _ in pairs(self._pending) do
    n = n + 1
  end
  return n
end

---@return boolean
function Client:is_closed()
  return self._closed
end

---@return boolean
function Client:is_initialized()
  return self._initialized
end

---@return table|nil the current process handle (nil when not started/closed)
function Client:process()
  return self.proc
end

--- Bump the connection generation: pending entries created under an older
--- generation are settled as cancelled (old generation), and any future
--- response for them is dropped with a generation_mismatch diagnostic.
---@param generation integer new generation
function Client:set_generation(generation)
  local old = self.generation
  self.generation = generation
  local pending = self._pending
  self._pending = {}
  for id, entry in pairs(pending) do
    if entry.timer then
      self.clock.cancel_timer(entry.timer)
    end
    self:_diagnostic(
      "generation_dropped",
      { id = id, method = entry.method, old_generation = old, generation = generation }
    )
    if entry.on_done then
      pcall(entry.on_done, nil, cancel_error(entry.method, "generation_replaced"))
    end
  end
end

--- Spawn the process and attach the read loop. May complete synchronously when
--- the process delivers data inline (fake processes).
---@return table|nil err typed error when the process cannot be started
function Client:start()
  local proc = self.process_factory(self.config)
  self.proc = proc
  proc.set_callbacks({
    on_stdout = function(data)
      self:_on_stdout(data)
    end,
    on_stderr = function(data)
      -- stderr is diagnostics only; the server layer owns the bounded buffer.
      if self.on_stderr then
        pcall(self.on_stderr, data)
      end
    end,
    on_exit = function(code, signal)
      self:_on_exit(code, signal)
    end,
  })
  local ok, err = pcall(proc.start, proc)
  if not ok then
    self._closed = true
    self.proc = nil
    return typed(
      schema.ERROR.NETWORK,
      ("mcp client %q: process start failed: %s"):format(self.server_id, tostring(err)),
      {
        reason = "spawn_error",
      }
    )
  end
  return nil
end

function Client:_on_stdout(data)
  if self._closed then
    return
  end
  self._buf = self._buf .. tostring(data or "")
  if #self._buf > M.MAX_BUFFER_BYTES then
    self._buf = ""
    self:_fail_all(
      protocol_error(("mcp client %q: frame buffer overflow (server never completed a frame)"):format(self.server_id))
    )
    return
  end
  local frames, rest, ferr = M.parse_frames(self._buf)
  if ferr then
    self._buf = ""
    self:_fail_all(protocol_error(("mcp client %q: framing error -- %s"):format(self.server_id, ferr)))
    return
  end
  self._buf = rest
  for _, body in ipairs(frames) do
    local msg, derr = M.decode_frame(body)
    if not msg then
      self:_fail_all(protocol_error(("mcp client %q: %s"):format(self.server_id, derr)))
      return
    end
    self:_on_message(msg)
  end
end

function Client:_on_exit(code, signal)
  if self._closed then
    return -- deliberate close; exit is expected
  end
  local err = network_error(
    ("mcp client %q: process exited unexpectedly (code=%s signal=%s)"):format(
      self.server_id,
      tostring(code),
      tostring(signal)
    ),
    {
      reason = "process_exit",
      code = code,
      signal = signal,
    }
  )
  self:_fail_all(err)
  if self.on_process_exit then
    pcall(self.on_process_exit, code, signal)
  end
end

--- Settle every pending request with a typed failure (transport/process loss).
---@param err table typed error
---@param cause? table|nil extra cause detail
function Client:_fail_all(err)
  if self._closed then
    return
  end
  local pending = self._pending
  self._pending = {}
  for id, entry in pairs(pending) do
    if entry.timer then
      self.clock.cancel_timer(entry.timer)
    end
    if entry.on_done then
      pcall(entry.on_done, nil, err)
    end
  end
end

--- Route one decoded message: response (with id), server request (with id +
--- method), or notification (method only).
---@param msg table decoded message
function Client:_on_message(msg)
  if msg.method ~= nil then
    if msg.id ~= nil then
      -- Server-initiated request: no sampling/roots support in W3; answer
      -- method-not-found so the server never waits on us.
      self:_write_response(msg.id, nil, { code = -32601, message = "method not found: " .. tostring(msg.method) })
    else
      if self.on_notification then
        pcall(self.on_notification, msg.method, msg.params or {})
      end
    end
    return
  end
  local id = msg.id
  local entry = self._pending[id]
  if not entry then
    -- Unknown id: a late response from an old connection/generation.
    self:_diagnostic("late_response", { id = id, closed = self._closed })
    return
  end
  if entry.generation ~= self.generation then
    self._pending[id] = nil
    self:_diagnostic("generation_mismatch", {
      id = id,
      method = entry.method,
      entry_generation = entry.generation,
      generation = self.generation,
    })
    return
  end
  self._pending[id] = nil
  if entry.timer then
    self.clock.cancel_timer(entry.timer)
  end
  if msg.error ~= nil then
    pcall(entry.on_done, nil, rpc_error(msg.error, entry.method))
  else
    pcall(entry.on_done, msg.result or {}, nil)
  end
end

--- Write a client request frame (records the request for diagnostics).
---@param msg table message
---@return table|nil err typed write error
function Client:_write(msg)
  if self._closed then
    return network_error("mcp client %q: client is closed"):format(self.server_id), { reason = "closed" }
  end
  if not self.proc then
    return network_error("mcp client %q: no process handle (not started)"):format(self.server_id),
      { reason = "no_process" }
  end
  self._requests[#self._requests + 1] = msg
  local ok, werr = pcall(self.proc.write, self.proc, M.encode_frame(msg))
  if not ok then
    return network_error(("mcp client %q: write failed: %s"):format(self.server_id, tostring(werr))),
      { reason = "write_error" }
  end
  return nil
end

--- Write a server-request response (used for method-not-found answers).
---@param id any request id
---@param result any|nil
---@param err table|nil error object
function Client:_write_response(id, result, err)
  local msg = { jsonrpc = "2.0", id = id }
  if err then
    msg.error = err
  else
    msg.result = result
  end
  pcall(self.proc.write, self.proc, M.encode_frame(msg))
end

--- Send a one-way notification.
---@param method string
---@param params table|nil
---@return table|nil err typed write error
function Client:notify(method, params)
  return self:_write({ jsonrpc = "2.0", method = method, params = params or {} })
end

--- Send a JSON-RPC request and await its response.
---
--- Completion is delivered through `on_done(result, err)`; the return value is
--- the pending request id (nil + typed err when the write failed immediately).
--- With synchronous (fake) processes the response may arrive inline during this
--- call, in which case on_done has already run when the call returns.
---
---@param method string
---@param params table|nil
---@param timeout_ms integer|nil per-request timeout (nil = no timeout)
---@param on_done fun(result: any, err: table|nil) completion callback
---@return integer|nil id pending request id
---@return table|nil err immediate typed write error
function Client:request(method, params, timeout_ms, on_done)
  if self._closed then
    return nil, network_error(("mcp client %q: client is closed"):format(self.server_id))
  end
  local id = self._next_id
  self._next_id = id + 1
  local entry = {
    id = id,
    method = method,
    generation = self.generation,
    timer = nil,
    on_done = on_done,
  }
  self._pending[id] = entry
  local werr = self:_write({ jsonrpc = "2.0", id = id, method = method, params = params or {} })
  if werr then
    self._pending[id] = nil
    return nil, werr
  end
  -- The response may have arrived inline (fake process); only arm the timer
  -- when the entry is still pending.
  if self._pending[id] then
    if type(timeout_ms) == "number" and timeout_ms > 0 then
      entry.timer = self.clock.schedule(timeout_ms, function()
        self:_settle(id, nil, timeout_error(method, timeout_ms))
      end)
    end
  end
  return id, nil
end

--- Settle a pending request (remove + cancel timer + deliver). No-op when the
--- entry is already gone (idempotent for inline responses and timers).
---@param id integer
---@param result any
---@param err table|nil
function Client:_settle(id, result, err)
  local entry = self._pending[id]
  if not entry then
    return
  end
  self._pending[id] = nil
  if entry.timer then
    self.clock.cancel_timer(entry.timer)
  end
  if entry.on_done then
    pcall(entry.on_done, result, err)
  end
end

--- Cancel a pending request: send `notifications/cancelled` and settle with a
--- typed CANCELLED error.
---@param id integer
---@param reason? string|nil
---@return boolean cancelled true when a pending request was cancelled
function Client:cancel(id, reason)
  local entry = self._pending[id]
  if not entry then
    return false
  end
  if entry.timer then
    self.clock.cancel_timer(entry.timer)
  end
  self._pending[id] = nil
  self:notify("notifications/cancelled", { requestId = id, reason = reason or "cancelled" })
  if entry.on_done then
    pcall(entry.on_done, nil, cancel_error(entry.method, reason))
  end
  return true
end

--- Cancel every pending request (stop/drain policy).
---@param reason? string|nil
---@return integer count cancelled
function Client:cancel_all(reason)
  local ids = {}
  for id in pairs(self._pending) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local n = 0
  for _, id in ipairs(ids) do
    if self:cancel(id, reason) then
      n = n + 1
    end
  end
  return n
end

--- Shut the client down: settle pending as NETWORK failure, close stdin, and
--- terminate the process. Later unexpected-exit callbacks are ignored (closed).
function Client:close()
  if self._closed then
    return
  end
  -- Settle pending BEFORE marking closed (_fail_all refuses closed clients).
  self:_fail_all(network_error(("mcp client %q: client closed"):format(self.server_id), { reason = "client_close" }))
  self._closed = true
  local proc = self.proc
  self.proc = nil
  if proc then
    pcall(proc.shutdown, proc)
    pcall(proc.close, proc)
  end
end

--- Run the initialize handshake: `initialize` -> validate serverInfo ->
--- `notifications/initialized`. Uses the startup timeout.
---@param on_done fun(server_info: table, err: table|nil)
---@return integer|nil id
---@return table|nil err immediate write error
function Client:initialize(on_done)
  return self:request(
    "initialize",
    {
      protocolVersion = M.PROTOCOL_VERSION,
      capabilities = { tools = { listChanged = false } },
      clientInfo = M.CLIENT_INFO,
    },
    self.startup_timeout_ms,
    function(result, err)
      if err then
        return on_done(nil, err)
      end
      if type(result) ~= "table" or type(result.serverInfo) ~= "table" then
        return on_done(
          nil,
          protocol_error(("mcp client %q: initialize response missing serverInfo"):format(self.server_id))
        )
      end
      self._initialized = true
      self.server_info = result
      self:notify("notifications/initialized", {})
      on_done(result, nil)
    end
  )
end

--- List tools with cursor pagination.
---@param on_done fun(tools: table[], err: table|nil)
---@return table|nil err immediate write error (nil = accepted)
function Client:list_tools(on_done)
  local all = {}
  local function page(cursor)
    local params = {}
    if cursor then
      params.cursor = cursor
    end
    local _, werr = self:request("tools/list", params, self.request_timeout_ms, function(result, err)
      if err then
        return on_done(nil, err)
      end
      local tools = result.tools
      if type(tools) ~= "table" then
        return on_done(nil, protocol_error(("mcp client %q: tools/list result missing tools"):format(self.server_id)))
      end
      for _, t in ipairs(tools) do
        all[#all + 1] = t
      end
      if result.nextCursor then
        page(result.nextCursor)
      else
        on_done(all, nil)
      end
    end)
    if werr then
      on_done(nil, werr)
    end
  end
  page(nil)
  return nil
end

--- Call a tool.
---@param name string tool name
---@param args table|nil arguments
---@param on_done fun(result: table, err: table|nil)
---@return integer|nil id
---@return table|nil err immediate write error
function Client:call_tool(name, args, on_done)
  return self:request(
    "tools/call",
    { name = name, arguments = args or {} },
    self.request_timeout_ms,
    function(result, err)
      if err then
        return on_done(nil, err)
      end
      if type(result) ~= "table" then
        return on_done(
          nil,
          protocol_error(("mcp client %q: tools/call returned a non-object result"):format(self.server_id))
        )
      end
      on_done(result, nil)
    end
  )
end

---@return table[] ordered client requests (diagnostics/tests)
function Client:requests()
  return self._requests
end

return M
