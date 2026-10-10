---
title: MCP Creator Workflow 稳定规格
created: 2026-06-29
updated: 2026-10-09
type: source
doc_role: spec
authority: stable
status: stable
capability: mcp-creator-workflow
validation:
  specification: passed
  automated: passed
  live: partial
  human: passed
sources:
  - abilities/mcp-creator/SKILL.md
  - abilities/mcp-creator/references/native-server-guide.md
  - abilities/mcp-creator/references/external-server-guide.md
  - abilities/mcp-creator/references/llm-facing-tool-contract.md
  - lua/maxa/mcphub/
  - lua/maxa/mcphub/native_servers/
  - mcp-servers/
confidence: high
---

## Purpose and scope

MCP Creator owns server creation/maintenance: Native/External selection, LLM-facing contracts, validation, reload and schema/guidance layering. Schemas, results, reload and documentation caches are public downstream contracts; general prompt engineering is out of scope. Concrete tools belong to [Chat Builtins](../../../runtime/chat-builtins.md), [SubAgent Runtime](../subagent/subagent-runtime.md) and [Browser MCP](../browser/index.md). Debugging MUST NOT read `.env` or secret files without explicit user authorization for minimum necessary access.

## Requirements

Imperatives express SHALL obligations; explicit preferences and options retain their strength.

### Requirement: MCP work loads MCP Creator first

Before creating, editing or debugging MCP servers, schemas, handlers, results or server configuration, load `mcp-creator`. Non-chat Native work under `lua/maxa/mcphub/native_servers/**` follows its Native guidance, validation and restart rules.

### Requirement: Server type selection is based on runtime needs

Select by runtime integration needs:

| Need | Preferred type; source owner |
| --- | --- |
| Buffer, window, chat or Neovim state/API access | In-process Native MCP; `lua/maxa/mcphub/native_servers/{server}/`, core in `lua/maxa/mcphub/`. |
| npm/pip libraries, browser automation, network-heavy work or independent process lifecycle | External MCP; `mcp-servers/{server}/` or configured third-party server. |

### Requirement: Tool contracts are LLM-facing public interfaces

Descriptions, input schemas, result shapes and errors are stable Agent-facing contracts; technical schema validity alone does not establish LLM clarity.

- For new/changed tools, description/schema concisely states purpose, parameters and key side effects. Results provide bounded facts, state, side effects, ids/paths and diagnostics needed for the next Agent step, rather than generic tutorials or broad `next_action` advice on every success.
- **Consumer-oriented result representation**: Distinguish internal structured results, model-visible text and UI presentation. Prose/answer/search-line output SHOULD use necessary metadata plus raw body; repeated records MAY use compact tables or flat JSON. Preserve structure required by machine consumers, existing JSON APIs and outputSchema. Do not mandate universal success/data/meta envelopes, duplicate input/default config/IDs or truncate semantic content for compactness. Preserve abnormal completion, recovery and uncertainty. Output-volume policy belongs to each tool, including complete protected SubAgent answers; affected templates/examples MUST agree with `abilities/mcp-creator/references/llm-facing-tool-contract.md`.

### Requirement: Repository-owned MCPHub and Native MCP changes require Neovim reload strategy

Source/setup/state/UI/Native-framework/schema/handler/registration changes under `lua/maxa/mcphub/**` or `lua/maxa/mcphub/native_servers/**` require a full Neovim restart-resume strategy:

1. Run the closest `nvim --headless -l <test-file>` or Lua syntax/load checks.
2. When runtime verification is required, use `restart_nvim_resume.lua` after local validation; verify active modules, schemas, handlers and registrations in fresh Neovim.

Disk edits do not refresh loaded Lua/closures; MCPHub restart and `package.loaded` clearing MUST NOT substitute for full Neovim restart-resume.

### Requirement: Backend-only refresh remains process-level

Exact npm backend installation/refresh from unchanged committed manifests (`mcp-hub@4.2.1`) remains process-level: after package/local validation, MCPHub restart suffices if refresh is required. Concurrent `lua/maxa/mcphub/**` changes instead require the full Neovim strategy above.

