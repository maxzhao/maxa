---
title: <Chinese semantic title>
created: YYYY-MM-DD
updated: YYYY-MM-DD
doc_role: coverage-audit
authority: draft
status: experimental
sources: []
confidence: medium
---

# Behavior Coverage Audit: <capability or extraction scope>

<!-- Scoped review evidence, not a formal behavior spec or task. Formal contracts retain necessary source coverage and gaps directly. -->

## Scope

- Target specs: <paths>
- Source behavior scope: <API/UI/CLI/runtime surfaces, not file inventory>
- Out of scope: <excluded behavior>

## Coverage

<!-- Follow references/bootstrap-from-code.md for dimensions and completion rules. Group dimensions only when they share coverage status and evidence; record n/a rationale and unknowns explicitly. Remove comments before publishing. -->

| Surface / Dimension | Status | Contract Reference | Evidence / Check Or Gap |
| --- | --- | --- | --- |
| <behavior surface / dimension(s)> | <covered / partial / missing / n/a> | <spec path + rule names> | <source + check, missing behavior, or n/a rationale> |

## Findings And Required Actions

- [<critical / high / medium / low>] <missing behavior / ambiguity / conflict / validation gap / source-evidence gap>: <finding>; evidence: <path + rule/symbol>; action: <owning artifact and fix>.

## Validation / Review

- <rule/group or finding> — <primary / regression>: <behavior surface and validation method> → <expected / actual observation>; evidence: <existing check/review source>; gaps: <required evidence still missing, if any>.

## Open Questions

<!-- Omit when empty; do not drop questions that block coverage or promotion. -->
- <question and affected behavior>.

## Promotion Readiness

- Status: blocked|partial|ready-for-review|ready-for-normative-promotion
- Blocking gaps: <items>
