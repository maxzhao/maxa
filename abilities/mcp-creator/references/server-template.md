# Native Server Template

Package-owned template for Native MCP Server work. Replace placeholders exactly; keep tool/schema/result prose dense and LLM-facing.

## `init.lua`

```lua
-- {server-name} MCP Server
-- {short function description}

local tools = {
  require("maxa.mcphub.native_servers.{server-name}.tools.{tool_a}"),
  require("maxa.mcphub.native_servers.{server-name}.tools.{tool_b}"),
}

return {
  name = "{server-name}",
  displayName = "{Display Name}",
  capabilities = {
    tools = tools,
    resources = {},
    resourceTemplates = {},
    prompts = {},
  },
  config = {
    version = "1.0.0",
    description = "{description}",
  },
  lifecycle = {
    onInitialize = function(context)
      vim.notify("[{server-name}] Server initialized", vim.log.levels.INFO)
    end,
    onShutdown = function(context)
      vim.notify("[{server-name}] Server shutting down", vim.log.levels.INFO)
    end,
  },
}
```

## `tools/xxx.lua`

```lua
-- {tool function description}
-- local utils = require("maxa.mcphub.native_servers.{server-name}.utils")

--- @param req table MCPHub request {params: table, caller: table}
--- @param res table MCPHub response {text(), error(), send()}
local function handler(req, res)
  if not req or not req.params then
    return res:error("{tool_name}: Invalid request - missing params")
  end

  local required_param = req.params.required_param
  if not required_param or required_param == "" then
    return res:error("{tool_name}: required_param is required")
  end

  local optional_param = req.params.optional_param or "default_value"

  local ok, result = pcall(function()
    return {
      object_id = "...", -- reference needed after this operation
      changed = true, -- meaningful state delta, not transport success
    }
  end)

  if not ok then
    return res:error(string.format("{tool_name}: %s", tostring(result)))
  end

  return res:text(vim.json.encode(result)):send()
end

return {
  name = "{tool_name}",
  description = "Dense tool purpose, use condition, key side effects, and result summary.",
  inputSchema = {
    type = "object",
    properties = {
      required_param = {
        type = "string",
        description = "One-line parameter purpose.",
      },
      optional_param = {
        type = "string",
        description = "One-line parameter purpose.",
        default = "default_value",
        enum = { "option_a", "option_b", "option_c" },
      },
      number_param = {
        type = "number",
        description = "One-line parameter purpose.",
        default = 10,
      },
      bool_param = {
        type = "boolean",
        description = "One-line parameter purpose.",
        default = false,
      },
    },
    required = { "required_param" },
  },
  handler = handler,
}
```

Rules:

- Validate request and required params before side effects.
- Return actionable errors, not raw stack traces alone.
- This flat JSON example represents precise state facts, not a universal wrapper. For prose-heavy LLM results use necessary metadata plus raw body; preserve required machine/outputSchema JSON. Select format through `references/llm-facing-tool-contract.md`.
- Do not echo large params, base64, long commands, full logs, or full JSON by default.
- Keep workflow guidance in Ability/reference docs unless the tool is explicitly a workflow-state tool.

## Optional Shared Helper

Create a shared helper only when multiple tools need the same semantic operation.

```lua
local M = {}

function M.format_error(tool_name, message)
  return string.format("[%s] %s", tool_name, message)
end

function M.read(filepath)
  local file, err = io.open(filepath, "r")
  if not file then
    return nil, string.format("Cannot open file: %s (%s)", filepath, err or "unknown")
  end
  local content = file:read("*a")
  file:close()
  return content, nil
end

function M.write(filepath, content)
  local dir = vim.fn.fnamemodify(filepath, ":h")
  vim.fn.mkdir(dir, "p")

  local file, err = io.open(filepath, "w")
  if not file then
    return false, string.format("Cannot write file: %s (%s)", filepath, err or "unknown")
  end
  file:write(content)
  file:close()
  return true, nil
end

return M
```
