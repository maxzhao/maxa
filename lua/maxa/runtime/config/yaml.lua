-- filepath: lua/maxa/runtime/config/yaml.lua
--- maxa runtime YAML decode adapter for `.maxa/state.yaml`.
---
--- This is a thin fail-closed wrapper over the vendored TinyYaml parser
--- (see ./vendor/tinyyaml.lua). It replaces the previous hand-written YAML
--- subset decoder; per AGENTS.md Dependency Policy, generic YAML parsing is
--- delegated to a mature ecosystem parser instead of being reimplemented.
---
--- Contract preserved for `config/init.lua`:
---   `decode(source) -> table|nil, err|nil`
---     * a plain Lua table (mapping/sequence, or {}) on success;
---     * `nil` plus a descriptive string error on failure. Callers must treat any
---       decode failure as a fail-closed configuration error (never partial data).
---
--- TinyYaml behavior notes (verified against the vendored build, commit d280b04):
---   * `parse` RAISES on structurally broken input (bad indenting, malformed flow
---     like `{ ...`), which we catch with pcall and normalize to `nil, err`.
---   * `parse` is TOLERANT of some malformed flow/quote syntax (`k: [unclosed`,
---     `a: \"unclosedquote`) and decodes them to a table rather than erroring.
---     This is less strict than the prior hand-written fail-closed decoder, but
---     the actual configuration fail-closed guarantee still holds one layer up in
---     `config.load` (schema/unknown-key/secret validation rejects bad data). We
---     keep this documented rather than silently promising strict YAML validation.
---   * `null`/`~` scalars decode to the `yaml.null` marker (a Null-class table whose
---     `tostring` is "yaml.null"), not `nil`. `config/init.lua` treats the marker as
---     "absent" for scalar fields via `is_null_marker`; acceptable for
---     `.maxa/state.yaml` (state validation treats empty-map/absent keys
---     similarly); documented in case a later phase needs strict nulls.
---   * multi-document YAML with a leading `---` yields an array of documents;
---     `.maxa/state.yaml` is a single mapping, so load_state rejects a non-table
---     root via the decode contract.
-------------------------------------------------------------------------------
local tinyyaml = require("maxa.runtime.config.vendor.tinyyaml")

local M = {}
M.name = "config.yaml"
M.VERSION = 1

--- Decode a YAML source string into a plain Lua table.
---@param source string YAML document text
---@return table|nil decoded value (table mapping/sequence, or {} for empty doc)
---@return string|nil err descriptive error on failure (nil on success)
function M.decode(source)
  if type(source) ~= "string" then
    return nil, "config.yaml: decode expects a string source"
  end
  local ok, data = pcall(tinyyaml.parse, source)
  if not ok then
    -- TinyYaml raises a table/string on malformed input; flatten to a message.
    local detail = type(data) == "string" and data or vim.inspect(data)
    return nil, ("config.yaml: yaml parse error -- %s"):format(detail)
  end
  if type(data) ~= "table" then
    return nil, "config.yaml: yaml parsed to a non-table value"
  end
  return data, nil
end

return M
