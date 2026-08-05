-- filepath: lua/maxa/runtime/mcp/server.lua
--- maxa external MCP server lifecycle (phase-3 W3).
---
--- Contract (see `specs/runtime-fixture-contract.md` §MCP lifecycle and
--- `specs/modules/mcp-skill-runtime/spec.md` §Server registry and lifecycle):
---
--- State machine (external process):
---   disabled -> stopped -> starting -> connected -> stopping -> stopped
---                          |             |
---                          v             v
---                        failed <---- reconnecting
---   plus `unavailable` (config-level: missing env reference; no process).
---
--- Rules:
---   * start/stop/restart/reload are idempotent by operation key: a single
---     in-flight operation owns the transition; concurrent calls join it
---     ({ joined = true }). stop() may interrupt an in-flight start/reconnect
---     (replaces the op key) so shutdown always wins.
---   * capabilities (tools) are published ONLY after the server is connected
---     (initialize + tools/list succeeded), each publish bumps
---     `capabilities_revision`; tools are registered into the tool registry
---     with id `server-id/tool-name`.
---   * stop/reload: block new calls (`accepting_calls=false`), cancel/drain
---     owned requests (typed CANCELLED), remove capabilities, then terminate
---     the process. The request-timeout policy retains the connection
---     (independent request failure; restart is an explicit action).
---   * generation increments per process spawn; the client rejects responses
---     from an older generation (late-response diagnostics). Transport/process
---     loss fails all pending calls with typed errors so ToolBatch cannot hang.
---   * process stderr is bounded (line + byte caps), sanitized, and kept as
---     diagnostics only (never model context).
---   * every state transition emits `mcp.server_state`
---     { server_id, state, revision, reason, kind, generation } exactly once.
---
--- Dependencies: `maxa.runtime.schema`, `maxa.runtime.clock`,
--- `maxa.runtime.mcp.client`. Never loads codecompanion.* / mcphub.* /
--- lua/util/hooks/*.

local schema = require("maxa.runtime.schema")
local clock_lib = require("maxa.runtime.clock")
local client_mod = require("maxa.runtime.mcp.client")

local M = {}
M.name = "mcp.server"

--- External server states (lifecycle machine).
M.STATES = {
  disabled = "disabled",
  stopped = "stopped",
  starting = "starting",
  connected = "connected",
  stopping = "stopping",
  failed = "failed",
  reconnecting = "reconnecting",
  unavailable = "unavailable",
}

--- Operation keys (idempotent by operation key).
M.OPS = { start = "start", stop = "stop", restart = "restart", reload = "reload", reconnect = "reconnect" }

--- stderr bounded buffer limits (diagnostics only).
M.STDERR_MAX_LINES = 200
M.STDERR_MAX_BYTES = 16384
--- Max recorded server diagnostics (bounded memory).
M.DIAG_CAP = 256

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

---@param code string schema.ERROR.*
---@param message string
---@param cause? table|nil
---@return table err
local function typed(code, message, cause)
  return schema.new_error(code, message, cause)
end

--- Sanitize a stderr chunk: strip ANSI escape sequences and control characters
--- (keeps \n and \t), so raw terminal noise never leaks into diagnostics.
---@param data string
---@return string
local function sanitize_stderr(data)
  local s = tostring(data or ""):gsub("\27%[%d+;%d+[a-zA-Z]", ""):gsub("\27%[[%d;]*[a-zA-Z]", ""):gsub("\27%]%d+;", "")
  s = s:gsub("[%z\1-\8\11-\12\14-\31\127]", "")
  return s
end

--- Normalize an MCP tools/call result into tool-result text (join text parts;
--- fall back to structuredContent/JSON so the result is never empty).
---@param result table MCP tools/call result
---@return string
local function mcp_result_text(result)
  if type(result.content) == "table" then
    local parts = {}
    for _, part in ipairs(result.content) do
      if type(part) == "table" and type(part.text) == "string" then
        parts[#parts + 1] = part.text
      end
    end
    if #parts > 0 then
      return table.concat(parts, "\n")
    end
  end
  if result.structuredContent ~= nil then
    local ok, encoded = pcall(vim.json.encode, result.structuredContent)
    if ok then
      return encoded
    end
  end
  return vim.json.encode(result)
end

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------

local Server = {}
Server.__index = Server

--- Create an external MCP server instance.
---@param opts table {
---   cfg: table normalized server record (mcp.config.load output),
---   events?: table|nil event bus (events.new() instance; emit mcp.server_state),
---   clock?: table|nil deterministic clock,
---   tool_registry?: table|nil tools registry (registration/unregister),
---   process_factory?: fun(config)->process|nil (default stdio_process_factory),
---   reconnect_max?: integer|nil reconnect attempts after an unexpected exit,
--- }
---@return table server
function M.new(opts)
  assert(type(opts) == "table" and type(opts.cfg) == "table", "mcp.server.new: cfg required")
  local cfg = opts.cfg
  local enabled = cfg.enabled ~= false
  return setmetatable({
    id = cfg.id,
    kind = opts.kind or "external",
    cfg = cfg,
    events = opts.events,
    clock = opts.clock or clock_lib.default(),
    tool_registry = opts.tool_registry,
    process_factory = opts.process_factory or client_mod.stdio_process_factory,
    reconnect_max = opts.reconnect_max or 1,
    state = enabled and M.STATES.stopped or M.STATES.disabled,
    accepting_calls = enabled,
    generation = 0,
    capabilities = {},
    capabilities_revision = 0,
    state_revision = 0,
    server_info = nil,
    client = nil,
    process_handle = nil,
    last_error = nil,
    op = nil,
    _op_seq = 0,
    _registered_tools = {},
    _tool_names = {},
    _task_slots = {},
    _reconnect_attempts = 0,
    _stderr_tail = {},
    _stderr_bytes = 0,
    diagnostics = {},
  }, Server)
end

---@return integer
function Server:_next_op_id()
  self._op_seq = self._op_seq + 1
  return self._op_seq
end

---@return boolean true when an operation owns the transition
function Server:_op_running()
  return self.op ~= nil
end

--- End the operation only when this flow owns it (never steals a stop op).
function Server:_end_op_if_flow_owner()
  if self.op and self.op.key ~= M.OPS.stop then
    self.op = nil
  end
end

---@param message string
---@param cause? table|nil
---@return table err
function Server:_network_error(message, cause)
  return typed(schema.ERROR.NETWORK, message, cause)
end

--- Record a bounded diagnostic (server-level).
---@param kind string
---@param info table|nil
function Server:_record_diagnostic(kind, info)
  self.diagnostics[#self.diagnostics + 1] = { kind = kind, info = info or {}, at_ms = self.clock.now_ms() }
  if #self.diagnostics > M.DIAG_CAP then
    table.remove(self.diagnostics, 1)
  end
end

--- Record a stderr chunk into the bounded tail (line + byte caps, sanitized).
---@param data string
function Server:_on_stderr(data)
  local sanitized = sanitize_stderr(data)
  if sanitized == "" then
    return
  end
  self._stderr_tail[#self._stderr_tail + 1] = sanitized
  self._stderr_bytes = self._stderr_bytes + #sanitized
  while #self._stderr_tail > M.STDERR_MAX_LINES or self._stderr_bytes > M.STDERR_MAX_BYTES do
    local first = table.remove(self._stderr_tail, 1)
    if first then
      self._stderr_bytes = self._stderr_bytes - #first
    end
  end
end

---@return string current bounded stderr tail (diagnostics only)
function Server:stderr_diagnostics()
  return table.concat(self._stderr_tail, "")
end

--- State transition: set state, bump the monotonic state revision, and emit
--- `mcp.server_state` exactly once per transition.
---@param state string M.STATES.*
---@param reason string transition reason (start/stop/ready/process_exit/...)
function Server:_set_state(state, reason)
  self.state = state
  self.state_revision = self.state_revision + 1
  if self.events then
    -- The events bus methods are plain closures (no self parameter): emit is
    -- called without the bus as an explicit receiver.
    pcall(self.events.emit, self.events.events.mcp_server_state, {
      server_id = self.id,
      state = state,
      revision = self.state_revision,
      reason = reason,
      kind = self.kind,
      generation = self.generation,
      capabilities_revision = self.capabilities_revision,
    })
  end
end

--- Remove capabilities: unregister every registered tool, clear the
--- capabilities snapshot. The revision counter is NOT reset (it counts
--- publishes; the next publish increments it).
function Server:_remove_capabilities()
  for id in pairs(self._registered_tools) do
    if self.tool_registry and type(self.tool_registry.unregister) == "function" then
      self.tool_registry:unregister(id)
    end
  end
  self._registered_tools = {}
  self._tool_names = {}
  self.capabilities = {}
end

--- Publish capabilities after a successful handshake (connected gate):
--- register every listed tool into the tool registry (id server-id/tool-name).
--- Invalid tool definitions are recorded as diagnostics; the connection stays.
---@param tools table[] MCP tools/list tools
function Server:_publish_capabilities(tools)
  self.capabilities = { tools = tools }
  self.capabilities_revision = self.capabilities_revision + 1
  for _, tool in ipairs(tools) do
    if type(tool) ~= "table" or type(tool.name) ~= "string" or tool.name == "" then
      self:_record_diagnostic("tool_definition_invalid", { tool = tool })
    else
      local def, derr = self:_make_tool_definition(tool)
      if not def then
        self:_record_diagnostic(
          "tool_register_invalid",
          { name = tool.name, err = derr and derr.message or "definition failed" }
        )
      else
        local registered, regerr = self.tool_registry:register(def)
        if regerr then
          self:_record_diagnostic("tool_register_error", { name = tool.name, err = regerr.message })
        else
          self._registered_tools[registered.id] = true
          self._tool_names[registered.name] = true
        end
      end
    end
  end
end

--- Build a tool-registry definition for one MCP tool. The `run` handler issues
--- `tools/call` through this server and completes the executor task with the
--- normalized result; `cancel` maps to client:cancel by request id.
---@param tool table MCP tool definition
---@return table|nil def
---@return table|nil err
function Server:_make_tool_definition(tool)
  if not self.tool_registry then
    return nil, typed(schema.ERROR.INTERNAL, ("mcp server %q: no tool registry bound"):format(self.id))
  end
  local tool_name = tool.name
  local slot = {}
  local function cleanup_slot()
    for rid, s in pairs(self._task_slots) do
      if s == slot then
        self._task_slots[rid] = nil
      end
    end
  end
  local def = {
    id = self.id .. "/" .. tool_name,
    name = tool_name,
    description = type(tool.description) == "string" and tool.description or "",
    input_schema = type(tool.inputSchema) == "table" and tool.inputSchema or { type = "object", properties = {} },
    execution = { mode = "async", timeout_ms = nil, cancellable = true, side_effect = "process" },
    result = { durable = true, display = "summary" },
    run = function(args, ctx, task)
      slot.task = task
      local rid, err = self:call_tool(tool_name, args, function(result, cerr)
        cleanup_slot()
        -- The task completion contract is task.complete(value[, caller]) — the
        -- executor-owned task object is NOT passed as the value (that would
        -- normalize to an empty content and break the barrier).
        if cerr then
          pcall(task.complete, { status = "error", content = cerr.message })
        else
          pcall(
            task.complete,
            { status = result.isError == true and "error" or "success", content = mcp_result_text(result) }
          )
        end
      end)
      if not rid then
        cleanup_slot()
        pcall(task.complete, {
          status = "error",
          content = err and err.message or ("mcp call failed: " .. tool_name),
        })
      else
        slot.request_id = rid
        self._task_slots[rid] = slot
      end
    end,
    cancel = function()
      if slot.request_id then
        local client = self.client
        if client then
          client:cancel(slot.request_id, "tool_cancel")
        end
      end
    end,
  }
  return def, nil
end

--- Reap the current client/process handle (close process, drop references).
function Server:_reap_client()
  local client = self.client
  self.client = nil
  self.process_handle = nil
  if client then
    client:close()
  end
end

---@return integer number of owned in-flight requests
function Server:owned_count()
  local client = self.client
  return client and client:pending_count() or 0
end

--- Call one of this server's tools (only while connected and accepting).
---@param name string tool name
---@param args table|nil arguments
---@param on_done fun(result: table|nil, err: table|nil) completion callback
---@return integer|nil id pending request id (nil on immediate failure)
---@return table|nil err typed error on immediate failure
function Server:call_tool(name, args, on_done)
  if self.state ~= M.STATES.connected or not self.accepting_calls then
    return nil,
      typed(schema.ERROR.INVALID_REQUEST, ("mcp server %q not accepting calls (state=%s)"):format(self.id, self.state))
  end
  if not self._tool_names[name] then
    return nil, typed(schema.ERROR.INVALID_REQUEST, ("mcp server %q has no tool %q"):format(self.id, tostring(name)))
  end
  local client = self.client
  if not client then
    return nil, self:_network_error(("mcp server %q: no client (state=%s)"):format(self.id, self.state))
  end
  return client:call_tool(name, args, function(result, err)
    if err then
      -- Enrich transport-level errors with the tool name for diagnostics
      -- (the client only knows the JSON-RPC method, e.g. "tools/call").
      on_done(nil, {
        code = err.code,
        message = ("mcp tool %q: %s"):format(name, err.message),
        cause = err.cause,
        terminal = err.terminal,
      })
      return
    end
    on_done(result, nil)
  end)
end

--------------------------------------------------------------------------------
-- Start flow
--------------------------------------------------------------------------------

--- Spawn a new connection and run initialize -> tools/list -> publish.
--- Assumes the operation owns the transition (self.op set by the caller).
function Server:_do_start()
  -- Reap any previous connection (restart/reconnect/reload path).
  self:_reap_client()
  -- The new generation is assigned BEFORE the starting transition so the
  -- state event already carries the generation of the coming process.
  self.generation = self.generation + 1
  self:_set_state(M.STATES.starting, "start")
  local client = client_mod.new({
    server_id = self.id,
    config = self.cfg,
    clock = self.clock,
    process_factory = self.process_factory,
    generation = self.generation,
    on_notification = function(method, params)
      self:_record_diagnostic("notification", { method = method, params = params })
    end,
    on_diagnostic = function(kind, info)
      self:_record_diagnostic(kind, info)
    end,
    on_process_exit = function(code, signal)
      self:_on_connection_lost(code, signal)
    end,
  })
  client.on_stderr = function(data)
    self:_on_stderr(data)
  end
  self.client = client
  self.process_handle = client.proc
  local serr = client:start()
  if serr then
    return self:_startup_failed(serr, "spawn_error")
  end
  self.process_handle = client:process()
  local _, ierr = client:initialize(function(server_info, err)
    if err then
      return self:_startup_failed(err, "initialize")
    end
    self.server_info = server_info
    client:list_tools(function(tools, lerr)
      if lerr then
        return self:_startup_failed(lerr, "tools_list")
      end
      -- Connected gate: capabilities are published only now.
      self.accepting_calls = true
      self:_publish_capabilities(tools)
      self:_set_state(M.STATES.connected, "ready")
      self:_end_op_if_flow_owner()
    end)
  end)
  if ierr then
    return self:_startup_failed(ierr, "initialize_write")
  end
end

--- Startup failure: transition to failed with a typed cause, reap the handle.
---@param err table typed error
---@param reason string state-event reason
function Server:_startup_failed(err, reason)
  if self.state ~= M.STATES.starting then
    return -- a stop/reload took over; the flow is no longer ours
  end
  self.last_error = err
  self.accepting_calls = false
  self:_reap_client()
  self:_set_state(M.STATES.failed, reason)
  self:_end_op_if_flow_owner()
end

--- Unexpected process exit while connected: reconnect policy (bounded attempts),
--- then failed. While starting, the startup fails immediately.
---@param code integer|nil
---@param signal integer|nil
function Server:_on_connection_lost(code, signal)
  local cause = { reason = "process_exit", code = code, signal = signal }
  if self.state == M.STATES.starting then
    return self:_startup_failed(
      self:_network_error(
        ("mcp server %q: process exited during startup (code=%s signal=%s)"):format(
          self.id,
          tostring(code),
          tostring(signal)
        ),
        cause
      ),
      "process_exit"
    )
  end
  if self.state ~= M.STATES.connected then
    return -- stopping/stopped: deliberate close paths handle their own state
  end
  self._reconnect_attempts = self._reconnect_attempts + 1
  self:_set_state(M.STATES.reconnecting, "process_exit")
  if self._reconnect_attempts > self.reconnect_max then
    self.last_error = self:_network_error(
      ("mcp server %q: reconnect exhausted after %d attempt(s)"):format(self.id, self.reconnect_max),
      cause
    )
    self:_reap_client()
    self:_set_state(M.STATES.failed, "reconnect_exhausted")
    return
  end
  self.op = { key = M.OPS.reconnect, id = self:_next_op_id() }
  self:_do_start()
end

--------------------------------------------------------------------------------
-- Stop flow
--------------------------------------------------------------------------------

--- Perform the stop transition (op assumed set; does not manage self.op).
function Server:_do_stop()
  if self.state == M.STATES.stopped or self.state == M.STATES.disabled or self.state == M.STATES.unavailable then
    return
  end
  self:_set_state(M.STATES.stopping, "stop")
  self.accepting_calls = false
  local client = self.client
  if client then
    -- Drain/cancel owned requests: every pending call settles with a typed
    -- CANCELLED error (ToolBatch cannot hang on shutdown).
    client:cancel_all("stop")
  end
  self:_remove_capabilities()
  self:_reap_client()
  self:_set_state(M.STATES.stopped, "stop")
end

--------------------------------------------------------------------------------
-- Public lifecycle API (idempotent by operation key)
--------------------------------------------------------------------------------

--- Start the server. Idempotent: joins an in-flight start/reconnect/stop.
---@return table|nil result { joined=boolean, already=boolean|nil, state=string }
---@return table|nil err typed error (disabled/unavailable start)
function Server:start()
  if self.state == M.STATES.starting or self.state == M.STATES.reconnecting or self.state == M.STATES.stopping then
    return { joined = true, op = self.op, state = self.state }, nil
  end
  if self.state == M.STATES.connected then
    return { joined = false, already = true, state = self.state }, nil
  end
  if self.state == M.STATES.disabled then
    return nil, typed(schema.ERROR.INVALID_ARGUMENT, ("mcp server %q is disabled and cannot start"):format(self.id))
  end
  if self.state == M.STATES.unavailable then
    return nil, typed(schema.ERROR.PROVIDER_UNAVAILABLE, ("mcp server %q is unavailable"):format(self.id))
  end
  if self.op then
    return { joined = true, op = self.op, state = self.state }, nil
  end
  self.op = { key = M.OPS.start, id = self:_next_op_id() }
  self._reconnect_attempts = 0
  self:_do_start()
  return { joined = false, state = self.state }, nil
end

--- Stop the server: drain/cancel owned requests, remove capabilities,
--- terminate the process. May interrupt an in-flight start/reconnect/restart.
---@return table result { joined=boolean, already=boolean|nil, state=string }
function Server:stop()
  if self.state == M.STATES.stopped or self.state == M.STATES.disabled or self.state == M.STATES.unavailable then
    return { joined = false, already = true, state = self.state }
  end
  if self.state == M.STATES.stopping then
    return { joined = true, op = self.op, state = self.state }
  end
  -- Interrupt an in-flight start/reconnect/restart flow: shutdown wins.
  if not self.op then
    self.op = { key = M.OPS.stop, id = self:_next_op_id() }
  else
    self.op.key = M.OPS.stop
  end
  self:_do_stop()
  self.op = nil
  return { joined = false, state = self.state }
end

--- Restart the server (stop + start under ONE operation owner). A concurrent
--- restart/start/stop joins the in-flight operation.
---@return table result { joined=boolean, ok=boolean|nil, state=string }
---@return table|nil err typed error
function Server:restart()
  if self.op then
    return { joined = true, op = self.op, state = self.state }, nil
  end
  if self.state == M.STATES.disabled then
    return nil, typed(schema.ERROR.INVALID_ARGUMENT, ("mcp server %q is disabled and cannot restart"):format(self.id))
  end
  self.op = { key = M.OPS.restart, id = self:_next_op_id() }
  self._reconnect_attempts = 0
  self:_do_stop()
  if self.state == M.STATES.stopped then
    self:_do_start()
  end
  return { joined = false, ok = self.state == M.STATES.connected, state = self.state }, nil
end

--- Reload with a new config snapshot (stop + start under one owner; the new
--- snapshot is applied before the start so the process uses the new command).
---@param new_cfg table normalized server record
---@return table result { joined=boolean, ok=boolean|nil, state=string }
---@return table|nil err typed error
function Server:reload(new_cfg)
  if self.op then
    return { joined = true, op = self.op, state = self.state }, nil
  end
  if self.state == M.STATES.disabled then
    self.cfg = new_cfg
    return { joined = false, ok = false, state = self.state }, nil
  end
  self.op = { key = M.OPS.reload, id = self:_next_op_id() }
  self._reconnect_attempts = 0
  self:_do_stop()
  self.cfg = new_cfg
  if self.state == M.STATES.stopped then
    self:_do_start()
  end
  return { joined = false, ok = self.state == M.STATES.connected, state = self.state }, nil
end

return M
