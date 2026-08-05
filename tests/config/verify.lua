-- filepath: tests/config/verify.lua
--- W3 headless verification: full `runtime.yaml` schema + provider resolution.
---
--- Covers (phase1-todo W3):
---   * legal config: the real /home/maxzhao/maxa/.maxa/runtime.yaml parses; every
---     provider definition resolves to a normalized record (protocol/base_url/
---     api_key_env/model/capabilities/request/adapter bind interface).
---   * fail-closed: unknown top-level and nested fields, deprecated top-level
---     `model`/`prompts`, invalid enum values, wrong request types.
---   * credential guard: literal secrets rejected; `api_key_env` must be an env name.
---   * provider cross-fields: `provider.default` must exist in `definitions`.
---   * protocol capability matrix: `false` for a protocol-native channel conflicts
---     (gemini tools, openai_responses/anthropic reasoning); non-native/optional
---     channels (openai_chat reasoning, vision anywhere) may be false.
---   * protocol names are not aliases: provider id `gemini` with protocol
---     `openai_chat` stays openai_chat.
---   * adapter binding: `resolve_provider` binds a registered protocol adapter and
---     exposes `record:bind()` for later W4-W7 registration.
---
--- Offline; no network, no key. Exit contract: returns true on success; the justfile
--- recipe turns a false/error into `:cq`.
local failures = 0
local checks = 0

local function expect(cond, label)
  checks = checks + 1
  if cond then
    print(("  ok   %s"):format(label))
  else
    failures = failures + 1
    print(("  FAIL %s"):format(label))
  end
end

local function contains(haystack, needle)
  return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

-- Ensure LazyVim ecosystem (plenary.path) is require-able before loading config.
local function ensure_ecosystem()
  if pcall(require, "plenary.path") then
    return true
  end
  local deadline = vim.loop.hrtime() + 20000 * 1e6
  while vim.loop.hrtime() < deadline do
    if pcall(require, "plenary.path") then
      return true
    end
    vim.wait(100)
  end
  return false
end

if not ensure_ecosystem() then
  print("CONFIG_VERIFY_FAIL: plenary not ready")
  return false
end

local config = require("maxa.runtime.config")
local schema = require("maxa.runtime.schema")
local yaml = require("maxa.runtime.config.yaml")

--- Write `content` to a fresh temp project's `.maxa/runtime.yaml` and load it.
---@param content string YAML document
---@return table|nil snap
---@return table|nil err
local function load_cfg(content)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.maxa", "p")
  local fh = assert(io.open(dir .. "/.maxa/runtime.yaml", "wb"))
  fh:write(content)
  fh:close()
  return config.load(dir, { resolve_root = false })
end

--- Resolve a provider from a temp config; convenience for error-case assertions.
local function resolve_from(content, id)
  local snap, err = load_cfg(content)
  if not snap then
    return nil, err
  end
  return config.resolve_provider(snap, id)
end

print("== config W3 verify ==")

