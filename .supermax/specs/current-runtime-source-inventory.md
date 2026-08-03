---
title: Current maxa Runtime Source Inventory
created: 2026-08-02
updated: 2026-08-02
doc_role: evidence-inventory
authority: draft
status: partial
sources:
  - lua/plugins/ai.lua
  - lua/util/hooks/
  - lua/util/codecompanion/status/
  - lua/util/mcphub/
  - lua/util/skill_hooks/
  - lua/codecompanion/_extensions/history/
confidence: high
---

# Purpose

Route every current behavior-bearing integration source to a target owner and prevent implementation work from overlooking a hook or extension. This is an evidence inventory, not a target implementation layout.

## Runtime entry and configuration

| Source | Current responsibility | Target owner | Coverage |
| --- | --- | --- | --- |
| `lua/plugins/ai.lua` | provider/gateway construction, CodeCompanion setup, MCPHub setup, system prompt, mappings, lualine/status integration | `provider-contract`, `supermax-configuration`, `chat-ui`, `mcp-skill-runtime`, `events-status`, `migration-compatibility` | broad static trace; exact config extraction partial |
| `lua/util/GenerateSystemPrompt.lua` | runtime/project prompt lookup, template/slot rendering | `supermax-configuration`, `message-context-target` | target contract drafted; slot fixtures open |
| `lua/util/supermax_schema_check.lua` | `.supermax` schema/rule validation evidence | `supermax-configuration` | current tests passed; replacement schema absent |

## Hook patch layer

| Sources | Current responsibility | Target owner | Retirement evidence |
| --- | --- | --- | --- |
| `adapter_form_messages.lua`, `adapter_form_tools.lua`, `adapter_parse_tokens.lua`, `adapter_tool_calls.lua`, `adapter_openai_responses_streaming_tools.lua` | provider request/stream/tool/usage corrections | `provider-contract`, `message-context-target`, `streaming-usage`, `tool-runtime` | protocol fixtures plus normalized adapter tests |
| `chat_soft_stop.lua`, `chat_context_limit_stop.lua`, `chat_request_watchdog.lua` | stop boundary, context budget, watchdog/retry | `request-orchestrator`, `async-lifecycle` | state/cancel/retry fixtures |
| `chat_agent_loop_auto_restore.lua` | loop recovery after restore | `chat-runtime-state`, `session-history`, `request-orchestrator` | restored-loop fixture |
| `chat_response_started_event.lua`, `chat_submitted_event` behavior in hook init | lifecycle event repair | `events-status` | event ordering/de-duplication fixtures |
| `tool_execution.lua`, `tool_calls_completed_event.lua`, `mcpx_async_tasks.lua` | automatic tool execution, batch barrier, async task ownership | `tool-runtime`, `async-lifecycle`, `request-orchestrator` | tool batch/cancel/late-callback fixtures |
| `tool_display.lua`, `chat_ui.lua`, `chat_ui_buffer_guard.lua`, `codecompanion_slash_command_input_capture.lua` | Chat rendering, tool projection, view guards, Chat input capture | `chat-ui`, `actions-commands-target` | view detach/render/input fixtures |
| `session_trace_lifecycle.lua` | trace turn/event recording and de-duplication | `session-history`, `events-status` | trace/recovery fixtures |
| `chat_buf_get_chat_fix.lua` | buffer-to-Chat lookup correction | `chat-runtime-state`, `migration-compatibility` | session/view identity fixtures |
| `mcphub_helpers_fix.lua`, `mcphub_native_fix.lua` | MCPHub compatibility repairs | `mcp-skill-runtime`, `migration-compatibility` | replacement MCP registration/lifecycle fixtures |
| `proxy.lua` | shared hook installation/proxy primitive | `migration-compatibility` | unused after direct target ownership |
| `lua/util/hooks/init.lua` | patch installation and event wiring | all owners above | all mapped hooks retired |

Current production hook files: 23. Current focused hook tests: 12. Exact test mapping and results are in `hook-replacement-map.md` and the draft plan.

## Built-in status/spine projection

| Source | Current responsibility | Target owner | Coverage |
| --- | --- | --- | --- |
| `lua/util/codecompanion/status/state.lua` | request/warmup/running counts, active/display Chat, provider/model/token snapshot, lualine refresh | `events-status`, `streaming-usage` | state contract enriched; replacement snapshot tests open |
| `status/spinner.lua` | per-view request/tool-argument/retry spinner, timer/extmark cleanup | `events-status`, `chat-ui`, `async-lifecycle` | current evidence only |
| `status/lualine.lua` | statusline projection | `events-status` | target projection contract drafted |
| `status/context_limits.lua` | model/provider context limits | `streaming-usage`, `provider-contract` | exact replacement schema open |
| `status/billing.lua` | provider billing/usage projection | `streaming-usage`, `events-status` | target normalized usage owner selected |
| `status/init.lua` | subsystem setup/accessors | `events-status` | replacement composition open |

## MCP runtime

Native MCP roots exported by `lua/util/mcphub/init.lua`:

| Root | Current file count | Target disposition |
| --- | ---: | --- |
| `mcpx` | 56 | built-in core tool/file/command/server bridge |
| `cc_history` | 64 | built-in session/history/trace/compaction runtime |
| `subagent` | 28 | built-in optional delegation capability under runtime policy |
| `genai` | 21 | built-in dynamic image capability |
| `json_artifact` | 19 | built-in large-JSON artifact capability |
| `misc` | 4 | inspect and split into explicit primitives before replacement |
| `shared` | 2 | reusable MCP result/schema helpers |

