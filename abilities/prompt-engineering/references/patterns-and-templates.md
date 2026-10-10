# Prompt Patterns and Templates

## Selection

Apply [Direct Instruction Writing](../SKILL.md#direct-instruction-writing). Choose patterns and sections for the contract's actual needs; do not copy a full template or teach familiar syntax by default.

| Need | Prompt-specific contract |
| --- | --- |
| Structured output | Required schema, field constraints, missing-data/error semantics, and permitted wrapping; prefer native structured-output support when available. |
| Classification or transformation | Task-specific labels and mappings; few-shot examples only for concrete ambiguity or evidenced failure. |
| Long context or grounding | Selected authoritative sources, trust boundaries, citation requirements, and missing-fact behavior. |
| Tool-using Agent | Tool selection, exact interface constraints, bounded recovery, validation, and stop conditions. |
| Production prompt builder | Typed parameters or schemas and explicit template-variable contracts. |

## Context And Variables

- Keep the current goal distinguishable from historical context. Include task-relevant source material and material gaps, not unrelated full dumps.
- Define each template variable's source, type, and trust level. Do not insert unescaped user input into high-authority instruction sections.
- When source-only answers are required, state that constraint and how to handle missing facts; source boundaries alone do not impose it.

## Examples

Use examples to resolve a named ambiguity, not to demonstrate standard Markdown, JSON, XML, or familiar methods. Match the required output and separate examples from real input. Preserve safety and privacy.

## Validation

Use `references/quality-checklist.md` for the selected contract and consumer. Verify that removing templates or examples preserved prompt-specific requirements; distinguish static, tool-integration, and model-behavior evidence.