------------------------------------------------------------
-- 1. Legal config: real /home/maxzhao/maxa/.maxa/runtime.yaml
------------------------------------------------------------
print("-- 1 legal: real .maxa/runtime.yaml")
do
  local snap, err = config.load("/home/maxzhao/maxa", { resolve_root = false })
  expect(snap ~= nil, "real runtime.yaml loads" .. (err and (" (" .. err.message .. ")") or ""))
  if snap then
    local src = snap:source()
    expect(src.config_path == "/home/maxzhao/maxa/.maxa/runtime.yaml", "evidence config_path")
    expect(src.schema_version == 1, "evidence schema_version")

    local p = snap:get("provider")
    expect(type(p) == "table" and p.default == "deepseek-chat", "provider.default == deepseek-chat")

    local cases = {
      {
        id = "deepseek-chat",
        protocol = "openai_chat",
        base_url = "https://api.deepseek.com",
      },
      {
        id = "deepseek-responses",
        protocol = "openai_responses",
        base_url = "https://api.deepseek.com",
      },
      {
        id = "deepseek-anthropic",
        protocol = "anthropic_messages",
        base_url = "https://api.deepseek.com/anthropic",
      },
    }
    for _, c in ipairs(cases) do
      local rec, rerr = config.resolve_provider(snap, c.id)
      expect(rec ~= nil, ("resolve %s"):format(c.id) .. (rerr and (" (" .. rerr.message .. ")") or ""))
      if rec then
        expect(rec.id == c.id, ("%s.id"):format(c.id))
        expect(rec.protocol == c.protocol, ("%s.protocol == %s"):format(c.id, c.protocol))
        expect(rec.base_url == c.base_url, ("%s.base_url normalized (%s)"):format(c.id, rec.base_url))
        expect(rec.api_key_env == "DEEPSEEK_TEST_KEY", ("%s.api_key_env"):format(c.id))
        expect(
          rec.api_key == nil or type(rec.api_key) == "string",
          ("%s.api_key is nil-or-string (never persisted)"):format(c.id)
        )
        expect(rec.model == "deepseek-v4-flash", ("%s.model"):format(c.id))
        expect(
          rec.capabilities.vision == false and rec.capabilities.tools == true and rec.capabilities.reasoning == true,
          ("%s.capabilities merged {vision=false,tools=true,reasoning=true}"):format(c.id)
        )
        expect(
          rec.request.timeout_ms == 60000
            and rec.request.connect_timeout_ms == 10000
            and rec.request.retries == 0
            and rec.request.proxy_env == nil,
          ("%s.request normalized (null proxy_env -> nil)"):format(c.id)
        )
        expect(rec.adapter == nil, ("%s.adapter unbound (no W4-W7 adapter yet)"):format(c.id))
        expect(type(rec.bind) == "function", ("%s.bind interface present"):format(c.id))
      end
    end

    -- snapshot immutability (fail-closed)
    local ok_set, set_err = pcall(function()
      snap:get(nil).project_id = "mutated"
    end)
    expect(not ok_set and contains(tostring(set_err), "immutable"), "snapshot is immutable")

    -- default provider resolution without explicit id
    local defrec = config.resolve_provider(snap)
    expect(defrec ~= nil and defrec.id == "deepseek-chat", "resolve_provider defaults to provider.default")
  end
end

------------------------------------------------------------
-- 2. Legal: trailing-slash base_url + absent capabilities + extensions
------------------------------------------------------------
print("-- 2 legal: trailing slash, defaults, extensions, null structs")
do
  local y = [=[
schema_version: 1
project_id: w3-test
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com/v1///
      model: m1
extensions:
  custom:
    anything: true
history: null
]=]
  local snap, err = load_cfg(y)
  expect(snap ~= nil, "parses with trailing slash / extensions / null" .. (err and (" (" .. err.message .. ")") or ""))
  if snap then
    local rec = config.resolve_provider(snap, "p1")
    expect(rec.base_url == "https://api.example.com/v1", "base_url trailing slashes stripped")
    expect(
      rec.capabilities.vision == false and rec.capabilities.tools == true and rec.capabilities.reasoning == false,
      "openai_chat capability defaults {vision=false,tools=true,reasoning=false}"
    )
    expect(rec.api_key_env == nil and rec.api_key == nil, "api_key_env optional")
  end
end

