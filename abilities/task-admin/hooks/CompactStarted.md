---
load: on_load
scope: session
opts:
  visible: false
---

## user

[TaskAdmin compression supplement]

If this session is executing a TaskAdmin task, preserve the smallest complete execution skeleton:

- task ID, tag and title;
- task `plan.md` goal, scope, constraints, decisions, acceptance criteria and validation plan;
- current `todo.md` phase, completed/unresolved items, next action and paths not to re-explore;
- current tag and task-tag match status;
- changed files, current error/blocker, latest valid validation result and residual risk;
- supporting document paths still needed by the next action.

TaskAdmin execution signals include reading/writing a task workspace, calling TaskAdmin scripts, or emitting Task lifecycle events. If no signal exists, ignore this supplement.

Compress stale discussion, repeated reads, large logs and resolved failed attempts before active plan/TODO state. Do not introduce parent/subtask state.
