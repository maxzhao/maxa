-- filepath: tests/tools/display-projection.lua
--- Phase-3 W7 fixture: display summary projection never mutates persisted/API
--- result messages (tool-runtime §Result and UI separation).
---   * a registry tool executes through the FULL chain: host view
---     (host.new({ tool_registry = reg })) -> orchestrator registry bridge ->
---     executor (no injected handlers, so the registry resolves the tool),
---   * the host subscribes to execution-side `tool_call.finished` and projects
---     the persisted tool_result into display-only fold data
---     (summary/detail); the stack is never written by rendering,
---   * the persisted message stack serialization is byte-identical before and
---     after rendering (render -> projection -> build),
---   * the display summary is DERIVED from the persisted content (substring),
---     proving display and persisted projections stay separate.
---
--- Fixture convention: prints TOOLS_DISPLAY_PROJECTION_OK on success; throws.
local assert_mod = require("tests.state.lib.assert")
local registry_mod = require("maxa.runtime.tools.registry")
local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")
local n = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

do
  local reg = registry_mod.new()
  local def, err = reg:register({
    id = "demo/read_file",
    name = "read_file",
    description = "returns a deterministic multi-line result",
    input_schema = { type = "object", properties = { path = { type = "string" } } },
    execution = { mode = "sync" },
    run = function(args)
      return ("content of %s\nline two\nline three"):format(args.path or "?")
    end,
  })
  A.check(def ~= nil and err == nil, "display: registry tool registered")

  local chunks = {
    n.tool_call_started("call_dp_1", "read_file"),
    n.tool_args_delta("call_dp_1", '{"path":'),
    n.tool_args_delta("call_dp_1", '"x"}'),
    n.tool_call_completed("call_dp_1", '{"path":"x"}'),
  }
  local bus = events.new()
  local v = host.new({
    provider = "mock",
    events = bus,
    provider_params = { chunks = chunks },
    tool_registry = reg, -- W7 registry bridge (no injected handlers)
  })
  local res = v:submit("read the file")
  A.assert_eq(res.terminal_state, "completed", "display: submit completed")

  -- Persisted stack: user + assistant(tool_call) + tool(result) + continuation.
  local stack = v.orch.messages
  A.check(stack ~= nil and stack:len() >= 3, "display: stack has persisted messages")
  local persisted = nil
  for i = 1, stack:len() do
    local msg = stack:get(i)
    if msg and msg.role == "tool" then
      for _, part in ipairs(msg.content or {}) do
        if part.type == "tool_result" and part.call_id == "call_dp_1" then
          persisted = part.content
        end
      end
    end
  end
  A.check(persisted ~= nil and persisted:find("content of x", 1, true) ~= nil, "display: persisted tool result content")
  A.check(persisted:find("line three", 1, true) ~= nil, "display: full multi-line result persisted")

  -- Display projection exists and is DERIVED from the persisted content.
  local disp = v._tool_display["call_dp_1"]
  A.check(disp ~= nil, "display: tool display projection recorded")
  A.assert_eq(disp.exec_status, "success", "display: exec status success")
  A.check(disp.summary ~= nil and persisted:find(disp.summary, 1, true) ~= nil, "display: summary is a substring of persisted content")
  A.check(disp.detail ~= nil and disp.detail:find("line two", 1, true) ~= nil, "display: detail projects multi-line content")

  -- Rendering never mutates the persisted/API result: stack serialization is
  -- byte-identical before and after render + build.
  local before = vim.json.encode(stack:to_table())
  v:_render() -- idempotent re-render (guarded: no buffer attached)
  local after = vim.json.encode(stack:to_table())
  A.assert_eq(after, before, "display: stack byte-identical across re-render")

  local lines = v:_build_lines()
  local joined = table.concat(lines, "\n")
  A.check(joined:find("### Tool: read_file", 1, true) ~= nil, "display: tool fold header rendered")
  A.check(joined:find("content of x", 1, true) ~= nil, "display: fold body projects result detail")
  A.check(joined:find("line two", 1, true) ~= nil, "display: full detail projected into render")
  local after2 = vim.json.encode(stack:to_table())
  A.assert_eq(after2, before, "display: stack byte-identical after _build_lines")

  v:close()
end

if A.ok then
  print("TOOLS_DISPLAY_PROJECTION_OK")
else
  error("TOOLS_DISPLAY_PROJECTION_FAILED count=" .. #A.failures)
end
