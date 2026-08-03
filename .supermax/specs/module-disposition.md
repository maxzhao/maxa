---
title: CodeCompanion Module Target Disposition
created: 2026-08-02
updated: 2026-08-02
doc_role: target-disposition
authority: draft
status: partial
sources:
  - modules/target-scope/spec.md
  - downstream/index.md
  - hook-replacement-map.md
---

# Purpose

Prevent upstream reverse-engineering facts from being mistaken for target requirements. Baseline-only details may remain as evidence only when explicitly classified below; target implementation authority belongs to the named target module.

| Upstream module/evidence | Target disposition | Target owner | Notes |
| --- | --- | --- | --- |
| `bootstrap-configuration` | redefined | `supermax-configuration`, `provider-contract`, `actions-commands-target` | Replace broad CodeCompanion setup/adapter schema with a runtime developed in the mother repository and a target-project `.maxa/` contract; the development `.supermax/` is not a runtime dependency. |
| `chat-lifecycle` | retained and redefined | `chat-runtime-state`, `request-orchestrator`, `chat-ui`, `async-lifecycle` | Preserve observable Chat behavior; replace implicit fields/callback order with explicit state and orchestration. |
| `message-context` | retained and redefined | `message-context-target`, `supermax-configuration` | Preserve conversation/context behavior; provider-neutral model and target-project `.maxa/` prompt authority are normative. |
| `tools-agent-loop` | retained and redefined | `tool-runtime`, `request-orchestrator`, `mcp-skill-runtime` | Remove approval gates; automatic execution and built-in MCP/Skill are normative. |
| `http-transport` | narrowed and replaced | `provider-contract`, `streaming-usage` | Only OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and Gemini native are target protocols. Other provider/protocol sections are baseline evidence only and MUST NOT create implementation requirements. |
| `background-interactions` | narrowed | `async-lifecycle`, `session-history`, `events-status` | Retain title/background operations only when required by current SuperMax history/status behavior. |
| `actions-extensions` | retained and redefined | `actions-commands-target`, `chat-ui` | Retain Actions/Commands/extension registration; remove workflow execution and standalone command-input Chat interaction. |
| `events-integration` | retained and redefined | `events-status` | Preserve required observable boundaries; replace distributed CodeCompanion autocmd payloads with typed runtime events. |
| ACP | removed | none | Source/downstream/delta module files deleted. |
| Inline assistant | removed | none | Source/downstream/delta module files deleted. |
| Workflow behavior in retained files | removed from target | none | May remain only as labeled upstream evidence; target parser/runtime rejects or ignores workflow semantics. |
| CodeCompanion `gemini` adapter | compatibility evidence only | `provider-contract` | Pinned adapter uses Google's OpenAI-compatible endpoint, not Gemini native API. It MUST NOT satisfy native Gemini requirements. |
| CodeCompanion plugin/extension/internal APIs | temporary compatibility | `migration-compatibility` | No new target module may depend on them. |
| legacy `display_chat_history` extension | superseded/removed | `session-history` | Consolidate into one versioned project history implementation. |
| buffer translation | retained optional Command | `actions-commands-target`, `provider-contract` | Uses provider runtime directly; cached translation behavior is not Chat identity. |
| default adapter/model UI | retained and redefined | `provider-contract`, `supermax-configuration`, `chat-ui` | Project/session provider selection; no `.env` mutation as runtime persistence API. |
| Telegram notification/bridge | retained optional integration | `events-status`, `session-history`, `mcp-skill-runtime` | Typed event/session consumer; no CodeCompanion callbacks. |
| session stats/status panel | retained and redefined | `session-history`, `streaming-usage`, `chat-ui` | Reads normalized session/status snapshots. |
| LLM error handler | retained and redefined | `provider-contract`, `request-orchestrator` | Typed protocol-aware classification and bounded retry policy. |
| MCPHub restart/resume helper | superseded | `mcp-skill-runtime`, `request-orchestrator` | Native lifecycle state and continuation replace polling patch. |
| Neovim restart/resume helper | retained and redefined | `session-history`, `async-lifecycle` | Versioned recovery contract replaces CodeCompanion restoration. |
| TaskBrowser integration | external consumer | public `events-status`/spine API | TaskAdmin remains independently owned; no Chat internals. |
| provider quota/proxy modules | compatibility backend | `provider-contract`, `streaming-usage`, `events-status` | Provider IDs do not expand the four-protocol enum. |

## Cleanup rule

When editing retained upstream files, either delete unsupported behavior or label it baseline-only. No unsupported provider, ACP, inline, workflow, approval gate or command-input Chat behavior may appear as a target `MUST`/`SHOULD` requirement.

## Completion gate

This map becomes complete when every requirement in retained upstream modules and every repository-wide CodeCompanion/MCPHub consumer is classified as target-retained, target-redefined, baseline-only, external consumer or removed; scoped search must find no ambiguous unsupported normative behavior. Current classifications are broad-complete, while executable replacement and newly introduced consumer audits remain open.
