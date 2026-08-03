---
title: Downstream delta — message-context
authority: draft
status: experimental
baseline_module: ../modules/message-context/spec.md
---

## Classification

- `compatibility shim`: SuperMax hooks adapter message/tool formation and uses CodeCompanion chat/config structures.
- `product requirement`: context limits, fragments, drafts, history transfer, and MCP history operations extend the context surface.

## Evidence

- Baseline: `../modules/message-context/spec.md`.
- `lua/util/hooks/adapter_form_messages.lua`, `adapter_form_tools.lua`.
- `lua/util/hooks/chat_context_limit_stop.lua`, `codecompanion_slash_command_input_capture.lua`.
- `lua/util/mcphub/cc_history/chat_fragments/`, `slash_commands/`, `tools/`.
- `lua/codecompanion/_extensions/history/transfer.lua`, `storage.lua`.

## Coverage / risk / decision

- Upstream baseline behavior: messages, context variables/rules, slash dispatch, and provider payload boundary.
- SuperMax coverage: preserves payload integration while adding durable fragments, cross-project transfer, compaction, probes, and context-stop controls.
- Coupling risk: message shape and slash-command parsing are shared by adapters, history, and MCP tools.
- Independent runtime decision: downstream compatibility/product evidence only; baseline remains untouched.
