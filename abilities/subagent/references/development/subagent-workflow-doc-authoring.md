# SubAgent Workflow Document Authoring

Purpose: write reusable SubAgent / multi-agent workflow instructions. Output must be a workflow blueprint, not a task log.

## Applicability

Use when the user asks to solidify an execution pattern involving supervisor agents, execution agents, repair agents, reviewers, multi-agent discussion, staged processes, loops, or reusable handoff prompts.

## Output Goals

- Start with a navigable summary: who acts first, who acts next, where loops return, and when the flow stops.
- Preserve roles, stages, handoff conditions, loop/stop conditions, prohibitions, and prompt templates.
- Keep implementation details, one-off task state, validation logs, and tool schema tables out unless the workflow depends on them.
- Make the document executable by a future Agent with fresh context.

## Recommended Structure

1. Title and applicability.
2. Flow summary.
3. Role structure.
4. Role responsibilities and boundaries.
5. Start/resume entrypoints.
6. Staged flow.
7. Loop and stop conditions.
8. Prohibitions.
9. Prompt templates.
10. References.

## Flow Summary Rules

- Use numbered steps.
- Each step says: actor -> action -> next actor/step.
- If a loop exists, write “return to step N”.
- Keep summary skeletal; move rules to stage sections.
- Add section references where useful, e.g. “see Stage 2”.

## Role And Stage Rules

- For each role, define responsibility, boundary, allowed delegation, and output.
- For each stage, define input, actor, action, output, next step, and failure path.
- If repair/review/exploration agents exist, state exact handoff conditions.
- If the same actor continues, write “return to step N” rather than inventing a new role.

## Constraint Rules

- Stable constraints first; variable task inputs second.
- Keep only constraints required by this workflow.
- Do not copy tool signatures, complete parameter tables, or implementation internals.
- Do not write development logs, validation records, or task progress.
- Preserve exact tool names, role names, files, commands, status labels, stop conditions, and prompt templates.

## Template

```markdown
# [Workflow Name]

> Applicability: ...

## Flow Summary
1. ...
2. ...
3. ...

## Role Structure
...

## Stage 1: ...
- Input:
- Actor:
- Action:
- Output:
- Next:
- Failure path:

## Loop And Stop Conditions
...

## Prohibitions
...

## Prompt Templates
...

## References
...
```

## References

- SubAgent selection and operation rules: `SKILL.md`.
- SubAgent implementation details: `references/architecture.md`.
