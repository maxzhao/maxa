-- filepath: tests/tools/config-assembly.lua
--- Phase-3 W7 fixture: mcp/skills config wiring + runtime assembly.
---   * M.defaults expose the documented mcp/skills fields (enabled /
---     servers_file; enabled / roots.bundled|config|project),
---   * fail-closed validation: unknown mcp/skills keys and wrong field types
---     are configuration errors,
---   * maxa.setup assembles the project extension content: `.maxa/mcp/servers
---     .yaml` is loaded through mcp.config (missing file = EMPTY configuration,
---     never an error; `.supermax/` is never consulted) and the skill root
---     switches are recorded on M.assembly,
---   * mcp.config.load honors an explicit servers_file option.
---
--- Fixture convention: prints TOOLS_CONFIG_ASSEMBLY_OK on success; throws.
local assert_mod = require("tests.state.lib.assert")
local config = require("maxa.runtime.config")
local maxa_mod = require("maxa")
local mcp_config = require("maxa.runtime.mcp.config")

local src = debug.getinfo(1, "S").source or ""
local dir = src:match("^@(.*)/[^/]+$") or (vim.fn.getcwd() .. "/tests/tools")
local repo_root = dir:match("^(.*)/tests/tools$") or "/home/maxzhao/maxa"

local A = assert_mod.new()

do
  -- Defaults expose the W7 fields (comments are the documentation).
  local d = maxa_mod.defaults
  A.check(d.mcp ~= nil and d.mcp.enabled == true, "assembly: default mcp.enabled")
  A.assert_eq(d.mcp.servers_file, ".maxa/mcp/servers.yaml", "assembly: default servers_file")
  A.check(d.skills ~= nil and d.skills.enabled == true, "assembly: default skills.enabled")
  A.check(
    d.skills.roots and d.skills.roots.bundled == true and d.skills.roots.config == true and d.skills.roots.project == true,
    "assembly: default skills roots (bundled/config/project)"
  )

  -- Fail-closed validation: unknown keys / wrong types rejected.
  local bad1, e1 = config.configure(d, { mcp = { unknown_key = 1 } })
  A.check(bad1 == nil and e1 ~= nil and e1.message:find("unknown key", 1, true) ~= nil, "assembly: mcp unknown key rejected")
  local bad2, e2 = config.configure(d, { skills = { roots = { extra = true } } })
  A.check(bad2 == nil and e2 ~= nil and e2.message:find("unknown key", 1, true) ~= nil, "assembly: skills.roots unknown key rejected")
  local bad3, e3 = config.configure(d, { mcp = { enabled = "yes" } })
  A.check(bad3 == nil and e3 ~= nil, "assembly: mcp.enabled wrong type rejected")
  local bad4, e4 = config.configure(d, { skills = { roots = { project = 1 } } })
  A.check(bad4 == nil and e4 ~= nil, "assembly: skills.roots value wrong type rejected")
  local ok5, e5 = config.configure(d, { mcp = { enabled = false }, skills = { enabled = false, roots = { bundled = false } } })
  A.check(ok5 ~= nil and e5 == nil, "assembly: valid overrides accepted")

  -- Setup assembles the extension content (this repo has NO servers.yaml).
  local ok_setup, setup_err = pcall(maxa_mod.setup, {})
  A.check(ok_setup, "assembly: setup ok (" .. tostring(setup_err) .. ")")
  A.check(maxa_mod.assembly ~= nil, "assembly: M.assembly populated")
  A.check(maxa_mod.assembly.skills ~= nil and maxa_mod.assembly.skills.enabled == true, "assembly: skills switches recorded")
  A.check(maxa_mod.assembly.skills.roots ~= nil and maxa_mod.assembly.skills.roots.project == true, "assembly: skills roots recorded")
  A.check(maxa_mod.assembly.mcp ~= nil, "assembly: mcp servers config loaded")
  -- The repo now ships `.maxa/mcp/servers.yaml` (phase-3 manual-test config
  -- pointing at the local node fixture), so setup must discover fixture-echo
  -- instead of an empty config; the empty-config path is covered below by the
  -- explicit-missing-servers_file load.
  A.check(maxa_mod.assembly.mcp.servers ~= nil, "assembly: servers map present")
  A.check(
    maxa_mod.assembly.mcp.servers["fixture-echo"] ~= nil,
    "assembly: repo servers.yaml discovered (fixture-echo present)"
  )
  A.check(maxa_mod.assembly.mcp_error == nil, "assembly: no assembly error for missing file")
  -- The repo root may be reached through the nvim-maxa symlink
  -- (~/.config/nvim-maxa -> repo), so compare symlink-resolved paths.
  A.check(
    maxa_mod.assembly.mcp.project_root ~= nil
      and vim.fn.resolve(maxa_mod.assembly.mcp.project_root) == vim.fn.resolve(repo_root),
    "assembly: project root recorded (got " .. tostring(maxa_mod.assembly.mcp.project_root) .. ")"
  )

  -- mcp.config.load honors an explicit servers_file (missing -> empty config).
  local loaded, lerr = mcp_config.load(repo_root, { servers_file = ".maxa/mcp/nonexistent.yaml" })
  A.check(loaded ~= nil and lerr == nil, "assembly: explicit missing servers_file -> empty config")
  A.check(loaded.servers ~= nil and next(loaded.servers) == nil, "assembly: empty servers list")
  A.check(loaded.source == nil, "assembly: no source recorded for empty config")
end

if A.ok then
  print("TOOLS_CONFIG_ASSEMBLY_OK")
else
  error("TOOLS_CONFIG_ASSEMBLY_FAILED count=" .. #A.failures)
end
