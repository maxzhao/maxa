# TaskAdmin Execution Protocol

Purpose: execute a resolved task workspace with recoverable TODO state, complete lifecycle events and validated completion.

## Entry Checks

1. Resolve the integer task ID with `resolve_task.py`, `next_task.py` or `list_tasks.py`; use returned paths.
2. Read valid `state.yaml` and confirm its current tag has a directory and `_meta.yaml`. Before execution/continuation or task Markdown edits, require the resolved task tag to equal `currentTag`. Stop on mismatch/invalid state; require explicit tag selection and never switch automatically. Cross-tag queries are inspection only.
3. Read `plan.md`, then current `todo.md`, then only supporting paths explicitly needed by them. TaskAdmin does not interpret workspace declarations or load/check external environments; caller-owned environment constraints remain outside this protocol.
4. Confirm task dependencies are done and task status is executable (`pending`, `in-progress` or `review`).
5. Select the smallest sufficient checks for this change under `Validation Strategy` below; reuse existing coverage rather than planning separate validation tracks by default.
6. Internally confirm scope, acceptance criteria, current TODO, validation and blockers. Ask only for a concrete unresolved decision or required external action.

## Lifecycle Events

| Event | Required payload | Owner |
| --- | --- | --- |
| `TaskPhaseChanged` | `task_id`, `tag`, `title`, `phase` | Execution Agent only, on meaningful phase change |
| `TaskStatusChanged` | `task_id`, `tag`, `title`, `prev_status`, `new_status` | `update_task.py`, after a successful status update |
| `TaskStarted` | `task_id`, `tag`, `title` | `update_task.py`, after `TaskStatusChanged` when the status changes to `in-progress` |
| `TaskCompleted` | `task_id`, `tag`, `title` | `update_task.py`, after `TaskStatusChanged` when the status changes to `done` |

Execution Agents must not fire `TaskStarted` or `TaskCompleted` directly. For an actual transition, `update_task.py` emits `TaskStatusChanged` first and then the derived event. Assigning the current status again emits no derived event. `bufnr` is framework-injected; do not fire partial payloads.

## TODO Recovery State

`todo.md` is overwrite-written recovery state. Read it before replacing it and preserve the complete current body.

Update it only after changes affecting recovery or required acceptance, not after every tool call. Keep existing-task progress, not a retrospective work log; never create a task merely to store these results. Retain relevant fields only:

- completed/unresolved checklist items;
- current phase and next action;
- changed files;
- checks actually run, their covered behavior and results; cite evidence once when a check serves both primary validation and regression;
- current errors/blockers;
- decisions/findings affecting remaining work;
- paths/hypotheses not to re-explore.

Do not turn TODO into a narrative log or duplicate report. Omit empty optional sections; preserve exact paths, commands, task IDs, errors and necessary validation evidence.

## Implementation And Validation

- Stay inside user-authorized plan scope and the owning module boundary. Implement the minimum sufficient change; report unrelated findings without fixing them or adding TODOs on the user's behalf.
- For an implementation task, execute the selected approach; do not add open-ended research, investigation or option-selection TODOs that should have been resolved before task creation.
- Follow explicit external references; search additional knowledge only for a real context gap.
- If new evidence invalidates the plan, stop work that depends on the false premise, record the exact evidence/blocker in TODO, complete the necessary analysis, and revise the plan plus executable TODO before resuming. This recovery path does not make placeholder exploration valid at creation time.
- Bounded runtime reproduction, diagnosis and rechecking the selected behavior are normal implementation work, not deferred open-ended research. If observations invalidate the approach, use the plan-recovery rule above.
- Apply `Validation Strategy` below after behavior-affecting changes; rerun affected checks after follow-up fixes.

## Validation Strategy

This section owns method selection and recovery for task planning/execution under the Runtime Validation Contract. Choose the smallest sufficient check set for the changed behavior and applicable acceptance requirements. **Primary validation** checks the current change; **regression protection** protects the affected stable behavior. These are evidence purposes, not two mandatory test suites: one focused check may serve both and is recorded once.

