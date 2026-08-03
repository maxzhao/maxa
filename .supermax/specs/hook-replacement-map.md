---
title: Hook Replacement Map for maxa Target Runtime
created: 2026-08-02
updated: 2026-08-02
doc_role: migration-map
authority: draft
status: partial
sources:
  - lua/util/hooks/init.lua
  - lua/util/hooks/
  - lua/plugins/ai.lua
---

# Purpose

Map every current CodeCompanion hook to a target runtime owner. A replacement is complete only when the named target module has accepted requirements, implementation, and validation; until then the hook remains required by the current runtime.

| Current hook | Current reason | Target owner / requirement | Replacement status |
| --- | --- | --- | --- |
| `proxy.lua` | proxy and model-list transport behavior | `provider-contract`; project runtime defaults | specified, unimplemented |
| `adapter_parse_tokens.lua` | canonical total-token extraction | `streaming-usage`; `events-status` | specified, unimplemented |
| `adapter_form_messages.lua` | reasoning retention, image/message conversion, provider guards | `message-context-target`; `provider-contract` | specified, unimplemented |
| `adapter_form_tools.lua` | Responses strict schema and deterministic tool schema | `provider-contract`; `tool-runtime` | specified, unimplemented |
| `adapter_openai_responses_streaming_tools.lua` | tool-only Responses streams and normalized errors | `streaming-usage` | specified, unimplemented |
| `adapter_tool_calls.lua` | protocol call argument normalization | `streaming-usage`; `tool-runtime` | specified, unimplemented |
| `chat_agent_loop_auto_restore.lua` | restore loop, submit intent, orphan tool repair | `chat-runtime-state`; `request-orchestrator`; `session-history` | specified, unimplemented |
| `chat_buf_get_chat_fix.lua` | absent buffer/chat registry safety | `chat-runtime-state`; `chat-ui` | specified, unimplemented |
| `chat_context_limit_stop.lua` | safe context-limit continuation stop | `request-orchestrator`; `streaming-usage` | specified, unimplemented |
| `chat_request_watchdog.lua` | progress detection, bounded retry, terminal error | `request-orchestrator`; `events-status` | specified, unimplemented |
| `chat_response_started_event.lua` | first-response lifecycle signal | `events-status` | specified, unimplemented |
| `chat_soft_stop.lua` | drain active response/tools then stop continuation | `chat-runtime-state`; `request-orchestrator`; `async-lifecycle` | specified, unimplemented |
| `chat_ui.lua` | view intro, model/provider display, multiline virtual text | `chat-ui`; `events-status` | specified, unimplemented |
| `chat_ui_buffer_guard.lua` | protect async work from invalid view buffer | `async-lifecycle`; `chat-ui` | specified, unimplemented |
| `codecompanion_slash_command_input_capture.lua` | retain Chat input before completion mutation | `chat-ui`; `actions-commands-target` | specified, unimplemented |
| `mcphub_helpers_fix.lua` | image/helper capability gap | `mcp-skill-runtime`; `message-context-target` | specified, unimplemented |
| `mcphub_native_fix.lua` | native MCP server lifecycle gap | `mcp-skill-runtime`; `async-lifecycle` | specified, unimplemented |
| `mcpx_async_tasks.lua` | cancel session-owned async tasks on close/exit | `async-lifecycle`; `tool-runtime` | specified, unimplemented |
| `session_trace_lifecycle.lua` | natural-turn capture and trace idempotency | `session-history`; `events-status` | specified, unimplemented |
| `tool_calls_completed_event.lua` | batch completion at continuation boundary | `tool-runtime`; `request-orchestrator`; `events-status` | specified, unimplemented |
| `tool_display.lua` | result summary, pending state and TTL projection | `tool-runtime`; `chat-ui`; `events-status` | specified, unimplemented |
| `tool_execution.lua` | invalid call standardization and batch participation | `tool-runtime` | specified, unimplemented |

## Non-hook migration evidence

- `lua/plugins/ai.lua`: target provider/configuration/prompt/MCP/lualine policy.
- `lua/util/codecompanion/status/`: target spine and lualine projection.
- `lua/util/mcphub/cc_history/`: target session history and trace behavior.
- `lua/util/skill_hooks/`: target Skill runtime/event integration.

## Evidence validation

Current compatibility tests passed on 2026-08-02:

- `nvim --headless -u NONE -l lua/util/hooks/chat_soft_stop_test.lua` — 5 tests.
- `nvim --headless -u NONE -l lua/util/hooks/chat_context_limit_stop_test.lua` — 10 tests.
- `nvim --headless -u NONE -l lua/util/hooks/adapter_openai_responses_streaming_tools_test.lua` — 4 tests.
- `nvim --headless -u NONE -l lua/util/hooks/tool_calls_completed_event_test.lua` — passed.
- `nvim --headless -u NONE -l lua/util/hooks/chat_request_watchdog_retry_limit_test.lua` — 2 tests.
- `nvim --headless -u NONE -l lua/util/hooks/chat_response_started_event_test.lua` — 1 test.
- `nvim --headless -u NONE -l lua/util/hooks/session_trace_lifecycle_test.lua` — 6 tests.

- `adapter_form_messages_load_image_test.lua` — 3 tests.
- `adapter_form_messages_on_exit_guard_test.lua` — 3 tests.
- `chat_submitted_event_test.lua` — passed.
- `mcpx_async_tasks_spec.lua` — passed.
- `tool_display_test.lua` — 10 tests.
- `lua/util/skill_hooks/inject_at_test.lua` — passed.
- `lua/util/mcphub/config_test.lua` — 4 tests.

These are evidence for current behavior only. They do not satisfy replacement-runtime retirement gates.

## Gate

Do not delete a hook solely because a target spec exists. Delete only after its target behavior has passing replacement checks and the CodeCompanion compatibility path no longer invokes it.
