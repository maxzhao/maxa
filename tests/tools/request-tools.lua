-- filepath: tests/tools/request-tools.lua
--- Phase-3 W1 fixture: orchestrator request tools filling (real adapter path).
---
---   * a REAL openai_chat adapter is bound through use_provider_record and
---     driven by a FAKE transport (injected into package.loaded BEFORE the
---     adapter module loads, so its module-level `local transport = require`
---     captures the seam — the real curl transport is never loaded); the
---     submit constructs the provider request and `body.tools` carries the
---     full registry definitions (name = registry id ENCODED for the wire —
---     `fixture-echo/echo` -> `fixture-echo-echo`, since OpenAI/Anthropic/
---     Gemini function names reject `/` — description, parameters as a
---     per-provider schema copy);
---   * a scripted two-response stream proves the round trip: the provider
---     calls the tool by its wire name, the executor resolves it back to the
---     registry id through the orchestrator's provider-name map, the tool
---     result persists, and the automatic continuation completes;
---   * the mock provider path never constructs normalized tools (no tools
---     field in the stream params — regression guard);
---   * `form_tools` shapes for all four protocol adapters are asserted
---     directly (pure functions, offline).
---
--- Fixture convention: prints TOOLS_REQUEST_TOOLS_OK on success; throws.
local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local tools_registry = require("maxa.runtime.tools.registry")
local protocol = require("maxa.runtime.protocol")

local A = assert_mod.new()

-- Shared registry with one fixture tool (MCP-like definition).
local reg = tools_registry.new()
local def, derr = reg:register({
  id = "fixture-echo/echo",
  name = "echo",
  description = "Echo the provided text argument back (fixture stdio MCP server)",
  input_schema = {
    type = "object",
    properties = { text = { type = "string", description = "text to echo" } },
    required = { "text" },
  },
  execution = { mode = "sync", side_effect = "none" },
  run = function(args)
    return "echo:" .. tostring(args and args.text or "")
  end,
})
A.check(def ~= nil, "request-tools: fixture tool registered (" .. tostring(derr and derr.message or "") .. ")")
A.assert_eq(tools_registry.provider_name(def), "fixture-echo-echo", "request-tools: wire name encoding")

-- -------------------------------------------------------------------------
-- 1. Real openai_chat adapter + fake transport: submit builds body.tools and
--    a tool call by the WIRE name executes through the provider-name map.
-- -------------------------------------------------------------------------
local function sse_frame(json)
  return "data: " .. vim.json.encode(json) .. "\n\n"
