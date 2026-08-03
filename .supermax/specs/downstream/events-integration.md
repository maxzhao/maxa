---
title: Downstream delta — events-integration
authority: draft
status: experimental
baseline_module: ../modules/events-integration/spec.md
---

## Classification

- `compatibility shim`: hook modules observe and extend CodeCompanion event/lifecycle boundaries.
- `product requirement`: response-started, tool-completed, trace, submitted, and display events expose SuperMax runtime behavior.

## Evidence

- Baseline: `../modules/events-integration/spec.md`.
- `lua/util/hooks/chat_response_started_event.lua`, `tool_calls_completed_event.lua`, `session_trace_lifecycle.lua`, `codecompanion_slash_command_input_capture.lua`.
- Tests: `chat_response_started_event_test.lua`, `tool_calls_completed_event_test.lua`, `chat_submitted_event_test.lua`, `session_trace_lifecycle_test.lua`.

## Coverage / risk / decision

- Upstream baseline behavior: event emission and public integration hooks.
- SuperMax coverage: injects additional lifecycle notifications, trace lineage, tool completion, and slash-command capture.
- Coupling risk: event names, callback payloads, and ordering are upstream public/internal contracts.
- Independent runtime decision: compatibility and product additions remain separate; no target contract asserted.
