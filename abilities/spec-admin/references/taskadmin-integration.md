# TaskAdmin Integration

Purpose: turn specifications into plans for future implementation, not tasks that record specification authoring. `SKILL.md` owns the stage boundary.

## Ownership

| Owner | Content |
| --- | --- |
| SpecAdmin | Behavior, scope, requirements/scenarios, observable acceptance and spec lifecycle. |
| TaskAdmin `plan.md` | Selected implementation approach, affected paths, sequence, risks and minimum validation. |
| TaskAdmin `todo.md` | Execution checklist, current state, necessary check results, blockers and next action. |

SpecAdmin defines expected acceptance observations. `#task-admin[/references/execution-protocol.md]` owns check selection, recovery and result recording; one check may serve acceptance and regression. Formal specs retain the contract and material coverage limits without execution logs or task links.

## Implementation Planning

Only when future implementation planning is requested:

1. Read the relevant specs and current code; resolve behavior questions affecting the planned scope. Drafts may be planning inputs, but do not authorize implementation or become stable behavior.
2. Load `task-admin` and follow its creation guide. Search for an existing task matching the remaining implementation outcome, scope and exact spec paths; a shared formal path alone is not a match.
3. Reuse one matching task. If none exists, prepare an executable plan/TODO for unperformed work and create a task. Multiple matches require ownership repair before publication. Keep cohesive implementation together; split only independently deliverable outcomes, not implementation/validation/promotion phases by default.
4. Reference exact authoritative spec paths in the plan; do not copy spec bodies. Include formal merge/cleanup only when required by this implementation's authorized scope.

Do not create a task for completed work or only to store authoring/review evidence. Original completed implementation tasks remain historical evidence, not owners of every later spec edit.

## Association And Recovery

The implementation plan owns the canonical association:

```markdown
## Spec References

- Proposal/change: `.maxa/specs/changes/<change-id>/proposal.md`
- Delta specs: `.maxa/specs/changes/<change-id>/specs/<capability>/spec.md`
- Stable owners: `.maxa/specs/<owner>.md`
```

Include only applicable paths. New spec artifacts need no reciprocal task fields. Existing temporary `taskadmin_tag`/`taskadmin_id` are legacy hints: resolve the cached identity and verify exact plan paths and implementation scope before relying on it. Never infer association from an integer ID alone. Formal absence of task identity is valid.

For requested recovery of an existing implementation association, search plans by exact paths and implementation scope if cached identity is stale. One match recovers it; multiple matches block pending ownership repair. A missing previously linked task blocks only work that depends on that task; restore it or obtain explicit authorization for a replacement covering remaining work. Do not recreate authoring-only tasks or block independent specification edits merely because a task is absent.

Task execution/edits still require TaskAdmin current-tag checks. Move/renumber/tag changes may stale cached identity. After promotion, recover from formal owners and existing implementation state; mark deleted input paths historical and never recreate them for link symmetry.

## Implementation And Convergence

1. Execute through the existing implementation plan/TODO; record only state/evidence needed for recovery and acceptance.
2. Deliver after minimum required checks and state updates. Pending required user review/evidence keeps the task `review` and unaccepted changes draft, with the exact gap.
3. For authorized promotion, follow `references/change-workflow.md`; reuse valid evidence, reconcile affected owners and repair active plan references before deleting successful inputs.
4. If the implementation plan requires convergence/cleanup, complete it before `done`. Task status never establishes spec acceptance by itself; TaskAdmin does not interpret spec lifecycle.

Specification-only work finishes against its own requested deliverable and checks. Record required spec maintenance in existing indexes/logs and report the result directly; task creation is not a completion or evidence requirement.
