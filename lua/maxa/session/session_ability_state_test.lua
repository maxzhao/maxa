-- Run: nvim --headless -u NONE --cmd 'set rtp^=.' -l lua/maxa/session/session_ability_state_test.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local session_stats = require("maxa.session.session_stats")
local status_panel = require("maxa.session.session_status_panel")

local function eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", message or "assertion", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function contains(text, needle, message)
  if not tostring(text):find(needle, 1, true) then
    error(message or string.format("expected %q in %q", needle, text))
  end
end

local ability = { name = "demo", digest = "digest-1", catalog_call_id = "call-load-demo" }
local messages = {
  { role = "user", content = "revision", _meta = { tag = "ability_revision", ability = vim.deepcopy(ability) } },
  { role = "user", content = "instructions", _meta = { tag = "ability_instructions", ability = vim.deepcopy(ability) } },
  { role = "user", content = "guidance", _meta = { tag = "ability_guidance", ability = vim.deepcopy(ability) } },
  {
    role = "tool",
    content = "ability: demo",
    tools = { call_id = "call-load-demo" },
    _meta = {
      tag = "ability_catalog",
      ability_catalogs = { demo = { name = "demo", digest = "digest-1", catalog = "ability: demo" } },
    },
  },
  {
    role = "user",
    content = "# Project Context",
    context = { id = ".maxa/index.md" },
    _meta = { tag = "context_file" },
  },
  { role = "user", content = "# Skill: legacy-only", _meta = { tag = "skill" } },
  { role = "user", content = "MCP Server authorization: legacy-server", _meta = { tag = "mcp_server" } },
}

local stats, err = session_stats.collect_chat_data({
  save_id = "ability-state-test",
  title = "Ability state test",
  adapter = "test",
  settings = { model = "test" },
  messages = messages,
}, "ability-state-test")
assert(stats, err)

eq({ "demo" }, stats.loaded.abilities, "loaded Ability names")
eq({ ".maxa/index.md" }, stats.loaded.contexts, "loaded context paths")
eq(nil, stats.loaded.skills, "retired Skill list is absent")
eq(nil, stats.loaded.servers, "retired MCP Server list is absent")
eq(5, stats.compact_retention.preserved.loaded_item_context.count, "current Ability/context retention count")
eq(1, stats.meta_tags.skill, "legacy Skill tag remains observable as history evidence")
eq(1, stats.meta_tags.mcp_server, "legacy MCP tag remains observable as history evidence")

local panel = table.concat(status_panel.render(stats), "\n")
contains(panel, "abilities", "status panel should use Ability terminology")
contains(panel, "demo", "status panel should list the committed Ability")
assert(not panel:find("| skills |", 1, true), "status panel must not expose a Skill row")
assert(not panel:find("| servers |", 1, true), "status panel must not expose an MCP Server row")

print("SESSION_ABILITY_STATE_OK")
