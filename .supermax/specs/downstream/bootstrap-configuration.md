---
title: Downstream delta — bootstrap-configuration
authority: draft
status: experimental
baseline_module: ../modules/bootstrap-configuration/spec.md
---

## Classification

- `compatibility shim`: SuperMax calls CodeCompanion adapter/config APIs and extends native adapters.
- `product requirement`: gateway provider selection, quotas, defaults, and restart-safe initialization are SuperMax behavior.

## Evidence

- Baseline: `../modules/bootstrap-configuration/spec.md`.
- `lua/plugins/ai.lua`: `make_supermax_config`, `make_llm_gateway_adapter`, `make_openai_responses_gateway_adapter`, `make_anthropic_messages_gateway_adapter`.
- `lua/util/codecompanion/default_adapter.lua`, `default_adapter_ui.lua`.
- `lua/util/mcphub/config.lua`.

## Coverage / risk / decision

- Upstream baseline behavior: bootstrap/configuration and public setup entrypoints at v18.7.0.
- SuperMax coverage: preserves adapter setup while adding provider-owned models, gateway protocols, quotas, defaults, and UI selection.
- Coupling risk: adapter extension deep-merge semantics and upstream schema shape are explicitly relied upon.
- Independent runtime decision: compatibility surface retained; product decisions remain draft.
