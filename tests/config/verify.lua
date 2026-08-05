-- filepath: tests/config/verify.lua
--- W3 headless verification: LazyVim opts config merge/validation + provider resolution.
---
--- Covers (phase1-todo W3, reworked to the LazyVim-opts configuration model):
---   * legal config: `config.configure(defaults, opts)` merges and validates; every
---     provider definition resolves to a normalized record (protocol/base_url/
---     api_key_env/model/capabilities/request/adapter bind interface).
---   * fail-closed: unknown top-level keys, invalid protocol enum values, wrong
---     field types (negative context_window), literal credentials.
---   * credential guard: literal secrets rejected; `api_key_env` must be an env name.
---   * provider cross-fields: `provider.default` must exist in `definitions`
---     (or be a built-in mock/echo); empty definitions with non-builtin default fails.
---   * protocol capability matrix: `false` for a protocol-native channel conflicts
---     (gemini tools, openai_responses/anthropic reasoning); non-native/optional
---     channels (openai_chat reasoning, vision anywhere) may be false.
---   * protocol names are not aliases: provider id `gemini` with protocol
---     `openai_chat` stays openai_chat.
---   * adapter binding: `resolve_provider` binds a registered protocol adapter and
---     exposes `record:bind()` for later W4-W7 registration.
---   * built-in default: `provider.default = "mock"` with empty definitions is legal.
---
--- Offline; no network, no key. Exit contract: returns true on success; the justfile
--- recipe turns a false/error into `:cq`.
local ok_all = true
local failures = {}
local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("VERIFY_FAIL: " .. msg)
  end
end
local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end
local function contains(haystack, needle)
  for _, v in ipairs(haystack) do
    if v == needle then
      return true
    end
  end
  return false
end
-- Ensure LazyVim ecosystem (plenary.path) is require-able before loading config.
local function ensure_ecosystem()
  local ok, _ = pcall(require, "plenary.path")
  if not ok then
    error("tests/config/verify.lua: plenary.path not require-able (LazyVim ecosystem missing)")
  end
end
ensure_ecosystem()
local config = require("maxa.runtime.config")
local maxa_mod = require("maxa")
--- Merge defaults + user opts and resolve a provider; convenience wrapper.
---@param opts table user opts
---@param id? string provider id
---@return table|nil record
---@return table|nil err
local function configure_and_resolve(opts, id)
  local cfg, cerr = config.configure(maxa_mod.defaults, opts)
  if not cfg then
    return nil, cerr
  end
  return config.resolve_provider(cfg, id)
end

------------------------------------------------------------
-- 1. Legal: full deepseek definitions (mirror of lua/plugins/maxa.lua opts)
------------------------------------------------------------
do
  local opts = {
    provider = {
      default = "deepseek-chat",
      definitions = {
        ["deepseek-chat"] = {
          protocol = "openai_chat",
          base_url = "https://api.deepseek.com/",
          api_key_env = "DEEPSEEK_TEST_KEY",
          model = "deepseek-v4-flash",
          capabilities = { vision = false, tools = true, reasoning = true },
          request = { timeout_ms = 60000, connect_timeout_ms = 10000, retries = 0 },
        },
        ["deepseek-responses"] = {
          protocol = "openai_responses",
          base_url = "https://api.deepseek.com",
          api_key_env = "DEEPSEEK_TEST_KEY",
          model = "deepseek-v4-flash",
        },
        ["deepseek-anthropic"] = {
          protocol = "anthropic_messages",
          base_url = "https://api.deepseek.com/anthropic",
          api_key_env = "DEEPSEEK_TEST_KEY",
          model = "deepseek-v4-flash",
        },
      },
    },
  }
  local record, err = configure_and_resolve(opts)
  check(record ~= nil, "1: default provider resolves (err=" .. tostring(err and err.message) .. ")")
  if record then
    assert_eq(record.protocol, "openai_chat", "1: default provider protocol")
    assert_eq(record.base_url, "https://api.deepseek.com", "1: trailing slash normalized")
    assert_eq(record.api_key_env, "DEEPSEEK_TEST_KEY", "1: api_key_env preserved")
    assert_eq(record.model, "deepseek-v4-flash", "1: model carried")
    assert_eq(record.capabilities.reasoning, true, "1: declared reasoning kept")
    assert_eq(record.request.timeout_ms, 60000, "1: request timeout carried")
    check(type(record.bind) == "function", "1: record exposes bind()")
    -- openai_chat default capability matrix: tools=true native; reasoning non-native
    -- but declared true stays true; vision default false.
    assert_eq(record.capabilities.tools, true, "1: openai_chat tools native true")
    assert_eq(record.capabilities.vision, false, "1: vision defaults false")
  end
  local r2, e2 = configure_and_resolve(opts, "deepseek-responses")
  check(r2 ~= nil, "1b: named provider resolves (err=" .. tostring(e2 and e2.message) .. ")")
  if r2 then
    assert_eq(r2.protocol, "openai_responses", "1b: responses protocol")
    -- absent capabilities -> protocol defaults (reasoning true for responses).
    assert_eq(r2.capabilities.reasoning, true, "1b: responses reasoning default true")
  end
