---
title: Downstream delta — chat-lifecycle
authority: draft
status: experimental
baseline_module: ../modules/chat-lifecycle/spec.md
---

## Classification

- `defect workaround`: guard/watchdog/auto-restore patches target unsafe or stuck lifecycle edges.
- `product requirement`: soft stop, context-limit stop, trace lifecycle, and richer session handling are SuperMax additions.

## Evidence

- Baseline: `../modules/chat-lifecycle/spec.md`.
- `lua/util/hooks/chat_soft_stop.lua`, `chat_context_limit_stop.lua`, `chat_request_watchdog.lua`.
- `lua/util/hooks/chat_agent_loop_auto_restore.lua`, `chat_ui_buffer_guard.lua`, `session_trace_lifecycle.lua`.
- Tests: corresponding `*_test.lua` files under `lua/util/hooks/`.

## Coverage / risk / decision

- Upstream baseline behavior: create/open/submit/stop/close chat and request state transitions.
- SuperMax coverage: additional stop guards, context limits, watchdog retries, auto-restore, trace state, and buffer protection.
- Coupling risk: monkey patches depend on exact chat/request state and event order; upstream updates may silently invalidate guards.
- Independent runtime decision: retain as draft downstream evidence; do not label every patch a confirmed upstream defect.
