# Analysis And Convergence

Purpose: analyze behavior specs, proposals, implementation, linked TaskAdmin evidence and validation for ambiguity, coverage gaps and divergence.

## Inputs

Read only relevant artifacts:

- stable spec;
- change proposal/delta specs;
- implementation diff/source;
- linked TaskAdmin plan/TODO/status;
- validation output;
- lifecycle/index/log state.

Analysis and authorized specification repairs do not create tasks. Future implementation planning follows `references/taskadmin-integration.md`; existing task evidence is an input only when relevant.

## Detection Passes

Select only dimensions relevant to the requested change and its direct contract/reference impact; this list is not an unconditional audit checklist. Stop when the scoped question is answered. Review whole modules/spec collections only when requested; report material out-of-scope findings without repairing them or expanding acceptance.

1. Duplication/conflict between requirements.
2. Ambiguous actors, triggers, outcomes or success criteria.
3. Missing normal behavior, edge/failure, data, permission, external-dependency, concurrency/idempotency or validation behavior.
4. Source coverage cited without behavior requirements/scenarios.
5. Proposal/delta/stable-spec inconsistency.
6. Implementation divergence from accepted behavior.
7. Task plan/TODO/validation missing required implementation coverage.
8. Lifecycle fields that misroute current behavior.
9. Stale existing implementation associations; task-free drafts, proposals and formal output are valid.
10. Index/log/source-trace/reference integrity.
11. Semantic drift across consumers of one normative fact.
12. Lost or invented conditions, actors, negations, exceptions, priority, numeric boundaries, side effects or obligation strength after compacting; compare meaning, not line count.
13. Duplicate rule names, dangling heading references or format changes incompatible with the actual consumer.
14. Validation method/evidence mismatched to the behavior surface: for example UI acceptance supported only by green scripts/mocks, or an unrun primary check hidden by passed regression checks. Apply `Acceptance Evidence` in `references/spec-authoring.md`.

Accept compact statements and legacy scenarios under `references/spec-authoring.md`; a testable statement needs no redundant GIVEN/WHEN/THEN restatement. Check applicable behavior dimensions, not mandatory headings or document length.

Build only a bounded reference graph from declared links and repository routing. Each normative fact has one owner; shared keywords alone do not create an edge.

## Output

```markdown
### Spec Analysis
- Scope: <artifacts reviewed>
- Status: pass | needs changes | blocked
- Findings:
  - [critical|high|medium|low] <issue or coverage gap> — evidence: <path + rule/section>; action: <owning artifact and fix>
- Validation / next check:
  - <rule/group> — <primary / regression>: <interaction or check> → <expected observation>; <missing evidence, if any>
```

Severity:

- Critical: behavior cannot be safely implemented or validation would be misleading.
- High: likely implementation/coverage error.
- Medium: missing edge or unclear requirement.
- Low: traceability/maintainability issue.

## Convergence Rule

Do not claim convergence unless:

- proposal/delta/stable requirements and scenarios agree;
- implementation satisfies accepted behavior;
- an existing implementation task's plan/TODO/status reflects actual work when relevant;
- the selected minimum required evidence matches the changed behavior and results are accurate; one check may cover both primary validation and regression;
- lifecycle fields and indexes/logs are current;
- any existing implementation association used as evidence resolves through exact plan references; formal owners have no reciprocal execution association.

Accepted fields or task completion alone do not prove convergence. Verify changed and directly affected owners, including later supersession, before using `references/change-workflow.md` for formal publication and successful-workspace deletion. Temporary `merged_to` points to current owners; retired input paths in task/log evidence are explicitly historical.

For UI appearance/interaction, apply the Runtime UI Validation Boundary through the TaskAdmin strategy: missing actual interaction remains a gap regardless of test-suite status, and a review finding does not authorize test-code development. Tool-driven checks do not establish `validation.human: passed`; only actual recorded human review does, and `not-run` does not itself require such review. Use the change workflow for explicit risk acceptance without relabeling missing/failed checks as passed. Formal output follows `references/spec-authoring.md` rather than absorbing execution history.
