# MCP Server Candidate / Install Handoff

Purpose: Resource Scout handoff checklist for MCP Server candidates. For installation, creation, configuration, reload, or maintenance, load and follow `mcp-creator`.

## Mandatory Authority

```text
load(target="mcp-creator")
```

`mcp-creator` is authoritative for Native/External classification, final code/config paths, `servers.json`, MCPHub reload, Neovim restart, and validation. Resource Scout only evaluates candidates and prepares handoff information.

## 1. Classify Candidate

Use `mcp-creator` server-type rules before editing config/code.

| Type | Typical use | Location/config | Activation |
| --- | --- | --- | --- |
| Native Server | Neovim API, Buffer/Window/State, low-latency Lua integration | `lua/maxa/mcphub/native_servers/{name}/` + `servers.json` `nativeMCPServers` | usually restart Neovim |
| External Server | third-party stdio/SSE/HTTP, npm/pip/uvx/npx, network/browser/heavy compute | `mcp-servers/{name}/` or package + `servers.json` `mcpServers` | usually restart MCPHub |

If uncertain, stop at candidate report and load `mcp-creator`; do not infer final config from registry snippets alone.

## 2. Evaluate Before Install

Record:

- Transport/runtime: stdio, SSE, HTTP, Native Lua.
- Dependency source: npm, uvx, pip, binary, local source.
- Config needs: API key, token, path, environment variables.
- Permission risks: filesystem, browser, shell, network, database, credentials.
- Compatibility with Neovim + MCPHub + MaxaAI.
- Maintenance signals: update date, stars/downloads, issues, docs.
- Minimal safe validation call after loading.

## 3. Handoff By Type

### External Server

1. Read upstream install/start docs.
2. Record command, env vars, permissions, and validation command.
3. Load `mcp-creator`.
4. Let `mcp-creator` decide final directory, `servers.json` shape, restart method, and validation steps.
5. If restart is needed, follow current `mcp-creator` instructions.

### Native Server

1. Confirm Neovim API/Buffer/Window/State/low-latency Lua integration is required.
2. Record intended tools, input/output, permission boundary, tests, and user-visible behavior.
3. Load `mcp-creator`.
4. Let `mcp-creator` decide Native Server code path, schema/handler shape, config, static validation, and restart requirement.
5. Tell the user Native Server changes usually require restarting Neovim.

Do not treat MCPHub restart as sufficient for Native Server Lua/schema/handler code reload. Neovim process caches and MaxaAI closures may retain old behavior.

## 4. Load And Test

After configuration is expected to be active:

```text
load(target="<server-name>")
```

Check:

- Server starts/connects.
- Tool schemas are concise and usable.
- Required env vars/paths exist without exposing secrets.
- A simple read-only or low-risk titled `run(scope="tool", command="@<server-name>:<cataloged-tool>", args=<encoded JSON object string>)` succeeds; do not invoke a Server tool as an unregistered bare builtin.
- Failure messages are actionable.

## 5. Tool Definition Context Review

If tool definitions are too large, route to `mcp-creator` optimization:

- Identify schema/description redundancy.
- Compress tool/schema descriptions to purpose + parameter meaning.
- Move examples, usage guide, warnings, and behavior constraints to skill/docs.
- When live tool descriptions are materially unsuitable, create a same-named composite Ability and declare a root-confined `mcp.overrides` description file; never copy the complete live schema.

## 6. Update Existing Server

Before update:

1. Record current `servers.json` entry.
2. Check local server code/config changes.
3. Read upstream breaking changes.
4. Reconfirm Native vs External activation method.

After update:

- External: restart MCPHub and test.
- Native: ask for/rely on Neovim restart, then test.

## Quick Rule

```text
MCP candidate found
  ├─ install/configure? -> load mcp-creator
  ├─ third-party stdio/SSE/HTTP/npm/uvx/pip? -> External + mcpServers + MCPHub restart
  └─ Neovim Lua/Buffer/Window/State? -> Native + nativeMCPServers + Neovim restart
```
