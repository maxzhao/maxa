# Change Workflow

Purpose: author behavior changes, publish verified independent formal contracts, and delete successfully promoted workspaces. Specification work does not require a task; future implementation planning follows `references/taskadmin-integration.md`. Keep unvalidated behavior separate from formal owners. Editorial-only corrections follow `SKILL.md`.

## Workspace

```text
.maxa/specs/changes/<change-id>/
├── proposal.md
└── specs/<capability>/spec.md
```

Use a stable ASCII `change-id`. Do not create `design.md` or `tasks.md` for new work.

## Workflow

1. Read existing stable specs, project rules, scoped knowledge and relevant code.
2. Define intent, in/out scope, affected capabilities, compatibility decision, risks and acceptance criteria.
3. Determine proposal/delta/stable-owner paths.
4. Create `proposal.md` from `assets/change-proposal-template.md`; no task identity is required.
5. Keep unresolved behavior questions in the proposal/deltas; resolve those affecting a later implementation plan before planning that work.
6. Apply `references/spec-authoring.md` and fill `assets/delta-spec-template.md` with ADDED/MODIFIED/REMOVED behavior statements; retain scenarios only when they add needed boundary or sequence detail.
7. Update required indexes/logs and record source traces.
8. Specification delivery does not authorize implementation. When implementation planning is requested, follow `references/taskadmin-integration.md`; an existing implementation task owns its plan/TODO/status.
9. For authorized acceptance/promotion, follow the ordered procedure below: reconcile changed rules/owners, reuse sufficient evidence, publish formal output, repair references and delete successful inputs. Do not polish unrelated specs or historical records.

Deliver the requested specification after its relevant checks; do not implement it to complete authoring. Pending required acceptance evidence keeps the change draft with the exact gap; use `review` for an existing implementation task when applicable. Do not add approval gates or defer authorized convergence that can be completed now.

## Proposal Boundary

Proposal owns:

- why the change exists;
- in/out scope and non-goals;
- affected behavior capabilities;
- compatibility/migration decision;
- behavior-level risks;
- acceptance criteria;
- source trace.

Proposal does not own technical implementation steps or TODO state.

## Delta Rules

Use the template's `ADDED Requirements`, `MODIFIED Requirements` and `REMOVED Requirements` sections; omit unused sections. Apply rule identity, full-replacement and format compatibility checks from `references/spec-authoring.md`. Proposal summaries point to delta rules instead of repeating them.

Before merge, resolve each modified/removed name against the stable owner; missing or multiple matches block that merge until identity is resolved. Add only new rules, replace only the named rule's complete behavior, and remove only the named obsolete behavior. Preserve unrelated content, valid inbound anchors and direct source/stable dependencies; formal execution associations are removed through `references/spec-authoring.md`. An explicit rename maps old to new and updates affected references.

Use delta specs for brownfield changes. Do not rewrite stable owners before implementation/validation convergence.

## Lifecycle Interpretation

| State | Action |
| --- | --- |
| `draft` | Proposed/unvalidated; never current stable behavior. |
| `accepted` | Read `merged_to` formal owners first; retained legacy/interrupted workspaces still require convergence and cleanup for an authorized promotion. |
| `rejected` | Do not implement unless explicitly revived. |
| `superseded` | Follow `superseded_by`. |

`validation.automated` and `validation.human` reflect actual evidence. Legacy `archive_state: retained` describes past storage, not a new retention obligation. Read-only inspection does not trigger cleanup.

## Acceptance And Promotion

Acceptance requires active references to resolve, implementation to match the changed contract where applicable, and the minimum evidence in `references/spec-authoring.md` to be satisfied. A task is not an acceptance prerequisite. Distinguish automated/live checks from human review; do not require separate test tracks or unrequested approval. Accepted fields, `merged_to` or task `done` alone do not establish semantic convergence.

For authorized promotion, execute in this order:

1. Read the complete selected proposal/deltas and corresponding formal rule units. Resolve every added/modified/removed identity; account for later reviewed replacements. Verify full conditions, permissions, outcomes, failure, ordering and limits, not just matching names. Reconcile directly affected secondary owners so obsolete clauses do not contradict the promoted behavior. Reuse valid implementation/validation evidence.
2. Merge verified behavior into formal owners, or record an explicit no-merge rationale in the required spec log. Apply the independent formal-output boundary in `references/spec-authoring.md`: remove execution/change associations while preserving behavior, source dependencies, acceptance and material evidence limits.
3. Repair current indexes and directly affected references, including existing implementation plans, to point to formal owners. Do not retain active links to inputs scheduled for deletion; mark retained task/log input paths explicitly historical.
4. Record concise acceptance, rule-to-owner mapping, supersession/removal/no-merge decisions, actual validation/review and cleanup scope in the required spec log. Update an existing implementation TODO only for its affected acceptance/recovery state. Temporary accepted frontmatter may retain `status: accepted`, `accepted_at`, `merged_to` and actual `validation` for interruption recovery; do not add task identity or `archive_state: retained` to new work.
5. Delete each successfully promoted `.maxa/specs/changes/<change-id>/` in full, including its proposal, deltas, indexes and legacy files. Do not move it to an archive directory or create a durable copy. Keep failed, pending, rejected, superseded or unselected workspaces unless their disposition is separately authorized and recorded. Remove the parent `changes/` and its routing-only index when no unpromoted workspace or other unselected content remains; update its index instead when work remains.
6. Run the smallest relevant rule/metadata/reference/consumer and whitespace checks; confirm selected inputs are absent and formal owners remain independently readable. This completes promotion; update an existing implementation task if its plan requires that convergence. Do not create a task to record promotion.

Already accepted/merged legacy workspaces use the same ordered cleanup after verifying actual coverage. Directly promoting a standalone draft uses the formal-output, evidence and check steps without requiring a new change workspace. Preserve original implementation tasks/logs; cleanup does not delete them or upgrade historical failed/partial/not-run results. Record a new user review at its actual scope/time.

## Failure Handling

- Missing existing implementation association: recover through `references/taskadmin-integration.md` only for work depending on that task. Task-free specification authoring/promotion and formal owners are valid.
- Unresolved behavior question: ask one targeted question or keep the change draft with an explicit open question.
- A required check failed/not run, including actual UI interaction blocked despite green tests: do not accept or merge stable specs unless the user explicitly accepts and records the specific unverified behavior/risk. Preserve the actual failed/not-run result. Use the Runtime UI Validation Boundary's bounded recovery/handoff, not substitute test authoring. Optional unrun checks do not create new acceptance gates.
- Missing coverage, unresolved rule identity or conflicting owners: retain affected inputs, repair the owning contract/evidence and recheck before deletion. Independent verified promotions may proceed within the authorized scope.
- Deletion/reference/check failure: report exactly what was published/deleted and the remaining work; preserve necessary recovery facts in the existing spec log, and an existing implementation TODO when affected. Do not claim promotion complete. Resume from remaining inputs/formal owners; do not recreate deleted proposals or create recording tasks.
- Spec/code/task drift: update the owning artifact before claiming convergence.
