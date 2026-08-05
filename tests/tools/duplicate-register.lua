-- filepath: tests/tools/duplicate-register.lua
--- Phase-3 W1 fixture: registry registration rules (tool-runtime §Tool
--- definition: unique IDs, idempotent same-hash duplicates, typed error on
--- conflicting duplicates, schema fail-closed, resolve/schema_for semantics).
---
--- Fixture convention: prints TOOLS_DUPLICATE_REGISTER_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local schema_mod = require("maxa.runtime.schema")
local registry_mod = require("maxa.runtime.tools.registry")
local jschema = require("maxa.runtime.tools.schema")

local A = assert_mod.new()

local reg = registry_mod.new()

local function base_def(overrides)
  return vim.tbl_extend("force", {
    id = "demo/echo",
    name = "echo",
    description = "echo a path",
    input_schema = {
      type = "object",
      properties = { path = { type = "string" } },
      required = { "path" },
    },
  }, overrides or {})
end

-------------------------------------------------------------------------------
-- A. Same-hash duplicate is idempotent
-------------------------------------------------------------------------------
do
  local d1, e1 = reg:register(base_def())
  A.check(d1 ~= nil, "dr: first registration succeeded (" .. tostring(e1 and e1.message) .. ")")
  local d2, e2 = reg:register(base_def())
  A.check(d2 == d1, "dr: same-hash duplicate returns the existing definition")
  A.check(e2 == nil, "dr: same-hash duplicate is not an error")
  A.assert_eq(reg:count(), 1, "dr: registry holds exactly one definition")
  A.check(d1.hash ~= nil and d1.hash:match("^%x+$") ~= nil, "dr: definition hash present and hex")
end

-------------------------------------------------------------------------------
-- B. Same id, different definition hash -> typed error, no registration
-------------------------------------------------------------------------------
do
  local d3, e3 = reg:register(base_def({ description = "DIFFERENT description" }))
  A.check(d3 == nil, "dr: conflicting duplicate rejected")
  A.check(e3 ~= nil, "dr: conflicting duplicate returns a typed error")
  A.assert_eq(e3.code, schema_mod.ERROR.TOOL, "dr: duplicate error code TOOL")
  A.check(e3.cause and e3.cause.reason == "duplicate_registration", "dr: duplicate cause reason")
  A.check(e3.message:find("demo/echo", 1, true) ~= nil, "dr: duplicate message names the id")
  A.assert_eq(reg:count(), 1, "dr: conflicting duplicate did not register")
end

-------------------------------------------------------------------------------
-- C. Invalid definitions fail closed
-------------------------------------------------------------------------------
do
  local bad, berr = reg:register({ id = "demo/x", name = "x", description = "missing schema" })
  A.check(bad == nil and berr ~= nil, "dr: missing input_schema rejected")
  A.assert_eq(berr.code, schema_mod.ERROR.INVALID_ARGUMENT, "dr: invalid definition uses INVALID_ARGUMENT")

  local bad2, berr2 = reg:register(base_def({ input_schema = { type = "foobar" } }))
  A.check(bad2 == nil and berr2 ~= nil, "dr: malformed schema rejected (fail-closed)")
  A.check(berr2.message:find("input_schema", 1, true) ~= nil, "dr: schema error names input_schema")

  local bad3, berr3 = reg:register(base_def({ id = "no-slash-here" }))
  A.check(bad3 == nil and berr3 ~= nil, "dr: id without server-id/tool-name rejected")
  A.check(berr3.message:find("server-id/tool-name", 1, true) ~= nil, "dr: id format message")

  local bad4, berr4 = reg:register(base_def({ execution = { mode = "parallel" } }))
  A.check(bad4 == nil and berr4 ~= nil, "dr: invalid execution.mode rejected")
end

-------------------------------------------------------------------------------
-- D. Resolve by name and by full id; ambiguous names are typed errors
-------------------------------------------------------------------------------
do
  local by_name = reg:resolve("echo")
  local by_id = reg:resolve("demo/echo")
  A.check(by_name == by_id and by_name ~= nil, "dr: resolve by name == resolve by id")

  local unk = reg:resolve("no_such_tool")
  A.check(unk == nil, "dr: unknown tool resolves to nil")

  -- A second server registering the SAME tool name is legal; the bare name
  -- then becomes ambiguous while the full id stays unambiguous.
  local reg2 = registry_mod.new()
  reg2:register(base_def({ id = "demo/echo", name = "echo" }))
  reg2:register(base_def({ id = "other/echo", name = "echo", description = "other server echo" }))
  A.assert_eq(reg2:count(), 2, "dr: two servers may share a tool name")
  local amb, aerr = reg2:resolve("echo")
  A.check(amb == nil and aerr ~= nil, "dr: ambiguous bare name resolves to nil + error")
  A.check(aerr.cause and aerr.cause.reason == "ambiguous_name", "dr: ambiguous cause reason")
  local unamb = reg2:resolve("other/echo")
  A.check(unamb ~= nil, "dr: full id stays unambiguous")
end

-------------------------------------------------------------------------------
-- E. schema_for returns independent copies (provider adaptation surface)
-------------------------------------------------------------------------------
do
  local schemas = reg:schema_for("mock")
  local copy = schemas["demo/echo"]
  A.check(copy ~= nil, "dr: schema_for exposes every registered tool")
  A.check(copy ~= reg:resolve("demo/echo").input_schema, "dr: schema_for returns a copy, not the normalized schema")
  -- Mutating the copy must not affect the registered definition.
  copy.required[1] = "mutated"
  local still = reg:resolve("demo/echo").input_schema
  A.assert_eq(still.required[1], "path", "dr: mutation of the provider copy never touches the definition")
end

-------------------------------------------------------------------------------
-- F. Schema validator subset sanity (definition + oneOf + enum + items)
-------------------------------------------------------------------------------
do
  local ok_def = jschema.validate_schema_definition({
    type = "object",
    properties = { n = { type = "integer" }, tag = { type = "string", enum = { "a", "b" } } },
    items = { type = "string" },
  })
  A.check(ok_def == true, "dr: valid subset schema accepted")
  local bad_def = jschema.validate_schema_definition({ type = "array", items = { { type = "string" } } })
  A.check(bad_def == false, "dr: tuple-form items rejected (fail-closed)")
  local okv = jschema.validate({ oneOf = { { type = "string" }, { type = "integer" } } }, "x")
  A.check(okv == true, "dr: oneOf exactly-one match")
  -- 42 matches BOTH number and integer => exactly-one is violated.
  local badv, verr = jschema.validate({ oneOf = { { type = "number" }, { type = "integer" } } }, 42)
  A.check(badv == false and verr == "oneOf", "dr: oneOf double-match rejected at root")
  local badarr, verr2 = jschema.validate({ type = "array", items = { type = "integer" } }, { 1, "x" })
  A.check(badarr == false and verr2 == "[2].type", "dr: items path is indexed ([2].type)")
  local badenum, verr3 = jschema.validate({ type = "string", enum = { "a" } }, "z")
  A.check(badenum == false and verr3 == "enum", "dr: enum mismatch path")
end

if A.ok then
  print("TOOLS_DUPLICATE_REGISTER_OK")
else
  error("TOOLS_DUPLICATE_REGISTER_FAILED count=" .. #A.failures)
end
