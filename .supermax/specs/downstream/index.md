---
title: CodeCompanion v18.7.0 downstream adaptation evidence map
created: 2026-08-01
updated: 2026-08-01
doc_role: downstream-adaptation-evidence-map
authority: draft
status: experimental
baseline: ../baseline.md
---

> Scope: evidence map only. It records observed SuperMax coverage against the locked CodeCompanion `v18.7.0` reverse-spec baseline; it does not rewrite baseline behavior or define a target specification.

## Decision vocabulary

- `defect workaround`: downstream behavior appears to compensate for an upstream defect or unsafe edge.
- `compatibility shim`: preserves/adapts an upstream interface or lifecycle boundary.
- `product requirement`: independent SuperMax behavior not implied by upstream.
- `obsolete behavior`: upstream behavior intentionally bypassed or replaced; evidence is not sufficient to claim deletion from the target product.
- `unknown`: evidence or causal decision is insufficient.

## Module map

| Baseline module | Delta evidence | Runtime decision |
| --- | --- | --- |
| ACP protocol | removed from target; no downstream implementation required | deleted from target scope |
| [[actions-extensions]] | [[actions-extensions]] | retained Actions/Commands and extension contract; standalone command-input Chat mode removed |
| Target runtime modules | `modules/*-target/spec.md` | SuperMax target requirements derived from hooks and current runtime |
| [[background-interactions]] | [[background-interactions]] | product requirement / unknown |
| [[bootstrap-configuration]] | [[bootstrap-configuration]] | compatibility shim + product requirement |
| [[chat-lifecycle]] | [[chat-lifecycle]] | defect workaround + product requirement |
| [[events-integration]] | [[events-integration]] | compatibility shim + product requirement |
| [[http-transport]] | [[http-transport]] | defect workaround + compatibility shim |
| Inline assistant | removed from target | deleted from target scope |
| [[message-context]] | [[message-context]] | compatibility shim + product requirement |
| [[tools-agent-loop]] | [[tools-agent-loop]] | defect workaround + product requirement |

## Cross-cutting evidence

- Configuration and adapter composition: `lua/plugins/ai.lua` (`make_supermax_config`, `make_llm_gateway_adapter`, `make_openai_responses_gateway_adapter`, `make_anthropic_messages_gateway_adapter`).
- Hook patch layer: `lua/util/hooks/init.lua` (`M.setup`) and modules under `lua/util/hooks/`.
- Session/UI extensions: `lua/codecompanion/_extensions/history/init.lua` (`History.new`, `_create_commands`, `_setup_autocommands`, `_setup_keymaps`) and `lua/codecompanion/_extensions/display_chat_history/init.lua`.
- Native MCP surface: `lua/util/mcphub/init.lua` exports `mcpx`, `cc_history`, `genai`, `json_artifact`, `subagent`, and `misc`; module behavior is under `lua/util/mcphub/*`.
- Tests are cited per delta; this map is not a behavior-coverage claim. Several baseline modules remain `partial` in their source specs.

## Final audit / gaps

- Causal classification is evidence-backed only where a test or explicit change/spec identifies the reason; otherwise it remains `unknown`.
- No baseline checkout/source diff was re-read in this pass; upstream facts are inherited from the baseline module specs and `baseline.md`.
- No final target requirement is defined here. Human review is required before promotion or convergence claims.
- Static validation: file/link/frontmatter checks should pass; runtime and upstream-baseline behavioral validation remain not run.