end

------------------------------------------------------------
-- 2. Built-in default: mock with empty definitions is legal
------------------------------------------------------------
do
  local cfg, cerr = config.configure(maxa_mod.defaults, {})
  check(cfg ~= nil, "2: default opts (mock, empty definitions) configure ok (err=" .. tostring(cerr and cerr.message) .. ")")
  if cfg then
    assert_eq(cfg.provider.default, "mock", "2: default provider is mock")
    -- Built-in providers never resolve through definitions (protocol registry).
    local rec, rerr = config.resolve_provider(cfg, "mock")
    check(rec == nil and rerr ~= nil, "2: mock not in definitions -> resolve_provider errors (registry owns it)")
  end
end

------------------------------------------------------------
-- 3. Fail-closed: unknown / invalid / wrong-typed fields
------------------------------------------------------------
do
  local bad_unknown, err_unknown = config.configure(maxa_mod.defaults, { not_a_key = 1 })
  check(bad_unknown == nil and err_unknown ~= nil, "3: unknown top-level key rejected fail-closed")

  local bad_proto, err_proto = config.configure(maxa_mod.defaults, {
    provider = {
      default = "p1",
      definitions = { p1 = { protocol = "ftp", base_url = "https://x", model = "m" } },
    },
  })
  check(bad_proto == nil and err_proto ~= nil, "3b: invalid protocol enum rejected")

  local bad_ctx, err_ctx = config.configure(maxa_mod.defaults, {
    provider = {
      default = "p1",
      definitions = { p1 = { protocol = "openai_chat", base_url = "https://x", model = "m", context_window = -5 } },
    },
  })
  check(bad_ctx == nil and err_ctx ~= nil, "3c: negative context_window rejected fail-closed")

  local bad_url, err_url = config.configure(maxa_mod.defaults, {
    provider = {
      default = "p1",
      definitions = { p1 = { protocol = "openai_chat", base_url = "", model = "m" } },
    },
  })
  check(bad_url == nil and err_url ~= nil, "3d: empty base_url rejected")
end

------------------------------------------------------------
-- 4. Credential guard
------------------------------------------------------------
do
  local bad_secret, err_secret = config.configure(maxa_mod.defaults, {
    provider = {
      default = "p1",
      definitions = { p1 = { protocol = "openai_chat", base_url = "https://x", model = "m", api_key = "sk-literal" } },
    },
  })
  check(bad_secret == nil and err_secret ~= nil, "4: literal api_key rejected")

  local bad_secret_nested, _ = config.configure(maxa_mod.defaults, {
    provider = {
      default = "p1",
      definitions = { p1 = { protocol = "openai_chat", base_url = "https://x", model = "m", request = { headers = { token = "xyz" } } } },
    },
  })
  check(bad_secret_nested == nil, "4b: nested secret value rejected (request.headers.token)")

  local bad_env, err_env = config.configure(maxa_mod.defaults, {
    provider = {
      default = "p1",
      definitions = { p1 = { protocol = "openai_chat", base_url = "https://x", model = "m", api_key_env = "sk-12345" } },
    },
  })
  check(bad_env == nil and err_env ~= nil, "4c: api_key_env must be an env name (not a literal)")
end

