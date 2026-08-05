-- filepath: tests/protocol/runner.lua
--- Headless protocol fixture runner (phase-1 W1 infrastructure).
---
--- Purpose: W1 delivers the skeleton only — fixture discovery + envelope
--- validation + comparison helpers. Adapter execution (fixture -> adapter ->
--- feed frames -> assert) lands with W4-W7; this runner is their harness.
---
--- Behavior today (W1):
---   - waits for the LazyVim ecosystem (plenary) and the maxa runtime modules
---   - loads `lua/maxa/runtime/protocol/sse.lua` + `transport.lua` (proves the
---     W1 infrastructure loads headless)
---   - runs the assertion-helper self-test (deep_eq semantics)
---   - discovers every `*.yaml` under tests/protocol/fixtures (and subdirs),
---     decodes it with maxa.runtime.config.yaml, validates the fixture envelope
---     against protocol-fixture-contract.md
---   - prints a summary; exits 0 on success, `cq` (exit 1) on any failure
---
--- Usage:
---   nvim --headless -l tests/protocol/runner.lua [--dir DIR] [--only ID]
---   just test-protocol    (same script via the lazy-wait wrapper)
---
--- Comparison rules (contract §"Common fixture envelope"):
---   - JSON object key order is irrelevant; array order is significant.
---   - Empty JSON objects stay objects (adapter-side concern; here deep_eq
---     treats empty tables as equal because Lua cannot distinguish {} and []).
---   - Omitted optional fields and explicit null are distinct where the
---     provider distinguishes them (adapter-phase assertion concern).

vim.opt.runtimepath:prepend("/home/maxzhao/maxa")

--- Resolve the directory containing this script (works for both `-l` and
--- `dofile` invocation; absolutized so relative -l paths resolve correctly).
---@return string dir
local function script_dir()
  local src = debug.getinfo(1, "S").source or ""
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(vim.fn.fnamemodify(path, ":p"), ":h")
end

local ROOT = vim.fn.fnamemodify(script_dir() .. "/..", ":p")
local DEFAULT_FIXTURE_DIR = ROOT .. "protocol/fixtures"

--- Wait until the LazyVim ecosystem modules are require-able. `-l` scripts run
--- before lazy.nvim's startup pass finishes, so plenary may not be on rtp yet
--- (mirrors scripts/smoke.lua::ensure_ecosystem).
---@return boolean ready
local function ensure_ecosystem()
  local needs = { "plenary.path", "plenary.curl", "maxa.runtime.config.yaml" }
  local function all_ready()
    for _, name in ipairs(needs) do
      if not pcall(require, name) then
        return false
      end
    end
    return true
  end
  if all_ready() then
    return true
  end
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    pcall(lazy.load, { "nvim-lua/plenary.nvim" })
  end
  local deadline = vim.loop.hrtime() + 20000 * 1e6
  while vim.loop.hrtime() < deadline do
    if all_ready() then
      return true
    end
    vim.wait(100)
  end
  return false
end

local M = {}

M.name = "protocol.runner"

---@class ProtocolFixture
---@field path string absolute fixture file path
---@field id string
---@field protocol string
---@field mode string
---@field data table decoded YAML

------------------------------------------------------------
-- Comparison helpers (contract comparison rules)
------------------------------------------------------------

