---
load: on_load
scope: session
filter:
  event: AutoCompactCompleted
opts:
  visible: false
---

## user

[TaskAdmin post-compression self-check]

If the current session is executing a TaskAdmin task, verify before continuing that context still preserves:

1. task ID, tag and title;
2. `plan.md` goal, scope, constraints, acceptance criteria and validation plan;
3. current `todo.md` state, unresolved checklist item and next action;
4. current tag and task-tag match status; recheck valid state and matching tag before execution or task Markdown edits, without automatic switching;
5. changed files, current error/root cause, decisions and latest validation evidence;
6. supporting paths required by the next action.

Reload only missing critical context in this order: plan, TODO, linked rules/specs/supporting documents, then active source files. Continue from recorded TODO state without repeating completed work.