end
-- Scripted responses: request 1 = tool call by the wire name; request 2 = the
-- plain continuation text (terminates the chain, like the gate's mock).
local scripted = {
  {
    sse_frame({
      choices = {
        {
          delta = {
            tool_calls = {
              {
                index = 0,
                id = "c1",
                type = "function",
                ["function"] = { name = "fixture-echo-echo", arguments = '{"text":"hi"}' },
              },
            },
          },
        },
      },
    }),
    sse_frame({ choices = { { delta = {}, finish_reason = "tool_calls" } } }),
    "data: [DONE]\n\n",
  },
  {
    sse_frame({ choices = { { delta = { content = "chain done" }, finish_reason = "stop" } } }),
    "data: [DONE]\n\n",
  },
}
local captured = { bodies = {} }
local request_idx = 0
local fake_transport = {
  new = function()
    return {
      post = function(_, opts, callbacks)
        request_idx = request_idx + 1
        captured.bodies[request_idx] = opts.body
        captured.url = opts.url
        local script = scripted[request_idx] or scripted[#scripted]
        for _, chunk in ipairs(script) do
          if callbacks.on_chunk then
            callbacks.on_chunk(chunk)
          end
        end
        if callbacks.on_done then
          callbacks.on_done()
        end
        return {
          id = "fake",
          active = true,
          cancel = function()
            return true
          end,
          status = function()
            return "ok"
          end,
        }
      end,
    }
  end,
}
-- The adapter must not be preloaded: its module-level require must capture the
-- fake seam (never the real curl transport).
A.check(
  package.loaded["maxa.runtime.protocol.adapters.openai_chat"] == nil,
  "request-tools: openai_chat not preloaded (fake transport seam is safe)"
)
package.loaded["maxa.runtime.protocol.transport"] = fake_transport
local adapter_mod = require("maxa.runtime.protocol.adapters.openai_chat")
local adapter = adapter_mod.adapter

vim.env.MAXA_TEST_KEY = "fake-key"
local record = {
  id = "test-openai",
  protocol = "openai_chat",
  base_url = "http://fake.local/v1",
  api_key_env = "MAXA_TEST_KEY",
  api_key = "fake-key",
  model = "test-model",
  capabilities = adapter.capabilities,
  request = { connect_timeout_ms = 1000, timeout_ms = 1000 },
  adapter = adapter,
}
local orch = orchestrator.new({ events = events.new(), tool_registry = reg })
orch:use_provider_record(record, {
  params = {
    model = "test-model",
    stream = false,
    base_url = record.base_url,
    api_key_env = record.api_key_env,
  },
})
local res = orch:submit("hello tools")
A.check(res ~= nil and res.ok == true, "request-tools: submit completed through the fake transport")
A.check(captured.bodies[1] ~= nil, "request-tools: first request body captured")
if captured.bodies[1] then
  local body = captured.bodies[1]
  A.check(type(body.tools) == "table" and #body.tools == 1, "request-tools: body.tools non-empty")
  local tool = body.tools and body.tools[1]
  A.check(tool ~= nil, "request-tools: one tool in body")
  if tool then
    A.assert_eq(tool.type, "function", "request-tools: openai chat tool type")
    A.check(tool["function"] ~= nil, "request-tools: openai chat function wrapper")
    if tool["function"] then
      A.assert_eq(tool["function"].name, "fixture-echo-echo", "request-tools: tool name = encoded registry id")
      A.check(tool["function"].description:find("Echo the provided", 1, true) ~= nil, "request-tools: tool description")
      A.check(
        tool["function"].parameters ~= nil and tool["function"].parameters.type == "object",
        "request-tools: tool parameters (schema copy)"
      )
      A.check(
        tool["function"].parameters ~= reg:resolve("fixture-echo/echo").input_schema,
        "request-tools: parameters are a copy (never the definition)"
      )
    end
  end
end

-- Round trip: the provider called the tool by its WIRE name; the executor
-- resolved it through the provider-name map and the result persisted; the
-- automatic continuation completed with the second scripted response.
A.check(
  orch.messages ~= nil and orch.messages:len() == 4,
  "request-tools: four persisted messages (user+assistant+tool+assistant)"
)
if orch.messages then
  local m3 = orch.messages:get(3)
  A.check(m3 ~= nil and m3.role == "tool", "request-tools: msg 3 is the persisted tool result")
  if m3 then
    A.assert_eq(m3.content[1].call_id, "c1", "request-tools: tool result call_id")
    A.assert_eq(m3.content[1].status, "success", "request-tools: tool result status")
    A.assert_eq(m3.content[1].content, "echo:hi", "request-tools: tool result content (wire name resolved to id)")
  end
  local m4 = orch.messages:last()
  A.check(m4 ~= nil and m4.role == "assistant", "request-tools: msg 4 is the continuation assistant")
  if m4 then
    A.assert_eq(m4.content[1].text, "chain done", "request-tools: continuation text")
  end
end
orch:close()

-- -------------------------------------------------------------------------
-- 2. Mock provider path: no normalized tools (no tools field) — regression.
-- -------------------------------------------------------------------------
do
  local base = protocol.get("mock")
  local seen = {}
  local mock_clone = {}
  for k, v in pairs(base) do
    mock_clone[k] = v
  end
  mock_clone.stream = function(self, params, callbacks)
    seen.params = params
    return base.stream(base, params, callbacks)
  end
  local orch2 = orchestrator.new({ events = events.new(), tool_registry = reg })
  orch2:use_provider(mock_clone)
  local res2 = orch2:submit("hello", { provider_params = { chunks = { "mock says hi" } } })
  A.check(res2 ~= nil and res2.ok == true, "request-tools: mock submit completed")
  A.check(seen.params ~= nil, "request-tools: mock stream params observed")
  A.check(seen.params.normalized == nil, "request-tools: mock path has no normalized tools field")
  orch2:close()
end

-- -------------------------------------------------------------------------
-- 3. form_tools shapes (all four protocol adapters; pure functions, offline).
-- -------------------------------------------------------------------------
do
  local anthropic = require("maxa.runtime.protocol.adapters.anthropic_messages")
  local responses = require("maxa.runtime.protocol.adapters.openai_responses")
  local gemini = require("maxa.runtime.protocol.adapters.gemini")
  local defs = reg:list()
  -- Encoded baseline of the normalized definition BEFORE any form_tools call.
  local before_def = vim.json.encode(reg:resolve("fixture-echo/echo").input_schema)

  local t1 = adapter:form_tools(defs)
  A.assert_eq(t1[1].type, "function", "form_tools: openai_chat type")
  A.assert_eq(t1[1]["function"].name, "fixture-echo-echo", "form_tools: openai_chat wire name")
  A.check(t1[1]["function"].parameters.type == "object", "form_tools: openai_chat parameters")

  local t2 = anthropic:form_tools(defs)
  A.assert_eq(t2[1].name, "fixture-echo-echo", "form_tools: anthropic wire name")
  A.check(t2[1].input_schema ~= nil and t2[1].input_schema.type == "object", "form_tools: anthropic input_schema")
  A.check(t2[1].description ~= nil and t2[1].description ~= "", "form_tools: anthropic description")

  local t3 = responses:form_tools(defs)
  A.assert_eq(t3[1].type, "function", "form_tools: responses type")
  A.assert_eq(t3[1].name, "fixture-echo-echo", "form_tools: responses wire name")
  A.check(t3[1].parameters.type == "object", "form_tools: responses parameters")
  A.check(
    t3[1].parameters ~= reg:resolve("fixture-echo/echo").input_schema,
    "form_tools: responses parameters are a copy"
  )

  local t4 = gemini:form_tools(defs)
  A.assert_eq(t4[1].name, "fixture-echo-echo", "form_tools: gemini wire name")
  A.check(t4[1].parameters ~= nil and t4[1].parameters.type == "object", "form_tools: gemini parameters")

  -- Adaptation never touches the original definition (no strictify residue,
  -- no schema mutation): the definition still encodes to its baseline.
  local after = reg:resolve("fixture-echo/echo").input_schema
  A.check(after.additionalProperties == nil, "form_tools: definition not strictified in place")
  A.check(after.properties.text.type == "string", "form_tools: definition properties intact")
  A.check(vim.json.encode(after) == before_def, "form_tools: definition unchanged")
end

if A.ok then
  print("TOOLS_REQUEST_TOOLS_OK")
else
  error("TOOLS_REQUEST_TOOLS_FAILED count=" .. #A.failures)
end
