-- filepath: tests/mcp/config-invalid.lua
--- Phase-3 W3 fixture: `mcp/config-invalid` (runtime-fixture-contract).
---   * missing command / unsupported schema version / schema violations are
---     classified as typed configuration errors BEFORE any process spawn,
---   * every error is `schema.ERROR.CONFIGURATION` and names the failing
---     file/field path,
---   * zero process spawns across all invalid cases.

local assert_mod = require("tests.state.lib.assert")
local mcp_config = require("maxa.runtime.mcp.config")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()
local h = harness.new()

---@param yaml_text string
---@param expect string substring the error message must contain
---@param label string
local function expect_error(yaml_text, expect, label)
  local root = h.write_project(yaml_text, "config-invalid")
  local cfg, err = mcp_config.load(root)
  A.check(cfg == nil, label .. ": load rejected")
  A.check(err ~= nil, label .. ": typed error returned")
  if err then
    A.assert_eq(err.code, "configuration", label .. ": code = configuration")
    A.check(err.message:find(expect, 1, true) ~= nil, label .. ": message mentions " .. expect .. " :: " .. err.message)
  end
  h.cleanup(root)
end

-- Unsupported schema version.
expect_error("schema_version: 2\nservers:\n  demo:\n    command: x\n", "schema_version", "ci-version")
-- Missing schema_version.
expect_error("servers:\n  demo:\n    command: x\n", "schema_version", "ci-missing-version")
-- Missing command.
expect_error("schema_version: 1\nservers:\n  demo:\n    enabled: true\n", "command", "ci-missing-command")
-- Non-mapping server declaration.
expect_error("schema_version: 1\nservers:\n  demo: not-a-map\n", "server declaration", "ci-not-map")
-- Unknown server key (fail-closed).
expect_error(
  "schema_version: 1\nservers:\n  demo:\n    command: x\n    bogus: 1\n",
  "unknown server key",
  "ci-unknown-key"
)
-- Unknown top-level key.
expect_error("schema_version: 1\nservers: {}\nbogus: 1\n", "unknown top-level", "ci-unknown-top")
-- Unsupported transport.
expect_error("schema_version: 1\nservers:\n  demo:\n    command: x\n    transport: http\n", "transport", "ci-transport")
-- args must be a list.
expect_error("schema_version: 1\nservers:\n  demo:\n    command: x\n    args: notalist\n", "args", "ci-args-type")
-- args elements must be strings.
-- tinyyaml stringifies flow scalars, so a nested sequence is the reliable
-- non-string args element.
expect_error("schema_version: 1\nservers:\n  demo:\n    command: x\n    args: [[nested]]\n", "args[1]", "ci-args-elem")
-- env must be a mapping.
expect_error("schema_version: 1\nservers:\n  demo:\n    command: x\n    env: [a, b]\n", "env", "ci-env-type")
-- env key must be an env-name.
expect_error(
  "schema_version: 1\nservers:\n  demo:\n    command: x\n    env:\n      MY-KEY: v\n",
  "env key",
  "ci-env-key"
)
-- Invalid timeout (negative).
expect_error(
  "schema_version: 1\nservers:\n  demo:\n    command: x\n    request_timeout_ms: -5\n",
  "request_timeout_ms",
  "ci-timeout-neg"
)
-- Invalid timeout (non-integer).
expect_error(
  "schema_version: 1\nservers:\n  demo:\n    command: x\n    startup_timeout_ms: 1.5\n",
  "startup_timeout_ms",
  "ci-timeout-float"
)
-- Invalid env reference inside a value (structural).
expect_error(
  "schema_version: 1\nservers:\n  demo:\n    command: x\n    env:\n      TOKEN: '${BAD NAME}'\n",
  "invalid reference",
  "ci-bad-ref"
)
-- Malformed YAML.
expect_error("schema_version: 1\nservers:\n  demo:\n   command: x\n    enabled: true\n", "yaml", "ci-yaml")

-- No invalid case ever spawned a process.
A.assert_eq(#h.spawned, 0, "ci: zero process spawns across all invalid configs")

if A.ok then
  print("MCP_CONFIG_INVALID_OK")
else
  error("MCP_CONFIG_INVALID_FAILED count=" .. #A.failures)
end