Additional sources: `lua/util/mcphub/config.lua`, `config_test.lua`, `init.lua`. External server process lifecycle currently remains in `mcphub.nvim` and `ai.lua`; replacement ownership belongs to `mcp-skill-runtime`.

## Skill and SkillHook runtime

| Source | Current responsibility | Target owner |
| --- | --- | --- |
| `lua/util/skill_hooks/parser.lua` | Markdown/Lua hook parsing and frontmatter | `mcp-skill-runtime` |
| `registry.lua` | registration, scope and dispatch state | `mcp-skill-runtime`, `events-status` |
| `filter.lua` | event payload filtering | `mcp-skill-runtime` |
| `injector.lua` | synchronous/asynchronous message injection, once state | `mcp-skill-runtime`, `message-context-target` |
| `fire.lua` | custom SkillHook event bridge | `events-status` |
| `init.lua` | global/project discovery, startup/on-load and history restore | `mcp-skill-runtime`, `session-history` |
| `inject_at_test.lua` | pre-submit ordering evidence | replacement SkillHook fixture |

## History and trace

| Sources | Current responsibility | Target owner |
| --- | --- | --- |
| `lua/codecompanion/_extensions/history/` | JSON storage/index/project registry/title/UI/pickers/transfer | `session-history`, `migration-compatibility` |
| `lua/util/mcphub/cc_history/history_core.lua`, `history_session.lua` | project-scoped identities, save/restore and active-session mutation | `session-history` |
| `session_trace.lua` | trace manifests/events/index/membership/archive | `session-history`, `events-status` |
| `default_session_cache.lua`, `llm_error_recovery.lua` | warmup/cache and error recovery | `session-history`, `request-orchestrator` |
| `chat_fragments/`, `loaded_items.lua` | reusable fragments/context membership | `session-history`, `message-context-target` |
| `slash_commands/` | fork/merge/rewind/redo/save/scratch/compact/trace/insert/pick operations | `actions-commands-target`, `session-history` |
| `tools/` | MCP-accessible history query/transfer/compaction operations | `session-history`, `mcp-skill-runtime` |

## Adjacent CodeCompanion/MCPHub consumers

A repository-wide reference audit found additional behavior-bearing consumers outside the initial entry families:

| Sources | Target disposition / owner |
| --- | --- |
| `lua/util/codecompanion/buffer_translate.lua` | retain as optional Action/Command; replace background CodeCompanion request with provider runtime (`actions-commands-target`, `provider-contract`) |
| `default_adapter.lua`, `default_adapter_ui.lua` | replace adapter persistence/UI with project/session provider selection; no direct `.env` mutation (`provider-contract`, `supermax-configuration`, `chat-ui`) |
| `notify_when_done.lua`, `telegram_bridge/` | optional notification/human-assist consumer over typed events/session APIs; no Chat callback patch (`events-status`, `session-history`, `mcp-skill-runtime`) |
| `session_stats.lua`, `session_status.lua`, `session_status_panel.lua` | retain normalized session diagnostics and optional panel; remove CodeCompanion object dependency (`session-history`, `streaming-usage`, `chat-ui`) |
| `token_usage.lua` | replace fallback probing with normalized usage snapshot (`streaming-usage`) |
| `lua/util/llm_error_handler.lua` | retain typed provider error classification/retry policy (`provider-contract`, `request-orchestrator`) |
| `lua/util/mcphub_control.lua` | replace restart/poll/resume patch with MCP lifecycle state plus continuation decision (`mcp-skill-runtime`, `request-orchestrator`) |
| `lua/util/nvim_restart_resume.lua` | retain host restart recovery through versioned session/recovery contract (`session-history`, `async-lifecycle`) |
| `lua/codecompanion/_extensions/display_chat_history/` | superseded by target `session-history`; remove after migration |
| `lua/plugins/task_browser.lua` and TaskBrowser lualine integration | independent TaskAdmin host consumer; use public runtime event/spine APIs only, not core Chat ownership |
| Copilot/deepseek/newapi/sub2api quota/proxy modules | compatibility provider/quota backends; provider IDs map to four protocols, billing is optional projection |

## Inventory completion state

Covered entry families: provider/configuration, all production hook filenames, status modules, MCP root modules/counts, all SkillHook sources, history/trace core and operation families, and repository-wide CodeCompanion/MCPHub consumers listed above.

Open inventory work before `status: complete`:

1. Finalize the target history schema version and migration implementation; current fields are inventoried in `history/types.lua` and the minimum target envelope is in `runtime-fixture-contract.md`.
2. Finalize provider/model context-limit and quota/billing configuration schemas; ownership is assigned to `provider-contract`, `streaming-usage`, and `events-status`.
3. Re-run the repository-wide import/reference audit after implementation begins and classify newly introduced consumers.

Resolved:

- `misc` currently contains only `echo` plus lifecycle notifications. It is removed as a bucket; a future diagnostic echo, if required, must be an explicitly named opt-in primitive.
- Current project/external MCP evidence is hard-coded in `ai.lua`: `tauri-wdio`, global project-root environment, 600000ms request timeout, automatic server toggling, automatic tool execution and native-server injection. The target replaces this with target-project `.maxa/mcp/servers.yaml` plus bundled native registration; the development mother repository's `.supermax/` is evidence only. `dotfiles/mcphub/servers.json` is local-only evidence and is not promoted into the shared target contract.
