# Repairing a Noncompliant Prompt

## Goal

Diagnose and repair prompts that are unclear, conflicting, oversized, unverifiable, unsafe, unmaintainable, or incompatible with Maxa runtime constraints. Apply [Direct Instruction Writing](../SKILL.md#direct-instruction-writing).

## Diagnostic Scope

Check goal clarity, authority, rule consistency, output contracts, complexity, context relevance, instruction balance, grounding, portability, and safety. Include repeated teaching in the diagnosis under Direct Instruction Writing, even when the prose is accurate and not duplicated elsewhere.

For output failures, define missing prompt-specific schema or constraints; add examples only for unresolved ambiguity. For safety conflicts, preserve higher-priority restrictions and required approvals.

For early stops, repeated confirmation, approval ambiguity, or unnecessary validation loops, read `references/autonomy-and-completion.md`. For duplicate ownership or moving instructions between load layers, use the relevant sections of `references/maintain-existing-prompt.md`; preserve authority and inspect affected indirect execution sources.

## Repair Steps

1. Inspect the full requested scope and distinguish existing knowledge from prompt-specific contracts using Direct Instruction Writing.
2. List concrete failed behaviors; do not replace evidence with abstract criticism.
3. Identify smallest root cause: missing field, conflict, wrong placement, misleading example, context pollution, or model mismatch.
4. Make the minimal repair and verify retained obligations, conditions, boundaries, and public behavior.
5. Select checks that decide the repaired behavior, including the problem input when available; reuse valid evidence. Distinguish static contract, tool integration, and model-behavior checks and state material gaps. Retest further only for changes, failures, unresolved concerns, or required acceptance evidence.
6. If public behavior changes, state compatibility impact and rollback path.

## Repair Constraints

Convert failure evidence into stable contracts, not incident logs. Isolate retrieved and user-controlled context from instruction authority, and define required missing-fact behavior.

## Repairs Not to Add by Default

Follow the non-default technique boundaries in `references/source-analysis.md` and the exclusions in `SKILL.md`; repair work does not authorize adding those techniques automatically.
