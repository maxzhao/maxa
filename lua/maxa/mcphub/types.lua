---@meta
---@class CustomMCPServerConfig.CustomInstructions
---@field text string
---@field disabled? string

---@class CustomMCPServerConfig
---@field disabled? boolean
---@field description? string Optional pre-load capability description for MCP-only Ability discovery
---@field triggers? string[] Optional English routing phrases for MCP-only Ability discovery
---@field suite? string[] Canonical suite identifiers for MCP-only Abilities; Skill metadata owns composites
---@field disabled_tools? string[]
---@field disabled_prompts? string[]
---@field disabled_resources? string[]
---@field disabled_resourceTemplates? string[]
---@field custom_instructions? CustomMCPServerConfig.CustomInstructions

---@class MCPServerConfig: CustomMCPServerConfig
---@field command? string
---@field args? table
---@field env? table<string,string>
---@field cwd? string
---@field headers? table<string,string>
---@field url? string

---@class NativeMCPServerConfig : CustomMCPServerConfig

---@class MCPServer
---@field name string
---@field displayName string
---@field description string
---@field transportType string
---@field status MCPHub.Constants.ConnectionStatus
---@field error string
---@field capabilities MCPCapabilities
---@field uptime number
---@field lastStarted string
---@field authorizationUrl string
---@field config_source string Include which config file this server came from

---@class LogEntry
---@field type string
---@field message string
---@field timestamp number
---@field data table<string,any>
---@field code number

---@class MCPResponseOutput
---@field text string
---@field images table[]
---@field blobs table[]
---@field audios table[]
---@field error? string

---@class EnhancedMCPPrompt : MCPPrompt
---@field server_name string
---@field description string? -- Optional description for the prompt

---@class EnhancedMCPResourceTemplate : MCPResourceTemplate
---@field description string? -- Optional description for the resource template
---@field server_name string

---@class EnhancedMCPResource : MCPResource
---@field server_name string
---@field description string? -- Optional description for the resource

---@class EnhancedMCPTool : MCPTool
---@field server_name string
---@field inputSchema? table -- Optional input schema for the tool
---@field description string? -- Optional description for the tool

---@class MCPRequestOptions
---@field timeout? number
---@field resetTimeoutOnProgress? boolean
---@field maxTotalTimeout? number

---@class MCPHub.JobContext
---@field cwd string -- Current working directory for the job
---@field port number -- Port to connect to the MCP server
---@field config_files string[] -- List of configuration files used to start the Hub including the project config and global
---@field is_workspace_mode boolean -- Whether the job is running in workspace mode
---@field workspace_root string? -- Root directory of the workspace if in workspace mode
---@field existing_hub MCPHub.WorkspaceDetails? -- Details of an existing hub if applicable

---@class MCPHub.Workspaces
---@field current string? -- Name of the current workspace
---@field allActive table<string, MCPHub.WorkspaceDetails>? -- Map of workspace names to their details

---@class MCPHub.WorkspaceDetails
---@field pid number -- Process ID of the mcp-hub server
---@field port number -- Port the mcp-hub server is running on
---@field config_files string[] -- List of configuration files used to start the Hub including the project config and global
---@field startTime string -- ISO 8601 formatted start time of the workspace
---@field cwd string -- Current working directory of the mcp-hub
---@field shutdownDelay number? -- Optional delay before the workspace is shut down after inactivity
---@field state "active" | "shutting_down" -- Current state of the workspace
---@field activeConnections number -- Number of active connections to the workspace
