---
name: mcp-creator
description: "Create, maintain, and debug Native or External MCP Servers for Neovim + MCPHub, including tool schema/handler changes, servers.json configuration, reload strategy, and LLM-facing tool contract optimization."
compatibility: Requires Maxa Ability runtime.
---
# MCP Creator

Create and maintain MCP Servers for Neovim + MCPHub.

## Ownership And Reload Strategy

Maxa AI owns MCPHub core under `lua/maxa/mcphub/**` and Native Server implementations under `lua/maxa/mcphub/native_servers/**`; `maxa.setup(opts)` initializes the Hub directly. The exact external npm backend is declared under `bundled/mcp-hub/` and installed with `just mcphub-backend-install`.

| Change | Correct reload |
| --- | --- |
| MCPHub core/setup/state/UI/framework under `lua/maxa/mcphub/**` | Do local validation, then use `scripts/restart_nvim_resume.lua` to fully restart Neovim, restore the current chat, wait for MCPHub, and continue. Do not rely on MCPHub restart. |
| Native Server code/schema/handler/registration/`nativeMCPServers` under `lua/maxa/mcphub/native_servers/**` | Do local validation, then use `scripts/restart_nvim_resume.lua` to fully restart Neovim, restore the current chat, wait for MCPHub, and continue. Do not rely on MCPHub restart. |
| External Server code/config under `mcp-servers/**`, third-party stdio/SSE server, `mcpServers` config, or an npm backend reinstall from unchanged manifests | Use `scripts/restart_mcphub.lua` to restart MCPHub. |

Reason: repository-owned MCPHub and Native Servers are in-process Lua and may be cached by `package.loaded`, MCPHub state/registration, and Maxa AI tool closures. Restarting MCPHub alone may leave old modules, schemas, or handlers active. If in-process Lua and process-level files change together, use the full Neovim restart path.

Agent rules:

- Restart scripts require the caller chat to be history-backed. If the current chat is temporary/unsavable or has no valid `save_id`, the script returns `ERROR:` and must not restart.
- For repository-owned MCPHub or Native Server changes, never treat MCPHub restart or manual `package.loaded` clearing as the standard reload path.
- After `dofile("{ability_root}/scripts/restart_nvim_resume.lua")` returns `OK: Neovim restart-resume queued ...`, immediately end the current turn. Fresh Neovim will resume the chat automatically.
- If restart-resume returns `ERROR:`, do not exit; fix the reported precondition when possible.
- After `dofile("{ability_root}/scripts/restart_mcphub.lua")` returns `OK: MCPHub restart queued ...`, immediately end the current turn. Do not call more MCPHub tools in the same round.

## Script Entrypoints

Explicit current-instance exception: these restart scripts are not cataloged external-process commands. Load `mcp-creator`, resolve its returned root, then load `neovim` and use `run(scope="@neovim:lua", command='dofile(...)')` for a real restart. Do not invent `@mcp-creator:/scripts/...` call targets or run another Neovim process. The following standalone commands are manual help-only diagnostics, not Agent restart entrypoints:

```bash
lua {ability_root}/scripts/restart_mcphub.lua --help
lua {ability_root}/scripts/restart_nvim_resume.lua --help
```

| Script | Use for | Notes |
| --- | --- | --- |
| `scripts/restart_mcphub.lua` | External Server or MCPHub connection/config refresh | Run through `run(scope="@neovim:lua")` with `dofile(...)`. Direct `lua` only shows help. |
| `scripts/restart_nvim_resume.lua` | Repository-owned MCPHub or Native Lua/MCP Server changes requiring a fresh Neovim process | tmux-only. Writes one-shot `.maxa/tmp/nvim-restart-resume.json`, starts `nvim --cmd 'let g:maxa_restart_resume_file="..."'`, restores session/chat by `save_id`, waits for MCPHub ready, then auto-submits. |

Agent calls after substituting the actual loaded root (choose one, not both):

```yaml
- load: {target: "neovim"}
# External/connection refresh only
- run:
    title: "Restart MCPHub"
    scope: "@neovim:lua"
    command: 'dofile("{ability_root}/scripts/restart_mcphub.lua")'
# Repository-owned MCPHub or Native Lua/MCP Server changes
- run:
    title: "Restart Neovim and resume Chat"
    scope: "@neovim:lua"
    command: 'dofile("{ability_root}/scripts/restart_nvim_resume.lua")'
```

## Server Types

