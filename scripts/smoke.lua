-- filepath: scripts/smoke.lua
--- Phase-0 headless smoke/verify script for maxa (invoked via `just smoke`).
---
--- Loads the full maxa runtime inside the harness, checks import-guard semantics
--- (forbids codecompanion/mcphub/util.hooks; allows ecosystem), and runs one
--- end-to-end echo submit through the host Chat view. Deterministic, offline,
--- no key/network required.
--
-- Note: `just` runs this with `nvim --headless -l scripts/smoke.lua` under NVIM_APPNAME=nvim-maxa
-- (booting THIS repo as LazyVim config, so lua/maxa is on rtp). defend-prepend the repo too.
vim.opt.runtimepath:prepend("/home/maxzhao/maxa")

-- `-l script` may execute before lazy.nvim has finished registering plugin runtimes
-- (plenary/snacks land on rtp only after lazy's startup pass). Wait for the key
-- ecosystem modules to be require-able before loading the maxa runtime.
local function ensure_ecosystem()
  if pcall(require, "plenary.path") and pcall(require, "snacks") then
    return true
  end
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    pcall(lazy.load, { "nvim-lua/plenary.nvim", "folke/snacks.nvim" })
  end
  local deadline = vim.loop.hrtime() + 20000 * 1e6
  while vim.loop.hrtime() < deadline do
    if pcall(require, "plenary.path") and pcall(require, "snacks") then
      return true
    end
    vim.wait(100)
  end
  return false
end

if not ensure_ecosystem() then
  error("smoke: LazyVim ecosystem (plenary/snacks) not ready; run `just setup` and a first `nvim-maxa` boot to install plugins, then retry")
end

local ok, err = true, nil

-- 1) guard + runtime load
local g = require("maxa.runtime.guard")
local r = require("maxa.runtime")
if #r.modules < 1 then ok = false; err = "runtime modules empty" end

-- 2) ecosystem allowed, three legacy families forbidden
if ok and g.is_forbidden("plenary.async") then ok = false; err = "guard wrongly blocks plenary" end
if ok and g.is_forbidden("snacks") then ok = false; err = "guard wrongly blocks snacks" end
if ok and (not g.is_forbidden("codecompanion") or not g.is_forbidden("mcphub") or not g.is_forbidden("util.hooks")) then
  ok = false; err = "guard misses legacy families"
end

-- 3) host echo submit end-to-end
if ok then
  local host = require("maxa.runtime.host.nvim")
  local v = host.new({ provider = "echo" })
  local res = v:submit("smoke")
  if res == nil or res.terminal_state ~= "completed" then
    ok = false; err = "echo submit not completed: " .. tostring(res and res.terminal_state)
  end
end

-- 4) terminal import-guard assert (nothing legacy loaded)
if ok and not g.assert_no_forbidden() then ok = false; err = "assert_no_forbidden failed" end

if ok then
  print("SMOKE_OK modules=" .. #r.modules)
else
  print("SMOKE_FAIL: " .. tostring(err))
  vim.cmd("cq")
end