--- Deep structural equality: objects compare by key set (order irrelevant),
--- arrays compare in order. Empty tables compare equal (Lua cannot
--- distinguish `{}` from `[]`; adapters assert that distinction separately
--- when serializing).
---@param a any
---@param b any
---@return boolean equal
function M.deep_eq(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  local a_list, b_list = vim.tbl_islist(a), vim.tbl_islist(b)
  if a_list ~= b_list then
    -- Lua cannot distinguish an empty JSON object from an empty array at the
    -- table level (vim.tbl_islist({}) is true, vim.empty_dict() is not, yet both
    -- are "empty tables"). The object-vs-array distinction is asserted by
    -- adapters via JSON encoding (vim.empty_dict/vim.json.encode), never here;
    -- two empty tables are structurally equal.
    if vim.tbl_isempty(a) and vim.tbl_isempty(b) then
      return true
    end
    return false
  end
  if a_list then
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if not M.deep_eq(a[i], b[i]) then
        return false
      end
    end
    return true
  end
  for k, v in pairs(a) do
    if not M.deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

--- Human-readable description of the first difference (for failure output).
---@param a any
---@param b any
---@param path? string current comparison path
---@return string|nil description
function M.diff_desc(a, b, path)
  path = path or "$"
  if type(a) ~= type(b) then
    return ("%s: type mismatch %s vs %s"):format(path, type(a), type(b))
  end
  if type(a) ~= "table" then
    if a ~= b then
      return ("%s: %s vs %s"):format(path, vim.inspect(a), vim.inspect(b))
    end
    return nil
  end
  local a_list, b_list = vim.tbl_islist(a), vim.tbl_islist(b)
  if a_list ~= b_list then
    -- Same empty-table rule as deep_eq: {} vs [] is indistinguishable in Lua
    -- and must be asserted via JSON encoding, not here.
    if vim.tbl_isempty(a) and vim.tbl_isempty(b) then
      return nil
    end
    return ("%s: shape mismatch (%s vs %s)"):format(
      path,
      a_list and "array" or "object",
      b_list and "array" or "object"
    )
  end
  if a_list then
    if #a ~= #b then
      return ("%s: length mismatch %d vs %d"):format(path, #a, #b)
    end
    for i = 1, #a do
      local d = M.diff_desc(a[i], b[i], ("%s[%d]"):format(path, i))
      if d then
        return d
      end
    end
    return nil
  end
  for k, v in pairs(a) do
    if b[k] == nil then
      return ("%s.%s: missing in expected"):format(path, tostring(k))
    end
    local d = M.diff_desc(v, b[k], ("%s.%s"):format(path, tostring(k)))
    if d then
      return d
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return ("%s.%s: unexpected key"):format(path, tostring(k))
    end
  end
  return nil
end

--- Assert deep equality; appends a failure record when mismatched.
---@param actual any
---@param expected any
---@param label string
---@param failures string[] accumulator
function M.assert_eq(actual, expected, label, failures)
  local d = M.diff_desc(actual, expected)
  if d then
    failures[#failures + 1] = ("assert_eq(%s): %s"):format(label, d)
  end
end

--- Assert a boolean condition; appends a failure record when false.
---@param cond any
---@param msg string
---@param failures string[] accumulator
function M.expect(cond, msg, failures)
  if not cond then
    failures[#failures + 1] = ("expect: %s"):format(msg)
  end
end

--- Self-test of the comparison helpers (always runs; deterministic).
---@return string[] failures
function M.self_test()
  local f = {}
  M.expect(M.deep_eq({ a = 1, b = { c = 2 } }, { b = { c = 2 }, a = 1 }), "object key order must be irrelevant", f)
  M.expect(not M.deep_eq({ 1, 2, 3 }, { 3, 2, 1 }), "array order must be significant", f)
  M.expect(not M.deep_eq({ 1, 2 }, { 1, 2, 3 }), "array length mismatch must fail", f)
  M.expect(M.deep_eq({ a = {} }, { a = {} }), "empty objects must compare equal", f)
  M.expect(not M.deep_eq({ a = 1 }, { a = 2 }), "value mismatch must fail", f)
  M.expect(not M.deep_eq({ 1, 2 }, { a = 1, b = 2 }), "array vs object shape must fail", f)
  M.expect(M.diff_desc(1, 2) ~= nil, "diff_desc must describe a mismatch", f)
  M.expect(M.diff_desc({ 1 }, { 1 }) == nil, "diff_desc must return nil when equal", f)
  return f
end

------------------------------------------------------------
-- Fixture discovery / envelope validation
------------------------------------------------------------

--- List all fixture files under a directory (recursive, *.yaml).
---@param dir string absolute directory
---@return string[] paths
function M.find_fixtures(dir)
  local paths = {}
  if vim.fn.isdirectory(dir) == 0 then
    return paths
  end
  -- `vim.fs.find` with a predicate does not recurse reliably on nvim 0.11.5
  -- (it visits a single top-level entry only); `globpath` with `**` is the
  -- robust recursive discovery used here.
  local found = vim.fn.globpath(dir, "**/*.yaml", false, true)
  for _, p in ipairs(found) do
    local abs = vim.fs.normalize(p)
    if not vim.startswith(abs, "/") then
      abs = dir .. "/" .. abs
    end
    paths[#paths + 1] = abs
  end
  table.sort(paths)
  return paths
end

--- Read a file's full content.
---@param path string
---@return string|nil content
---@return string|nil err
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot open " .. path
  end
  local content = f:read("*a")
  f:close()
  return content, nil
end

--- Load and decode one fixture file into a ProtocolFixture.
---@param path string
---@return table|nil fixture
---@return string|nil err
function M.load_fixture(path)
  local content, rerr = read_file(path)
  if not content then
    return nil, rerr
  end
  local yaml = require("maxa.runtime.config.yaml")
  local data, derr = yaml.decode(content)
  if not data then
    return nil, ("%s: %s"):format(path, derr)
  end
  return { path = path, data = data }, nil
end

--- Validate a fixture envelope against the protocol-fixture-contract schema.
--- Returns a list of human-readable problems (empty when valid).
---@param fixture table loaded fixture
---@return string[] problems
function M.validate_envelope(fixture)
  local problems = {}
  local data = fixture.data
  if type(data) ~= "table" then
    return { ("%s: fixture root must be a mapping"):format(fixture.path) }
  end

  local protocols = { openai_chat = true, openai_responses = true, anthropic_messages = true, gemini = true }
  local modes = { streamed = true, non_streamed = true }
  local terminals = { completed = true, failed = true, cancelled = true, incomplete = true }

  local function is_map(v)
    return type(v) == "table"
  end
  local function is_list(v)
    return type(v) == "table" and vim.tbl_islist(v)
  end
  local function is_str(v)
    return type(v) == "string" and v ~= ""
  end

  if not is_str(data.id) then
    problems[#problems + 1] = "missing/invalid id (non-empty string)"
  end
  if not is_str(data.protocol) or not protocols[data.protocol] then
    problems[#problems + 1] = "invalid protocol (openai_chat|openai_responses|anthropic_messages|gemini)"
  end
  if not is_str(data.mode) or not modes[data.mode] then
    problems[#problems + 1] = "invalid mode (streamed|non_streamed)"
  end

  local req = data.request
  if not is_map(req) then
    problems[#problems + 1] = "request: missing mapping"
  else
    if not is_list(req.normalized_messages) then
      problems[#problems + 1] = "request.normalized_messages: must be a list"
    end
    if not is_list(req.normalized_tools) then
      problems[#problems + 1] = "request.normalized_tools: must be a list"
    end
    if not is_map(req.expected_body) then
      problems[#problems + 1] = "request.expected_body: must be a mapping"
    end
  end

  local res = data.response
  if not is_map(res) then
    problems[#problems + 1] = "response: missing mapping"
  else
    if not is_list(res.chunks) then
      problems[#problems + 1] = "response.chunks: must be a list"
    end
    if not is_list(res.expected_events) then
      problems[#problems + 1] = "response.expected_events: must be a list"
    end
    if not is_map(res.expected_message) then
      problems[#problems + 1] = "response.expected_message: must be a mapping"
    end
    if not is_list(res.expected_tool_calls) then
      problems[#problems + 1] = "response.expected_tool_calls: must be a list"
    end
    if not is_map(res.expected_usage) then
      problems[#problems + 1] = "response.expected_usage: must be a mapping"
    end
    if not is_str(res.expected_terminal) or not terminals[res.expected_terminal] then
      problems[#problems + 1] = "response.expected_terminal: invalid (completed|failed|cancelled|incomplete)"
    end
  end

  return problems
end

------------------------------------------------------------
-- CLI / main
------------------------------------------------------------

--- Parse `--key value` style args from the global `arg` table.
---@return table opts { dir=string|nil, only=string|nil }
local function parse_args()
  local opts = {}
  local args = arg or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--dir" then
      opts.dir = args[i + 1]
      i = i + 1
    elseif a == "--only" then
      opts.only = args[i + 1]
      i = i + 1
    elseif a:match("^%-%-dir=") then
      opts.dir = a:sub(7)
    elseif a:match("^%-%-only=") then
      opts.only = a:sub(8)
    end
    i = i + 1
  end
  return opts
end

--- Main entry: ecosystem check, module load, helper self-test, fixture
--- discovery + envelope validation, summary, exit.
---@return boolean ok
function M.main()
  if not ensure_ecosystem() then
    print("PROTOCOL_RUNNER_FAIL: LazyVim ecosystem not ready (run `just setup` and boot nvim-maxa once)")
    return false
  end

  local failures = {}

  -- W1 infrastructure module load proof (adapters use these in W4+).
  local sse_ok, sse = pcall(require, "maxa.runtime.protocol.sse")
  local transport_ok, transport = pcall(require, "maxa.runtime.protocol.transport")
  M.expect(sse_ok and type(sse.new) == "function", "maxa.runtime.protocol.sse must load", failures)
  M.expect(transport_ok and type(transport.new) == "function", "maxa.runtime.protocol.transport must load", failures)

  -- Comparison helper self-test.
  vim.list_extend(failures, M.self_test())

  -- Fixture discovery + envelope validation.
  local opts = parse_args()
  local dir = opts.dir or DEFAULT_FIXTURE_DIR
  local fixture_paths = M.find_fixtures(dir)
  local fixtures = {}
  for _, path in ipairs(fixture_paths) do
    local fx, err = M.load_fixture(path)
    if not fx then
      failures[#failures + 1] = err
    else
      fixtures[#fixtures + 1] = fx
    end
  end
  for _, fx in ipairs(fixtures) do
    if opts.only and fx.data.id ~= opts.only then
      goto continue
    end
    local problems = M.validate_envelope(fx)
    for _, p in ipairs(problems) do
      failures[#failures + 1] = ("%s [%s]: %s"):format(fx.path, tostring(fx.data.id), p)
    end
    ::continue::
  end

  -- Adapter execution via per-protocol drivers (W4-W7).
  -- Each driver lives at tests/protocol/drivers/<protocol>.lua and exposes
  --   run_fixture(fixture, adapter, runner) -> string[] (empty on success).
  -- Driver loading uses dofile (tests/ is not on rtp; runner knows its own dir).
  local protocol_mod_ok, protocol_mod = pcall(require, "maxa.runtime.protocol")
  if not protocol_mod_ok then
    failures[#failures + 1] = "maxa.runtime.protocol failed to load: " .. tostring(protocol_mod)
  else
    local drivers_dir = ROOT .. "protocol/drivers"
    for _, fx in ipairs(fixtures) do
      if not (opts.only and fx.data.id ~= opts.only) then
        local pname = fx.data.protocol
        local driver_path = drivers_dir .. "/" .. pname .. ".lua"
        local d_ok, driver = pcall(dofile, driver_path)
        if not d_ok then
          failures[#failures + 1] = ("%s [%s]: driver error: %s"):format(fx.path, tostring(fx.data.id), tostring(driver))
        elseif type(driver) ~= "table" or type(driver.run_fixture) ~= "function" then
          failures[#failures + 1] = ("%s [%s]: driver %s missing run_fixture"):format(fx.path, tostring(fx.data.id), pname)
        else
          local adapter = protocol_mod.get_adapter(pname)
          if not adapter then
            failures[#failures + 1] = ("%s [%s]: adapter %q not registered"):format(fx.path, tostring(fx.data.id), pname)
          else
            local f = driver.run_fixture(fx, adapter, M)
            for _, item in ipairs(f or {}) do
              failures[#failures + 1] = ("%s [%s]: %s"):format(fx.path, tostring(fx.data.id), item)
            end
          end
        end
      end
    end
  end

  if #failures == 0 then
    print(("PROTOCOL_RUNNER_OK fixtures=%d self_test=ok modules=sse+transport"):format(#fixtures))
    return true
  end

  print(("PROTOCOL_RUNNER_FAIL fixtures=%d failures=%d"):format(#fixtures, #failures))
  for _, f in ipairs(failures) do
    print("  - " .. f)
  end
  return false
end

local ok = M.main()
if not ok then
  vim.cmd("cq")
end

return M
