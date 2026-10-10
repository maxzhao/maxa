# Native Server Development Guide

Native Servers are Lua modules executed inside the Neovim process. They have low latency and direct access to Neovim APIs, buffers, windows, chat state, and runtime globals.

## Context

| Item | Path / source |
| --- | --- |
| Server code | `lua/maxa/mcphub/native_servers/{server-name}/` |
| Optional usage guidance | same-named Ability `SKILL.md` / references |
| Native template | `references/server-template.md`, read through `#mcp-creator[/references/server-template.md]` |

## Structure

```text
lua/maxa/mcphub/native_servers/{server-name}/
├── init.lua
├── tools/
│   ├── tool_a.lua
│   └── tool_b.lua
└── utils.lua              # optional; extract only shared semantics
```

## Creation Workflow

### 1. Define the contract

Determine:

- Server responsibility and ownership boundary.
- Tool list and why each tool is needed.
- Each tool's input contract, result shape, and side effects.
- Result category: query, state change, context injection, file read, execution, media/binary, workflow guidance, or subagent/orchestration.
- Minimum facts the LLM needs after each tool call.
- Dependencies: Neovim API, filesystem, curl/system tools, plugins, external services.

Tool contracts must follow `references/llm-facing-tool-contract.md`. Do not copy one tool class's result format to every tool.

### 2. Read the Native template

Read `#mcp-creator[/references/server-template.md]`. Maxa retains MCPHub core but does not register the upstream `mcphub` management Server/Ability or its guide resources.

### 3. Create server files

`init.lua`:

```lua
local tools = {
  require("maxa.mcphub.native_servers.{server-name}.tools.tool_a"),
  require("maxa.mcphub.native_servers.{server-name}.tools.tool_b"),
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
}
```

`tools/xxx.lua`:

```lua
local function handler(req, res)
  if not req or not req.params then
    return res:error("tool_name: Invalid request")
  end

  local param_a = req.params.param_a
  if not param_a or param_a == "" then
    return res:error("tool_name: param_a is required")
  end

  local result = do_something(param_a)
  return res:text(vim.json.encode(result)):send()
end

return {
  name = "tool_name",
  description = "Dense LLM-facing purpose, key side effects, and result summary.",
  inputSchema = {
    type = "object",
    properties = {
      param_a = { type = "string", description = "One-line parameter purpose." },
      param_b = { type = "number", description = "One-line parameter purpose.", default = 10 },
    },
    required = { "param_a" },
  },
  handler = handler,
}
```

Shared modules: extract semantically named helpers when multiple tools share logic. Avoid creating broad `utils.lua` unless it has clear shared ownership.

### 4. Add context artifacts only when needed

| Artifact | Default | Owns |
| --- | --- | --- |
| Native tool `description` / `inputSchema` | Required source owner | tool and parameter contract |
| Same-named Ability `SKILL.md` / references | Only when separate usage guidance is needed | when to call, how to combine, failure handling |
| Ability `mcp.overrides` file | Avoid for repository-owned Native tools | third-party descriptions that cannot be repaired at their source |
| system prompt | Existing hard constraints only | core prohibitions |

Fix repository-owned Native tool descriptions at their source. Do not duplicate their complete schema in an Ability package.

### 5. Register the server

Add the require entry in `lua/maxa/mcphub/native_servers/init.lua`:

```lua
return {
  ["{server-name}"] = require("maxa.mcphub.native_servers.{server-name}"),
}
```

Add optional config in `<Maxa-root>/abilities/mcp.json` under `nativeMCPServers`, or in the project's `.maxa/abilities/mcp.json`:

```json
{
  "nativeMCPServers": {
    "<server-name>": {}
  }
}
```


Registration chain:

```text
maxa.setup(opts)
  -> config.setup(opts)
  -> setup_mcphub() loads maxa.mcphub.native_servers
  -> maxa.mcphub.setup(hub_opts)
  -> Native.setup(user_native_servers)
  -> Native.register(def)
```

Project `.maxa/_meta.yaml` `abilities.states.<server-name>` controls availability. Server JSON `disabled` is retired; tool/resource filters remain definition-owned. Disabling one project does not stop a Native singleton needed by another. Registered Native abilities cannot be physically deleted through the panel.

## Native Reload And Validation

Native changes require a fresh Neovim process. Do not use MCPHub restart or manual `package.loaded` clearing as the normal reload/validation path.

### Cache model

| Layer | Location | Cached data | Risk |
| --- | --- | --- | --- |
| L1 Lua module | `package.loaded["maxa.mcphub.native_servers.xxx"]` | tool definition table, handler, schema | old Lua code remains loaded |
| L2 MCPHub state | `State.server_state.native_servers` | NativeServer instance and `capabilities.tools` | old MCPHub routing/tool list |
| L3 Maxa AI config | `config.interactions.chat.tools` + groups | tool id, callback closure, schema | old chat tool closure/schema |

Because all layers may hold old data, MCPHub restart alone can leave disk changes unapplied.

### Reload by change type

| Change | Required path |
| --- | --- |
| Tool handler logic | local validation -> `scripts/restart_nvim_resume.lua` -> post-resume tool check |
| `inputSchema`, `description`, `required`, `enum` | local validation -> `scripts/restart_nvim_resume.lua` -> schema/tool check |
| Add/move/delete/rename tool | local validation -> `scripts/restart_nvim_resume.lua` -> load/tool check |
| Add/delete Native Server | local validation -> `scripts/restart_nvim_resume.lua` -> load/tool check |
| `nativeMCPServers` config | local validation -> `scripts/restart_nvim_resume.lua` -> load/tool check |

