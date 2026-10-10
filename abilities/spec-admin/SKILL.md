---
name: spec-admin
description: "Create, optimize, review, converge, and promote verifiable behavior specifications; keep specification authoring separate from TaskAdmin implementation planning."
compatibility: Requires Maxa Ability runtime.
---

# Spec Admin

Purpose: maintain complete behavior contracts for independent LLM readers in the fewest useful tokens. Preserve decisions, conditions, exceptions and explicit dependencies.

## Ownership And Stage Boundary

| Owner | Content |
| --- | --- |
| SpecAdmin | Draft/stable specs, proposals/deltas, requirements, scenarios, scope, observable acceptance, coverage/convergence reviews, lifecycle, indexes/logs. |
| TaskAdmin | Plans for future implementation, affected paths and technical decisions; execution TODO, necessary validation and recovery state. |

Specification discussion, authoring, revision, extraction, optimization and lifecycle maintenance do not create tasks. Persisting a spec is not implementation authorization. Keep unresolved behavior questions in the spec; do not label specification writing as an implementation task.

When implementation planning is requested, use `references/taskadmin-integration.md` to plan unperformed work from the relevant specs. Do not create tasks retrospectively to document completed work. Existing implementation tasks may update their necessary execution/validation state; this does not justify creating a recording task.

SpecAdmin does not create change-workspace `design.md` or `tasks.md`. TaskAdmin remains independently usable. Ordinary code development enters SpecAdmin only when the request or applicable workflow requires a behavior-spec operation.

## Authoring Entry

Before drafting or rewriting requirements, read `references/spec-authoring.md`. For requested optimization, also read `references/spec-optimization.md`.

A requested editorial-only correction, such as a typo or unambiguous ordinary link repair, may be applied directly without proposal/delta. Preserve behavior, rule identity/anchors, evidence, lifecycle and existing implementation associations. If meaning is uncertain, use the behavior-change workflow. Check only corrected content and affected references.

## Scenario Router

| Scenario | Read | Output |
| --- | --- | --- |
| New draft/stable spec | `references/spec-authoring.md` | Independent behavior contract from `assets/spec-template.md`. |
| Behavior change or promotion | `references/change-workflow.md` | Proposal/deltas, verified formal merge and successful-workspace cleanup. |
| Optimize existing specs | `references/spec-authoring.md`, `references/spec-optimization.md` | Equivalent contracts, complete target inventory, measured savings and checks. |
| Editorial correction | Authoring Entry above | Local correction and affected-reference check. |
| Plan, recover or converge implementation tasks | `references/taskadmin-integration.md` | Executable future implementation plan or scoped recovery/convergence. |
| Ambiguity, coverage or code-spec review | `references/analysis-and-convergence.md` | Scoped findings. |
| Brownfield extraction | `references/bootstrap-from-code.md` | Evidence-backed draft and explicit coverage limits. |

Templates: `assets/spec-template.md`, `assets/change-proposal-template.md`, `assets/delta-spec-template.md`, `assets/coverage-audit-template.md`.

## Change Workspace

```text
.maxa/specs/changes/<change-id>/
├── proposal.md
└── specs/<capability>/spec.md
```

Unvalidated changes SHALL NOT overwrite stable specs. Drafts/proposals/deltas need no task identity; existing implementation associations follow `references/taskadmin-integration.md`. Formal specs remain independent of execution associations.

Legacy `design.md`/`tasks.md` are historical evidence, not workflow inputs or templates. Successful promotion removes the selected workspace in full through `references/change-workflow.md`.

## Lifecycle Frontmatter

- `status: draft`: proposed/unvalidated; not current stable behavior.
- `status: accepted`: read `merged_to` formal owners first; interrupted/legacy promotion still needs scoped convergence and cleanup.
- `status: rejected`: do not implement unless explicitly revived.
- `status: superseded`: follow `superseded_by`.
- `validation.automated|human`: preserve actual `passed|failed|not-run` evidence.
- `archive_state: retained`: legacy provenance, not the policy for new successful promotions. Read-only inspection never deletes it.

`references/change-workflow.md` owns acceptance and cleanup; accepted fields or task status alone do not prove convergence.

## Operating Rules

1. Inspect authorized specs, applicable rules and needed source/consumer evidence before writing. Optimization uses the complete inventory in `references/spec-optimization.md`.
2. Keep behavior in specs and future implementation steps in task plans; do not copy spec bodies into TODO or execution logs into specs.
3. Use delta specs for brownfield behavior changes; preserve stable owners until required validation/convergence.
4. Preserve exact governed terms, paths, schema keys, rule identities, evidence and lifecycle values.
5. Before acceptance, reconcile changed requirements, directly affected stable owners, implementation and actual validation; inspect existing task evidence when relevant.
6. Formal output follows `references/spec-authoring.md`; durable `.maxa/` writes follow the Vault/index/log contract.
7. For missing/nonstandard `.maxa/specs/`, load `project-admin` before proposing structure changes.
8. Keep extraction, review, fixes and convergence within requested semantics and direct dependencies. Do not add optional audits, approval gates, reports or polishing.

## Completion

Complete specification work when requested artifacts, affected references/indexes/logs and required checks are current. Deliver the specification and unresolved questions without creating a task or implementing it merely to close the authoring stage. Pending acceptance keeps unaccepted changes draft; state the exact evidence/review gap.

Optimization completes through `references/spec-optimization.md`. Promotion completes only after verified formal merge (or an explicit no-merge rationale), independent formal output, current reference repair and successful-workspace deletion/checks through `references/change-workflow.md`.

If an existing implementation task requires this convergence, update it and satisfy its completion gate before `done`; otherwise no task is needed. Do not create a task to record completed authoring, validation or promotion.
