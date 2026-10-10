--- Maxa configuration help, independent of MCP backend readiness.
local Text = require("maxa.mcphub.utils.text")
local View = require("maxa.mcphub.ui.views.base")

local HelpView = setmetatable({}, { __index = View })
HelpView.__index = HelpView

local content = [[
# Maxa Configuration

Manage abilities, service defaults and MCP connections for the project shown above. Open or close this panel with :MaxaConfig.

## Pages and Controls

- P Abilities: inspect abilities and suites; manage project availability, visibility, details and filters.
- D Defaults: select project llm, image, tts and video services, or inherit global defaults.
- H MCP Servers: inspect connections, manage server definitions, start/stop services and browse tools, resources and prompts.
- L Logs: inspect MCPHub logs and errors.
- ? Help: return to this page.
- q closes the panel; r refreshes (project-only in P/D); R restarts the MCPHub backend.
- Available actions appear in the footer. Standard Neovim movement keys are unchanged.

## Availability and Connections

- In P, l/h/t enables, disables or toggles project availability; i shows details, v sets visibility, u resets overrides, f/s filters, and d starts guarded deletion.
- Availability controls whether the project may use an ability. Visibility controls discovery/completion; it grants no authorization.
- In H, t changes runtime connection state only. Starting a service cannot bypass project restrictions.
- In H, l/Enter expands, h collapses, A adds a definition, e edits, and d starts guarded deletion.
- An enabled or connected ability is not automatically authorized for a Chat. Agents must explicitly load the Ability before invoking cataloged @ability:tool or reading #ability[target].
- @/# completion inserts literal text only; it does not load or execute. Chat/project authorizations are independent.
- Green means enabled/connected; amber means partial or transitioning; red means an error. Muted text marks inactive state or provenance. State labels/icons remain visible.

## Service Defaults

- In D, l/Enter selects a default; h clears the project override and inherits the global value.
- LLM defaults affect new Chats only; they do not replace existing Chat models or messages.
- Media defaults apply to subsequent generation calls. Model selection is separate from ability management.
- Project settings live in .maxa/_meta.yaml; project MCP definitions in .maxa/abilities/mcp.json; global MCP definitions in Maxa's abilities/mcp.json.

## Troubleshooting

- Check the project path first, then availability in P, connection state in H and errors in L.
- P, D and Help remain usable when the backend is not ready. Missing project configuration is reported, not created automatically.
- Use R to restart external MCP connections. Changes to Maxa Lua core or Native Servers require a full Neovim restart; R cannot reload those modules.
- For a missing backend, follow the error guidance and run just mcphub-backend-install. Use the mcp-creator Ability for MCP development/maintenance.
]]

function HelpView:new(ui)
    return setmetatable(View:new(ui, "help"), self)
end

function HelpView:render()
    local lines = self:render_header(false)
    vim.list_extend(lines, Text.render_markdown(content))
    return lines
end

return HelpView
