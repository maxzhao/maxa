-- filepath: tests/mcp/lib/harness.lua
--- Phase-3 W3 MCP-suite harness (test-only; never loaded by the runtime).
---
--- Builds an isolated MCP test environment:
---   * deterministic fake clock (tests.state.lib.fake_clock),
---   * fresh event bus (events.new(); carries the mcp.server_state constant),
---   * fresh tool registry (tools.registry.new()),
---   * scripted FAKE stdio processes implementing the client process contract
---     ({ set_callbacks, start, write, shutdown, close }): they auto-respond
---     to initialize/tools/list/tools/call from a per-process script, record
---     every received request, support delayed responses via the fake clock
---     (deterministic timeouts) and explicit stdout/exit/stderr emission.
---   * process_factory returns fake processes in spawn order and records them
---     (h.spawned / h.spawned_by_id), so fixtures can script and assert.
---
--- Fixtures use the same convention as tests/tools: fresh assert context per
--- fixture, print an OK marker on success, error(...) on failure.

local events = require("maxa.runtime.events")
local tools_registry = require("maxa.runtime.tools.registry")
local mcp_config = require("maxa.runtime.mcp.config")
local mcp_server = require("maxa.runtime.mcp.server")
local mcp_registry = require("maxa.runtime.mcp.registry")
local fake_clock = require("tests.state.lib.fake_clock")

local M = {}

--- Default fake-server script: a well-behaved MCP server with two tools
--- (alpha/beta). `tools/call` echoes the tool name.
M.DEFAULT_SCRIPT = {
  ["initialize"] = function()
    return {
      protocolVersion = "2024-11-05",
      capabilities = { tools = { listChanged = false } },
      serverInfo = { name = "fake-mcp", version = "1.0.0" },
    }
  end,
  ["tools/list"] = function()
    return {
      tools = {
        {
          name = "alpha",
          description = "fake tool alpha",
          inputSchema = { type = "object", properties = { x = { type = "number" } } },
        },
        {
          name = "beta",
          description = "fake tool beta",
          inputSchema = { type = "object", properties = {} },
        },
      },
    }
  end,
  ["tools/call"] = function(params)
    return { content = { { type = "text", text = ("called:%s"):format(params.name) } } }
  end,
}

--- Encode one JSON-RPC message as a Content-Length frame.
---@param msg table
---@return string
function M.encode_frame(msg)
  local body = vim.json.encode(msg)
  return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

---@param body string frame body
---@return table msg
local function decode_body(body)
  local ok, msg = pcall(vim.json.decode, body)
  if not ok or type(msg) ~= "table" then
    error("harness: malformed JSON frame from client: " .. tostring(body))
  end
  return msg
end

