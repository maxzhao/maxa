# External Server Development Guide

External Servers run as independent Node/Python/Rust processes and communicate with MCPHub over stdio or SSE.

## Types And Config

| Type | `mcp.json` shape | Example |
| --- | --- | --- |
| Third-party package | `command` + `args` | `context7`, `fetch`, `open-websearch` |
| Local project | local command path | `mcp-servers/browser` |
| Remote service | `url` | CopilotKit MCP, bridge services |

Global config goes under `<Maxa-root>/abilities/mcp.json.mcpServers`; project definitions belong to `<project>/.maxa/abilities/mcp.json.mcpServers` and override same-named global definitions:

```json
{
  "mcpServers": {
    "{server-name}": {
      "command": "npx",
      "args": ["-y", "package-name@latest"],
      "env": {
        "API_KEY": "xxx",
        "PROXY_URL": "http://localhost:10808"
      }
    }
  }
}
```

Fields:

- `command` + `args`: stdio server command.
- `url`: SSE endpoint.
- `env`: API keys, proxy, runtime config. Do not commit secrets.
- Availability: project `.maxa/_meta.yaml` `abilities.states.<server-name>`; false prohibits loading/start/calls, true/absence permits explicit activation without connecting automatically. Server JSON `disabled` is retired; capability-specific filters remain supported.
- `description`: optional capability purpose and loading conditions for MCP-only Ability discovery. A nonblank description enables a full generated routing row; without one, only the name is disclosed.
- `triggers`: optional ordered unique nonblank English routing phrases; they supplement description, not replace it.

These discovery fields also apply to Native Server config. Explicit config description wins over an already-registered static Native description. A same-name composite follows its Skill/Ability metadata instead. Discovery never starts a Server to obtain its description; do not put credentials or connection details in these public fields.

## Local Project Shape

```text
mcp-servers/{server-name}/
├── package.json
├── src/
│   └── index.ts
├── tsconfig.json
└── README.md
```

Use each subproject's package manager/test entrypoints. Prefer its Justfile/package scripts when present.

## Creation Workflow

1. Choose SDK/runtime:
   - Node.js: `@modelcontextprotocol/sdk`
   - Python: `mcp`
2. Implement server from official MCP SDK patterns.
3. Add `mcpServers` config in `servers.json`.
4. Design LLM-facing tool contract:
   - Follow `references/llm-facing-tool-contract.md`.
   - Convert raw CLI/API responses into concise Agent-usable facts.
   - If live tool descriptions are materially oversized, first improve the upstream Server when owned locally; otherwise use a same-named composite Ability with an `mcp.overrides` file containing only changed tool/parameter descriptions.
5. Put decision/workflow guidance in the same-named Ability's `SKILL.md` or references. Do not copy the complete live schema into the package.
6. Restart MCPHub and validate.
7. Supply concise discovery metadata in the owning Server config, or in a same-named composite Ability. The generated Ability table owns disclosure; do not add MCP content or static Server rows to `prompts/system.md`.

## Reload And Debug

External Server reload is simple: restart MCPHub; child processes and config are recreated.

| Change | Reload |
| --- | --- |
| server source code | restart MCPHub |
| `servers.json` config | restart MCPHub |
| new server | restart MCPHub |
| deleted server | restart MCPHub |
| exact backend reinstall from unchanged `bundled/mcp-hub/` manifests | `just mcphub-backend-install`, validate, then restart MCPHub |

If repository-owned Lua under `lua/maxa/mcphub/**` also changed, use a full Neovim restart-resume instead; MCPHub restart alone cannot reload those modules and closures.

Restart script, run inside Neovim:

```lua
dofile("<ability_root>/scripts/restart_mcphub.lua")
```

`OK: MCPHub restart queued ...` means queued successfully. The Agent must immediately end the current turn and wait for automatic recovery before more MCPHub calls.

Do not use this script as a reliable Native Lua Server reload path.

Debug sources:

- Maxa configuration / MCP management UI: `:MaxaConfig`
- MCPHub log: `~/.local/state/nvim/mcphub.log`
- Server stderr captured by MCPHub
- Package/subproject logs

Validation after restart:

1. `load(target="{server-name}", force_reload=true)`
2. `run(title="Verify MCP target", scope="tool", command="@{server-name}:tool_a", args=<encoded JSON object string>)` with minimal valid target parameters

## Reference Implementations

| Server | Type | Language | Use as reference for |
| --- | --- | --- | --- |
| `mcp-servers/browser` | local project | TypeScript | browser automation + Tauri integration |
| `context7` | third-party package | npx | minimal package config |
| `fetch` | third-party package | uvx | proxy config |
| `open-websearch` | third-party package | npx | multi-tool env config |
| CopilotKit MCP | remote SSE | - | SSE connection |
