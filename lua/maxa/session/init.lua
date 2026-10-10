-- Maxa AI session owner: history/UI, cache/recovery, status, bridge, and Native MCP tool assembly.
local M = {}
local setup_complete = false
local history_api

local function session_tools()
  return {
    require("maxa.session.tools.list_chats"),
    require("maxa.session.tools.get_messages"),
    require("maxa.session.tools.search_messages"),
    require("maxa.session.tools.get_loaded_items"),
    require("maxa.session.tools.get_message"),
    require("maxa.session.tools.get_trace"),
    require("maxa.session.tools.get_chat_summary"),
    require("maxa.session.tools.get_session_status"),
    require("maxa.session.tools.probe_messages"),
    require("maxa.session.tools.scan_collapse_candidates"),
    require("maxa.session.tools.compact_range"),
    require("maxa.session.tools.collapse_tail"),
    require("maxa.session.tools.compact_full"),
    require("maxa.session.tools.compact_self"),
    require("maxa.session.tools.handoff_compact"),
    require("maxa.session.tools.get_session_stats"),
    require("maxa.session.tools.transfer_chat"),
  }
end

function M.setup(opts)
  if setup_complete then
    return
  end
  opts = opts or {}

  local history = require("maxa.session.history")
  history.setup(opts)
  history_api = history.exports
  require("maxa.session.default_session_cache").setup()
  require("maxa.session.llm_error_recovery").setup()
  local runtime = require("maxa.config").runtime()
  require("maxa.session.status").setup(runtime.status)
  require("maxa.session.telegram_bridge").setup()
  require("maxa.session.notify_when_done").setup()

  setup_complete = true
end

function M.history()
  return history_api
end

function M.reset_setup()
  setup_complete = false
  history_api = nil
end

function M.native_server()
  return {
    name = "session",
    displayName = "Maxa AI Session Tools",
    capabilities = {
      tools = session_tools(),
      resources = {},
      resourceTemplates = {},
      prompts = {},
    },
  }
end

return M