--- Parse complete frames out of a buffer (same framing as the client).
---@param buf string
---@return string[] frames
---@return string rest
local function parse_frames(buf)
  local frames, rest = {}, buf
  while true do
    local sep
    local crlf = rest:find("\r\n\r\n", 1, true)
    local lf = rest:find("\n\n", 1, true)
    if crlf and lf then
      sep = crlf < lf and "\r\n\r\n" or "\n\n"
    elseif crlf then
      sep = "\r\n\r\n"
    elseif lf then
      sep = "\n\n"
    else
      return frames, rest
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
      error("harness: missing Content-Length in client frame")
    end
    local body_start = start + #sep
    if #rest < body_start + content_length - 1 then
      return frames, rest
    end
    frames[#frames + 1] = rest:sub(body_start, body_start + content_length - 1)
    rest = rest:sub(body_start + content_length)
  end
end

--- Create a fake stdio process.
---
--- Behavior:
---   * `start()` marks started and runs `on_spawn(self)` (may emit stdout/exit
---     inline, simulating a process that dies immediately).
---   * `write(data)` decodes client frames; for each request with a method in
---     `script` (and not in `no_response`) it emits a response after
---     `respond_delay` ms (0 = inline; >0 = scheduled on the fake clock).
---     Requests are recorded in `requests` ({ method, params, id }).
---   * `emit(data)` / `emit_at(delay, data)` / `emit_exit(code, signal)` /
---     `emit_stderr(data)` let fixtures drive the fake.
---   * `close()` marks closed WITHOUT emitting exit (deliberate close);
---     `emit_exit` simulates an unexpected exit.
---
---@param opts table { clock, script?, on_spawn?, respond_delay? }
---@return table proc
function M.fake_process(opts)
  local self = {
    clock = opts.clock,
    script = vim.deepcopy(opts.script or M.DEFAULT_SCRIPT),
    on_spawn = opts.on_spawn,
    respond_delay = opts.respond_delay or 0,
    no_response = opts.no_response or {}, -- method -> true: never auto-respond
    cbs = {},
    started = false,
    closed = false,
    exited = false,
    writes = {}, -- raw client frames (diagnostics)
    requests = {}, -- decoded client requests (order preserved)
    notifications = {}, -- decoded notifications (method -> count)
    cancelled = {}, -- notifications/cancelled requestId list
    buf_stdin = "",
  }
  function self.set_callbacks(cbs)
    self.cbs = cbs or {}
  end
  -- Colon methods: the client invokes them with the process as the first
  -- argument (pcall(proc.start, proc) / pcall(proc.write, proc, frame) ...).
  -- set_callbacks stays a plain single-arg function (client dot-calls it).
  function self:start()
    self.started = true
    if self.on_spawn then
      self.on_spawn(self)
    end
  end
  function self:write(data)
    if self.closed or self.exited then
      -- A dead process cannot respond (unexpected-exit scenarios).
      self.writes[#self.writes + 1] = data
      return
    end
    self.writes[#self.writes + 1] = data
    self.buf_stdin = self.buf_stdin .. tostring(data or "")
    local frames, rest = parse_frames(self.buf_stdin)
    self.buf_stdin = rest
    for _, body in ipairs(frames) do
      local msg = decode_body(body)
      if msg.id ~= nil and msg.method then
        self.requests[#self.requests + 1] = { method = msg.method, params = msg.params or {}, id = msg.id }
        if self.no_response[msg.method] then
          -- fixture chooses when/how to answer (timeout scenarios)
        else
          local handler = self.script[msg.method]
          if handler then
            local result, err = handler(msg.params or {})
            local resp = err and { jsonrpc = "2.0", id = msg.id, error = err }
              or { jsonrpc = "2.0", id = msg.id, result = result }
            self:emit_at(self.respond_delay, M.encode_frame(resp))
          end
        end
      elseif msg.id == nil and msg.method then
        self.notifications[msg.method] = (self.notifications[msg.method] or 0) + 1
        if msg.method == "notifications/cancelled" and msg.params and msg.params.requestId ~= nil then
          self.cancelled[#self.cancelled + 1] = msg.params.requestId
        end
      end
    end
  end
  function self:shutdown()
    self.stdin_closed = true
  end
  function self:close()
    self.closed = true
  end
  function self:emit(data)
    if self.cbs.on_stdout then
      pcall(self.cbs.on_stdout, data)
    end
  end
  function self:emit_at(delay, data)
    if delay and delay > 0 then
      self.clock.schedule(delay, function()
        self:emit(data)
      end)
    else
      self:emit(data)
    end
  end
  function self:emit_exit(code, signal)
    if self.exited or self.closed then
      return
    end
    self.exited = true
    if self.cbs.on_exit then
      pcall(self.cbs.on_exit, code, signal)
    end
  end
  function self:emit_stderr(data)
    if self.cbs.on_stderr then
      pcall(self.cbs.on_stderr, data)
    end
  end
  return self
end

--- Build a fresh harness.
---@param opts table {
---   scripts?: { [server_id] = script }|nil per-server scripts,
---   spawn_configs?: { [spawn_index] = { respond_delay, on_spawn, script } }|nil,
--- }
---@return table h { clock, bus, tool_reg, spawned, spawned_by_id, process_factory }
function M.new(opts)
  opts = opts or {}
  local h = {
    clock = fake_clock.new(),
    bus = events.new(),
    tool_reg = tools_registry.new(),
    spawned = {},
    spawned_by_id = {},
    scripts = opts.scripts or {},
    spawn_configs = opts.spawn_configs or {},
  }

  function h.process_factory(cfg)
    local n = #h.spawned + 1
    local extra = h.spawn_configs[n] or {}
    local proc = M.fake_process({
      clock = h.clock,
      script = h.scripts[cfg.id] or extra.script,
      on_spawn = extra.on_spawn,
      respond_delay = extra.respond_delay or 0,
      no_response = extra.no_response or {},
    })
    h.spawned[n] = proc
    h.spawned_by_id[cfg.id] = (h.spawned_by_id[cfg.id] or 0) + 1
    return proc
  end

  --- Create an external server bound to this harness.
  ---@param cfg table normalized server record (mcp.config.load per-server)
  ---@return table server
  function h.server(cfg)
    return mcp_server.new({
      cfg = cfg,
      events = h.bus,
      clock = h.clock,
      tool_registry = h.tool_reg,
      process_factory = h.process_factory,
    })
  end

  --- Create a registry bound to this harness.
  ---@return table registry
  function h.registry()
    return mcp_registry.new({
      events = h.bus,
      clock = h.clock,
      tool_registry = h.tool_reg,
      process_factory = h.process_factory,
    })
  end

  --- Build a normalized config record for one server (bypasses the file).
  ---@param id string server id
  ---@param overrides table|nil field overrides
  ---@return table cfg
  function h.cfg(id, overrides)
    local base = {
      id = id,
      enabled = true,
      transport = "stdio",
      command = "fake-bin-" .. id,
      args = {},
      env = {},
      cwd = "/tmp/project-" .. id,
      request_timeout_ms = 1000,
      startup_timeout_ms = 5000,
      env_secret_keys = {},
      secret_args = {},
      cwd_secret = false,
    }
    for k, v in pairs(overrides or {}) do
      base[k] = v
    end
    return base
  end

  --- Create a temporary project root with a servers.yaml file.
  ---@param yaml_text string servers.yaml content
  ---@param name string|nil fixture name
  ---@return string root
  function h.write_project(yaml_text, name)
    local root = vim.fn.tempname() .. "-" .. (name or "mcp")
    vim.fn.mkdir(root .. "/.maxa/mcp", "p")
    local fh = assert(io.open(root .. "/.maxa/mcp/servers.yaml", "wb"))
    fh:write(yaml_text)
    fh:close()
    return root
  end

  --- Remove a temporary project root (best effort).
  ---@param root string
  function h.cleanup(root)
    pcall(vim.fn.delete, root, "rf")
  end

  return h
end

--- Convenience: attach a recorder to the harness bus.
---@param h table harness
---@return table rec (tests.state.lib.recorder)
function M.recorder(h)
  local recorder = require("tests.state.lib.recorder")
  local rec = recorder.new({ skip = {} })
  rec.attach(h.bus)
  return rec
end

return M