------------------------------------------------------------
-- 3. Fail-closed: unknown / deprecated / invalid fields
------------------------------------------------------------
print("-- 3 fail-closed: unknown and deprecated fields")
do
  local _, err = load_cfg("schema_version: 1\nproject_id: x\nbogus: 1\n")
  expect(err ~= nil and contains(err.message, "unknown core field"), "unknown top-level field rejected")

  local _, err2 = load_cfg("schema_version: 1\nproject_id: x\nmodel: m\n")
  expect(
    err2 ~= nil and contains(err2.message, "unknown core field"),
    "deprecated top-level model rejected (fail-closed)"
  )

  local _, err3 = load_cfg("schema_version: 1\nproject_id: x\nprompts: {}\n")
  expect(err3 ~= nil and contains(err3.message, "unknown core field"), "deprecated top-level prompts rejected")

  local ui_err = [=[
schema_version: 1
project_id: x
ui:
  layout: vertical
  bogus: 1
]=]
  local _, err4 = load_cfg(ui_err)
  expect(err4 ~= nil and contains(err4.message, "ui.bogus"), "unknown nested ui field rejected")

  local cap_err = [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
      capabilities:
        capabilitiez: true
]=]
  local _, err5 = load_cfg(cap_err)
  expect(err5 ~= nil and contains(err5.message, "capabilitiez"), "unknown capability key rejected")

  local enum_err = [=[
schema_version: 1
project_id: x
ui:
  layout: popup
]=]
  local _, err6 = load_cfg(enum_err)
  expect(err6 ~= nil and contains(err6.message, "must be one of"), "ui.layout enum enforced")

  local type_err = [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
      request:
        timeout_ms: fast
]=]
  local _, err7 = load_cfg(type_err)
  expect(err7 ~= nil and contains(err7.message, "timeout_ms"), "request.timeout_ms type enforced")

  local _, err8 = load_cfg("project_id: x\n")
  expect(err8 ~= nil and contains(err8.message, "schema_version"), "required schema_version enforced")
end

------------------------------------------------------------
-- 4. Credential guard
------------------------------------------------------------
print("-- 4 credential guard")
do
  local lit = [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
      api_key: sk-abcdef123456
]=]
  local _, err = load_cfg(lit)
  expect(err ~= nil and contains(err.message, "literal credential"), "literal api_key rejected")

  local bad_env = [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
      api_key_env: sk-abc/def
]=]
  local _, err2 = load_cfg(bad_env)
  expect(
    err2 ~= nil and contains(err2.message, "environment variable name"),
    "api_key_env must be an env name (no literals)"
  )

  local ok_env = [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
      api_key_env: W3_TEST_KEY
      request:
        proxy_env: HTTPS_PROXY
]=]
  local snap, err3 = load_cfg(ok_env)
  expect(snap ~= nil, "valid env-name api_key_env accepted" .. (err3 and (" (" .. err3.message .. ")") or ""))
  if snap then
    local rec = config.resolve_provider(snap, "p1")
    expect(rec.api_key_env == "W3_TEST_KEY", "env name preserved in record")
    expect(rec.request.proxy_env == "HTTPS_PROXY", "proxy_env env name preserved")
  end
end

------------------------------------------------------------
-- 5. provider.default cross-field
------------------------------------------------------------
print("-- 5 provider.default cross-field")
do
  local no_default = [=[
schema_version: 1
project_id: x
provider:
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
]=]
  local _, err = load_cfg(no_default)
  expect(err ~= nil and contains(err.message, "provider.default"), "provider.default required when block present")

  local bad_default = [=[
schema_version: 1
project_id: x
provider:
  default: nope
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
]=]
  local _, err2 = load_cfg(bad_default)
  expect(err2 ~= nil and contains(err2.message, "not defined"), "provider.default must exist in definitions")

  local no_provider = "schema_version: 1\nproject_id: x\n"
  local snap, err3 = load_cfg(no_provider)
  expect(
    snap ~= nil,
    "provider block optional (bundled defaults apply)" .. (err3 and (" (" .. err3.message .. ")") or "")
  )
  if snap then
    local rec, rerr = config.resolve_provider(snap)
    expect(
      rec == nil and rerr ~= nil and contains(rerr.message, "no provider block"),
      "resolve without provider block errors"
    )
  end

  local unknown_id, uerr = resolve_from(
    [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
]=],
    "nope"
  )
  expect(
    unknown_id == nil and uerr ~= nil and contains(uerr.message, "unknown provider"),
    "resolve unknown provider id errors"
  )
end

