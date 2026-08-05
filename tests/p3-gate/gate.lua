-- filepath: tests/p3-gate/gate.lua
--- Phase-3 W8 gate end-to-end test (headless, offline).
---
--- Chains the real W1-W7 surfaces through ONE provider response:
---   * external MCP: `.maxa/mcp/servers.yaml` discovery -> mcp registry ->
---     REAL node stdio fixture process (tests/mcp/fixtures/stdio_server.mjs)
---     -> initialize/tools/list -> tool registered (fixture-echo/echo) ->
---     tools/call JSON-RPC round trip;
---   * skill tool registration: loader with a tool registry activates
---     demo-echo (repo-root bundled skill) and registers skills/demo-echo/
---     tools/echo.lua as demo-echo/echo;
---   * host submit: the scripted mock provider emits TWO tool calls
---     (fixture-echo/echo + demo-echo/echo); both execute, results persist as
---     role="tool" messages BEFORE the batch barrier, the barrier fires exactly
---     once, continuation.decided fires exactly once, and exactly one automatic
---     continuation request completes the chain; the host renders tool lines /
---     fold headers / result-detail projections;
---   * W1 real-path assembly: `maxa.runtime.assemble` wires tool registry +
---     mcp + skills in ONE call (the UI/boot path) and its teardown is
---     idempotent;
---   * W1 request tools: a REAL openai_chat adapter turns the assembled
---     registry into body.tools (name = registry id encoded for the wire
---     (`/` -> `-`; OpenAI/Anthropic/Gemini reject `/` in function names),
---     description, parameters as a per-provider copy).
---
--- Guardrails:
---   * import-guard (no codecompanion.*/mcphub.*/lua/util/hooks/*);
---   * `.supermax/` is never read: mcp config source is the temp project's
---     `.maxa/mcp/servers.yaml`, discovery roots never contain `.supermax`,
---     the demo skill record resolves from the repo-root `skills/`;
---   * no network: the fixture is a local node process (stdio only); the
---     protocol HTTP transport module, if loaded, is ONLY the fake test seam
---     injected for the adapter request-construction assertion — the real
---     curl transport is never loaded.
---
--- Run (just test-gate):
---   NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
---     local d='<root>/tests/p3-gate/gate.lua' local ok=pcall(dofile,d)
---     vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
--- Exit 0 on success; 1 (cq) on any failed assertion.

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/p3-gate")
local root = dir:match("^(.*)/tests/p3-gate$") or "/home/maxzhao/maxa"

-- Preload shared helpers (same convention as the suite runners; keeps this
-- file runnable regardless of runtimepath layout).
package.loaded["tests.state.lib.assert"] = dofile(root .. "/tests/state/lib/assert.lua")
package.loaded["tests.state.lib.fake_clock"] = dofile(root .. "/tests/state/lib/fake_clock.lua")
package.loaded["tests.state.lib.recorder"] = dofile(root .. "/tests/state/lib/recorder.lua")

local assert_mod = require("tests.state.lib.assert")
local recorder_mod = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local tools_registry = require("maxa.runtime.tools.registry")
local mcp_config = require("maxa.runtime.mcp.config")
local mcp_registry = require("maxa.runtime.mcp.registry")
local discover_mod = require("maxa.runtime.skills.discover")
local loader_mod = require("maxa.runtime.skills.loader")
local host = require("maxa.runtime.host.nvim")
local normalize = require("maxa.runtime.protocol.normalize")
local runtime = require("maxa.runtime")

local A = assert_mod.new()

local function has_line(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Environment prerequisite: the gate spawns a REAL node process (local only).
A.check(vim.fn.executable("node") == 1, "gate: node executable available")

-- -----------------------------------------------------------------------------
-- 1. Temp project root: `.maxa/mcp/servers.yaml` -> fixture node server;
--    `.maxa/skills/` deliberately ABSENT (gate contract: empty or nonexistent).
-- -----------------------------------------------------------------------------
local tmp = vim.fn.tempname() .. "-p3gate"
vim.fn.mkdir(tmp .. "/.maxa/mcp", "p")
local fixture = root .. "/tests/mcp/fixtures/stdio_server.mjs"
local yaml = ("schema_version: 1\nservers:\n  fixture-echo:\n    enabled: true\n    transport: stdio\n    command: node\n    args: [%q]\n    cwd: %q\n    request_timeout_ms: 10000\n    startup_timeout_ms: 10000\n"):format(
  fixture,
  root
)
do
  local fh = assert(io.open(tmp .. "/.maxa/mcp/servers.yaml", "wb"))
  fh:write(yaml)
  fh:close()
end

-- -----------------------------------------------------------------------------
-- 2. MCP discovery -> registry -> REAL process spawn -> connected.
-- -----------------------------------------------------------------------------
local bus = events.new()
local tool_reg = tools_registry.new()
local rec = recorder_mod.new() -- default skip: session.created
rec.attach(bus)

local cfg, cerr = mcp_config.load(tmp)
A.check(cfg ~= nil, "gate: servers.yaml loads (err=" .. tostring(cerr and cerr.message) .. ")")
if cfg then
  A.check(cfg.servers["fixture-echo"] ~= nil, "gate: fixture-echo server discovered")
  A.check(next(cfg.unavailable) == nil, "gate: no unavailable servers")
  A.assert_eq(
    cfg.source,
    tmp .. "/.maxa/mcp/servers.yaml",
    "gate: config source is the temp project .maxa file (never .supermax)"
  )
  A.check(cfg.source:find(".supermax", 1, true) == nil, "gate: config source has no .supermax reference")
  A.check(cfg.project_root:find(".supermax", 1, true) == nil, "gate: project root has no .supermax reference")
end

local reg = mcp_registry.new({ events = bus, tool_registry = tool_reg }) -- real clock + real process factory
local apply =
  reg:apply_config(cfg or { version = 1, project_root = tmp, servers = {}, unavailable = {}, warnings = {} })
A.assert_eq(#apply.errors, 0, "gate: apply_config has no registration errors")
A.check(vim.tbl_contains(apply.added, "fixture-echo"), "gate: fixture-echo added")

local entry = reg:get("fixture-echo")
A.check(entry ~= nil and entry.server ~= nil, "gate: external server entry created")
if entry and entry.server then
  local connected = vim.wait(15000, function()
    return entry.server.state == "connected"
  end)
  A.check(connected, "gate: real node server connected (state=" .. tostring(entry.server.state) .. ")")
  if not connected then
    print("gate: server diagnostics: " .. tostring(entry.server:stderr_diagnostics()))
    print("gate: last_error: " .. tostring(entry.server.last_error and entry.server.last_error.message))
  end

  -- Real JSON-RPC evidence from the node process. The client records every
  -- write (requests AND notifications): the handshake sequence is
  -- initialize -> notifications/initialized -> tools/list; tools/call is
  -- asserted after the chain below (it only exists once the batch runs).
  A.assert_eq(
    entry.server.server_info and entry.server.server_info.serverInfo and entry.server.server_info.serverInfo.name,
    "fixture-echo",
    "gate: initialize serverInfo from real process"
  )
  local requests = entry.server.client and entry.server.client:requests() or {}
  A.check(#requests >= 3, "gate: handshake requests recorded (got " .. #requests .. ")")
  A.check(requests[1] ~= nil and requests[1].method == "initialize", "gate: first request initialize")
  A.check(
    requests[2] ~= nil and requests[2].method == "notifications/initialized",
    "gate: initialized notification sent"
  )
  A.check(requests[3] ~= nil and requests[3].method == "tools/list", "gate: tools/list request")

  -- State machine: starting -> connected (exactly once each, non-aggregate).
  local states = {}
  for _, item in ipairs(rec.items) do
    if item.event == "mcp.server_state" and not item.payload.aggregate then
      states[#states + 1] = item.payload.state
    end
  end
  A.assert_eq(table.concat(states, ","), "starting,connected", "gate: mcp state sequence")
end

-- Capability registration: the MCP tool is in the tool registry.
local mcp_tool = tool_reg:resolve("fixture-echo/echo")
A.check(mcp_tool ~= nil, "gate: fixture-echo/echo registered from tools/list")
if mcp_tool then
  A.assert_eq(mcp_tool.name, "echo", "gate: mcp tool name")
  A.assert_eq(mcp_tool.execution.mode, "async", "gate: mcp tools are async")
  A.check(type(mcp_tool.run) == "function", "gate: mcp run bridge bound")
end

-- -----------------------------------------------------------------------------
-- 3. Skill tool registration: loader -> tool registry (demo-echo/echo).
-- -----------------------------------------------------------------------------
local d = discover_mod.new({
  roots = {
    { path = tmp .. "/.maxa/skills", kind = "project" }, -- absent: empty/nonexistent project skills
    { path = root .. "/skills", kind = "bundled" }, -- repo-root bundled skills
  },
})
d.scan()
A.check(
  d.roots[1].path:find(".supermax", 1, true) == nil and d.roots[2].path:find(".supermax", 1, true) == nil,
  "gate: discovery roots never contain .supermax"
)

-- Loader methods follow the loader's DOT-call convention (self.load(id)).
local loader = loader_mod.new({ discover = d, tool_registry = tool_reg })
local record, lerr = loader.load("demo-echo")
A.check(record ~= nil, "gate: demo-echo loads (err=" .. tostring(lerr and lerr.message) .. ")")
if record then
  A.assert_eq(
    record.file,
    root .. "/skills/demo-echo/SKILL.md",
    "gate: demo skill file is the repo-root bundled SKILL.md"
  )
  A.check(record.file:find(".supermax", 1, true) == nil, "gate: demo skill file has no .supermax reference")
end
A.assert_eq(#loader.tool_diagnostics("demo-echo"), 0, "gate: no skill tool registration diagnostics")

local skill_tool = tool_reg:resolve("demo-echo/echo")
A.check(skill_tool ~= nil, "gate: demo-echo/echo registered by the loader")
if skill_tool then
  A.assert_eq(skill_tool.execution.mode, "sync", "gate: skill tool is sync")
  A.check(type(skill_tool.run) == "function", "gate: skill tool run bound")
end
A.assert_eq(tool_reg:count(), 2, "gate: exactly two tools registered (mcp + skill)")

-- -----------------------------------------------------------------------------
-- 3.5 W1 real-path assembly: maxa.runtime.assemble wires tool registry + mcp +
--     skills through ONE call (the UI/boot path). A fresh temp project runs
--     its own real node fixture server; teardown is deterministic + idempotent.
-- -----------------------------------------------------------------------------
local asm_tmp = vim.fn.tempname() .. "-p3gate-asm"
vim.fn.mkdir(asm_tmp .. "/.maxa/mcp", "p")
do
  local fh = assert(io.open(asm_tmp .. "/.maxa/mcp/servers.yaml", "wb"))
  fh:write(yaml)
  fh:close()
end
do
  local asm = runtime.assemble({
    mcp = { enabled = true, servers_file = ".maxa/mcp/servers.yaml" },
    skills = { enabled = true, roots = { bundled = true, config = false, project = false } },
  }, { events = events.new(), project_root = asm_tmp, bundled_roots = { root .. "/skills" } })
  A.check(asm.tool_registry ~= nil, "gate: assemble creates the tool registry")
  A.check(asm.mcp_error == nil, "gate: assemble has no mcp error")
  A.check(asm.skills_state ~= nil, "gate: assemble creates skills state")
  A.check(vim.tbl_contains(asm.skills_state.loaded, "demo-echo"), "gate: assemble loads demo-echo")
  local asm_entry = asm.mcp_registry and asm.mcp_registry:get("fixture-echo")
  local asm_connected = asm_entry
    and asm_entry.server
    and vim.wait(15000, function()
      return asm_entry.server.state == "connected"
    end)
  A.check(asm_connected == true, "gate: assemble external server connected")
  A.check(asm.tool_registry:resolve("fixture-echo/echo") ~= nil, "gate: assemble registers the mcp tool")
  A.check(asm.tool_registry:resolve("demo-echo/echo") ~= nil, "gate: assemble registers the skill tool")
  A.assert_eq(asm.tool_registry:count(), 2, "gate: assemble registers exactly two tools")
  local asm_report = asm.teardown()
  A.check(asm_report.mcp_stopped == true, "gate: assemble teardown stops mcp")
  A.check(asm_report.skills_unloaded >= 1, "gate: assemble teardown unloads skills")
  A.check(asm.tool_registry:resolve("fixture-echo/echo") == nil, "gate: assemble teardown unregisters the mcp tool")
  A.check(asm.tool_registry:resolve("demo-echo/echo") == nil, "gate: assemble teardown unregisters the skill tool")
  A.check(asm.teardown().already == true, "gate: assemble teardown idempotent")
end
pcall(vim.fn.delete, asm_tmp, "rf")

-- -----------------------------------------------------------------------------
-- 4. Host submit: ONE scripted response with TWO tool calls through the view.
--    Tool call names use the FULL ids (two tools named `echo` would be
--    ambiguous by bare name; full ids resolve deterministically).
-- -----------------------------------------------------------------------------
local chunks = {
  normalize.tool_call_started("g1", "fixture-echo/echo"),
  normalize.tool_args_delta("g1", '{"text":'),
  normalize.tool_args_delta("g1", '"gate-mcp"}'),
  normalize.tool_call_completed("g1", '{"text":"gate-mcp"}'),
  normalize.tool_call_started("g2", "demo-echo/echo"),
  normalize.tool_args_delta("g2", '{"text":'),
  normalize.tool_args_delta("g2", '"gate-skill"}'),
  normalize.tool_call_completed("g2", '{"text":"gate-skill"}'),
}

local v = host.new({ provider = "mock", events = bus, tool_registry = tool_reg })
local res = v:submit("run gate tools", { provider_params = { chunks = chunks } })
A.check(res ~= nil, "gate: submit accepted")
A.check(res.tool_pending == true, "gate: sync submit parks at tool_pending (mcp tool is async)")

-- Drive the event loop until the FULL chain is persisted: the first request's
-- response.completed fires inline (status already "completed" before the batch
-- finishes), so the wait predicate must key on the persisted chain state — the
-- continuation assistant message only exists after the barrier + decision +
-- automatic submit completed (5 messages total).
local finished = vim.wait(30000, function()
  return v.orch.messages:len() == 5
end)
A.check(finished, "gate: chain persisted all five messages (got " .. tostring(v.orch.messages:len()) .. ")")
A.assert_eq(v.status, "completed", "gate: final status completed")
if v.status == "failed" then
  print("gate: view errors: " .. vim.inspect(v.errors))
end
if not finished then
  print("gate-debug events: " .. table.concat(rec.names, ","))
  if entry and entry.server then
    print("gate-debug server state: " .. tostring(entry.server.state))
    print("gate-debug server stderr: " .. tostring(entry.server:stderr_diagnostics()))
    print("gate-debug server diags: " .. vim.inspect(entry.server.diagnostics))
    print("gate-debug client diags: " .. vim.inspect(entry.server.client and entry.server.client:diagnostics()))
    print("gate-debug pending: " .. tostring(entry.server.client and entry.server.client:pending_count()))
  end
end

-- The real node process received the tools/call request (JSON-RPC evidence).
if entry and entry.server then
  local reqs = entry.server.client and entry.server.client:requests() or {}
  local call = reqs[4]
  A.check(call ~= nil and call.method == "tools/call", "gate: tools/call request sent to the node process")
  if call then
    A.assert_eq(call.params.name, "echo", "gate: tools/call tool name")
    A.assert_eq(call.params.arguments and call.params.arguments.text, "gate-mcp", "gate: tools/call arguments")
  end
end

-- -----------------------------------------------------------------------------
-- 5. Chain assertions: persistence order, barrier once, continuation once.
-- -----------------------------------------------------------------------------
-- Message stack: user + assistant(2 tool_calls) + tool(skill, sync, completes
-- first) + tool(mcp, async, completes when the node responds) +
-- assistant(continuation echo). Persistence follows COMPLETION order, so the
-- sync skill result lands before the async mcp result.
A.assert_eq(v.orch.messages:len(), 5, "gate: five persisted messages (user+assistant+2 tool+assistant)")
local m3 = v.orch.messages:get(3)
A.check(m3 ~= nil and m3.role == "tool", "gate: msg 3 is the persisted skill tool result")
if m3 then
  A.assert_eq(m3.content[1].call_id, "g2", "gate: skill result call_id")
  A.assert_eq(m3.content[1].status, "success", "gate: skill result status")
  A.assert_eq(m3.content[1].content, "demo-echo:gate-skill", "gate: skill result content")
  A.check(m3.content[1].is_error == false, "gate: skill result is_error false")
end
local m4 = v.orch.messages:get(4)
A.check(m4 ~= nil and m4.role == "tool", "gate: msg 4 is the persisted mcp tool result")
if m4 then
  A.assert_eq(m4.content[1].call_id, "g1", "gate: mcp result call_id")
  A.assert_eq(m4.content[1].status, "success", "gate: mcp result status")
  A.assert_eq(m4.content[1].content, "echo:gate-mcp", "gate: mcp result content from the real node process")
  A.check(m4.content[1].is_error == false, "gate: mcp result is_error false")
end
local m5 = v.orch.messages:last()
A.check(m5 ~= nil and m5.role == "assistant", "gate: msg 5 is the continuation assistant")
A.assert_eq(m5.content[1].text, "Hello from maxa mock/echo provider.", "gate: continuation echo text")

-- Tool results persisted BEFORE the barrier and BEFORE the continuation
-- request (persistence/event order contract).
local function find_event(name, from)
  for i = from or 1, #rec.names do
    if rec.names[i] == name then
      return i
    end
  end
  return nil
end
local i_cf1 = find_event("tool_call.finished")
local i_cf2 = find_event("tool_call.finished", i_cf1 + 1)
local i_bf = find_event("tool_batch.finished")
local i_cd = find_event("continuation.decided")
local i_sub1 = find_event("request.submitted")
local i_sub2 = find_event("request.submitted", i_sub1 + 1)
A.check(i_cf1 ~= nil and i_cf2 ~= nil, "gate: two tool_call.finished events")
A.check(i_bf ~= nil, "gate: tool_batch.finished emitted")
A.check(i_cd ~= nil, "gate: continuation.decided emitted")
A.check(i_sub2 ~= nil, "gate: second request.submitted emitted")
A.check(
  i_cf1 < i_cf2 and i_cf2 < i_bf and i_bf < i_cd and i_cd < i_sub2,
  "gate: tool results -> barrier -> continuation.decided -> automatic submit"
)
A.assert_eq(rec.count("tool_batch.finished"), 1, "gate: barrier exactly once")
A.assert_eq(rec.count("continuation.decided"), 1, "gate: continuation.decided exactly once")
A.assert_eq(rec.count("request.submitted"), 2, "gate: exactly two requests (manual + automatic)")
A.assert_eq(rec.count("tool_call.finished"), 2, "gate: one tool_call.finished per call")

-- ToolBatch entity: terminal completed with both calls.
local batch = v.orch.session.tool_batches[1]
A.check(batch ~= nil and batch.terminal ~= nil, "gate: one ToolBatch entity")
if batch then
  A.assert_eq(batch.terminal.state, "completed", "gate: batch terminal completed")
  A.assert_eq(#batch.calls, 2, "gate: batch has two calls")
  A.assert_eq(batch.calls[1].name, "fixture-echo/echo", "gate: batch call 1 name")
  A.assert_eq(batch.calls[2].name, "demo-echo/echo", "gate: batch call 2 name")
end

-- Host projection: tool status lines + fold headers are visible lines; the
-- result-detail fold summaries are foldtext (markers), asserted via _build().
local lines = v:_build_lines()
A.check(has_line(lines, "✅ fixture-echo/echo"), "gate: host tool status line (mcp)")
A.check(has_line(lines, "✅ demo-echo/echo"), "gate: host tool status line (skill)")
A.check(has_line(lines, "### Tool: fixture-echo/echo"), "gate: host tool fold header (mcp)")
A.check(has_line(lines, "### Tool: demo-echo/echo"), "gate: host tool fold header (skill)")
A.check(has_line(lines, "### Response"), "gate: host response header closes the folds")
A.check(has_line(lines, "status: completed"), "gate: host status footer completed")
local build = v:_build()
local fold_summaries = {}
for _, m in ipairs(build.markers) do
  if m.kind == "tool-fold" then
    fold_summaries[#fold_summaries + 1] = m.summary
  end
end
A.check(
  vim.tbl_contains(fold_summaries, "[✅ fixture-echo/echo: echo:gate-mcp]"),
  "gate: host fold summary projects the mcp result (got " .. vim.inspect(fold_summaries) .. ")"
)
A.check(
  vim.tbl_contains(fold_summaries, "[✅ demo-echo/echo: demo-echo:gate-skill]"),
  "gate: host fold summary projects the skill result (got " .. vim.inspect(fold_summaries) .. ")"
)

-- Display projection records (read-only; persisted stack untouched).
A.check(
  v._tool_display["g1"] ~= nil and v._tool_display["g1"].exec_status == "success",
  "gate: display projection g1 success"
)
A.check(
  v._tool_display["g2"] ~= nil and v._tool_display["g2"].exec_status == "success",
  "gate: display projection g2 success"
)
if v._tool_display["g1"] then
  A.assert_eq(v._tool_display["g1"].summary, "echo:gate-mcp", "gate: display projection g1 summary")
end
if v._tool_display["g2"] then
  A.assert_eq(v._tool_display["g2"].summary, "demo-echo:gate-skill", "gate: display projection g2 summary")
end

-- Assistant item model: the automatic continuation REUSES the same assistant
-- item (no user boundary), so the last item carries both tool calls and the
-- continuation text.
local asst = v.items[#v.items]
A.check(asst ~= nil and asst.role == "assistant", "gate: assistant item with tool calls")
if asst and asst.tool_calls then
  A.assert_eq(#asst.tool_calls, 2, "gate: two tool calls tracked in the item")
  A.assert_eq(asst.tool_calls[1].name, "fixture-echo/echo", "gate: item call 1 name")
  A.assert_eq(asst.tool_calls[2].name, "demo-echo/echo", "gate: item call 2 name")
  A.assert_eq(asst.text, "Hello from maxa mock/echo provider.", "gate: item carries the continuation text")
end

-- -----------------------------------------------------------------------------
-- 5.5 W1 request tools through a REAL adapter: registry definitions ->
--     openai_chat form_tools -> build_request body.tools. Offline: the fake
--     transport seam is injected BEFORE the adapter module loads (its
--     module-level `local transport = require(...)` captures the seam), so the
--     real curl transport is never loaded (guardrail in section 6 asserts it).
--     Tool names are the registry ids ENCODED for the wire (`/` -> `-`):
--     OpenAI/Anthropic/Gemini function names reject `/`; the executor resolves
--     the wire name back to the registry id (see tests/tools/request-tools.lua
--     for the full round trip).
-- -----------------------------------------------------------------------------
local fake_transport = {
  new = function()
    return {
      post = function()
        error("gate: fake transport post must never run (request construction only)", 0)
      end,
    }
  end,
}
do
  A.check(
    package.loaded["maxa.runtime.protocol.adapters.openai_chat"] == nil,
    "gate: openai_chat not preloaded before the fake transport injection"
  )
  package.loaded["maxa.runtime.protocol.transport"] = fake_transport
  local adapter_mod = require("maxa.runtime.protocol.adapters.openai_chat")
  local openai_adapter = adapter_mod.adapter
  local tools = openai_adapter:form_tools(tool_reg:list())
  A.check(#tools == 2, "gate: form_tools covers both registered tools")
  local body = openai_adapter:build_request({ model = "test-model", stream = false }, {
    messages = {},
    tools = tools,
  })
  A.check(type(body.tools) == "table" and #body.tools == 2, "gate: body.tools populated")
  local echo_tool = nil
  for _, t in ipairs(body.tools or {}) do
    if t["function"] and t["function"].name == "fixture-echo-echo" then
      echo_tool = t["function"]
    end
  end
  A.check(echo_tool ~= nil, "gate: fixture-echo/echo complete definition in body.tools (wire name)")
  if echo_tool then
    A.check(type(echo_tool.description) == "string" and echo_tool.description ~= "", "gate: tool description")
    A.check(echo_tool.parameters ~= nil and echo_tool.parameters.type == "object", "gate: tool parameters")
    A.check(
      echo_tool.parameters ~= tool_reg:resolve("fixture-echo/echo").input_schema,
      "gate: parameters are a per-provider copy"
    )
  end
end

-- -----------------------------------------------------------------------------
-- 6. Guardrails: no real network plumbing, no .supermax, clean shutdown/unload.
-- -----------------------------------------------------------------------------
-- No network: the fixture is a local stdio process; the only protocol HTTP
-- transport ever loaded is the FAKE test seam injected in section 5.5 (never
-- the real curl transport) — offline by construction.
A.check(
  package.loaded["maxa.runtime.protocol.transport"] == fake_transport,
  "gate: transport loaded is the fake seam, never the real curl transport"
)
if entry and entry.server then
  A.assert_eq(entry.server.cfg.transport, "stdio", "gate: mcp transport is stdio (local)")
  A.assert_eq(entry.server.cfg.command, "node", "gate: mcp command is the local node binary")
end

-- Cleanup: skill unload unregisters its tools; mcp stop removes capabilities.
A.check(loader.unload("demo-echo") == true, "gate: loader unload accepted")
A.check(tool_reg:resolve("demo-echo/echo") == nil, "gate: unload unregisters the skill tool")
reg:stop_all()
A.check(tool_reg:resolve("fixture-echo/echo") == nil, "gate: mcp stop removes capabilities (unregister)")
v:close()
pcall(vim.fn.delete, tmp, "rf")

-- -----------------------------------------------------------------------------
-- 7. Terminal import-guard assert (nothing legacy loaded).
-- -----------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  A.check(guard.assert_no_forbidden(), "gate: import-guard clean (no codecompanion/mcphub/util.hooks)")
end

if A.ok then
  print("P3_GATE_OK")
else
  print("P3_GATE_FAILED count=" .. #A.failures)
  vim.cmd("cq")
end