| Behavior Surface | Minimum Relevant Check |
| --- | --- |
| UI, visual state or interaction | Follow the Runtime UI Validation Boundary: operate the actual app through the affected user path, diagnose with relevant code/logs, make the smallest fix and repeat that interaction. Use existing UI tools; for Tauri, load `browser`. Do not choose component/logic tests as a substitute or write test/diagnostic scripts without the authorization required by that boundary. |
| API, CLI or runtime integration | Use an existing focused contract/integration test or invoke the affected entrypoint. Require a live call only when acceptance or the specific boundary risk needs it. Mocks do not prove live integration. |
| Pure deterministic logic | Use existing focused tests or representative direct inputs covering the change and its relevant failure boundary. Do not invent a runtime/UI workflow. |

Passing builds, lint, unit tests or mocks must not be described as actual UI interaction or live integration. State coverage limits accurately without converting every untested surface into a mandatory gate. Preserve explicit project/user acceptance requirements. UI test-code work is authorized only by the Runtime UI Validation Boundary, not by this plan, a coverage gap or generic regression guidance. For non-UI work, add regression cases only for concrete material risks not covered by existing checks. Do not pursue exhaustive coverage or run full-project suites unless the user or applicable mandatory acceptance rules require them.

### Reproduce, Diagnose, Recheck

1. Use authorized environments/test data; checks do not authorize destructive or production-changing actions beyond scope.
2. For a UI bug, reproduce through the actual application's affected user path, not a test harness. For other bugs, use the smallest useful reproduction through an existing test or entrypoint. Record relevant preconditions and actual versus expected result; never invent an observation.
3. Diagnose using relevant code/state/logs as needed. A screenshot or failing test alone does not establish root cause.
4. Recheck the affected behavior after the fix. Expand to adjacent/error paths only for a concrete impact or failure; after further edits, rerun only affected checks. A short observation or test result normally suffices; collect screenshots/logs only when needed to establish the result.
5. Once required checks pass, stop. Do not append testing, review, refactoring or documentation rounds for extra reassurance.

### Evidence And Blockers

In TODO, record each distinct check's covered behavior, method/target or exact command, expected/actual result and any material gap. Link artifacts only when they add necessary evidence. Do not relabel an unrun/failed required check as passed or treat tool execution as human approval.

For an unavailable required target/tool, use bounded authorized recovery or an available equivalent tool observing the same behavior. For UI work, tests/mocks are not an equivalent substitute for actual interaction; do not build diagnostic scripts, sample apps or an automation environment to fill that gap. If still blocked, record the exact attempt/error, missing coverage and next action; request necessary assistance or hand over the scoped result explicitly unverified. Do not repair unrelated environments. Preserve any user-accepted exception and its actual failed/not-run status.

## Completion Gate

Before requesting `done`, the Execution Agent SHALL verify:

- required TODO items are complete or have an explicit user-authorized exception;
- acceptance criteria are met;
- the selected minimum required checks ran and passed, or an explicit user-authorized exception records the exact unverified behavior and risk;
- any claim of UI validation passing has actual interaction evidence, not a green build/test suite alone; a user-accepted exception remains explicitly unverified;
- required external convergence named by the plan (for example stable-spec merge) is complete;
- TODO records final changed files, evidence and residual risk.

After the scoped implementation, minimum required checks and necessary state/convergence updates, deliver immediately for user review. If all gates above are met, mark `done`; if required user acceptance, validation or convergence remains pending, use `review` with the exact gap and deliver the available result without claiming completion. User inspection is not an extra approval gate unless explicitly required. Do not add optional work to reach a more polished handoff or defer already-authorized required work that can be completed now.

`update_task.py` validates metadata and emits status plus derived lifecycle events; it does not parse Markdown checkboxes. The Agent owns this completion gate.
