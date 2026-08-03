---
title: Downstream delta — http-transport
authority: draft
status: experimental
baseline_module: ../modules/http-transport/spec.md
---

## Classification

- `defect workaround`: message/tool parsing and streaming guards address provider/adapter edge cases.
- `compatibility shim`: gateway adapters preserve CodeCompanion HTTP adapter contracts while changing endpoints/protocol details.

## Evidence

- Baseline: `../modules/http-transport/spec.md`.
- `lua/plugins/ai.lua`: `make_openai_responses_gateway_adapter`, `make_anthropic_messages_gateway_adapter`.
- `lua/util/hooks/adapter_form_messages.lua`, `adapter_form_tools.lua`, `adapter_parse_tokens.lua`, `adapter_tool_calls.lua`, `adapter_openai_responses_streaming_tools.lua`.
- Tests: `adapter_form_messages_load_image_test.lua`, `adapter_form_messages_on_exit_guard_test.lua`, `adapter_openai_responses_streaming_tools_test.lua`.

## Coverage / risk / decision

- Upstream baseline behavior: HTTP providers, request formation, streaming, parsing, and tool calls.
- SuperMax coverage: provider gateways, OpenAI Responses streaming/tool adaptation, token parsing, and message/tool guards.
- Coupling risk: provider response schemas and upstream adapter method signatures; failures can corrupt tool loops.
- Independent runtime decision: preserve as draft compatibility/workaround evidence; defect claims require upstream reproduction.