### Validation sequence

1. Run closest static validation: Lua syntax, unit test, handler-level test, prompt/schema static review, or minimal module load.
2. Run inside Neovim:

```lua
dofile("<ability_root>/scripts/restart_nvim_resume.lua")
```

3. If output is `OK: Neovim restart-resume queued ...`, end the current turn immediately.
4. After automatic resume, validate runtime state:
   - `load(target="{server-name}", force_reload=true)`
   - `run(title="Verify native MCP target", scope="tool", command="@{server-name}:tool_a", args=<encoded JSON object string>)`
5. If the script returns `ERROR:`, fix the reported precondition. If runtime validation fails, inspect Snacks notifier history and relevant logs.

If an Agent cannot use restart-resume, the fallback statement is: `Restart Neovim to load Native MCP Server changes.`

## MCPHub Core Reload Boundary

Repository-owned MCPHub source, setup, state, UI, Native framework, or registration under `lua/maxa/mcphub/**` is also in-process Lua. Validate it locally, then use `scripts/restart_nvim_resume.lua`; MCPHub restart and manual `package.loaded` clearing are not sufficient evidence. If these files change together with External Server or backend files, the full Neovim restart requirement wins.

The exact npm backend is declared under `bundled/mcp-hub/`. Run `just mcphub-backend-install` to install it. Reinstalling the backend from unchanged manifests is process-level and may use MCPHub restart after package validation.

## External Reload Boundary

`scripts/restart_mcphub.lua` is for External Servers or MCPHub connection/config refresh. Do not call it as a reliable Native Lua code reload path.

## Ability Discovery

When adding a new generally useful MCP Server, supply concise discovery metadata in the owning Server config or a same-named composite Ability. The generated Ability table owns disclosure; do not add static Server rows to `prompts/system.md`. Preserve names and load conditions.

## Key Patterns

### Response API

```lua
return res:text("message"):send()
return res:text(vim.json.encode(data)):send()
return res:error("actionable error message")
```

Choose the model-visible representation through `references/llm-facing-tool-contract.md`: short facts or metadata plus raw prose for LLM reading; compact tables/flat JSON for records; required JSON for machine/outputSchema consumers. Internal tables need not be exposed wholesale. Preserve actionable errors and the owning output-volume policy.

### Result design

Tool results are LLM inputs, not debug logs.

| Type | Include |
| --- | --- |
| Query | source, scope, count, key items, pagination/truncation, id/path/range |
| State change | status, changed object, side effects, new path/id/status, validation/restart fact |
| Context injection | injected object, source, dedupe/reload, TTL/persist behavior |
| File read | bounded content/range, line numbers, stats, next range suggestion |
| Execution | status, exit/error, cwd/env deltas, bounded stdout/stderr, preview/hash for long inputs |
| Media/binary | path/URL, MIME/type/size, preview/load guidance, no base64 body |
| Workflow guard | attempt/session/stage, required next tool or stop condition, minimal constraints |
| Subagent/orchestration | minimal continuation metadata plus complete raw final answer; preserve output exemptions |

See `references/llm-facing-tool-contract.md` for the full checklist.

### Parameter validation

```lua
if not param or param == "" then
  return res:error("tool: param is required")
end

if type(param) ~= "number" then
  return res:error("tool: param must be a number")
end

local valid = { "a", "b", "c" }
if not vim.tbl_contains(valid, param) then
  return res:error(string.format("tool: param must be one of: %s", table.concat(valid, ", ")))
end
```

### Async/system operations

For curl/system work, use `vim.system` + `vim.wait` for bounded synchronous waiting. Follow existing patterns such as `winctl/utils.lua`.

### Context injection

For persistent context injection like `load` or `load`, use the shared context-message utilities in `maxa.interactions.chat.tools.builtin.runtime.ability_utils`.

## Maxa AI Chat Integration

If a Native tool accesses Chat objects, lifecycle hooks, persisted state, adapter capability, or delayed actions, read `references/cc-chat-patterns.md`.

If it listens to Chat lifecycle events, auto-submits, touches `Chat.done` / `Chat.submit` / `Chat.add_message` / `chat.tools_done`, or must coexist with auto compact, retry, token warnings, or subagents, read `references/chat-listener-conflicts.md` first.

## Reference Implementations

| Server | Complexity | Pattern |
| --- | --- | --- |
| Chat builtins | high | context injection and session operations |
| `winctl` | medium | PowerShell/system command wrapper |
| `session` | medium | MaxaAI API integration |

Inspect with `read(path="lua/maxa/mcphub/native_servers/{server}/init.lua")` and related tool files.

## Restart-Resume Details

`scripts/restart_nvim_resume.lua`:

1. Saves the current Maxa AI chat to history.
2. Writes `.maxa/tmp/nvim-restart-resume.json` with `save_id`, cwd, and resume message.
3. Starts `scripts/restart_nvim_resume_supervisor.py` detached.
4. Exits old Neovim.
5. Starts fresh Neovim in the same tmux pane:

```bash
nvim --cmd 'let g:maxa_restart_resume_file="..."'
```

6. `lua/maxa/session/nvim_restart_resume.lua` consumes and deletes the pending file, restores LazyVim persistence, restores chat by `save_id`, waits for MCPHub readiness, and auto-submits the resume message.

Preconditions:

- tmux is required.
- Ordinary modified file buffers block restart.
- `.maxa/tmp/` must be git ignored.
- Pending file is one-shot and deleted on startup.