### Requirement: External MCP changes may use MCPHub restart

For External process/config changes (`mcp-servers/**` or `mcpServers`), run subproject package/uv tests or a smoke command; use MCPHub restart when appropriate. If runtime refresh is needed, the Agent MAY queue `scripts/restart_mcphub.lua` through mcp-creator. Because restart can disrupt active tools, queue only after validation, follow the stop-current-turn instruction and stop the workflow until the restored chat resumes.

### Requirement: MCP server configuration has no approval contract

Native `nativeMCPServers` and External `mcpServers` definitions, including new/changed `servers.json` entries, MUST NOT document, generate or maintain `auto_approve`, `autoApprove`, approval suitability classifications, approval windows or approval caller flags. Enable/disable, environment, transport and custom-instruction fields MAY remain. Validate actual side effects and tool contracts without approval categories: side effects stay explicit in the LLM-facing contract but do not trigger a runtime permission gate.

### Requirement: MCP Creator uses the Ability surface

`mcp-creator` retains Native/External development, schema, handler, result, configuration and reload ownership; direct callers to load the resulting same-named MCP-backed Ability and use `@ability:tool` / `#ability:resource`. After required server reload, load that Ability, validate its complete allowed tool/resource catalog and invoke only current cataloged targets. For schema/result changes, use `load(target="<ability>", force_reload=true)`, inspect the catalog, then invoke `@ability:tool` or read `#ability:resource` as applicable. `load_server` and `<server>__<tool>` are retired and permitted only in explicit history/migration evidence.

### Requirement: MCP context optimization uses live schemas and Ability-owned guidance

Live allowed MCP schemas are structural authority; concise guidance belongs to the same-named Ability's `SKILL.md` or cataloged references. Optional `ABILITY.yaml.mcp.overrides` names a root-confined file overriding tool/parameter descriptions only, never live names/types/required/enums/defaults/alternatives. Central `prompts/mcp/` and `prompts/abilities/` caches/guidance are retired. Detailed behavior belongs to [MCP Tool Schema And Ability Guidance](../../../runtime/mcp-doc-cache-contracts.md).

## Acceptance and evidence

The requirements define acceptance for type selection, LLM-facing contracts and distinct reload strategies/checks. The evidence below implies no measured future-Agent behavior.

## Validation Evidence

| Scope / date | Evidence and limits |
| --- | --- |
| Specification/source inspection | `passed` against the maintained `mcp-creator` Ability and current Native/External ownership layout. Human specification review: `passed`. |
| 2026-09-13 — reload classification | Focused tests and full Neovim restart-resume `passed` for repository-owned MCPHub core; backend-only refresh remains process-level without Lua changes. Broader Native/External server live validation remains `partial`. |
| 2026-09-16 — no-approval configuration | Ability guides, user guide, runtime docs and committed `servers.json` converged; Ability lint, JSON checks and fresh-process runtime validation `passed`. |
| 2026-09-22 — Ability/schema layering | Unified loading/addressing, package-owned description overrides, live-schema authority and central-cache removal passed focused catalog/load tests and fresh-Neovim validation; human acceptance `passed`. |
| SubAgent tool result contracts | Scoped templates/shared-owner review, Ability lint/reload and actual SubAgent representation/UI migration `passed`; historical human review `not-run`. |

## Source Trace

| Rule group | Sources |
| --- | --- |
| Gate, selection, workflow/reload | Global Ability table; `abilities/mcp-creator/SKILL.md`; package `references/native-server-guide.md`, `references/external-server-guide.md`, `scripts/restart_nvim_resume.lua`, `scripts/restart_mcphub.lua` |
| Tool contracts | `abilities/mcp-creator/references/llm-facing-tool-contract.md` |
| Runtime ownership | `lua/maxa/mcphub/`, `lua/maxa/mcphub/native_servers/`, `mcp-servers/` |
| Cache/guidance layering | [MCP Documentation Cache](../../../runtime/mcp-doc-cache-contracts.md) |

Existing TODO, not new evidence: if schema drift repeats, add a small tool-contract review checklist or fixture.
