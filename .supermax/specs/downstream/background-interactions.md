---
title: Downstream delta — background-interactions
authority: draft
status: experimental
baseline_module: ../modules/background-interactions/spec.md
---

## Classification

- `product requirement`: asynchronous status, notification, Telegram, and service integration are SuperMax-owned behavior.
- `unknown`: causal relation to any upstream background defect is not established.

## Evidence

- Baseline: `../modules/background-interactions/spec.md`.
- `lua/util/codecompanion/notify_when_done.lua`, `session_status.lua`, `session_stats.lua`.
- `lua/util/codecompanion/telegram_bridge/` (`service.lua`, `hooks.lua`, `status.lua`).
- `lua/util/hooks/chat_request_watchdog.lua`, `mcpx_async_tasks.lua`.

## Coverage / risk / decision

- Upstream baseline behavior: background interactions and asynchronous request lifecycle as recorded in the baseline.
- SuperMax coverage: notifications, watchdog/retry controls, status state, Telegram bridge, and MCP async task tracking.
- Coupling risk: event timing and chat/request state are shared with hook patches; failures can affect visible status and recovery.
- Independent runtime decision: downstream product behavior; target specification intentionally not defined.
