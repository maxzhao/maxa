-- filepath: tests/mcp/config-valid-external.lua
--- Phase-3 W3 fixture: `mcp/config-valid-external` (runtime-fixture-contract).
---   * `.maxa/mcp/servers.yaml` load + schema validation,
---   * `${PROJECT_ROOT}` and `${VAR}` substitution normalized WITHOUT executing
---     any process (spawn count stays 0),
---   * missing env reference marks ONLY that server unavailable (explicit
---     unavailable-server state; the rest of the config loads),
---   * secrets derived from env references never leave the process: the
---     in-memory config carries the resolved value, `snapshot()` redacts it,
---   * missing file = empty configuration, never an error, never a
---     `.supermax/` fallback.

local assert_mod = require("tests.state.lib.assert")
local mcp_config = require("maxa.runtime.mcp.config")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()
local h = harness.new()

-- Ensure the env references used by the fixture exist (nvim API setenv also
-- updates the C environment read by os.getenv inside the runtime).
vim.fn.setenv("MCP_FIXTURE_TOKEN", "s3cr3t-token")
vim.fn.setenv("MCP_FIXTURE_BIN", "fakebin")

do
  local root = h.write_project(
    [[
schema_version: 1
servers:
  demo:
    enabled: true
    transport: stdio
    command: ${PROJECT_ROOT}/bin/fake
    args: ["--root", "${PROJECT_ROOT}", "--bin", "${MCP_FIXTURE_BIN}"]
    env:
      MCP_FIXTURE_TOKEN: ${MCP_FIXTURE_TOKEN}
      PATH_MARKER: prefix-${PROJECT_ROOT}
      LITERAL: keepme
      NUMERIC: 42
    cwd: ${PROJECT_ROOT}
    request_timeout_ms: 2500
    startup_timeout_ms: null
  defaults:
    command: plain
  missing-env:
    enabled: true
    command: whatever
    env:
      TOKEN: ${MCP_DOES_NOT_EXIST_XYZ}
]],
    "config-valid"
  )

  local cfg, err = mcp_config.load(root)
  A.check(cfg ~= nil, "cv: load succeeded :: " .. tostring(err and err.message))
  if cfg then
    local project_root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
    local demo = cfg.servers["demo"]
    A.check(demo ~= nil, "cv: demo registered")
    if demo then
      A.assert_eq(demo.command, project_root .. "/bin/fake", "cv: command ${PROJECT_ROOT} substituted")
      A.assert_eq(demo.args[2], project_root, "cv: args ${PROJECT_ROOT} substituted")
      A.assert_eq(demo.args[4], "fakebin", "cv: args ${VAR} substituted")
      A.assert_eq(demo.env["MCP_FIXTURE_TOKEN"], "s3cr3t-token", "cv: env ${VAR} substituted in memory")
      A.assert_eq(demo.env["PATH_MARKER"], "prefix-" .. project_root, "cv: embedded ${PROJECT_ROOT} substituted")
      A.assert_eq(demo.env["LITERAL"], "keepme", "cv: literal env value kept")
      A.assert_eq(demo.env["NUMERIC"], "42", "cv: numeric env value coerced to string")
      A.assert_eq(demo.cwd, project_root, "cv: cwd ${PROJECT_ROOT} substituted")
      A.assert_eq(demo.request_timeout_ms, 2500, "cv: request_timeout_ms kept")
      A.check(demo.startup_timeout_ms == nil, "cv: startup_timeout_ms null -> nil")
    end
    local defaults = cfg.servers["defaults"]
    A.check(defaults ~= nil, "cv: defaults server registered")
    if defaults then
      A.assert_eq(defaults.enabled, true, "cv: enabled defaults to true")
      A.assert_eq(defaults.request_timeout_ms, mcp_config.DEFAULT_REQUEST_TIMEOUT_MS, "cv: request timeout default")
      A.assert_eq(defaults.startup_timeout_ms, mcp_config.DEFAULT_STARTUP_TIMEOUT_MS, "cv: startup timeout default")
      A.assert_eq(defaults.cwd, project_root, "cv: cwd defaults to project root")
      A.assert_eq(defaults.transport, "stdio", "cv: transport defaults to stdio")
    end
    -- Missing env reference: explicit unavailable-server state, not an error.
    A.check(cfg.unavailable["missing-env"] ~= nil, "cv: missing env -> unavailable state")
    A.check(
      cfg.unavailable["missing-env"]:find("MCP_DOES_NOT_EXIST_XYZ", 1, true) ~= nil,
      "cv: unavailable reason names the variable"
    )
    A.check(cfg.servers["missing-env"] == nil, "cv: unavailable server excluded from runnable set")

    -- Snapshot redacts env-ref-derived values; PROJECT_ROOT expansions stay.
    local snap = mcp_config.snapshot(cfg)
    local sd = snap.servers["demo"]
    A.check(sd ~= nil, "cv: snapshot has demo")
    if sd then
      A.assert_eq(sd.env["MCP_FIXTURE_TOKEN"], mcp_config.REDACTED, "cv: snapshot redacts env-ref secret")
      A.assert_eq(sd.env["PATH_MARKER"], "prefix-" .. project_root, "cv: snapshot keeps ${PROJECT_ROOT} expansion")
      A.assert_eq(sd.env["LITERAL"], "keepme", "cv: snapshot keeps literal env value")
      A.assert_eq(sd.args[4], mcp_config.REDACTED, "cv: snapshot redacts env-ref arg")
      A.assert_eq(sd.command, project_root .. "/bin/fake", "cv: snapshot keeps PROJECT_ROOT command")
    end

    -- Field-level diff: changed/unchanged classification.
    local cfg2 = {
      version = 1,
      project_root = project_root,
      servers = {
        demo = demo,
        defaults = vim.deepcopy(defaults),
        defaults2 = vim.deepcopy(defaults),
      },
    }
    cfg2.servers["defaults"].command = "changed-command"
    local diff = mcp_config.diff(cfg, cfg2)
    A.check(diff.unchanged["demo"] ~= nil, "cv: unchanged demo")
    A.check(diff.changed["defaults"] ~= nil, "cv: changed defaults")
    A.check(diff.added["defaults2"] ~= nil, "cv: added defaults2")
    A.check(diff.removed["missing-env"] == nil, "cv: unavailable server is not part of the runnable diff")
    A.check(diff.changed["defaults"].fields[1] == "command", "cv: field-level change detail")
  end

  -- No process was ever spawned: config load never executes.
  A.assert_eq(#h.spawned, 0, "cv: zero process spawns (substitution normalized without executing)")

  h.cleanup(root)
end

-- Missing file = empty configuration (no error, no `.supermax/` fallback).
do
  local cfg, err = mcp_config.load("/tmp/maxa-mcp-config-valid-no-such-project-xyz")
  A.check(cfg ~= nil and err == nil, "cv: missing file loads as empty config")
  if cfg then
    A.assert_eq(#vim.tbl_keys(cfg.servers), 0, "cv: empty servers for missing file")
    A.check(cfg.source == nil, "cv: no source path for empty config")
  end
end

-- Structural reference error is a hard error.
do
  local root = h.write_project(
    [[
schema_version: 1
servers:
  bad:
    command: "$HOME/bin/x"
]],
    "config-valid-badref"
  )
  local cfg, err = mcp_config.load(root)
  A.check(cfg == nil and err ~= nil, "cv: unrecognized $ reference is a hard error")
  if err then
    A.assert_eq(err.code, "configuration", "cv: typed configuration error")
    A.check(err.message:find("$", 1, true) ~= nil, "cv: error names the reference")
  end
  h.cleanup(root)
end

if A.ok then
  print("MCP_CONFIG_VALID_EXTERNAL_OK")
else
  error("MCP_CONFIG_VALID_EXTERNAL_FAILED count=" .. #A.failures)
end
