-- Run: nvim --headless -l lua/maxa/adapters/proxy_test.lua
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("✓ " .. name) else failed = failed + 1; print("✗ " .. name .. ": " .. tostring(err)) end
end
local function eq(expected, actual) assert(expected == actual, string.format("expected %s, got %s", tostring(expected), tostring(actual))) end

local root = vim.fn.stdpath("config")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local definitions = {
  gateway = { id = "gateway", proxy = true },
  direct = { id = "direct", proxy = false },
  own = { id = "own", proxy = "socks5://127.0.0.1:10809" },
}
package.loaded["maxa.provider_config"] = {
  provider = function(id) return definitions[id] end,
}
local proxy = require("maxa.adapters.proxy")
local function adapter(id) return { name = id, backend = { id = id } } end

test("provider owns proxy policy, not adapter metadata or name", function()
  eq(true, proxy.needs_proxy(adapter("gateway")))
  eq(false, proxy.needs_proxy({ name = "gateway", maxa = { proxy = true } }))
  eq(false, proxy.needs_proxy(adapter("direct")))
  eq(false, proxy.needs_proxy({ name = "gemini" }))
end)

test("env is explicit and disabled global never consults it", function()
  local original = package.loaded["maxa.utils.env"]
  local current = "http://env.example:8080"
  local lookups = 0
  package.loaded["maxa.utils.env"] = { proxy = function() lookups = lookups + 1; return current end }
  local ok, err = pcall(function()
    proxy.configure(nil)
    eq(nil, proxy.resolve(adapter("gateway")))
    proxy.configure(false)
    eq(nil, proxy.resolve(adapter("gateway")))
    eq(0, lookups)
    local direct = proxy.apply_curl({ "curl" }, adapter("gateway"))
    eq("--noproxy", direct[2]); eq("*", direct[3])
    eq("socks5://127.0.0.1:10809", proxy.resolve(adapter("own")))
    proxy.configure("env")
    eq("env", proxy.get_proxy())
    eq(nil, proxy.resolve(adapter("direct")))
    eq(0, lookups)
    eq(current, proxy.resolve(adapter("gateway")))
    current = "http://changed.example:8080"
    eq(current, proxy.resolve(adapter("gateway")))
    current = nil
    eq(nil, proxy.resolve(adapter("gateway")))
    eq(3, lookups)
  end)
  package.loaded["maxa.utils.env"] = original
  if not ok then error(err) end
end)

test("global and provider addresses have independent precedence", function()
  proxy.configure("http://127.0.0.1:10808")
  eq("http://127.0.0.1:10808", proxy.resolve(adapter("gateway")))
  eq("socks5://127.0.0.1:10809", proxy.resolve(adapter("own")))
  eq(nil, proxy.resolve(adapter("direct")))
  eq(nil, proxy.resolve(adapter("missing")))
  local args = proxy.apply_curl({ "curl" }, adapter("gateway"))
  eq("--proxy", args[2]); eq("http://127.0.0.1:10808", args[3])
  local direct = proxy.apply_curl({ "curl" }, adapter("direct"))
  eq("--noproxy", direct[2]); eq("*", direct[3])
end)

test("global and provider callbacks resolve per request, nil stays direct", function()
  local current = "http://127.0.0.1:10808"
  local seen = {}
  proxy.configure(function(provider) seen[#seen + 1] = provider.id; return current end)
  eq("http://127.0.0.1:10808", proxy.resolve(adapter("gateway")))
  current = nil
  eq(nil, proxy.resolve(adapter("gateway")))
  eq("gateway", seen[2])
  definitions.own.proxy = function(provider) eq("own", provider.id); return current end
  eq(nil, proxy.resolve(adapter("own")))
  current = "socks5://127.0.0.1:10809"
  eq(current, proxy.resolve(adapter("own")))
  eq(2, #seen)
end)

test("invalid policy and callback results fail explicitly", function()
  eq(false, pcall(proxy.configure, true))
  proxy.configure("http://127.0.0.1:10808")
  definitions.own.proxy = function() return false end
  eq(false, pcall(proxy.resolve, adapter("own")))
  definitions.own.proxy = function() error("proxy callback failed") end
  eq(false, pcall(proxy.resolve, adapter("own")))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
