-- filepath: tests/tools/assemble.lua
--- Phase-3 W1 fixture: real-path runtime assembly (maxa.runtime.assemble).
---
--- Exercises the ONE-call assembly chain the UI/boot path uses:
---   * MCP: temp project `.maxa/mcp/servers.yaml` -> mcp.config ->
---     mcp.registry -> REAL node stdio fixture process connected ->
---     fixture-echo/echo registered into the shared tool registry;
---   * skills: bundled repo-root `skills/` discovered (roots switches honored)
---     -> loader loads demo-echo -> skills/demo-echo/tools/echo.lua registered
---     as demo-echo/echo;
---   * teardown: mcp stop_all + skill unloads unregister every tool, stop the
---     node process, and are idempotent (second call is a no-op);
---   * missing servers.yaml -> EMPTY assembly, never an error.
---
--- Guardrails: `.supermax/` is never a source; the fixture is a local stdio
--- process (no network).
---
--- Fixture convention: prints TOOLS_ASSEMBLE_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")
local runtime = require("maxa.runtime")

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/tools")
local root = dir:match("^(.*)/tests/tools$") or "/home/maxzhao/maxa"
local fixture = root .. "/tests/mcp/fixtures/stdio_server.mjs"

local A = assert_mod.new()

A.check(vim.fn.executable("node") == 1, "assemble: node executable available")

local function make_project(tag)
  local tmp = vim.fn.tempname() .. "-" .. tag
  vim.fn.mkdir(tmp .. "/.maxa/mcp", "p")
  return tmp
end

-- -------------------------------------------------------------------------
-- 1. Full assembly: mcp (real node fixture) + skills (repo bundled demo-echo).
-- -------------------------------------------------------------------------
local tmp = make_project("asm")
do
  local fh = assert(io.open(tmp .. "/.maxa/mcp/servers.yaml", "wb"))
  fh:write(
    ("schema_version: 1\nservers:\n  fixture-echo:\n    enabled: true\n    transport: stdio\n    command: node\n    args: [%q]\n    cwd: %q\n    request_timeout_ms: 10000\n    startup_timeout_ms: 10000\n"):format(
      fixture,
      root
    )
  )
  fh:close()
end

local cfg = {
  mcp = { enabled = true, servers_file = ".maxa/mcp/servers.yaml" },
  skills = { enabled = true, roots = { bundled = true, config = false, project = true } },
}
local asm = runtime.assemble(cfg, {
  events = events.new(),
  project_root = tmp,
  bundled_roots = { root .. "/skills" },
})

A.check(asm.tool_registry ~= nil, "assemble: tool registry created")
A.check(asm.mcp_config ~= nil, "assemble: mcp config loaded")
A.check(asm.mcp_config.servers["fixture-echo"] ~= nil, "assemble: fixture-echo discovered")
A.check(asm.mcp_config.source:find(".supermax", 1, true) == nil, "assemble: mcp source never .supermax")
A.check(asm.mcp_error == nil, "assemble: no mcp error")
A.check(asm.mcp_registry ~= nil, "assemble: mcp registry created")
A.check(asm.skills_state ~= nil, "assemble: skills state created")
A.check(vim.tbl_contains(asm.skills_state.loaded, "demo-echo"), "assemble: demo-echo loaded")

-- External server connected (real node process).
local entry = asm.mcp_registry:get("fixture-echo")
A.check(entry ~= nil and entry.server ~= nil, "assemble: external server entry")
if entry and entry.server then
  local connected = vim.wait(15000, function()
    return entry.server.state == "connected"
  end)
  A.check(connected, "assemble: server connected (state=" .. tostring(entry.server.state) .. ")")
end

-- Registry contains both tools: mcp fixture tool + skill tool.
A.check(asm.tool_registry:resolve("fixture-echo/echo") ~= nil, "assemble: fixture-echo/echo registered")
A.check(asm.tool_registry:resolve("demo-echo/echo") ~= nil, "assemble: demo-echo/echo registered")
A.assert_eq(asm.tool_registry:count(), 2, "assemble: exactly two tools (mcp + skill)")

-- -------------------------------------------------------------------------
-- 2. Teardown: tools unregistered, process stopped, idempotent.
-- -------------------------------------------------------------------------
local report = asm.teardown()
A.check(report.mcp_stopped == true, "assemble: teardown stopped mcp")
A.check(
  report.skills_unloaded >= 1,
  "assemble: teardown unloaded skills (got " .. tostring(report.skills_unloaded) .. ")"
)
A.check(#report.failures == 0, "assemble: no teardown failures")
A.check(asm.tool_registry:resolve("fixture-echo/echo") == nil, "assemble: mcp tool unregistered")
A.check(asm.tool_registry:resolve("demo-echo/echo") == nil, "assemble: skill tool unregistered")
A.assert_eq(asm.tool_registry:count(), 0, "assemble: registry empty after teardown")
if entry and entry.server then
  A.check(
    entry.server.state ~= "connected" and entry.server.state ~= "starting",
    "assemble: server process stopped (state=" .. tostring(entry.server.state) .. ")"
  )
end
local report2 = asm.teardown()
A.check(report2.already == true, "assemble: teardown idempotent (second call no-op)")

pcall(vim.fn.delete, tmp, "rf")

-- -------------------------------------------------------------------------
-- 3. Missing servers.yaml = empty assembly, never an error.
-- -------------------------------------------------------------------------
local tmp2 = make_project("asm-empty")
local cfg2 = {
  mcp = { enabled = true, servers_file = ".maxa/mcp/servers.yaml" },
  skills = { enabled = false },
}
local asm2 = runtime.assemble(cfg2, { events = events.new(), project_root = tmp2 })
A.check(asm2.mcp_config ~= nil, "assemble: empty project still loads empty mcp config")
A.check(asm2.mcp_config.servers ~= nil and next(asm2.mcp_config.servers) == nil, "assemble: empty servers list")
A.check(asm2.mcp_error == nil, "assemble: missing servers.yaml never an error")
A.check(asm2.mcp_registry ~= nil, "assemble: mcp registry exists for empty config")
A.check(asm2.skills_state == nil, "assemble: skills disabled -> no skills state")
A.assert_eq(asm2.tool_registry:count(), 0, "assemble: no tools without servers/skills")
asm2.teardown()
pcall(vim.fn.delete, tmp2, "rf")

if A.ok then
  print("TOOLS_ASSEMBLE_OK")
else
  error("TOOLS_ASSEMBLE_FAILED count=" .. #A.failures)
end