| | Native Server | External Server |
| --- | --- | --- |
| Runtime | Lua in Neovim process | Independent Node/Python/Rust process over stdio/SSE |
| Code | `lua/maxa/mcphub/native_servers/{name}/` | `mcp-servers/{name}/` or third-party package |
| Config | `mcp.json.nativeMCPServers` | `mcp.json.mcpServers` |
| Strength | low latency, direct Neovim API/buffer/state | any language, npm/pip ecosystem, long-running work |
| Weakness | Lua only, blocking code freezes UI, in-process caches | process startup cost, serialization boundary |
| Use for | Neovim/session/UI integration, lightweight tools | network, browser automation, heavy compute, third-party APIs |
| Reload | full Neovim restart via `restart_nvim_resume.lua` | MCPHub restart via `restart_mcphub.lua` |
| Debug | `vim.notify` + Snacks notifier history | MCPHub UI/logs + process stderr |

Selection:

```text
Need Neovim API/buffer/window/state? -> Native
Need npm/pip/non-Lua ecosystem?      -> External
Need high-frequency low-latency call? -> Native
Need long-running or CPU-heavy work?  -> External
```

## Reference Routing

Read the matching reference after choosing task type, using its cataloged address, for example `read(path="#mcp-creator[/references/native-server-guide.md]")`. Physical source paths elsewhere in this guide describe maintenance targets, not a replacement for Ability reference loading.

| Need | Reference |
| --- | --- |
| Native Server creation/maintenance | `references/native-server-guide.md` |
| External Server creation/config/debug | `references/external-server-guide.md` |
| Native template for package-owned creation guidance | `references/server-template.md` |
| Tool description/schema/result/error contract | `references/llm-facing-tool-contract.md` |
| Common result/tool implementation patterns | `references/tool-patterns.md` |
| Maxa AI Chat access, persistence, hooks, adapter capability | `references/cc-chat-patterns.md` |
| ChatSubmitted/listener conflicts and auto-submit coexistence | `references/chat-listener-conflicts.md` |

## LLM-Facing Tool Contract

MCP tool `description`, `inputSchema`, parameters, result shape, and errors are LLM-facing contracts. Design both input and output before coding.

Rules:

- `description` / `inputSchema`: purpose, parameter passing, defaults, key side effects. Keep prose dense; remove tutorials, long examples, marketing copy, repeated warnings, and workflow decisions.
- Preserve exact tool names, parameter names, enum values, schema constraints, error codes/messages, result fields, and backward-compatible behavior.
- Separate internal results/trace, actual LLM payload and UI. Return necessary facts once; prose-heavy LLM output uses short metadata plus raw body, while machine/outputSchema contracts retain required structured data. Follow `references/llm-facing-tool-contract.md` before designing the representation; do not default to success/data/meta wrappers.
- Output-volume policy follows the owning tool: search/list/log limits are not authorization to truncate complete SubAgent answers or remove existing exemptions.
- Normal success should not return generic `next_action`, tutorials, or broad workflow advice.
- Put tool selection, composition flow, state interpretation, and exception handling in the same-named Ability's `SKILL.md` or references.
- Do not create a new tool for every Agent step. Prefer better existing tool semantics and result shapes.
- Do not generalize one tool class's result format, such as exit code/stdout/stderr, to all tools.

See `references/llm-facing-tool-contract.md` for the checklist and result-shape patterns.

## LLM Context Architecture For MCP Servers

`load(target="<ability>")` returns the complete allowed tool catalog. Keep three non-duplicating owners:

| Layer | Source | Owns |
| --- | --- | --- |
| Structural contract | live allowed MCP schema | tool/parameter names, types, required fields, enums, defaults, alternatives and constraints |
| Optional description overrides | same-named composite Ability file declared by `ABILITY.yaml.mcp.overrides` | only tool and parameter descriptions |
| Decision guidance | Ability `SKILL.md` / references | when to use tools, composition patterns, state interpretation and behavior constraints |

Use live descriptions by default. When third-party descriptions are materially oversized or unsuitable, create a same-named Skill-backed Ability with `merge: true`, declare one root-confined override file, and include only changed descriptions. Never copy the complete live schema into the package.

```yaml
merge: true
mcp:
  overrides: mcp/overrides.yaml
```

## Validation Expectations

- Repository-owned MCPHub or Native code/config changes: run closest Lua/static tests, then use `restart_nvim_resume.lua`, then `load(target="<ability>", force_reload=true)` and minimal `@ability:tool` checks through titled `run(scope="tool")` with encoded JSON object `args` after resume.
- External code/config changes: run project/package tests, use `restart_mcphub.lua`, then load the MCP-backed Ability and validate `@ability:tool` / `#ability[target]` targets using each resource's exact listed original identifier.
- Tool contract changes: inspect schema/result shape for density, exact names, backward compatibility, bounded outputs, and actionable errors.
- Chat listener changes: read `references/chat-listener-conflicts.md` and validate no duplicate auto-submit or hook-chain breakage. Agent Loop/`pause_loop` is retired and must not be restored as a conflict target.