------------------------------------------------------------
-- 6. Protocol capability matrix
------------------------------------------------------------
print("-- 6 protocol capability matrix")
do
  local function with_caps(protocol, caps_line)
    return [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: ]=] .. protocol .. "\n" .. [=[
      base_url: https://api.example.com
      model: m1
      capabilities:
]=] .. caps_line
  end

  local _, e1 = load_cfg(with_caps("gemini", "        tools: false\n"))
  expect(e1 ~= nil and contains(e1.message, "conflict"), "gemini tools=false conflicts (native channel)")

  local _, e2 = load_cfg(with_caps("openai_responses", "        reasoning: false\n"))
  expect(e2 ~= nil and contains(e2.message, "conflict"), "openai_responses reasoning=false conflicts (native channel)")

  local _, e3 = load_cfg(with_caps("anthropic_messages", "        reasoning: false\n"))
  expect(
    e3 ~= nil and contains(e3.message, "conflict"),
    "anthropic_messages reasoning=false conflicts (native channel)"
  )

  local _, e4 = load_cfg(with_caps("openai_responses", "        tools: false\n"))
  expect(e4 ~= nil and contains(e4.message, "conflict"), "openai_responses tools=false conflicts (native channel)")

  local snap5, e5 = load_cfg(with_caps("openai_chat", "        reasoning: false\n        vision: false\n"))
  expect(
    snap5 ~= nil,
    "openai_chat reasoning=false + vision=false allowed (non-native/optional)"
      .. (e5 and (" (" .. e5.message .. ")") or "")
  )

  local _, e6 = load_cfg(with_caps("gemini", "        protocol: openai_chat\n"))
  -- structural: protocol lives at definition top level, not under capabilities; this
  -- must fail as an unknown capability key (fail-closed), proving no alias handling.
  expect(e6 ~= nil and contains(e6.message, "protocol"), "capabilities.protocol unknown key rejected")
end

------------------------------------------------------------
-- 7. Protocol names are not aliases
------------------------------------------------------------
print("-- 7 protocol names are not aliases")
do
  local rec, err = resolve_from(
    [=[
schema_version: 1
project_id: x
provider:
  default: gemini
  definitions:
    gemini:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
      capabilities:
        tools: true
        reasoning: true
]=],
    "gemini"
  )
  expect(
    rec ~= nil and rec.protocol == "openai_chat",
    "provider id 'gemini' with protocol openai_chat stays openai_chat (no alias)"
      .. (err and (" (" .. err.message .. ")") or "")
  )

  local _, e2 = load_cfg([=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai
      base_url: https://api.example.com
      model: m1
]=])
  expect(e2 ~= nil and contains(e2.message, "must be one of"), "protocol enum rejects non-four-value names")
end

------------------------------------------------------------
-- 8. Adapter binding (W4-W7 forward path)
------------------------------------------------------------
print("-- 8 adapter binding interface")
do
  local proto = require("maxa.runtime.protocol")
  local dummy = { name = "dummy-w3-test" }
  proto.register_adapter("openai_chat", dummy)
  expect(proto.get_adapter("openai_chat") == dummy, "protocol.register_adapter/get_adapter roundtrip")

  local rec, err = resolve_from(
    [=[
schema_version: 1
project_id: x
provider:
  default: p1
  definitions:
    p1:
      protocol: openai_chat
      base_url: https://api.example.com
      model: m1
]=],
    "p1"
  )
  expect(
    rec ~= nil and rec.adapter == dummy,
    "resolve_provider binds registered adapter" .. (err and (" (" .. err.message .. ")") or "")
  )

  local bound = { name = "manual" }
  local rebound = rec:bind(bound)
  expect(rebound.adapter == bound and rebound == rec, "record:bind() rebinds without replacing record")
end

------------------------------------------------------------
-- Summary
------------------------------------------------------------
print(("CONFIG_VERIFY_RESULT checks=%d failures=%d"):format(checks, failures))
if failures == 0 then
  print("CONFIG_VERIFY_OK")
  return true
end
print("CONFIG_VERIFY_FAIL")
return false