------------------------------------------------------------
-- 5. provider.default cross-field
------------------------------------------------------------
do
  local bad_default, err_default = config.configure(maxa_mod.defaults, {
    provider = {
      default = "nope",
      definitions = { p1 = { protocol = "openai_chat", base_url = "https://x", model = "m" } },
    },
  })
  check(bad_default == nil and err_default ~= nil, "5: default not in definitions rejected")

  local bad_builtin, err_builtin = config.configure(maxa_mod.defaults, {
    provider = { default = "nope", definitions = {} },
  })
  check(bad_builtin == nil and err_builtin ~= nil, "5b: non-builtin default with empty definitions rejected")
end

------------------------------------------------------------
-- 6. Protocol capability matrix
------------------------------------------------------------
do
  local bad_gemini, err_gemini = config.configure(maxa_mod.defaults, {
    provider = {
      default = "g1",
      definitions = { g1 = { protocol = "gemini", base_url = "https://x", model = "m", capabilities = { tools = false } } },
    },
  })
  check(bad_gemini == nil and err_gemini ~= nil, "6: gemini tools=false conflicts native channel")

  local bad_anthropic, _ = config.configure(maxa_mod.defaults, {
    provider = {
      default = "a1",
      definitions = { a1 = { protocol = "anthropic_messages", base_url = "https://x", model = "m", capabilities = { reasoning = false } } },
    },
  })
  check(bad_anthropic == nil, "6b: anthropic reasoning=false conflicts native channel")

  -- openai_chat reasoning is non-native: false is legal.
  local ok_chat, err_chat = config.configure(maxa_mod.defaults, {
    provider = {
      default = "c1",
      definitions = { c1 = { protocol = "openai_chat", base_url = "https://x", model = "m", capabilities = { reasoning = false, vision = false } } },
    },
  })
  check(ok_chat ~= nil, "6c: openai_chat reasoning=false is legal (err=" .. tostring(err_chat and err_chat.message) .. ")")
end

------------------------------------------------------------
-- 7. Protocol names are not aliases + adapter binding
------------------------------------------------------------
do
  local opts = {
    provider = {
      default = "gemini",
      definitions = {
        gemini = { protocol = "openai_chat", base_url = "https://x", model = "m" },
      },
    },
  }
  local record, err = configure_and_resolve(opts)
  check(record ~= nil, "7: provider id gemini with openai_chat protocol resolves (err=" .. tostring(err and err.message) .. ")")
  if record then
    assert_eq(record.protocol, "openai_chat", "7: id is not a protocol alias")
  end
  -- Adapter binding: after registering openai_chat, resolve binds it.
  local ok_reg = pcall(require, "maxa.runtime.protocol.adapters.openai_chat")
  check(ok_reg, "7b: openai_chat adapter loads")
  local rec2, rerr2 = configure_and_resolve({
    provider = {
      default = "p1",
      definitions = { p1 = { protocol = "openai_chat", base_url = "https://x", model = "m" } },
    },
  })
  check(rec2 ~= nil, "7c: resolve ok (err=" .. tostring(rerr2 and rerr2.message) .. ")")
  if rec2 then
    check(rec2.adapter ~= nil, "7d: adapter bound to record")
  end
end

------------------------------------------------------------
-- 8. State file round-trip (.maxa/state.yaml, temp project)
------------------------------------------------------------
do
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp .. "/.maxa", "p")
  local root = tmp
  local path, serr = config.save_state(root, {
    schema_version = 1,
    project_id = "state-test",
    status = "active",
  })
  check(path ~= nil, "8: save_state ok (err=" .. tostring(serr and serr.message) .. ")")
  local state, lerr = config.load_state(root)
  check(state ~= nil, "8b: load_state ok (err=" .. tostring(lerr and lerr.message) .. ")")
  if state then
    assert_eq(state.schema_version, 1, "8c: state schema_version round-trips")
    assert_eq(state.project_id, "state-test", "8d: state project_id round-trips")
    assert_eq(state.status, "active", "8e: state status round-trips")
  end
  -- Missing state file is not an error.
  local empty_root = vim.fn.tempname()
  vim.fn.mkdir(empty_root .. "/.maxa", "p")
  local s2, e2 = config.load_state(empty_root)
  check(s2 == nil and e2 == nil, "8f: missing state.yaml -> nil, nil (not an error)")
end

if ok_all then
  print("CONFIG_VERIFY_OK")
else
  print("CONFIG_VERIFY_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
