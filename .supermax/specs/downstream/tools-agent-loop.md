---
title: Downstream delta — tools-agent-loop
authority: draft
status: experimental
baseline_module: ../modules/tools-agent-loop/spec.md
---

## Classification

- `defect workaround`: tool execution/display and async cancellation patches guard tool-loop failures and observability edges.
- `product requirement`: SubAgent, MCPX, JSON artifact, GenAI, and extended history tools are SuperMax capabilities.

## Evidence

- Baseline: `../modules/tools-agent-loop/spec.md`.
- `lua/util/hooks/tool_execution.lua`, `tool_display.lua`, `mcpx_async_tasks.lua`, `chat_agent_loop_auto_restore.lua`.
- `lua/util/mcphub/init.lua` exports `subagent`, `mcpx`, `json_artifact`, `genai`, and `cc_history`.
- `lua/util/mcphub/cc_history/tools/`, `json_artifact/`, `genai/`, and `lua/util/mcphub/subagent/`.
- Tests: `tool_display_test.lua`, `mcpx_async_tasks_spec.lua`, and module-specific tests.

## Coverage / risk / decision

- Upstream baseline behavior: tool registration, execution, agent loop, tool-call results, and failure handling.
- SuperMax coverage: adds MCP server capability, artifact protocol, delegation, async cancellation, tool display, recovery, and session tooling.
- Coupling risk: tool result schemas, cancellation propagation, and agent-loop sequencing cross server/hook boundaries.
- Independent runtime decision: product additions and workaround candidates remain draft; no final goal spec is defined.
